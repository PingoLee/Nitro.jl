module AuthMiddleware

using HTTP
using ...Types
using ...Types: _is_identity
using ...Cookies: get_cookie
using ...Errors: CookieError, is_unrecoverable
using ...Crypto: SecretString, _cookie_secret

export BearerAuth, CookieAuthMiddleware

const INVALID_HEADER = HTTP.Response(401, "Unauthorized: Missing or invalid Authorization header")
const EXPIRED_TOKEN = HTTP.Response(401, "Unauthorized: Invalid or expired token")
const MISSING_COOKIE = HTTP.Response(401, "Unauthorized: Missing or invalid authentication cookie")

# Shared post-validation dispatch for both auth middlewares — the single place the
# validated identity is attached to the request. A value that is not an identity →
# 401: `nothing`/`missing` (including a validator that threw, mapped by the callers), any
# `Bool`, `""`, an empty dict — see `_is_identity` (src/types.jl). A `(user, claims)` 2-tuple →
# `req.context[:user]` + `req.context[:auth_claims]`; anything else → `req.context[:user]`.
# A 2-tuple whose user half is not an identity is ALSO a 401: a nil user is no user, which is
# what `jwt_validator` already means when its `user_validator` returns nothing (#24).
#
# `Bool` is the case that bit (#313). A predicate validator — `t -> t == API_KEY`, which is
# what `false` means in Passport — returned `false` for a WRONG key, this layer stored it as
# the user, and the handler ran. `true` is rejected too: it answers "is this key valid?", it
# does not say who is calling.
# Auth error contract: 401 = unauthenticated (this layer), 403 = authenticated but not
# authorized (guards), 302 = browser redirect (`login_required`). A validator that throws is a
# 401 — because a failed credential lookup is exactly what this layer exists to turn into a
# response.
#
# THE ONE CARVE-OUT, and it is the same at both catch sites below (#254): the three types
# `is_unrecoverable` (`src/errors.jl`) names are rethrown instead. A bare `catch` also ate
# `StackOverflowError`, which Julia reports as "program state may be corrupted, so further
# execution might be unreliable" — and which arrives from request input, because `JSON.parse`
# raises it on a deeply-nested value and a credential whose JWT header segment is base64url of
# `[[[[…` reaches that inside `decode_jwt`. The request came back 401 and the worker carried
# on authenticating people. #252 stopped `decode_jwt` mislabelling it an encoding error; this
# stops this layer absorbing it anyway.
#
# Measure the reach before citing it. On a `Threads.@spawn` task — the stack a real request
# runs on — `JSON.parse` overflows at nesting depth ~3100, which is an `Authorization` header
# of ~8.3 KB. That is ABOVE nginx's default `large_client_header_buffers` 8k and Apache's
# `LimitRequestFieldSize` 8190, and far above the 4 KB per-cookie browser cap, so a
# default-configured proxy in front of Nitro stops this particular vector and a cookie cannot
# carry it at all. It reaches a directly-served Nitro. The same overflow needs only a ~6.2 KB
# request BODY or query string, which nothing gates — which is why the sibling narrowing in
# `src/utilities/bodyparsers.jl` and `src/utilities/misc.jl` matters more than this one.
#
# It is a deny-list, where `decode_jwt` one layer down uses an allow-list, and the difference
# is the guarded expression rather than taste: that one guards Nitro's own code, a closed set;
# these guard an arbitrary user callback whose error surface is unknowable, so there is no set
# to allow-list. `is_unrecoverable`'s docstring carries the full argument.
#
# Keeps `:user` and `:auth_claims` describing the SAME principal. Whatever was on the
# request belongs to an outer auth layer (or to application middleware) and describes a
# different identity, so this validator's claims always replace it — and when it produced
# none, the key is removed rather than set to `nothing`, so `haskey` stays a truthful
# signal. Without this, the claim guards and `kid_required` would authorize the identity in
# `:user` against someone else's verified token (#24).
function _set_auth_claims!(req::HTTP.Request, claims)
    if claims === nothing
        delete!(req.context, :auth_claims)
    else
        req.context[:auth_claims] = claims
    end
    return nothing
end

function _handle_validated(handle::Function, req::HTTP.Request, user_info)
    if !_is_identity(user_info)
        return EXPIRED_TOKEN
    elseif user_info isa Tuple && length(user_info) == 2
        user, claims = user_info
        _is_identity(user) || return EXPIRED_TOKEN
        req.context[:user] = user
        _set_auth_claims!(req, claims)
        return handle(req)
    else
        req.context[:user] = user_info
        _set_auth_claims!(req, nothing)
        return handle(req)
    end
end

"""
    CookieAuthMiddleware(validate_token::Function; cookie_name::String = "auth_token", secret_key = nothing)

Creates a middleware function for authentication using a pluggable token validation function based on cookies.

# Arguments
- `validate_token::Function`: A function that takes a token string from the cookie (and optionally the request) and returns user info, a `(user, claims)` tuple, or `nothing` if invalid. `nothing`, `missing`, a `Bool`, `""` and an empty dict are not identities, so each is a `401`, and so is a tuple whose *user* half is one of them — a predicate like `t -> t == KEY` authenticates nobody; return an identity (`t -> t == KEY ? "api-client" : nothing`).
- `cookie_name::String = "auth_token"`: The name of the cookie to extract the token from.
- `secret_key = nothing`: an `AbstractString` or a [`SecretString`](@ref). If provided, the cookie
  will be decrypted before validation. It is held as a `SecretString`, so the middleware never
  prints it.

Responses follow the auth error contract: missing/invalid cookie or a failed (or
throwing) validator yields a `401`; authorization denials are the guards' `403`.

`InterruptException`, `StackOverflowError` and `OutOfMemoryError` are the exception, and
**propagate** rather than becoming a `401` (#254): Julia reports a stack overflow as *"program
state may be corrupted"*, which is not an authentication outcome and must not be served as one.
They reach the server's error path as a `500`. If your validator wraps anything in its own
`try`, do the same there — catch the failures you expect, not everything.

On success the validator's claims replace anything already at `req.context[:auth_claims]`,
and a validator returning a plain user object clears that slot — the two slots always
describe the same principal, so a second auth layer cannot authorize against the first's.
"""
function CookieAuthMiddleware(validate_token::Function; cookie_name::String = "auth_token", secret_key::Union{AbstractString, SecretString, Nothing} = nothing)
    # Normalized once, here, so the closures capture a `SecretString` and not the raw key --
    # `repr` of a closure prints its captures (#307).
    sealed = _cookie_secret(secret_key)
    return function (handle::Function)
        return function(req::HTTP.Request)
            # Try to extract the authentication cookie
            token = try
                get_cookie(req, cookie_name, nothing; encrypted=sealed !== nothing, secret_key=sealed)
            catch e
                if e isa CookieError
                    return MISSING_COOKIE
                end
                # No-argument `rethrow()`: it preserves the original backtrace, which
                # `handlerequest` logs. `rethrow(e)` would reset it to this line (#254).
                rethrow()
            end
            if isnothing(token) || isempty(token)
                return MISSING_COOKIE
            end

            # Validate or Reject incoming request. A throwing validator (e.g.
            # `jwt_validator` on an expired token) is a 401, never a 500 — except for the
            # three `is_unrecoverable` names, which propagate. Both halves of that contract,
            # and why the carve-out is a deny-list, are at the top of this file (#254).
            user_info = try
                _validate_token(validate_token, req, token)
            catch e
                is_unrecoverable(e) && rethrow()
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
- `validate_token::Function`: A function that takes a token string (and optionally the request) and returns user info, a `(user, claims)` tuple, or `nothing` if invalid. `nothing`, `missing`, a `Bool`, `""` and an empty dict are not identities, so each is a `401`, and so is a tuple whose *user* half is one of them — a predicate like `t -> t == KEY` authenticates nobody; return an identity (`t -> t == KEY ? "api-client" : nothing`).
- `header::String = "Authorization"`: The name of the header to check for the token.
- `scheme::String = "Bearer"`: The authentication scheme prefix in the header (e.g., "Bearer" for "Bearer <token>").

Responses follow the auth error contract: missing/malformed credentials or a failed (or
throwing) validator yields a `401`; authorization denials are the guards' `403`.

`InterruptException`, `StackOverflowError` and `OutOfMemoryError` are the exception, and
**propagate** rather than becoming a `401` (#254): Julia reports a stack overflow as *"program
state may be corrupted"*, which is not an authentication outcome and must not be served as one.
A bearer token whose header segment is base64url of `[[[[…` reaches one through `JSON.parse`,
so this is request-reachable, not theoretical — though for *this* path it takes an ~8.3 KB
`Authorization` header, which nginx's and Apache's default per-header caps refuse. Nitro served
directly accepts it. They arrive at the server's error path as a `500`.

On success the validator's claims replace anything already at `req.context[:auth_claims]`,
and a validator returning a plain user object clears that slot — the two slots always
describe the same principal, so a second auth layer cannot authorize against the first's.

# Returns
A plain middleware closure, `handle -> req -> resp`. Unlike `RateLimiter`, `AccessLog` and
`SessionMiddleware`, this one owns no background resource, so there is nothing to hook and it is
not a `LifecycleMiddleware` — pass it to `serve(middleware = [...])` or `path(...)` as-is.
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
            # `jwt_validator` on an expired token) is a 401, never a 500 — except for the
            # three `is_unrecoverable` names, which propagate. Both halves of that contract,
            # and why the carve-out is a deny-list, are at the top of this file (#254).
            user_info = try
                _validate_token(validate_token, req, token)
            catch e
                is_unrecoverable(e) && rethrow()
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
