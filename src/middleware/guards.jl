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

function _request_user(req::HTTP.Request)
	user = Base.get(req.context, :user, nothing)
	if !isnothing(user)
		return user
	end

	session = getsession(req)
	return session isa AbstractDict ? session : nothing
end

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
		#   2. The raw `req.session` dict, used only as a fallback when no middleware
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

The principal is resolved like the other guards (`req.context[:user]` set by auth
middleware, with the raw-session fallback for session-based apps). `role_required` and
`permission_required` are thin aliases over this guard.
"""
function claim_required(claim::String, value; kind::Symbol=:equals)
	if kind === :equals
		return function(req::HTTP.Request)
			user = _request_user(req)
			if !(user isa AbstractDict) || get(user, claim, nothing) != value
				return FORBIDDEN
			end
			return nothing
		end
	elseif kind === :contains
		return function(req::HTTP.Request)
			user = _request_user(req)
			container = user isa AbstractDict ? get(user, claim, nothing) : nothing
			if !(container isa AbstractVector) || !(value in container)
				return FORBIDDEN
			end
			return nothing
		end
	end
	throw(ArgumentError("claim_required kind must be :equals or :contains, got $(repr(kind))"))
end

role_required(role::String; role_key::String="role") =
	claim_required(role_key, role; kind=:equals)

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
