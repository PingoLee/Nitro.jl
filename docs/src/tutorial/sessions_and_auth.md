# Sessions and Auth

Nitro now treats session storage and authenticated user resolution as separate concerns.

- `SessionMiddleware` is responsible for loading and persisting server-side session state.
- `BearerAuth` is responsible for extracting credentials and attaching the authenticated principal.
- Guards read `req.user`, so they work the same way for session-backed and JWT-backed routes.

## Session Stores

The built-in `MemoryStore` now implements `AbstractSessionStore`.

```julia
using Nitro

store = MemoryStore{String, Dict{String,Any}}()
set_session!(store, "session-1", Dict("user_id" => 42, "role" => "admin"); ttl=3600)

serve(middleware=[
    SessionMiddleware(store=store, secure=false),
])
```

To implement a custom store, define methods for:

- `get_session(store, session_id)`
- `set_session!(store, session_id, data; ttl=...)`
- `delete_session!(store, session_id)`
- `cleanup_expired_sessions!(store)`

Nitro core stays database-agnostic. If your application needs a user lookup, do that in a validator function instead of inside the framework.

## Unified Auth Context

Both session and bearer auth middleware populate `req.user`.

```julia
using HTTP
using Nitro

function dashboard(req::HTTP.Request)
    return Res.json(Dict(
        "session" => req.session,
        "user" => req.user,
    ))
end

urlpatterns("",
    path("/dashboard", dashboard, method="GET", middleware=[GuardMiddleware(login_required())]),
)
```

If a session contains a `user` entry, Nitro uses it directly. If it only contains `user_id`, `role`, or similar fields, Nitro exposes the full session dictionary as `req.user` so guards can still make authorization decisions.

## JWT Helpers

`Nitro.Auth` provides stateless JWT helpers with HS256 signing and claim validation.

```julia
using HTTP
using Nitro
using Nitro.Auth

validator = jwt_validator("super-secret")

function profile(req::HTTP.Request)
    return Res.json(Dict("sub" => req.user["sub"]))
end

urlpatterns("",
    path("/profile", profile, method="GET", middleware=[BearerAuth(validator)]),
)
```

You can also pass a keyset with `kid` values for rotation:

```julia
keys = Dict("default" => "secret-a", "rotated" => "secret-b")
token = encode_jwt(Dict("sub" => "42", "exp" => trunc(Int, time()) + 300), keys; kid="rotated")
claims = decode_jwt(token, keys)
```

`validate_claims` checks `exp`, `iat`, `nbf`, `iss`, and `aud` when present.

## Auth Cookies and CSRF

Use the higher-level cookie helpers for auth tokens:

```julia
using HTTP
using Nitro.Auth

res = HTTP.Response(200)
set_auth_cookie!(res, "jwt-token"; secure=false)
```

For cookie-authenticated browsers, add `CSRFMiddleware` to unsafe routes:

```julia
serve(middleware=[
    CSRFMiddleware("csrf-secret"; config=CookieConfig(httponly=false, secure=false)),
])
```

The middleware uses a signed double-submit cookie. Safe requests receive a CSRF cookie automatically; unsafe requests must echo either the raw token or the signed cookie value in the `X-CSRF-Token` header.