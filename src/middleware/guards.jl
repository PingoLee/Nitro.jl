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
		user = _request_user(req)
		if !(user isa AbstractDict)
			return HTTP.Response(302, ["Location" => redirect_url])
		end
		# Require a positive authentication marker: the configured session_key must be
		# present. Do NOT admit on `!isempty(user)` — `_request_user` falls back to the
		# raw `req.session` dict when `req.context[:user]` is unset, so treating any
		# non-empty dict as authenticated lets an anonymous visitor who merely has
		# session data (e.g. an anonymous cart) pass the guard.
		if haskey(user, session_key) || haskey(user, Symbol(session_key))
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
