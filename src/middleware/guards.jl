module GuardsMiddleware

using HTTP
using ...Core: getsession
using ...Types: Nullable, Principal, _is_identity
using ...Util: _check_denial_factory, _deny

export GuardMiddleware, login_required, role_required, permission_required,
	claim_required, kid_required

# Shared denial response for authorization guards. Module-level `const` Responses are
# reuse-safe in Nitro (non-consuming write path, see nitro-core §4), so denials are
# allocation-free. Contract: 401 = unauthenticated (auth middleware), 403 = authenticated
# but not authorized (guards), 302 = browser redirect (`login_required`). That contract is the
# default: every guard takes a `denied` factory (#515), and an app whose clients only handle a
# `401` may answer a wrong-`kid` token with one. `_deny` checks what the factory returns, so a
# factory that answers no response is an error at the factory, not a mystery at the guard.
const FORBIDDEN = HTTP.Response(403, "Forbidden")

# The default `denied` of the claim and kid guards.
_forbidden(::HTTP.Request, ::Symbol) = FORBIDDEN

"""
    GuardMiddleware(guards::Function...)

Turn authorization guards into a route or global middleware. Each guard is a
`req -> Union{Nothing, HTTP.Response}`: `nothing` admits the request, and a response denies it
and is returned as-is. Guards run in order and the first denial short-circuits the rest and the
handler.

**Any other result is an error, never an admission.** A guard that returns `false`, a `Dict`, a
status code or a message throws an `ArgumentError` naming the guard and the result's type. The server
answers that with a `500`, and the handler does not run:

```julia
only_admins = req -> getuser(req)["role"] == "admin"                     # ✗ `false` is a 500
only_admins = req -> getuser(req)["role"] == "admin" ? nothing :
                     Res.json(Dict("error" => "forbidden"); status = 403) # ✓
```

```julia
path("/admin/reports", reports;
     middleware = [BearerAuth(Auth.jwt_validator(secret)), GuardMiddleware(login_required(), role_required("admin"))])
```

The shipped guards are [`login_required`](@ref), [`claim_required`](@ref) and its aliases
[`role_required`](@ref) and [`permission_required`](@ref), and [`kid_required`](@ref). Any
function of the same shape is a guard. Guards authorize, they do not authenticate: put the auth
middleware that sets `getuser(req)` **before** this layer.

The status contract: an auth middleware answers `401` for no or bad credentials, the claim guards
answer `403` for an authenticated caller without the right, and `login_required` answers a `302`
browser redirect. Those are defaults. Each shipped guard takes `denied`, a factory
`(req::HTTP.Request, reason::Symbol) -> HTTP.Response` called with `:forbidden` (the claim and
kid guards) or `:login_required` (`login_required`); it follows the same rules as the auth
middleware's `unauthorized` (see
[`BearerAuth`](@ref Nitro.Core.Middleware.AuthMiddleware.BearerAuth)). A factory that returns
anything but an `HTTP.Response` is an error, not an admission.
"""
function GuardMiddleware(guards::Function...)
	return function(handle::Function)
		return function(req::HTTP.Request)
			# A counter, not `enumerate`: over a tuple of five or more distinct closures,
			# `enumerate` allocates per request where the plain loop did not.
			position = 0
			for guard in guards
				position += 1
				result = guard(req)
				result === nothing && continue
				result isa HTTP.Response && return result
				_refuse_guard_result(position, guard, result)
			end
			return handle(req)
		end
	end
end

# Fail closed (#519): the same rule `_deny` applies to a denial factory, applied to every guard.
# A guard that "denies" with `false`, a `Dict` it meant to serialize, a status `Int` or a message
# `String` used to ADMIT the request. Now it is an error, which the server answers with a 500; the
# handler never runs. The message names the guard and the result's type NAME only -- the value is
# whatever the application put in it, and a full type can carry a value as a parameter
# (`Val{secret}`), so `nameof(typeof(result))` rather than `typeof(result)`.
@noinline function _refuse_guard_result(position::Int, guard::Function, result)
	throw(ArgumentError("GuardMiddleware: guard #$position ($(nameof(guard))) returned a " *
	                    "$(nameof(typeof(result))); a guard must return `nothing` to admit the request " *
	                    "or an `HTTP.Response` to deny it"))
end

# Claims resolution for the claim guards. Mirrors `_request_kid`'s two-slot lookup: a
# `user_validator` parks the app's user object at `:user` and the verified `Principal` at
# `:auth_claims`, so reading only `:user` denies a correctly-authenticated request (#24).
#
# The precedence is deliberate and asymmetric. If the app's user object is READABLE as
# claims it is authoritative, and an absent claim means denial — a token's `role=admin` is
# verified but STALE, while an app dict that dropped the key after a demotion is fresh.
# Only when the app user is not a claims source at all do we fall back to the token's
# verified claims. An app that wants token claims honored merges them into the object its
# `user_validator` returns.
function _request_claims(req::HTTP.Request, session_key::String)::Nullable{AbstractDict}
	user = Base.get(req.context, :user, nothing)
	user isa AbstractDict && return user          # incl. `Principal`

	claims = Base.get(req.context, :auth_claims, nothing)
	claims isa AbstractDict && return claims

	# `:user` is the vouching slot: if an auth middleware put a non-claims identity there,
	# the raw session is not a claims source for that identity, so deny rather than fall
	# back. A non-dict `:auth_claims` alone does NOT gate the fallback — nothing vouched.
	user === nothing || return nothing

	# The raw session is app data, not an authentication: it is a claims source only while
	# it carries the login marker `login_required` checks (#337). A logout that deletes or
	# nulls `session_key` but leaves `role` behind must not stay authorized as that role.
	session = getsession(req)
	session isa AbstractDict || return nothing
	return _is_identity(_session_marker(session, session_key)) ? session : nothing
end

# The login marker of a raw session: `session_key` as a String key, else as a Symbol key.
# Shared by `login_required` and the claim guards so they cannot disagree about who is
# logged in.
_session_marker(session::AbstractDict, session_key::String) =
	haskey(session, session_key) ? session[session_key] :
		Base.get(session, Symbol(session_key), nothing)

# `login_required`'s denial factory: the app's `denied`, else the redirect. Resolved in a function
# rather than in branches of the guard factory, so the closure captures a variable assigned once
# (a branch-assigned capture is boxed -- `test/closure_boxing_tests.jl`).
function _login_denial(redirect_url::Nullable{String}, denied)
	if denied === nothing
		location = redirect_url === nothing ? "/login" : redirect_url
		# Built per request: nothing about a redirect needs to be a shared `const`.
		return (::HTTP.Request, ::Symbol) -> HTTP.Response(302, ["Location" => location])
	end
	redirect_url === nothing || throw(ArgumentError(
		"login_required: pass `redirect_url` or `denied`, not both — `denied` replaces the redirect"))
	return _check_denial_factory(denied, :denied)
end

"""
    login_required(; redirect_url = "/login", session_key = "user_id", denied = nothing)

Guard that admits an authenticated request and otherwise answers `302` with
`Location: redirect_url`. It is a factory, so call it: `GuardMiddleware(login_required())`.

Pass `denied` — a factory `(req, reason) -> HTTP.Response`, called with `:login_required` — to
answer something other than a redirect, e.g. a JSON `401`. It replaces the redirect, so passing
both `denied` and `redirect_url` is an `ArgumentError`.

A request counts as authenticated in one of two ways, and they are trusted differently:

1. **An auth middleware set `req.context[:user]`** (`BearerAuth`, `CookieAuthMiddleware`, or your
   own). The identity is trusted as-is, whatever its shape, so a JWT principal without a
   `user_id` passes. What is refused is a value that is no identity at all: a `Bool`, `""`,
   `missing`, or an empty dict — the same set the auth middleware answers with a `401`.
2. **Otherwise, the raw [`getsession`](@ref) dict**, which must carry `session_key` with an
   identity as its value. An anonymous visitor accumulates session data too (a cart, a CSRF
   token), so a non-empty session alone is not a login — and neither is a logout that set
   `session["user_id"] = nothing` rather than deleting the key.

`login_required` checks *that* someone is logged in, not *what* they may do. Stack
[`claim_required`](@ref) or [`role_required`](@ref) after it for that. For a JSON API a redirect
is usually the wrong answer; an auth middleware's own `401` already covers the anonymous case.
"""
function login_required(; redirect_url::Nullable{String}=nothing, session_key::String="user_id", denied=nothing)
	deny = _login_denial(redirect_url, denied)
	return function(req::HTTP.Request)
		# Two distinct sources of "user", which must be trusted differently:
		#
		#   1. `req.context[:user]` set by an auth middleware (BearerAuth /
		#      CookieAuthMiddleware / a SessionAuthMiddleware) — the request has
		#      ALREADY been authenticated, so trust the identity as-is. It need not
		#      contain `session_key` (a JWT-claims identity is keyed by `sub`, not
		#      `user_id`), and it may be a struct rather than a Dict.
		#
		#   2. The raw `getsession(req)` dict, used only as a fallback when no middleware
		#      set `:user`. This is NOT an authenticated identity — an anonymous
		#      visitor accumulates session data (e.g. a cart) — so it counts as
		#      logged in only when it carries the login marker (`session_key`).
		#
		# Conflating the two (admitting any non-empty dict) is the auth bypass fixed
		# here; requiring `session_key` on source 1 would instead lock out legitimate
		# token-authenticated users.
		#
		# Both sources go through `_is_identity` (src/types.jl), the predicate the auth
		# middleware rejects with (#313). A `:user` that is set but is no identity — `false`
		# from a predicate validator, `""`, an empty dict — is a denial, NOT a fall-through to
		# the session: something vouched, and what it vouched for is nobody.
		ctx_user = Base.get(req.context, :user, nothing)
		if ctx_user !== nothing
			_is_identity(ctx_user) && return nothing
			return _deny(deny, req, :login_required)
		end

		session = getsession(req)
		if session isa AbstractDict
			_is_identity(_session_marker(session, session_key)) && return nothing
		end
		return _deny(deny, req, :login_required)
	end
end

"""
    claim_required(claim, value; kind=:equals, session_key="user_id", denied=<403 Forbidden>)

Declarative authorization guard on a claim of the request principal: 403 unless the
principal's `claim` matches `value`. `denied`, a factory `(req, reason) -> HTTP.Response` called
with `:forbidden`, replaces that `403` (see [`GuardMiddleware`](@ref)).

- `kind = :equals` — the claim's value must `==` `value` (e.g. a role or action claim).
- `kind = :contains` — the claim must be a list containing `value` (e.g. permissions/scopes).

The claims are resolved in three steps: `req.context[:user]` when an auth middleware set
something dict-like there (a `Principal`, or your own claims dict); otherwise the verified
`Principal` at `req.context[:auth_claims]`, which is where a `user_validator`'s token claims
ride; otherwise the raw `getsession(req)` dict, for session-based apps — but only while it
carries the login marker `session_key` with an identity as its value, the same test
[`login_required`](@ref) applies. A logged-out session that kept its `role` authorizes
nothing. A non-dict `:user` (a plain user struct with no accompanying claims) denies rather
than falling through to the session. `role_required` and `permission_required` are thin
aliases over this guard.

!!! warning "A struct user authorizes off the token, not off your lookup"
    Those first two steps decide how fast a revocation takes effect. A dict-like `:user` is
    authoritative — an absent claim denies, so a demotion applies on the next request. A
    struct `:user` is not a claims source, so the guard reads the token's claims instead:
    verified, but issued in the past and never re-checked against your `user_validator`'s
    result. A demoted user keeps what the token says until it expires. Return a dict merging
    your fresh state if revocation must take effect within the token TTL.
"""
function claim_required(claim::String, value; kind::Symbol=:equals, session_key::String="user_id", denied=_forbidden)
	_check_denial_factory(denied, :denied)
	if kind === :equals
		return function(req::HTTP.Request)
			claims = _request_claims(req, session_key)
			if claims === nothing || get(claims, claim, nothing) != value
				return _deny(denied, req, :forbidden)
			end
			return nothing
		end
	elseif kind === :contains
		return function(req::HTTP.Request)
			claims = _request_claims(req, session_key)
			container = claims === nothing ? nothing : get(claims, claim, nothing)
			if !(container isa AbstractVector) || !(value in container)
				return _deny(denied, req, :forbidden)
			end
			return nothing
		end
	end
	throw(ArgumentError("claim_required kind must be :equals or :contains, got $(repr(kind))"))
end

"""
    role_required(role; role_key = "role", session_key = "user_id", denied = <403 Forbidden>)

Guard that answers `403` unless the principal's `role_key` claim equals `role`. Exactly
`claim_required(role_key, role; kind = :equals, session_key, denied)`; see [`claim_required`](@ref) for
where the claims are read from, when the session counts, and how fast a revocation takes effect.
"""
role_required(role::String; role_key::String="role", session_key::String="user_id", denied=_forbidden) =
	claim_required(role_key, role; kind=:equals, session_key, denied)

"""
    permission_required(permission; permissions_key = "permissions", session_key = "user_id", denied = <403 Forbidden>)

Guard that answers `403` unless the principal's `permissions_key` claim is a list containing
`permission`. Exactly `claim_required(permissions_key, permission; kind = :contains, session_key, denied)`;
see [`claim_required`](@ref).
"""
permission_required(permission::String; permissions_key::String="permissions", session_key::String="user_id", denied=_forbidden) =
	claim_required(permissions_key, permission; kind=:contains, session_key, denied)

# The verified key id of the request principal. Only a `Principal` carries a trusted kid
# (populated exclusively from keyset-verified decodes); there is deliberately no session
# fallback — a kid is meaningless in a session, so absence denies.
function _request_kid(req::HTTP.Request)
	user = Base.get(req.context, :user, nothing)
	if user isa Principal && user.kid !== nothing
		return user.kid
	end
	claims = Base.get(req.context, :auth_claims, nothing)
	if claims isa Principal && claims.kid !== nothing
		return claims.kid
	end
	return nothing
end

"""
    kid_required(allowed; denied = <403 Forbidden>)

Authorization guard on the *verified* JWT key id: 403 unless the token that authenticated
this request was verified against a keyset and its resolved `kid` is in `allowed` (a
string or collection of strings).

`denied`, a factory `(req, reason) -> HTTP.Response` called with `:forbidden`, replaces that
`403` — an API whose clients only handle `401` answers a wrong-`kid` token with one:

```julia
const UNAUTHORIZED = (req, reason) -> Res.json(Dict("error" => "Unauthorized"); status = 401)

middleware = [BearerAuth(Auth.jwt_validator(keyset); unauthorized = UNAUTHORIZED),
              GuardMiddleware(kid_required(["importer"]; denied = UNAUTHORIZED))]
```

A handler reads the verified key id with [`getprincipal`](@ref Nitro.Core.getprincipal)`(req).kid`.

Use with a keyset-backed `jwt_validator` — the resulting `Principal` carries the verified
`kid` (as does the `(user, principal)` tuple flow via `req.context[:auth_claims]`).
Custom validators opt in by returning a `Principal`. Requests authenticated with a single
string secret never carry a trusted kid and are denied — unless a `user_validator` returns a
`Principal` it built with a `kid` of its own, which this guard currently reads first (#517);
don't give an app-built `Principal` a `kid`.
"""
function kid_required(allowed; denied=_forbidden)
	_check_denial_factory(denied, :denied)
	allowed_set = allowed isa AbstractString ? Set{String}((String(allowed),)) :
		Set{String}(String(kid) for kid in allowed)
	isempty(allowed_set) && throw(ArgumentError("kid_required requires at least one allowed key id"))
	return function(req::HTTP.Request)
		kid = _request_kid(req)
		if kid === nothing || !(kid in allowed_set)
			return _deny(denied, req, :forbidden)
		end
		return nothing
	end
end

end # module GuardsMiddleware
