module AuthMiddleware

using HTTP
using ...Types

export BearerAuth, CookieAuthMiddleware

const INVALID_HEADER = HTTP.Response(401, "Unauthorized: Missing or invalid Authorization header")
const EXPIRED_TOKEN = HTTP.Response(401, "Unauthorized: Invalid or expired token")
const MISSING_COOKIE = HTTP.Response(401, "Unauthorized: Missing or invalid authentication cookie")

"""
    CookieAuthMiddleware(validate_token::Function; cookie_name::String = "auth_token", secret_key::Union{String, Nothing} = nothing)

Creates a middleware function for authentication using a pluggable token validation function based on cookies.

# Arguments
- `validate_token::Function`: A function that takes a token string from the cookie and returns user info (or `nothing` if invalid).
- `cookie_name::String = "auth_token"`: The name of the cookie to extract the token from.
- `secret_key::Union{String, Nothing} = nothing`: If provided, the cookie will be decrypted before validation.
"""
function CookieAuthMiddleware(validate_token::Function; cookie_name::String = "auth_token", secret_key::Union{String, Nothing} = nothing)
    return function (handle::Function)
        return function(req::HTTP.Request)
            # Try to extract the authentication cookie
            token = get_cookie(req, cookie_name, secret_key)
            if isnothing(token) || isempty(token)
                return MISSING_COOKIE
            end

            # Validate or Reject incoming request
            user_info = validate_token(token)
            if user_info === nothing || user_info === missing
                return EXPIRED_TOKEN
            else
                req.context[:user] = user_info
                return handle(req)
            end
        end
    end
end

"""
    BearerAuth(validate_token::Function; header::String = "Authorization", scheme::String = "Bearer")

Creates a middleware function for authentication using a pluggable token validation function.

# Arguments
- `validate_token::Function`: A function that takes a token string and returns user info (or `nothing` if invalid).
- `header::String = "Authorization"`: The name of the header to check for the token.
- `scheme::String = "Bearer"`: The authentication scheme prefix in the header (e.g., "Bearer" for "Bearer <token>").

# Returns
A `LifecycleMiddleware` struct containing the middleware function and a no-op shutdown function.
"""
function BearerAuth(validate_token::Function; header::String = "Authorization", scheme::String = "Bearer")

    full_scheme = scheme * " "
    scheme_prefix_len = length(full_scheme)

    return function (handle::Function)
        return function(req::HTTP.Request)

            # Try to extract the auth header
            auth_header = HTTP.header(req, header, missing)
            if ismissing(auth_header) || !startswith(auth_header, full_scheme)
                return INVALID_HEADER
            end

            header_len = length(auth_header)

            # Ensure there is something after the scheme (e.g. "Bearer <token>")
            if header_len <= scheme_prefix_len
                return INVALID_HEADER
            end
            
            # zero-copy view of the token portion
            token = strip(SubString(auth_header, scheme_prefix_len+1:header_len))
            if isempty(token)
                return INVALID_HEADER
            end

            # Validate or Reject incoming request
            user_info = validate_token(token)
            if user_info === nothing || user_info === missing
                return EXPIRED_TOKEN
            else
                req.context[:user] = user_info
                return handle(req)
            end
        end
    end
end

end
