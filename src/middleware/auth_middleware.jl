module AuthMiddleware

using HTTP
using ...Types
using ...Cookies: get_cookie

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
function BearerAuth(validate_token::Function; header::String = "Authorization", scheme::String = "Bearer", cookie_name::Nullable{String} = nothing)

    full_scheme = scheme * " "
    scheme_prefix_len = length(full_scheme)

    return function (handle::Function)
        return function(req::HTTP.Request)

            token = _extract_token(req, header, full_scheme, scheme_prefix_len, cookie_name)
            if token === nothing
                return INVALID_HEADER
            end

            # Validate or Reject incoming request
            user_info = try
                _validate_token(validate_token, req, token)
            catch
                nothing
            end
            if user_info === nothing || user_info === missing
                return EXPIRED_TOKEN
            elseif user_info isa Tuple && length(user_info) == 2
                req.context[:user] = user_info[1]
                req.context[:auth_claims] = user_info[2]
                return handle(req)
            else
                req.context[:user] = user_info
                return handle(req)
            end
        end
    end
end

function _extract_token(req::HTTP.Request, header::String, full_scheme::String, scheme_prefix_len::Int, cookie_name::Nullable{String})
    auth_header = HTTP.header(req, header, missing)
    if !(ismissing(auth_header) || !startswith(auth_header, full_scheme))
        header_len = length(auth_header)
        if header_len > scheme_prefix_len
            token = strip(SubString(auth_header, scheme_prefix_len + 1:header_len))
            if !isempty(token)
                return String(token)
            end
        end
    end

    if !isnothing(cookie_name)
        cookie_token = get_cookie(req, cookie_name, nothing)
        if !(cookie_token === nothing || cookie_token === missing || isempty(cookie_token))
            return String(cookie_token)
        end
    end

    return nothing
end

function _validate_token(validate_token::Function, req::HTTP.Request, token::String)
    methods = Base.methods(validate_token)
    if any(length(method.sig.parameters) - 1 == 2 for method in methods)
        return validate_token(token, req)
    end
    return validate_token(token)
end

end
