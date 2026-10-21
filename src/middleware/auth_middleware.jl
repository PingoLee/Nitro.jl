module AuthMiddleware

using HTTP
using ...Types
using ...Types: _is_identity
using ...Cookies: get_cookie
using ...Errors: CookieError, is_unrecoverable
using ...Crypto: SecretString, CookieKey, _cookie_secret
using ...Util: _auth_credential, _check_denial_factory, _deny, _takes_request

export BearerAuth, CookieAuthMiddleware

const INVALID_HEADER = HTTP.Response(401, "Unauthorized: Missing or invalid Authorization header")
const EXPIRED_TOKEN = HTTP.Response(401, "Unauthorized: Invalid or expired token")
const MISSING_COOKIE = HTTP.Response(401, "Unauthorized: Missing or invalid authentication cookie")

# The default `unauthorized` factories (#515) answer with the consts above, so an app that passes
# none gets the same bytes it always did, and no allocation. Two reasons, and only two:
# `:missing_credentials` -- no usable credential could be extracted -- and `:invalid_credentials`
# -- one was, and the validator refused it. Deliberately no finer: "expired" against "bad
# signature" is exactly what an app must not be able to leak into a body.
_bearer_unauthorized(::HTTP.Request, reason::Symbol) =
    reason === :missing_credentials ? INVALID_HEADER : EXPIRED_TOKEN
_cookie_unauthorized(::HTTP.Request, reason::Symbol) =
    reason === :missing_credentials ? MISSING_COOKIE : EXPIRED_TOKEN

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
# response. Those are the DEFAULTS: an app with its own error contract passes `unauthorized`
# here and `denied` to the guards (#515), and then the status and body are its choice. What it
# chooses is still only a response — whether the request is refused is decided here, not there.
#
# THE ONE CARVE-OUT, and it is the same at both catch sites below (#254): the three types
# `is_unrecoverable` (`src/errors.jl`) names are rethrown instead. A bare `catch` also ate
# `StackOverflowError`, which Julia reports as "program state may be corrupted, so further
# execution might be unreliable". The request came back 401 and the worker carried on
# authenticating people.
#
# Measure the reach before citing it — an earlier version of this comment got it wrong. On a
# `Threads.@spawn` task `JSON.parse` overflows at nesting depth ~3100, and an UNCLOSED `[[[…`
# gets there in ~3.1 KB: a 4,149-byte `Authorization` header once base64url-encoded into a JWT
# header segment. That is inside nginx's 8k and Apache's 8190-byte header defaults, and a
# hand-built request is not bound by a browser's 4 KB cookie cap, so neither a proxy nor
# `CookieAuthMiddleware` stopped it. The fix is not here: `decode_jwt` caps the header segment
# at 1 KB, depth-bounds every JSON parse, and decodes the claims only after the signature
# verifies (#314), so such a token is an ordinary `AuthError` and a 401. The rethrow stays for
# what that does not cover — above all the application's own `validate_token`.
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

function _handle_validated(handle::Function, req::HTTP.Request, user_info, unauthorized)
    if !_is_identity(user_info)
        return _deny(unauthorized, req, :invalid_credentials)
    elseif user_info isa Tuple && length(user_info) == 2
        user, claims = user_info
        _is_identity(user) || return _deny(unauthorized, req, :invalid_credentials)
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
    CookieAuthMiddleware(validate_token::Function; cookie_name::String = "auth_token", secret_key = nothing,
                         unauthorized = <default 401s>)

Creates a middleware function for authentication using a pluggable token validation function based on cookies.

# Arguments
- `validate_token::Function`: A function that takes a token string from the cookie (and optionally the request) and returns user info, a `(user, claims)` tuple, or `nothing` if invalid. `nothing`, `missing`, a `Bool`, `""` and an empty dict are not identities, so each is a `401`, and so is a tuple whose *user* half is one of them — a predicate like `t -> t == KEY` authenticates nobody; return an identity (`t -> t == KEY ? "api-client" : nothing`).
- `cookie_name::String = "auth_token"`: The name of the cookie to extract the token from.
- `secret_key = nothing`: an `AbstractString` or a [`SecretString`](@ref). If provided, the cookie
  will be decrypted before validation. It is held as a `SecretString`, so the middleware never
  prints it.
- `unauthorized`: the response for a refused request, as a factory
  `(req::HTTP.Request, reason::Symbol) -> HTTP.Response` — see [`BearerAuth`](@ref) for the two
  reasons and the rules. A missing, empty or undecryptable cookie is `:missing_credentials`; a
  cookie the validator refuses is `:invalid_credentials`.

Responses follow the auth error contract: missing/invalid cookie or a failed (or
throwing) validator yields a `401`; authorization denials are the guards' `403`. That is the
default — `unauthorized` replaces it.

`InterruptException`, `StackOverflowError` and `OutOfMemoryError` are the exception, and
**propagate** rather than becoming a `401` (#254): Julia reports a stack overflow as *"program
state may be corrupted"*, which is not an authentication outcome and must not be served as one.
They reach the server's error path as a `500`. If your validator wraps anything in its own
`try`, do the same there — catch the failures you expect, not everything.

On success the validator's claims replace anything already at `req.context[:auth_claims]`,
and a validator returning a plain user object clears that slot — the two slots always
describe the same principal, so a second auth layer cannot authorize against the first's.
"""
function CookieAuthMiddleware(validate_token::Function; cookie_name::String = "auth_token", secret_key::Union{AbstractString, SecretString, Nothing} = nothing,
                              unauthorized = _cookie_unauthorized)
    _check_denial_factory(unauthorized, :unauthorized)
    # Normalized once, here, so the closures capture a masked `CookieKey` and not the raw key --
    # `repr` of a closure prints its captures (#307). The AES key is derived here too, not per
    # request (#545).
    secret = _cookie_secret(secret_key)
    sealed = secret === nothing ? nothing : CookieKey(secret)
    return function (handle::Function)
        return function(req::HTTP.Request)
            # Try to extract the authentication cookie. A `CookieError` (one that does not
            # decrypt or verify) is no usable credential, the same as no cookie at all.
            token = try
                get_cookie(req, cookie_name, nothing; encrypted=sealed !== nothing, secret_key=sealed)
            catch e
                # No-argument `rethrow()`: it preserves the original backtrace, which
                # `handlerequest` logs. `rethrow(e)` would reset it to this line (#254).
                e isa CookieError || rethrow()
                nothing
            end
            if isnothing(token) || isempty(token)
                return _deny(unauthorized, req, :missing_credentials)
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
            return _handle_validated(handle, req, user_info, unauthorized)
        end
    end
end

"""
    BearerAuth(validate_token::Function; header::String = "Authorization", scheme::String = "Bearer",
               cookie_name = nothing, unauthorized = <default 401s>)

Creates a middleware function for authentication using a pluggable token validation function.

# Arguments
- `validate_token::Function`: A function that takes a token string (and optionally the request) and returns user info, a `(user, claims)` tuple, or `nothing` if invalid. `nothing`, `missing`, a `Bool`, `""` and an empty dict are not identities, so each is a `401`, and so is a tuple whose *user* half is one of them — a predicate like `t -> t == KEY` authenticates nobody; return an identity (`t -> t == KEY ? "api-client" : nothing`).
- `header::String = "Authorization"`: The name of the header to check for the token.
- `scheme::String = "Bearer"`: The authentication scheme prefix in the header (e.g., "Bearer" for "Bearer <token>").
  It is matched ASCII-case-insensitively, as RFC 9110 §11.1 requires, so `bearer <token>` and
  `BEARER <token>` are accepted too; the separator may be one or more spaces or tabs. It must
  be a single token: a scheme that is empty or contains a space or tab can never match.
- `cookie_name::Union{String, Nothing} = nothing`: when set, a request with no usable header
  credential falls back to this (plain, unencrypted) cookie. For an encrypted auth cookie use
  [`CookieAuthMiddleware`](@ref).
- `unauthorized`: the response for a refused request, as a factory
  `(req::HTTP.Request, reason::Symbol) -> HTTP.Response`. See *Denial responses* below.

Responses follow the auth error contract: missing/malformed credentials or a failed (or
throwing) validator yields a `401`; authorization denials are the guards' `403`. That is the
default — `unauthorized` replaces it.

# Denial responses

`unauthorized` is called with the request and one of two reasons:

| `reason` | when |
|:--|:--|
| `:missing_credentials` | no usable credential: no header, another scheme, an empty credential (and, with `cookie_name`, no cookie either) |
| `:invalid_credentials` | a credential was found and the validator refused it — returned no identity, or threw |

The set is closed and deliberately coarse: an expired token and a forged one are both
`:invalid_credentials`, so a factory cannot leak which. The split is the one RFC 6750 §3.1 draws —
no `error` attribute when no credentials were sent, `error="invalid_token"` when they were.

```julia
const UNAUTHORIZED = (req, reason) -> Res.json(Dict("error" => "Unauthorized"); status = 401)

BearerAuth(Auth.jwt_validator(keyset); unauthorized = UNAUTHORIZED)
```

The factory decides only what the refusal *looks like* — the request is refused either way. It
must return an `HTTP.Response`; anything else is an error (a `500`), never an admission. It must
accept `(req, reason)`: a one-argument function is an `ArgumentError` when the middleware is
built. Build a fresh response per call or return a `const` one — never one you mutate later.
The guards take the same factory as `denied` ([`kid_required`](@ref Nitro.Core.Middleware.GuardsMiddleware.kid_required),
[`claim_required`](@ref Nitro.Core.Middleware.GuardsMiddleware.claim_required)).

`InterruptException`, `StackOverflowError` and `OutOfMemoryError` are the exception, and
**propagate** rather than becoming a `401` (#254): Julia reports a stack overflow as *"program
state may be corrupted"*, which is not an authentication outcome and must not be served as one.
They arrive at the server's error path as a `500`. A crafted token no longer produces one:
`decode_jwt` and `jwt_validator` bound the JSON they parse and decode the claims only after
the signature verifies, so a bearer token of base64url `[[[[…` is an ordinary `401` (#314).

On success the validator's claims replace anything already at `req.context[:auth_claims]`,
and a validator returning a plain user object clears that slot — the two slots always
describe the same principal, so a second auth layer cannot authorize against the first's.

# Returns
A plain middleware closure, `handle -> req -> resp`. Unlike `RateLimiter`, `AccessLog` and
`SessionMiddleware`, this one owns no background resource, so there is nothing to hook and it is
not a `LifecycleMiddleware` — pass it to `serve(middleware = [...])` or `path(...)` as-is.
"""
function BearerAuth(validate_token::Function; header::String = "Authorization", scheme::String = "Bearer", cookie_name::Nullable{String} = nothing,
                    unauthorized = _bearer_unauthorized)
    _check_denial_factory(unauthorized, :unauthorized)
    return function (handle::Function)
        return function(req::HTTP.Request)

            token = _extract_token(req, header, scheme, cookie_name)
            if token === nothing
                return _deny(unauthorized, req, :missing_credentials)
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
            return _handle_validated(handle, req, user_info, unauthorized)
        end
    end
end

function _extract_token(req::HTTP.Request, header::String, scheme::String, cookie_name::Nullable{String})
    auth_header = HTTP.header(req, header, missing)
    if !ismissing(auth_header)
        # The scheme is case-insensitive (#470), and the header is bytes: `_auth_credential`
        # slices at a found SP/HTAB rather than by a counted length, so a non-ASCII or malformed
        # header can neither end the slice mid-character (#326) nor reach the Unicode tables.
        token = _auth_credential(auth_header, scheme)
        token === nothing || return String(token)
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
    _takes_request(validate_token) && return validate_token(token, req)
    return validate_token(token)
end

end
