function _invoke_user_validator(validator::Function, claims)
    methods = Base.methods(validator)
    if any(length(method.sig.parameters) - 1 == 2 for method in methods)
        return validator(claims, nothing)
    end
    return validator(claims)
end

function jwt_validator(secret_or_keyset; user_validator::Union{Function, Nothing}=nothing, kwargs...)
    return function(token::AbstractString, req::Union{HTTP.Request, Nothing}=nothing)
        claims = decode_jwt(token, secret_or_keyset; kwargs...)
        if user_validator === nothing
            return claims
        end
        user = if req === nothing
            _invoke_user_validator(user_validator, claims)
        else
            methods = Base.methods(user_validator)
            if any(length(method.sig.parameters) - 1 == 2 for method in methods)
                user_validator(claims, req)
            else
                user_validator(claims)
            end
        end
        return user === nothing ? nothing : (user, claims)
    end
end

function session_user_validator(store::AbstractSessionStore; user_key::String="user")
    return function(session_id::String, session_data=nothing)
        resolved = session_data === nothing ? get_session(store, session_id) : session_data
        resolved === nothing && return nothing
        if resolved isa AbstractDict
            if haskey(resolved, user_key)
                return resolved[user_key]
            elseif haskey(resolved, Symbol(user_key))
                return resolved[Symbol(user_key)]
            end
        end
        return resolved
    end
end

no_auth_validator() = _ -> nothing