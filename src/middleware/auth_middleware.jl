module AuthMiddleware

using HTTP
using ...Types
using ...Cookies: get_cookie
using ...Errors: CookieError

export BearerAuth, CookieAuthMiddleware

const INVALID_HEADER = HTTP.Response(401, "Unauthorized: Missing or invalid Authorization header")
const EXPIRED_TOKEN = HTTP.Response(401, "Unauthorized: Invalid or expired token")
const MISSING_COOKIE = HTTP.Response(401, "Unauthorized: Missing or invalid authentication cookie")

# Shared post-validation dispatch for both auth middlewares — the single place the
# validated identity is attached to the request. `nothing`/`missing` (including a
# validator that threw, mapped by the callers) → 401; a `(user, claims)` 2-tuple →
# `req.context[:user]` + `req.context[:auth_claims]`; anything else → `req.context[:user]`.
# Auth error contract: 401 = unauthenticated (this layer), 403 = authenticated but not
# authorized (guards), 302 = browser redirect (`login_required`). A throwing validator is
# always a 401, never a 500.
function _handle_validated(handle::Function, req::HTTP.Request, user_info)
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

"""
    CookieAuthMiddleware(validate_token::Function; cookie_name::String = "auth_token", secret_key::Union{String, Nothing} = nothing)

Creates a middleware function for authentication using a pluggable token validation function based on cookies.

# Arguments
- `validate_token::Function`: A function that takes a token string from the cookie (and optionally the request) and returns user info, a `(user, claims)` tuple, or `nothing` if invalid.
- `cookie_name::String = "auth_token"`: The name of the cookie to extract the token from.
- `secret_key::Union{String, Nothing} = nothing`: If provided, the cookie will be decrypted before validation.

Responses follow the auth error contract: missing/invalid cookie or a failed (or
throwing) validator yields a `401`; authorization denials are the guards' `403`.
"""
function CookieAuthMiddleware(validate_token::Function; cookie_name::String = "auth_token", secret_key::Union{String, Nothing} = nothing)
    return function (handle::Function)
        return function(req::HTTP.Request)
            # Try to extract the authentication cookie
            token = try
                get_cookie(req, cookie_name, nothing; encrypted=secret_key !== nothing, secret_key=secret_key)
            catch e
                if e isa CookieError
                    return MISSING_COOKIE
                end
                rethrow(e)
            end
            if isnothing(token) || isempty(token)
                return MISSING_COOKIE
            end

            # Validate or Reject incoming request. A throwing validator (e.g.
            # `jwt_validator` on an expired token) is a 401, never a 500.
            user_info = try
                _validate_token(validate_token, req, token)
            catch
                nothing
            end
            return _handle_validated(handle, req, user_info)
        end
    end
end

"""
    BearerAuth(validate_token::Function; header::String = "Authorization", scheme::String = "Bearer")

Creates a middleware function for authentication using a pluggable token validation function.

# Arguments
- `validate_token::Function`: A function that takes a token string (and optionally the request) and returns user info, a `(user, claims)` tuple, or `nothing` if invalid.
- `header::String = "Authorization"`: The name of the header to check for the token.
- `scheme::String = "Bearer"`: The authentication scheme prefix in the header (e.g., "Bearer" for "Bearer <token>").

Responses follow the auth error contract: missing/malformed credentials or a failed (or
throwing) validator yields a `401`; authorization denials are the guards' `403`.

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

            # Validate or Reject incoming request. A throwing validator (e.g.
            # `jwt_validator` on an expired token) is a 401, never a 500.
            user_info = try
                _validate_token(validate_token, req, token)
            catch
                nothing
            end
            return _handle_validated(handle, req, user_info)
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
