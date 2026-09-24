const DEFAULT_AUTH_COOKIE_NAME = "auth_token"

function extract_auth_token(req::HTTP.Request; header::String="Authorization", scheme::String="Bearer", cookie_name::Union{String, Nothing}=DEFAULT_AUTH_COOKIE_NAME)
    auth_header = HTTP.header(req, header, "")
    full_scheme = string(scheme, " ")
    if startswith(auth_header, full_scheme)
        token = strip(SubString(auth_header, length(full_scheme) + 1:lastindex(auth_header)))
        isempty(token) || return String(token)
    end

    if cookie_name !== nothing
        token = get_cookie(req, cookie_name, nothing; encrypted=false)
        if !(token === nothing || token === missing || isempty(token))
            return String(token)
        end
    end

    return nothing
end

"""
    set_auth_cookie!(res, token; ttl, cookie_name="auth_token", secure=true,
                     httponly=true, samesite="Lax", path="/", domain=nothing)

Write `token` to the auth cookie on `res`, with `Max-Age=ttl` seconds.

**`ttl` is required, and deliberately has no default.** This helper is handed an opaque
string: it never decodes the token, so it cannot know when the credential inside it dies.
A guessed default is wrong whenever the caller minted with its own lifetime, and the
failure is silent in the worst direction — the browser keeps sending a credential that is
guaranteed to `401`, so the app looks broken rather than signed out (#232). Only the caller
that just minted the token knows its lifetime, so only the caller may say.

Pass the same value you passed to `encode_jwt`:

```julia
token = encode_jwt(claims, secret; expires_in = 900)
set_auth_cookie!(res, token; ttl = 900)
```

If you never passed `expires_in`, the token carries no `exp` and is bounded instead by the
`iat + exp_timeout` fallback in `decode_jwt` — `ttl = 900` matches its default.

**Re-setting a token you minted earlier** — a refresh flow, or a re-login that reuses a
live token — is the one case where `expires_in` is the wrong number: `Max-Age` counts from
when the browser receives the cookie, while `exp` counts from `iat`, so passing the
original `expires_in` overshoots by however long the token has already lived. Pass what is
actually left:

```julia
ttl = claims["exp"] - trunc(Int, time())
set_auth_cookie!(res, token; ttl = ttl)
```

The cookie is written unencrypted: it carries a signed token, which is already tamper-evident.
Use `clear_auth_cookie!` to expire it.
"""
function set_auth_cookie!(res::HTTP.Response, token::AbstractString; ttl::Int, cookie_name::String=DEFAULT_AUTH_COOKIE_NAME, secure::Bool=true, httponly::Bool=true, samesite::String="Lax", path::String="/", domain=nothing)
    config = CookieConfig(secure=secure, httponly=httponly, samesite=samesite, path=path, domain=domain, maxage=ttl)
    set_cookie!(res, cookie_name, token; config=config, encrypted=false, maxage=ttl)
    return res
end

function clear_auth_cookie!(res::HTTP.Response; cookie_name::String=DEFAULT_AUTH_COOKIE_NAME, secure::Bool=true, httponly::Bool=true, samesite::String="Lax", path::String="/", domain=nothing)
    config = CookieConfig(secure=secure, httponly=httponly, samesite=samesite, path=path, domain=domain)
    set_cookie!(res, cookie_name, ""; config=config, encrypted=false, maxage=0)
    return res
end