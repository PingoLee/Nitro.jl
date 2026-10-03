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
   `req.context[:session_modified] = true` (as `CSRFMiddleware` does when it issues a token). A
   request that never touches the session stores nothing and gets no cookie, even behind a global
   `CSRFMiddleware`: it issues a new visitor a token only when a handler asks with `csrf_token!`
   (see [When a token is issued](../sessions_and_auth.md#When-a-token-is-issued)). A new session
   with no signed-in identity is saved *unconfirmed* until the browser sends its cookie back (see
   [Anonymous Sessions and Floods](#Anonymous-Sessions-and-Floods)).
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
| `max_age` | `86400` (1 day) | the last write | not written to |
| `absolute_max_age` | `604800` (7 days) | when the session was first stored | old, however active |

`max_age` is a **sliding** lifetime: every write moves the expiry forward, so on its own it never
ends a session that keeps being written, and a stolen session ID stays valid for as long as someone
keeps writing to it. `absolute_max_age` caps that.

The expiry slides on **writes, not reads**. A request that only reads the session writes nothing
to the store, which is what keeps a page view under a login from costing an `UPDATE`. So a
signed-in user who only reads is signed out `max_age` after the last request that changed their
session. That is Django's default as well. If your app has long read-only stretches, raise
`max_age`, or set `req.context[:session_modified] = true` in a handler that should keep the
session alive: that writes it back and moves the expiry.

`SessionMiddleware` writes a session back only when the request changed its data, rotated it,
confirmed it (see [Anonymous Sessions and Floods](#Anonymous-Sessions-and-Floods)), or set
`:session_modified`. `CSRFMiddleware` sets that flag only when it issues a new token, not when a
request presents a valid one. Once a session is older than the cap, it is treated
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

## Anonymous Sessions and Floods

Any route that writes to a visitor's session before they sign in — a cart, a "recently viewed"
list, a locale choice, a flash message on a public page — creates a session for every visitor
without a cookie. A script that calls such a route without cookies creates one per request. Two
things keep that from filling your store.

**New anonymous sessions start unconfirmed.** A new session that ends its first request with no
identity is saved with a short lifetime, `unconfirmed_max_age` (one hour by default), in the store
and in the cookie's `Max-Age`. When the browser sends the cookie back, `SessionMiddleware` writes
the session once more with the full `max_age` and re-sets the cookie. A browser usually does this
within seconds, on the next page or asset it fetches, so a real visitor keeps a full-length session.
That needs the request to pass through `SessionMiddleware`: when assets are served outside it, the
next page confirms the session instead. A script that never sends the cookie back leaves rows that expire in an hour rather than a day, and
the pruning janitor deletes them.

```julia
SessionMiddleware(store = store)                               # unconfirmed for 1 h, then max_age
SessionMiddleware(store = store, unconfirmed_max_age = 600)    # 10 minutes
SessionMiddleware(store = store, unconfirmed_max_age = nothing) # off: every session gets max_age
```

- **Signed-in sessions are never unconfirmed.** A new session that ends the request with an
  identity (`auth_key`, or `validator`), such as a login from a client with no cookie yet, gets
  the full lifetime at once. So does the anonymous session a logout leaves, because that client
  has already shown that it keeps cookies.
- **The default follows your lifetimes.** It is one hour, the default `CSRFMiddleware` `ttl`, so
  with both defaults a form whose session lapses unconfirmed has already lost its CSRF cookie.
  With a shorter lifetime the two differ, and a form left open between them gets a `403`. When
  `min(max_age, absolute_max_age)` is under two hours, the default is half of it. Under two
  minutes, confirm-on-return is off. An explicit value must be positive and at most half that
  lifetime.
- **What it costs.** One extra write per visitor, on their second request. That response carries
  the session cookie, so it is marked `private` like any other: if it is a public asset, that one
  response is not stored by a shared cache. A client that makes one session-writing request and
  returns after `unconfirmed_max_age` finds a fresh session.

**A store can also cap itself.** A database store has no size limit of its own, and an hour of a
fast enough flood is still a lot of rows. Give `pormg_nitro_session` a bound:

```julia
store = pormg_nitro_session(max_sessions = 1_000_000)
```

Once the table holds that many rows, `SessionMiddleware` stops saving **new anonymous** sessions.
The request still succeeds, no cookie is set, and one warning is logged. Sessions that end signed
in, existing sessions and rotations are never refused, so a full store logs nobody out. The count
is read at boot, kept by the store's own writes, and read again on
every prune tick, so it costs no query per request. Expired rows count until the janitor deletes
them.

**A full store does block some sign-ins.** While it is full, a visitor with no cookie holds no
session. If your login form carries a session-bound CSRF token (the default with
`CSRFMiddleware`), that visitor cannot get a token that verifies, so they cannot sign in until the
store has room again: new users, and anyone who cleared their cookies. Only a sign-in that needs
no session beforehand, such as a token or JSON login without session-bound CSRF, is unaffected.
An attacker keeps the store full with about `max_sessions / unconfirmed_max_age` cookieless
writes a second (about 280 a second for a bound of a million with the default hour). So treat the
cap as a last resort against running out of disk, not as flood protection, and size it well above
your normal number of live sessions.

With several processes sharing one table, each keeps its own count between prune ticks, so the
table can overshoot `max_sessions` by roughly the inserts each process makes in one
`prune_interval`.

**Sizing.** Without a sign-in, a flood leaves at most about
`rate × (unconfirmed_max_age + prune_interval)` rows. At 100 cookieless writes a second, that is
about 420 000 rows with the defaults, where it used to be about 8.7 million. A row costs a few
hundred bytes with its two indexes, more if your anonymous sessions hold more data. Set
`max_sessions` to a few times your normal number of live sessions.

`MemoryStore` already has a bound (`max_sessions`, 100 000 by default) and evicts the least recently
used session when it is full. A custom store opts in by implementing `session_store_full` (see
below).

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

`max_sessions` is unbounded by default. See
[Anonymous Sessions and Floods](#Anonymous-Sessions-and-Floods) for when to set it, and how.

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
session_store_full(store::S)                                                  # -> Bool
```

`SessionMiddleware` uses Nitro's `storesession!` and `prunesessions!` helpers, and those
delegate to `set_session!` and `cleanup_expired_sessions!` by default. It writes back a session
the request *loaded* with `update_session!`, except a logged-out session, which it re-stores with
`set_session!` for a fresh clock. `set_session!` must therefore overwrite an existing ID.
`regenerate_session!` moves a session to a new ID with `rotate_session!`. `update_session!` and
`rotate_session!` must each act only if the session still exists and has not expired, returning
`false` otherwise, as one atomic step. Implementing the methods above is enough for custom
backends; `cleanup_expired_sessions!` and `session_store_full` are optional.

`session_store_full` defaults to `false`. Implement it for a store that should stop accepting
new anonymous sessions at some size. `SessionMiddleware` calls it before every new anonymous
save, so answer from a cached count and never run a query per call.

`Base.get` returns a `SessionPayload(data, expires, created)`. `created` is the instant the
session was first stored: `set_session!` sets it, while `update_session!` keeps it and
`rotate_session!` carries it to the new ID. That instant is what `absolute_max_age` measures from,
so a store that reset it on every write would let sessions live forever. Take `created` and
`expires` from the same clock: `SessionMiddleware` tells an unconfirmed anonymous session apart by
its stored lifetime, `expires - created`.

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
the rotation genuinely happened first. A per-session logout cannot close that order, because it
only knows the ID in its own request. [Signing Out Everywhere](#Signing-Out-Everywhere) below does
close it ([#391](https://github.com/PingoLee/Nitro.jl/issues/391)).

If you manage sessions manually without `SessionMiddleware`, delete the old server-side record and invalidate the client cookie yourself.

## Signing Out Everywhere

`SessionMiddleware(session_auth_hash = …)` ends every session of a user at once, on every device,
whatever their IDs. Nitro has no user model, so you supply the hook. It takes the signed-in
identity (the value under `auth_key`, `"user_id"` by default) and returns a string, or `nothing`
if the user no longer exists. A per-user counter is the simplest source:

```julia
# A `session_version` integer column on your users table.
session_hash(uid) = (user = find_user(uid); user === nothing ? nothing : string(user.session_version))

app_sessions = SessionMiddleware(; store, session_auth_hash = session_hash)

# Route it behind `GuardMiddleware(login_required())`, so there is a signed-in user to read.
function logout_everywhere(req::HTTP.Request)
    bump_session_version!(getsession(req)["user_id"])   # every other session ends
    empty!(getsession(req))                             # ...and so does this one
    regenerate_session!(req, store)
    return Res.json(Dict("message" => "Signed out everywhere"))
end
```

When a user signs in, the middleware saves the hook's value in the session, under the reserved key
`"_nitro_auth_hash"`. Every later load of that session compares the saved value with the hook's
current one. When they differ, the session is deleted and the request continues as a new anonymous
visitor, the same way an expired session does.

Rotation keeps the value the session was signed in with. That is what closes the race above: a
rotated session still carries the old value, so the bump ends it, whichever request committed
first.

- **Password changes.** Return something derived from the stored password hash, and every session
  ends when the password changes, with no extra code (Django does this). The value is stored in
  each session row, so make it an HMAC keyed by a server secret, never the password hash itself or
  a plain hash of it. A counter needs an explicit bump in the password-change handler.
- **Keeping the current session.** Call [`rehash_session!`](@ref) in the handler that made the
  change. The session is re-stamped with the new value at the end of the request, and only the
  other sessions end.

  ```julia
  function sign_out_other_devices(req::HTTP.Request)
      bump_session_version!(getsession(req)["user_id"])
      rehash_session!(req)
      return Res.status(204)
  end
  ```

- **Turning the hook on signs everyone out once.** Sessions that signed in before it have no saved
  value, and nothing vouches for them.
- **Cost.** Anonymous sessions never call the hook. An authenticated request calls it once, so back
  it with a cache or a cheap indexed read. Requests run concurrently, so it must be thread-safe.
  An exception from it fails the request with a 500 rather than accepting an unchecked session.
- **A custom `validator`** must find the identity in the session data it is handed, not by reading
  the store by ID. A store read does not see the login the request is making, so the login is left
  unstamped and refused on the next request.
- **Other readers.** Pass the same hook to `Auth.session_user_validator(store; session_auth_hash)`
  when `CookieAuthMiddleware` authenticates from the session store. `get_session` and the
  `Session{T}` extractor read the store without the check.

## Summary Checklist

- Use `secure=true` in production.
- Keep `httponly=true` unless JavaScript must read the cookie.
- Prefer `samesite="Lax"` or `"Strict"` for browser-authenticated apps.
- Rotate the session ID on login, logout, and privilege changes.
- Configure `session_auth_hash` if users must be able to sign out everywhere, or if a password
  change must end their other sessions.
- Keep an absolute lifetime (`absolute_max_age`, 7 days by default); shorten it for sensitive apps.
- Use a persistent store such as `pormg_nitro_session()` for production deployments. Give it a
  `max_sessions` if public routes write to anonymous sessions.