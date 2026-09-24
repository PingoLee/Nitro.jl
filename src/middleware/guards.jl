module GuardsMiddleware

using HTTP
using ...Core: getsession
using ...Types: Nullable, Principal

export GuardMiddleware, login_required, role_required, permission_required,
	claim_required, kid_required

# Shared denial response for authorization guards. Module-level `const` Responses are
# reuse-safe in Nitro (non-consuming write path, see nitro-core §4), so denials are
# allocation-free. Contract: 401 = unauthenticated (auth middleware), 403 = authenticated
# but not authorized (guards), 302 = browser redirect (`login_required`).
const FORBIDDEN = HTTP.Response(403, "Forbidden")

"""
    GuardMiddleware(guards::Function...)

Turn authorization guards into a route or global middleware. Each guard is a
`req -> Union{Nothing, HTTP.Response}`: `nothing` admits the request, and a response denies it
and is returned as-is. Guards run in order and the first denial short-circuits the rest and the
handler.

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
browser redirect.
"""
function GuardMiddleware(guards::Function...)
	return function(handle::Function)
		return function(req::HTTP.Request)
			for guard in guards
				result = guard(req)
				if result isa HTTP.Response
					return result
				end
			end
			return handle(req)
		end
	end
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
function _request_claims(req::HTTP.Request)::Nullable{AbstractDict}
	user = Base.get(req.context, :user, nothing)
	user isa AbstractDict && return user          # incl. `Principal`

	claims = Base.get(req.context, :auth_claims, nothing)
	claims isa AbstractDict && return claims

	# `:user` is the vouching slot: if an auth middleware put a non-claims identity there,
	# the raw session is not a claims source for that identity, so deny rather than fall
	# back. A non-dict `:auth_claims` alone does NOT gate the fallback — nothing vouched.
	user === nothing || return nothing

	session = getsession(req)
	return session isa AbstractDict ? session : nothing
end

"""
    login_required(; redirect_url = "/login", session_key = "user_id")

Guard that admits an authenticated request and otherwise answers `302` with
`Location: redirect_url`. It is a factory, so call it: `GuardMiddleware(login_required())`.

A request counts as authenticated in one of two ways, and they are trusted differently:

1. **An auth middleware set `req.context[:user]`** (`BearerAuth`, `CookieAuthMiddleware`, or your
   own). The identity is trusted as-is, whatever its shape, so a JWT principal without a
   `user_id` passes. Only an empty dict is refused.
2. **Otherwise, the raw [`getsession`](@ref) dict**, which must carry `session_key`. An anonymous
   visitor accumulates session data too (a cart, a CSRF token), so a non-empty session alone is
   not a login.

`login_required` checks *that* someone is logged in, not *what* they may do. Stack
[`claim_required`](@ref) or [`role_required`](@ref) after it for that. For a JSON API a redirect
is usually the wrong answer; an auth middleware's own `401` already covers the anonymous case.
"""
function login_required(; redirect_url::String="/login", session_key::String="user_id")
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
		ctx_user = Base.get(req.context, :user, nothing)
		if ctx_user !== nothing
			# An empty Dict carries no identity; stay defensive and treat it as unauthenticated.
			if ctx_user isa AbstractDict && isempty(ctx_user)
				return HTTP.Response(302, ["Location" => redirect_url])
			end
			return nothing
		end

		session = getsession(req)
		if session isa AbstractDict && (haskey(session, session_key) || haskey(session, Symbol(session_key)))
			return nothing
		end
		return HTTP.Response(302, ["Location" => redirect_url])
	end
end

"""
    claim_required(claim, value; kind=:equals)

Declarative authorization guard on a claim of the request principal: 403 unless the
principal's `claim` matches `value`.

- `kind = :equals` — the claim's value must `==` `value` (e.g. a role or action claim).
- `kind = :contains` — the claim must be a list containing `value` (e.g. permissions/scopes).

The claims are resolved in three steps: `req.context[:user]` when an auth middleware set
something dict-like there (a `Principal`, or your own claims dict); otherwise the verified
`Principal` at `req.context[:auth_claims]`, which is where a `user_validator`'s token claims
ride; otherwise the raw `getsession(req)` dict, for session-based apps. A non-dict `:user`
(a plain user struct with no accompanying claims) denies rather than falling through to the
session. `role_required` and `permission_required` are thin aliases over this guard.

!!! warning "A struct user authorizes off the token, not off your lookup"
    Those first two steps decide how fast a revocation takes effect. A dict-like `:user` is
    authoritative — an absent claim denies, so a demotion applies on the next request. A
    struct `:user` is not a claims source, so the guard reads the token's claims instead:
    verified, but issued in the past and never re-checked against your `user_validator`'s
    result. A demoted user keeps what the token says until it expires. Return a dict merging
    your fresh state if revocation must take effect within the token TTL.
"""
function claim_required(claim::String, value; kind::Symbol=:equals)
	if kind === :equals
		return function(req::HTTP.Request)
			claims = _request_claims(req)
			if claims === nothing || get(claims, claim, nothing) != value
				return FORBIDDEN
			end
			return nothing
		end
	elseif kind === :contains
		return function(req::HTTP.Request)
			claims = _request_claims(req)
			container = claims === nothing ? nothing : get(claims, claim, nothing)
			if !(container isa AbstractVector) || !(value in container)
				return FORBIDDEN
			end
			return nothing
		end
	end
	throw(ArgumentError("claim_required kind must be :equals or :contains, got $(repr(kind))"))
end

"""
    role_required(role; role_key = "role")

Guard that answers `403` unless the principal's `role_key` claim equals `role`. Exactly
`claim_required(role_key, role; kind = :equals)`; see [`claim_required`](@ref) for where the claims
are read from and how fast a revocation takes effect.
"""
role_required(role::String; role_key::String="role") =
	claim_required(role_key, role; kind=:equals)

"""
    permission_required(permission; permissions_key = "permissions")

Guard that answers `403` unless the principal's `permissions_key` claim is a list containing
`permission`. Exactly `claim_required(permissions_key, permission; kind = :contains)`; see
[`claim_required`](@ref).
"""
permission_required(permission::String; permissions_key::String="permissions") =
	claim_required(permissions_key, permission; kind=:contains)

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
    kid_required(allowed)

Authorization guard on the *verified* JWT key id: 403 unless the token that authenticated
this request was verified against a keyset and its resolved `kid` is in `allowed` (a
string or collection of strings).

Use with a keyset-backed `jwt_validator` — the resulting `Principal` carries the verified
`kid` (as does the `(user, principal)` tuple flow via `req.context[:auth_claims]`).
Custom validators opt in by returning a `Principal`. Requests authenticated with a single
string secret never carry a trusted kid and are denied.
"""
function kid_required(allowed)
	allowed_set = allowed isa AbstractString ? Set{String}((String(allowed),)) :
		Set{String}(String(kid) for kid in allowed)
	isempty(allowed_set) && throw(ArgumentError("kid_required requires at least one allowed key id"))
	return function(req::HTTP.Request)
		kid = _request_kid(req)
		if kid === nothing || !(kid in allowed_set)
			return FORBIDDEN
		end
		return nothing
	end
end

end # module GuardsMiddleware
