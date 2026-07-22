module GuardsMiddleware

using HTTP
using ...Core: getsession
using ...Types: Nullable

export GuardMiddleware, login_required, role_required, permission_required

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

function role_required(role::String; role_key::String="role")
	return function(req::HTTP.Request)
		user = _request_user(req)
		if !(user isa AbstractDict) || get(user, role_key, nothing) != role
			return HTTP.Response(403, "Forbidden")
		end
		return nothing
	end
end

function permission_required(permission::String; permissions_key::String="permissions")
	return function(req::HTTP.Request)
		user = _request_user(req)
		permissions = user isa AbstractDict ? get(user, permissions_key, nothing) : nothing
		if !(permissions isa AbstractVector) || !(permission in permissions)
			return HTTP.Response(403, "Forbidden")
		end
		return nothing
	end
end

end # module GuardsMiddleware
