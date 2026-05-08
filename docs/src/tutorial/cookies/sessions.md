# Working with Sessions

Nitro sessions are server-side by default. The browser receives only a session ID cookie, while the data you assign to `req.session` stays in the configured store.

For the broader auth story, including guards and JWT helpers, see [Sessions and Auth](../sessions_and_auth.md).

## Quick Start

```julia
using HTTP
using Nitro

# Use the in-memory store for local development.
store = Nitro.Types.MemoryStore{String, Dict{String,Any}}()

function login_handler(req::HTTP.Request)
    body = req.json
    username = get(body, "username", "")
    password = get(body, "password", "")

    # Replace this with your real user lookup.
    if username != "alice" || password != "correct-horse"
        return Res.json(Dict("error" => "invalid credentials"); status=401)
    end

    # Persist the authenticated principal in the session.
    # With the default `auth_key="user_id"`, SessionMiddleware
    # will rotate an existing anonymous session ID automatically.
    req.session["user_id"] = 1
    req.session["username"] = username
    req.session["cart"] = Int[]

    return Res.json(Dict("message" => "logged in"))
end

function dashboard_handler(req::HTTP.Request)
    user_id = get(req.session, "user_id", nothing)
    if isnothing(user_id)
        return Res.json(Dict("error" => "login required"); status=401)
    end

    return Res.json(Dict(
        "user_id" => user_id,
        "username" => req.session["username"],
        "cart_items" => length(get(req.session, "cart", Int[])),
    ))
end

function logout_handler(req::HTTP.Request)
    # Clear the payload, then rotate so the previous authenticated ID is retired.
    empty!(req.session)
    regenerate_session!(req, store; ttl=3600)
    return Res.json(Dict("message" => "logged out"))
end

urlpatterns("/api",
    path("/login", login_handler, method="POST"),
    path("/dashboard", dashboard_handler, method="GET"),
    path("/logout", logout_handler, method="POST"),
)

serve(urlpatterns, middleware=[
    SessionMiddleware(store=store, max_age=3600, secure=false),
])
```

The `secure=false` example is only for local HTTP development. Keep `secure=true` in production.

## What SessionMiddleware Does

1. Reads the session ID cookie.
2. Loads the server-side payload into `req.session`.
3. Persists any changes at the end of the request.
4. Writes a new cookie when the session is created or the session ID rotates.

The cookie contains an opaque session identifier, not the session payload itself. With `SessionMiddleware`, you do not need to encrypt the session ID to keep user data off the client.

## Security Defaults

By default, `SessionMiddleware` writes the session cookie with:

- `HttpOnly=true`
- `Secure=true`
- `SameSite="Lax"`

For HTTPS deployments, also configure `Strict-Transport-Security`. See [Cookie Security](security.md).

## Session Rotation

Use `regenerate_session!` when you want the session ID to rotate immediately inside the current handler, especially for:

- login
- logout
- privilege changes
- impersonation flows

If you keep the default `auth_key="user_id"`, `SessionMiddleware` also rotates an existing session automatically when that key is added, removed, or changed during the request.

```julia
function elevate_handler(req::HTTP.Request)
    req.session["user_id"] = 42
    req.session["role"] = "admin"

    # Use explicit rotation if the handler must retire the old ID immediately.
    regenerate_session!(req, store; ttl=3600)

    return Res.json(Dict("status" => "elevated"))
end
```

## Store Options

### In-Memory Store

For local development:

```julia
store = Nitro.Types.MemoryStore{String, Dict{String,Any}}()

serve(urlpatterns, middleware=[
    SessionMiddleware(store=store, secure=false),
])
```

### PormG Store

For persistent sessions in production:

```julia
using Nitro
using PormG

PormG.Configuration.load("db")

store = pormg_nitro_session(db_key="db")

serve(urlpatterns, middleware=[
    SessionMiddleware(store=store, max_age=3600, secure=true),
])
```

### Custom Store Interface

Implement these methods for your own backend:

```julia
Base.get(store::S, session_id::String, default)
set_session!(store::S, session_id::String, data; ttl=3600)
delete_session!(store::S, session_id::String)
cleanup_expired_sessions!(store::S)
```

## Logout Semantics

With `SessionMiddleware`, `empty!(req.session)` only clears the current payload. To retire the old authenticated session ID, pair it with `regenerate_session!`.

If you manage sessions manually without `SessionMiddleware`, delete the old server-side record and invalidate the client cookie yourself.

## Summary Checklist

- Use `secure=true` in production.
- Keep `httponly=true` unless JavaScript must read the cookie.
- Prefer `samesite="Lax"` or `"Strict"` for browser-authenticated apps.
- Rotate the session ID on login, logout, and privilege changes.
- Use a persistent store such as `pormg_nitro_session()` for production deployments.