# Working with Sessions

Nitro sessions are server-side by default. The browser receives only a session ID cookie, while the data you assign to `getsession(req)` stays in the configured store.

For the broader auth story, including guards and JWT helpers, see [Sessions and Auth](../sessions_and_auth.md).

## Quick Start

```julia
using HTTP
using Nitro

# Use the in-memory store for local development.
store = MemoryStore()

function login_handler(req::HTTP.Request)
    body = getjson(req)
    username = get(body, "username", "")
    password = get(body, "password", "")

    # Replace this with your real user lookup.
    if username != "alice" || password != "correct-horse"
        return Res.json(Dict("error" => "invalid credentials"); status=401)
    end

    # Persist the authenticated principal in the session.
    # With the default `auth_key="user_id"`, SessionMiddleware
    # will rotate an existing anonymous session ID automatically.
    getsession(req)["user_id"] = 1
    getsession(req)["username"] = username
    getsession(req)["cart"] = Int[]

    return Res.json(Dict("message" => "logged in"))
end

function dashboard_handler(req::HTTP.Request)
    user_id = get(getsession(req), "user_id", nothing)
    if isnothing(user_id)
        return Res.json(Dict("error" => "login required"); status=401)
    end

    return Res.json(Dict(
        "user_id" => user_id,
        "username" => getsession(req)["username"],
        "cart_items" => length(get(getsession(req), "cart", Int[])),
    ))
end

function logout_handler(req::HTTP.Request)
    # Clear the payload, then rotate so the previous authenticated ID is retired.
    empty!(getsession(req))
    regenerate_session!(req, store; ttl=3600)
    return Res.json(Dict("message" => "logged out"))
end

urlpatterns("/api",
    path("/login", login_handler, method="POST"),
    path("/dashboard", dashboard_handler, method="GET"),
    path("/logout", logout_handler, method="POST"),
)

serve(middleware=[
    SessionMiddleware(store=store, max_age=3600, secure=false),
])
```

The `secure=false` example is only for local HTTP development. Keep `secure=true` in production.

## What SessionMiddleware Does

1. Reads the session ID cookie.
2. Loads the server-side payload into `getsession(req)`, or gives a new visitor an empty one.
3. Persists any changes at the end of the request. A **new** session is saved only once it is
   used: the handler stored something in it, rotated it, or set
   `req.context[:session_modified] = true` (as `CSRFMiddleware` does for its tokens). A request
   that never touches the session stores nothing and gets no cookie.
4. Writes the cookie when a session is saved or its ID rotates, and marks that response
   `Cache-Control: private` with `Vary: Cookie`, so a shared cache or CDN never hands one
   visitor's session to another. `private` replaces a `public` directive; `max-age` and the
   other directives are kept.

The cookie contains an opaque session identifier, not the session payload itself. With `SessionMiddleware`, you do not need to encrypt the session ID to keep user data off the client.

## Security Defaults

By default, `SessionMiddleware` writes the session cookie with:

- `HttpOnly=true`
- `Secure=true`
- `SameSite="Lax"`
- the name `__Host-nitro_session`

The `__Host-` prefix is a browser-enforced promise: such a cookie can only be set by this exact
origin, over HTTPS, with `Path=/` and no `Domain`. Without it, a sibling subdomain or anyone on a
plain-HTTP hop can plant their own `nitro_session` for your site — say, the id of a session they
are logged into, scoped to `Path=/account` so the browser sends it first — and the victim then
works inside the attacker's account (login CSRF, or "session swapping").

The name follows the cookie's attributes, so it is always the strongest one the browser will
accept:

| Attributes | Default `cookie_name` |
|---|---|
| `secure=true`, `path="/"`, no `domain` | `__Host-nitro_session` |
| `secure=true` with a `domain` or another `path` | `__Secure-nitro_session` |
| `secure=false` (local HTTP development) | `nitro_session` |

Passing `cookie_name` explicitly overrides it. A `__Host-`/`__Secure-` name the attributes cannot
carry is an `ArgumentError` when the middleware is built, because browsers would silently drop the
cookie. Changing the name logs every user out once, since their browser still holds the old one.

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
    getsession(req)["user_id"] = 42
    getsession(req)["role"] = "admin"

    # Use explicit rotation if the handler must retire the old ID immediately.
    regenerate_session!(req, store; ttl=3600)

    return Res.json(Dict("status" => "elevated"))
end
```

## Store Options

### In-Memory Store

For local development:

```julia
store = MemoryStore()

serve(middleware=[
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

serve(middleware=[
    SessionMiddleware(store=store, max_age=3600, secure=true),
])
```

The default `db_key` is `"db"`. Use a different one when your session database uses another
PormG connection, for example `db_key="sessions"` — the key selects the connection the table is
created on *and* the one every session query runs against.

!!! note "Sessions inside a PormG transaction"
    The store's `nitro_session` model is bound to `db_key`, so session reads and writes work
    inside a `PormG.run_in_transaction(db_key)` block. A session call inside a transaction
    opened on a **different** connection raises PormG's `TransactionError`, which names the
    `run_in_transaction` call you need.

### Custom Store Interface

Implement these methods for your own backend:

```julia
Base.get(store::S, session_id::String, default)
set_session!(store::S, session_id::String, data; ttl=3600)
update_session!(store::S, session_id::String, data; ttl=3600)   # -> Bool
delete_session!(store::S, session_id::String)
cleanup_expired_sessions!(store::S)
```

`SessionMiddleware` uses Nitro's `storesession!` and `prunesessions!` helpers, and those
delegate to `set_session!` and `cleanup_expired_sessions!` by default. It writes back a session
the request *loaded* with `update_session!`. That method must write only if the session still
exists and has not expired, returning `false` otherwise, as one atomic step. Implementing the
five methods above is enough for custom backends; only `cleanup_expired_sessions!` is optional.

`cleanup_expired_sessions!` is called from a background janitor owned by
`SessionMiddleware`'s lifecycle hooks — it never runs on the request path. Use
`prune_interval` to set its period, and `SessionPruner(store; interval)` when you use a
store without `SessionMiddleware`:

```julia
SessionMiddleware(store = store, prune_interval = Minute(5))   # janitor included
SessionPruner(store; interval = Minute(5))                     # janitor only
```

## Logout Semantics

With `SessionMiddleware`, `empty!(getsession(req))` only clears the current payload. To retire the old authenticated session ID, pair it with `regenerate_session!`.

A logout holds even against requests that are still in flight on the old session. Once the old
ID has been deleted, another request that loaded it earlier and then writes to it has that write
dropped: the session is not re-created, and that response does not set the old cookie again.
Each request also works on its own deep copy of the session, so concurrent requests never share a
nested value such as a `cart` vector.

If you manage sessions manually without `SessionMiddleware`, delete the old server-side record and invalidate the client cookie yourself.

## Summary Checklist

- Use `secure=true` in production.
- Keep `httponly=true` unless JavaScript must read the cookie.
- Prefer `samesite="Lax"` or `"Strict"` for browser-authenticated apps.
- Rotate the session ID on login, logout, and privilege changes.
- Use a persistent store such as `pormg_nitro_session()` for production deployments.