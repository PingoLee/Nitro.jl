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

## Session Lifetime

A session has two lifetimes, and it ends at whichever comes first:

| Keyword | Default | Measured from | Ends a session that is… |
|---|---|---|---|
| `max_age` | `86400` (1 day) | the last write | idle |
| `absolute_max_age` | `604800` (7 days) | when the session was first stored | old, however active |

`max_age` is a **sliding** lifetime: every write moves the expiry forward, so on its own it never
ends a session that keeps being used, and a stolen session ID stays valid for as long as someone
keeps using it. `absolute_max_age` caps that. Once a session is older than the cap, it is treated
as absent: the visitor gets a fresh session and signs in again.

```julia
SessionMiddleware(store = store, max_age = 3600, absolute_max_age = 12 * 3600)  # 1 h idle, 12 h total
SessionMiddleware(store = store, absolute_max_age = nothing)                     # no absolute cap
```

- **Rotation keeps the clock.** `regenerate_session!` and `rotate_on_auth` move a session to a new
  ID, so its lifetime is still measured from when it was first created. A login therefore does not
  buy a fresh week, and neither can an endpoint that rotates without re-checking credentials.
- **Logout starts a new one.** A rotated session that *ends the request empty* carries no
  identity, so `SessionMiddleware` writes it with a fresh clock. The logout recipe,
  `empty!(getsession(req))` then `regenerate_session!`, leaves an anonymous session with a full
  window, and logging back in carries that new clock. The check is made when the request ends:
  emptying a session, rotating it and putting the identity back keeps the old clock.
- **The cap binds every reader.** Each write sets the stored expiry to `max_age` from now or the
  absolute deadline, whichever is sooner, and the cookie's `Max-Age` too. Readers that skip the
  middleware — the `Session{T}` extractor, `Auth.session_user_validator` — refuse the session
  at the deadline through the same expiry check. A session `SessionMiddleware` finds past its cap
  anyway is deleted. That happens after you **lower** the cap, or after a direct `set_session!`.
  It also happens when two `SessionMiddleware`s with different caps share one store, so give them
  the same cap.
- **The deadline is exact.** A session that reaches it during a request ends with that request:
  nothing is written, a login rotation included, and no cookie is set.
- **`nothing` means no cap.** A huge number would overflow the date arithmetic, so the keyword
  refuses anything over 100 years.
- **Why seven days.** OWASP recommends an absolute timeout; Django ships none. A week keeps a
  regular user signed in across a working week and bounds how long a stolen ID works. Shorten it
  for sensitive apps.

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

`pormg_nitro_session()` also brings an existing table up to date on boot. A `nitro_session` table
created before `absolute_max_age` existed gains its `created_at` column. Rows already in it are
stamped with the upgrade instant, so live sessions get a full lifetime from the upgrade rather
than ending at once.

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
update_session!(store::S, session_id::String, data; ttl=3600)                 # -> Bool
rotate_session!(store::S, old_id::String, new_id::String, data; ttl=3600)     # -> Bool
delete_session!(store::S, session_id::String)
cleanup_expired_sessions!(store::S)
```

`SessionMiddleware` uses Nitro's `storesession!` and `prunesessions!` helpers, and those
delegate to `set_session!` and `cleanup_expired_sessions!` by default. It writes back a session
the request *loaded* with `update_session!`, except a logged-out session, which it re-stores with
`set_session!` for a fresh clock. `set_session!` must therefore overwrite an existing ID.
`regenerate_session!` moves a session to a new ID with `rotate_session!`. `update_session!` and
`rotate_session!` must each act only if the session still exists and has not expired, returning
`false` otherwise, as one atomic step. Implementing the six methods above is enough for custom
backends; only `cleanup_expired_sessions!` is optional.

`Base.get` returns a `SessionPayload(data, expires, created)`. `created` is the instant the
session was first stored: `set_session!` sets it, while `update_session!` keeps it and
`rotate_session!` carries it to the new ID. That instant is what `absolute_max_age` measures from,
so a store that reset it on every write would let sessions live forever.

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

A logout holds against requests that are still in flight on the old session and write to it.
Once the old ID has been deleted, another request that loaded it earlier and then writes to it has
that write dropped: the session is not re-created, and that response does not set the old cookie
again. Each request also works on its own deep copy of the session, so concurrent requests never
share a nested value such as a `cart` vector.

The same holds for an in-flight request that **rotates** the session after the logout, by
calling `regenerate_session!` or through `rotate_on_auth` on a user switch
([#361](https://github.com/PingoLee/Nitro.jl/issues/361)). The store moves a session to a new ID
only if it still exists, so the logged-out data is not copied into a fresh ID, the rotating
request's write is dropped, and it sets no cookie. `regenerate_session!` returns `nothing` in that
case.

The race has a second order, and it is not a resurrection. If the rotation commits **before** the
logout, the logout then targets an ID that no longer exists, and the rotated session lives on:
the rotation genuinely happened first. Logging out every session of a user is what closes that
order, and it is a separate mechanism.

If you manage sessions manually without `SessionMiddleware`, delete the old server-side record and invalidate the client cookie yourself.

## Summary Checklist

- Use `secure=true` in production.
- Keep `httponly=true` unless JavaScript must read the cookie.
- Prefer `samesite="Lax"` or `"Strict"` for browser-authenticated apps.
- Rotate the session ID on login, logout, and privilege changes.
- Keep an absolute lifetime (`absolute_max_age`, 7 days by default); shorten it for sensitive apps.
- Use a persistent store such as `pormg_nitro_session()` for production deployments.