# Sessions and Auth

Nitro treats session storage and authenticated user resolution as separate concerns.

- `SessionMiddleware` manages server-side session state via `getsession(req)`.
- `BearerAuth` extracts credentials and attaches the authenticated principal.
- Guards read `getuser(req)`, so they work the same way for session-backed and JWT-backed routes.

## Quick Start

```julia
using Nitro
using PormG

# 1. Configure PormG
PormG.Configuration.load("db")
PormG.@import_models "db/models.jl" models
import .models as M

# 2. One-call database session setup (creates table if needed)
store = pormg_nitro_session(db_key="db")

# 3. Define handlers
function login_handler(req::HTTP.Request)
    payload = getjson(req)
    username = get(payload, "username", "")
    password = get(payload, "password", "")

    user = M.User.objects.filter("username" => username).first()
    # Pass `nothing` for an unknown user instead of returning early: `check_password` then
    # hashes anyway, so the response time does not reveal which usernames exist.
    if !check_password(password, isnothing(user) ? nothing : user[:password])
        return Res.json(Dict("error" => "Invalid credentials"); status=401)
    end

    # Store data in the session — like Django's request.session
    getsession(req)["user_id"]  = user[:id]
    getsession(req)["username"] = user[:username]
    getsession(req)["role"]     = user[:is_staff] ? "staff" : "user"

    # Rotate the session ID after authentication to prevent fixation.
    regenerate_session!(req, store; ttl=3600)

    return Res.json(Dict("message" => "Welcome $(user[:username])!"))
end

function me_handler(req::HTTP.Request)
    user_id = get(getsession(req), "user_id", nothing)
    if isnothing(user_id)
        return Res.json(Dict("error" => "Not authenticated"); status=401)
    end
    return Res.json(Dict(
        "user_id"  => user_id,
        "username" => getsession(req)["username"],
        "role"     => getsession(req)["role"],
    ))
end

function logout_handler(req::HTTP.Request)
    empty!(getsession(req))
    regenerate_session!(req, store; ttl=3600)
    return Res.json(Dict("message" => "Logged out"))
end

# 4. Routes
urlpatterns("/api",
    path("/login",  login_handler,  method="POST"),
    path("/me",     me_handler,     method="GET"),
    path("/logout", logout_handler, method="POST"),
)

# 5. Serve
serve(middleware=[
    SessionMiddleware(store=store, cookie_name="nitro_sess", secure=false, samesite="Lax"),
])
```

The `secure=false` example is for local HTTP development only. Keep `secure=true` in production.

With the default `rotate_on_auth=true` and `auth_key="user_id"`, `SessionMiddleware`
also rotates an existing session automatically when `getsession(req)["user_id"]` is added,
removed, or changed. Keep `regenerate_session!` in login/logout flows when you want the
rotation to happen immediately inside the handler or when your authenticated principal
uses a different session key.

## Session Stores

### In-Memory (development)

The built-in `MemoryStore` keeps sessions in a process-local, size-bounded LRU. Sessions are lost
on restart and are not shared between processes. It holds at most `max_sessions` (default
`100_000`). Once full, each new session evicts the least recently used one, and the store warns
once. A flood of new sessions therefore logs idle users out instead of exhausting memory.

```julia
store = MemoryStore()                          # up to 100_000 sessions
store = MemoryStore(max_sessions = 500_000)    # raise the bound

serve(middleware=[
    SessionMiddleware(store=store, secure=false),
])
```

### PormG-Backed (production)

`pormg_nitro_session()` creates the `nitro_session` table with `IF NOT EXISTS`,
sets up the expiry index, and returns a ready-to-use store.

```julia
using Nitro, PormG

PormG.Configuration.load("db")

store = pormg_nitro_session(db_key="db")

serve(middleware=[
    SessionMiddleware(store=store, max_age=3600, secure=true),
])
```

Sessions are stored as JSON in the database with a fixed-point expiry timestamp
(no sliding expiry). Works with any PormG-supported backend (SQLite, PostgreSQL).

Session data may nest at most **512** levels, the same limit Nitro puts on request JSON.
Storing anything deeper throws an `ArgumentError` when the session is saved, instead of writing
a session that could never be read back. Real session data is a few levels deep; a recursive
structure is the only way to get near the limit. The in-memory store serializes nothing and has
no such limit, so a test suite on `MemoryStore` will not catch it.

The default `db_key` is `"db"`. Use a different one when your session database uses another
PormG connection, for example `db_key="sessions"` — the key selects the connection the table is
created on *and* the one every session query runs against, so the two can never disagree.

Unlike `MemoryStore`, the table has no size limit unless you give it one. If public routes write
to sessions before sign-in, pass `max_sessions`:
`pormg_nitro_session(db_key="db", max_sessions=1_000_000)`. New anonymous sessions also start
with a short, *unconfirmed* lifetime until the browser returns the cookie. For both, and for
sizing, see
[Anonymous Sessions and Floods](cookies/sessions.md#Anonymous-Sessions-and-Floods).

!!! note "Sessions inside a PormG transaction"
    The store's `nitro_session` model is bound to `db_key`, so session reads and writes work
    normally inside a `PormG.run_in_transaction(db_key)` block — logging a user out in the same
    transaction that writes an audit row, for instance.

    A session call inside a transaction opened on a **different** connection raises PormG's
    `TransactionError`, which names the `run_in_transaction` call you need. Move the session
    operation outside that block, or open the transaction on the store's own connection.

### Custom Stores

Five methods are **required** for your store type `S <: AbstractSessionStore{String, Dict{String,Any}}`:

```julia
Base.get(store::S, session_id::String, default)                     # → SessionPayload or default
set_session!(store::S, session_id::String, data; ttl)               # → persist data with TTL (insert or overwrite)
update_session!(store::S, session_id::String, data; ttl)            # → overwrite a LIVE session only; Bool
rotate_session!(store::S, old_id::String, new_id::String, data; ttl) # → move a LIVE session to a new id; Bool
delete_session!(store::S, session_id::String)                       # → remove a session
```

`Base.get` is easy to overlook and is not optional — both `get_session` and the session
middleware's own load path call it directly.

`update_session!` is how `SessionMiddleware` writes back a session the request loaded. It must
write **only if** the session still exists and has not expired, and return `false` (writing
nothing) otherwise. That is what stops a slow request from re-creating a session that a
concurrent logout just deleted. Make the check and the write one atomic step (an
`UPDATE … WHERE`, or one lock hold). A store *failure* must throw, not return `false`: `false`
means "logged out" and the middleware drops the write.

`rotate_session!` is how `regenerate_session!` moves a session to a new ID, and the same rule
applies: move it **only if** the old ID still exists and has not expired, as one atomic step, and
return `false` otherwise. Otherwise a request that rotates after a concurrent logout copies the
logged-out session into a fresh ID. In SQL without a key update, a guarded
`DELETE … WHERE key = old AND expires > now` whose row count decides, followed by the `INSERT`,
is enough.

The `SessionPayload` that `Base.get` returns carries three things: `data`, `expires`, and
`created`, the instant the session was first stored. `set_session!` sets `created`,
`update_session!` keeps it, and `rotate_session!` carries it to the new ID.
`SessionMiddleware(absolute_max_age = …)` measures a session's absolute lifetime from it, so a
store that reset it on every write would let sessions live forever.

A sixth is **optional**:

```julia
cleanup_expired_sessions!(store::S)                    # → prune expired entries
```

It defaults to doing nothing. Expiry is enforced when a session is *read* — `get_session`
refuses a payload whose expiry has passed — so a store that never prunes accumulates dead
rows but never serves a stale session. Implement it for any store whose rows outlive the
process.

So is a seventh, `session_store_full(store::S)` (→ `Bool`), which defaults to `false`. Answer
`true` to make `SessionMiddleware` stop saving new anonymous sessions once the store reaches a bound
of its own; signed-in and existing sessions are never refused. It runs on the request path, so
answer from a cached count. See
[Anonymous Sessions and Floods](cookies/sessions.md#Anonymous-Sessions-and-Floods).

**Deciding whether a payload has expired: call `is_expired`, do not compare `expires`
yourself.**

```julia
is_expired(payload)                 # against the current clock
is_expired(payload, current_time)   # against a clock you read once, for a prune sweep
```

The boundary counts as **expired**: a payload whose `expires` is exactly the instant you
compare against is refused, so a session is served only while `expires` is strictly in the
future. That one-character distinction is why the helper exists — the comparison used to be
written out at six sites and one of them drifted to the lenient form, which meant the
`Session{T}` extractor could serve a session the janitor had already deleted.

Pass the second argument when sweeping a whole store, so the clock is read once for the
sweep rather than once per row:

```julia
function cleanup_expired_sessions!(store::S)
    current_time = now(UTC)
    for (id, payload) in rows(store)
        is_expired(payload, current_time) && delete_session!(store, id)
    end
end
```

`SessionMiddleware` calls it from a **background janitor**, not from the request path: the
janitor starts on `serve()`, stops on `terminate()`, and ticks every `prune_interval`
(default 10 minutes). That is what the [`LifecycleMiddleware`](@ref Nitro.Core.Types.LifecycleMiddleware)
`SessionMiddleware` returns is for — its `on_startup`/`on_shutdown` hooks own the janitor's
lifetime.

```julia
SessionMiddleware(store = store, prune_interval = Minute(5))
```

If you reach sessions *without* `SessionMiddleware` — the `Session{T}` extractor reads the
store straight off the app context — add [`SessionPruner`](@ref) instead, or the store
grows for the life of the process:

```julia
serve(middleware = [SessionPruner(store; interval = Minute(5))], context = store)
```

The context must be the store itself, an `AbstractSessionStore{String}`. Any other context is not
read: every `Session{T}` parameter then binds no session, and Nitro logs one warning. A plain `Dict`
used to be indexed directly by the cookie's value, which let a client pick any entry of a context
that was really the app's configuration.

Your implementation runs on a background task, so keep it safe to call concurrently with
reads and writes, and keep the work it does under any lock bounded.

Omitting a required method raises `StoreInterfaceError`, which names the method and your
store type, rather than a bare `MethodError` from somewhere inside the middleware. Check a
store against the whole contract with `missing_session_methods`, which takes the type and
needs no instance:

```julia
using Test
using Nitro.Types: missing_session_methods   # not exported from `Nitro` itself

@test isempty(missing_session_methods(MySessionStore))
```

`Nitro.Workers.missing_store_methods` is the equivalent for the worker-queue contract
([`AbstractWorkerStore`](workers.md)).

## Using `getsession(req)` — Django-style

`getsession(req)` is a `Dict{String, Any}` injected by `SessionMiddleware`.
It works exactly like Django's `request.session`:

| Django (Python) | Nitro (Julia) |
|---|---|
| `request.session["user_id"] = 42` | `getsession(req)["user_id"] = 42` |
| `request.session.get("role", "guest")` | `get(getsession(req), "role", "guest")` |
| `del request.session["cart"]` | `delete!(getsession(req), "cart")` |
| `request.session.flush()` | `empty!(getsession(req)); regenerate_session!(req, store; ttl=3600)` |
| `"user_id" in request.session` | `haskey(getsession(req), "user_id")` |

Changes are automatically detected and persisted at the end of the request.
You do not need to call a save method.

A **new** session is saved, and its cookie set, only once it is used: once the handler stores
something in it, rotates it, or sets `req.context[:session_modified] = true`. That is the
equivalent of Django's `request.session.modified = True`. A request that never touches the
session, such as a health check or a static file, creates nothing. Set the flag yourself when you
hand the client something bound to `req.context[:session_id]` without writing to the session.
`CSRFMiddleware` sets it whenever it issues a token. It issues one to a new visitor only when a
handler asks, so a global `CSRFMiddleware` does not create sessions either (see
[When a token is issued](#When-a-token-is-issued)).

`empty!(getsession(req))` only clears the current payload. For the default `user_id`-based flow,
`SessionMiddleware` now rotates an existing session automatically when auth state changes.
Call `regenerate_session!` explicitly if you want that rotation to happen immediately in the
current handler or if your authenticated principal uses a different session key.

### Store data

```julia
function login_handler(req::HTTP.Request)
    # ... validate credentials ...
    getsession(req)["user_id"]   = user[:id]
    getsession(req)["username"]  = user[:username]
    getsession(req)["logged_in"] = string(Dates.now())
    return Res.json(Dict("status" => "ok"))
end
```

### Read data

```julia
function dashboard_handler(req::HTTP.Request)
    user_id = get(getsession(req), "user_id", nothing)
    if isnothing(user_id)
        return Res.json(Dict("error" => "Login required"); status=401)
    end
    return Res.json(Dict("user_id" => user_id))
end
```

### Update / append data

Because `getsession(req)` is a plain `Dict{String, Any}`, you update or append with
the same Julia idioms you would use on any dictionary.

**Overwrite a key:**

```julia
function update_role_handler(req::HTTP.Request)
    getsession(req)["role"] = "admin"       # replaces previous value
    return Res.json(Dict("status" => "role updated"))
end
```

**Append to a list stored in the session:**

```julia
function add_to_cart_handler(req::HTTP.Request, product_id::Int)
    cart = get(getsession(req), "cart", Int[])   # default to empty list
    push!(cart, product_id)
    getsession(req)["cart"] = cart               # write back
    return Res.json(Dict("cart" => cart))
end
```

**Merge a sub-dict (bulk update):**

```julia
function update_prefs_handler(req::HTTP.Request)
    patch = getjson(req)                         # e.g. Dict("theme" => "dark")
    prefs = get(getsession(req), "prefs", Dict{String,Any}())
    merge!(prefs, patch)
    getsession(req)["prefs"] = prefs
    return Res.json(Dict("prefs" => prefs))
end
```

All changes are automatically persisted at the end of the request by `SessionMiddleware`.

### Delete keys

```julia
function remove_cart_handler(req::HTTP.Request)
    delete!(getsession(req), "cart")
    return Res.json(Dict("status" => "cart cleared"))
end
```

### Flush / logout

```julia
function logout_handler(req::HTTP.Request)
    empty!(getsession(req))
    regenerate_session!(req, store; ttl=3600)
    return Res.json(Dict("message" => "Logged out"))
end
```

This invalidates the previous authenticated session on the server side and writes a fresh anonymous session cookie on the response.

That ends only the session that sent the logout. To end every session of the user, on every device,
configure `SessionMiddleware(session_auth_hash = …)`; see
[Signing Out Everywhere](cookies/sessions.md#Signing-Out-Everywhere).

## Session Regeneration

After login or any privilege change, regenerate the session ID to prevent session-fixation attacks:

```julia
function login_handler(req::HTTP.Request)
    # ... validate credentials ...
    getsession(req)["user_id"] = user[:id]

    # Cycle the session ID — works with any store backend.
    regenerate_session!(req, store; ttl=3600)

    return Res.json(Dict("status" => "ok"))
end
```

`regenerate_session!` moves the current session data to a new ID, removes the old
session, and updates the request context so `SessionMiddleware` writes the new
cookie automatically. In practice, use the same `ttl` you want for the rotated session.

The move is atomic: it happens only if the old session still exists. If a concurrent
request logged the session out while this one was running, `regenerate_session!` returns
`nothing`, nothing is copied into a new ID, and no cookie is set.

If you keep the default `auth_key="user_id"`, `SessionMiddleware` also performs this
rotation automatically for existing sessions whose auth state changes during the request.
Use explicit `regenerate_session!` calls for custom auth keys or for flows where you want
the rotation to happen before the handler finishes.

## Unified Auth Context

`SessionMiddleware` manages state (`getsession(req)`) but does not automatically
populate `getuser(req)`. Write a small middleware to bridge them:

```julia
# The scalar values `login_required` and the claim guards refuse as a login marker.
is_login_marker(uid) = !(uid === nothing || uid === missing || uid isa Bool || uid == "")

function SessionAuthMiddleware(handle)
    return function(req::HTTP.Request)
        session = getsession(req)
        # Check the VALUE, not just the key: a logout that set `user_id` to `nothing`, `false`
        # or `""` must not leave a `Dict("id" => "", "role" => "admin")` behind — a non-empty
        # dict is an identity, and `role_required` would authorize off it.
        uid = isnothing(session) ? nothing : get(session, "user_id", nothing)
        if is_login_marker(uid)
            req.context[:user] = Dict(
                "id"   => uid,
                "role" => get(session, "role", "user"),
            )
        end
        return handle(req)
    end
end

urlpatterns("",
    path("/dashboard", dashboard, method="GET", middleware=[
        SessionAuthMiddleware,
        GuardMiddleware(login_required()),
    ]),
)
```

## JWT Helpers

`Nitro.Auth` provides stateless JWT helpers with HS256 signing and claim validation.

```julia
using Nitro
using Nitro.Auth

jwt_secret = get(ENV, "JWT_SECRET", nothing)
isnothing(jwt_secret) && error("JWT_SECRET must be set")

validator = jwt_validator(jwt_secret)

function profile(req::HTTP.Request)
    return Res.json(Dict("sub" => getuser(req)["sub"]))
end

urlpatterns("",
    path("/profile", profile, method="GET", middleware=[BearerAuth(validator)]),
)
```

`jwt_validator` returns a normalized [`Principal`](authentication.md): the
verified claims stay readable dict-style (`getuser(req)["sub"]`, as above), and the resolved
identity is available as a typed field — `getuser(req).id` is the `sub` claim by default
(configurable via `identity_claim`, or derive it from the verified key id with
`identity_from=:kid`). See [Authentication](authentication.md) for the full contract.

You can also pass a keyset — one signing key, plus keys that only verify — for rotation:

```julia
required_env(name::String) = get(ENV, name, nothing) === nothing ? error("$name must be set") : ENV[name]

keyset = JWTKeyset(
    "current" => required_env("JWT_SECRET_CURRENT");
    verify = ["previous" => required_env("JWT_SECRET_PREVIOUS")],
)
token = encode_jwt(Dict("sub" => "42", "exp" => trunc(Int, time()) + 300), keyset)  # kid = "current"
claims = decode_jwt(token, keyset)
claims["sub"]    # "42"
```

`decode_jwt` returns the claims as a `Dict{String, Any}`, nested objects included. Read them
by **string** key: `claims["sub"]`, not `claims[:sub]` or `claims.sub`. The values are
whatever JSON the token carried.

`validate_claims` checks `exp`, `iat`, `nbf`, `iss`, and `aud` when present.

## Service and Capability Tokens

Not every token identifies a *user*. A **service token** authorizes a *capability*: it
carries an `action` (or scope) claim instead of a `sub`/`user_id`. This is the common
shape for service-to-service calls — one backend calling your API on behalf of no
particular person.

```julia
using Nitro.Auth

# A caller mints a short-lived token that authorizes one action.
token = encode_jwt(Dict(
    "app"    => "analytics-service",
    "action" => "reports:generate",
    "iat"    => trunc(Int, time()),
    "exp"    => trunc(Int, time()) + 300,
), jwt_secret)
```

`BearerAuth(jwt_validator(jwt_secret))` verifies the signature and attaches the decoded
claims as `getuser(req)`. Because the claims *are* the identity here, `getuser(req)` has no
`sub`/`user_id` — and that is fine:

- **`login_required` only checks that a validly-signed token is present.** It trusts any
  non-empty principal an auth middleware attached, so an `action`-keyed token (no `user_id`)
  passes.
  The `user_id` marker is required only on the raw-`getsession(req)` fallback, never on a
  principal that `BearerAuth` already authenticated.

To authorize the specific action, declare it with `claim_required`:

```julia
# 403 unless getuser(req)["action"] == "reports:generate"
authorize_generate = claim_required("action", "reports:generate")

function generate_report(req::HTTP.Request)
    return Res.json(Dict("status" => "queued", "requested_by" => getuser(req)["app"]))
end

urlpatterns("",
    path("/reports/generate", generate_report, method="POST", middleware=[
        BearerAuth(jwt_validator(jwt_secret)),
        GuardMiddleware(authorize_generate),
    ]),
)
```

For list-shaped claims (permissions, scopes), use `kind=:contains`:

```julia
# 403 unless "reports:read" in getuser(req)["scopes"]
GuardMiddleware(claim_required("scopes", "reports:read"; kind=:contains))
```

`role_required` and `permission_required` are thin aliases over `claim_required`, so the
older key-parameterized form (`role_required("reports:generate"; role_key="action")`)
still works and behaves identically.

### Tokens with `iat` but no `exp`

Short-lived service tokens sometimes carry only `iat`. Nitro accepts them (`decode_jwt`
does not require `exp` by default) but still bounds replay by enforcing a **maximum age
from `iat`** (about 15 minutes by default). Set `exp_timeout` to at least the token's real
lifetime so legitimate tokens are not rejected:

```julia
# accept iat-only tokens up to 5 minutes old
validator = jwt_validator(jwt_secret; exp_timeout=300)
```

### Key rotation with `kid`

When the signer sets a `kid` header, pass a keyset instead of a single secret; `decode_jwt`
reads the header's `kid` to select the matching key. A token that carries **no** `kid` is tried
against every key in the set — the signing key first, then the rest by name — so a foreign
issuer still signing with the old secret keeps working through the rotation window. See
[Key rotation and the `kid` trust model](authentication.md#Key-rotation-and-the-kid-trust-model)
for the full contract, including how a plain `Dict` is lifted into a keyset and why a keyset may
not hold one secret under two names.

```julia
keys = JWTKeyset("current" => current_secret; verify = ["previous" => previous_secret])
validator = jwt_validator(keys)
```

With a keyset, the *verified* key id is exposed as `getuser(req).kid`, which unlocks two more
patterns (both covered in depth in [Authentication](authentication.md)):

```julia
# Authorize by signer: only tokens signed by these keys may reach this route.
GuardMiddleware(kid_required(["service-a", "service-b"]))

# One key per caller? Make the signer the principal: getuser(req).id == verified kid.
validator = jwt_validator(keys; identity_from=:kid)
```

Note the trust boundary: a `kid` is only *verified* when resolved against a keyset. With a
single string secret the header `kid` is an unchecked label, so `kid_required` denies and
`identity_from=:kid` is a construction-time error.

## Auth Cookies and CSRF

Use the higher-level cookie helpers for auth tokens:

```julia
using Nitro.Auth

res = HTTP.Response(200)
token = encode_jwt(Dict("sub" => "42"), secret; expires_in = 900)
set_auth_cookie!(res, token; ttl = 900, secure = false)
```

**`ttl` is required and has no default.** `set_auth_cookie!` is handed an opaque string and
never decodes it, so it cannot know when the credential inside dies — pass the same number
you passed to `encode_jwt` as `expires_in`. A cookie that outlives its token is not an
authorization hole (the token still fails validation), but it is the confusing shape: the
browser keeps sending a credential guaranteed to `401`, so every request looks like a server
fault rather than an expired session. If you minted without `expires_in`, the token is bounded
by `decode_jwt`'s `iat + exp_timeout` fallback instead, which defaults to 900 seconds.

One exception: when you re-set a token minted in an *earlier* request — a refresh flow, or a
re-login that reuses a live token — `expires_in` is too long, because `Max-Age` counts from
delivery while `exp` counts from `iat`. Pass what is left, `claims["exp"] - trunc(Int, time())`.

For cookie-authenticated browsers, load the CSRF secret from the environment and add
`CSRFMiddleware` to the global pipeline:

```julia
csrf_secret = get(ENV, "CSRF_SECRET", nothing)
isnothing(csrf_secret) && error("CSRF_SECRET must be set")

serve(middleware=[
    SessionMiddleware(store=store),       # must be OUTSIDE CSRFMiddleware
    CSRFMiddleware(csrf_secret),
])
```

Read it with a `nothing` default, as above, not `get(ENV, "CSRF_SECRET", "")`: an empty secret —
or any run of up to 64 NUL bytes, which HMAC treats as the same empty key — is refused with an
`ArgumentError` at construction, because a token signed under it is one anyone can sign.
`issue_csrf_token!` and `validate_csrf_token` refuse it on every call too.

The middleware uses a signed double-submit cookie. Unsafe requests (anything but `GET`, `HEAD`,
`OPTIONS` and `TRACE`) must echo the token in the `X-CSRF-Token` header, in a `_csrf` form field,
or in a `_csrf` JSON body key, or they are refused with `403`.

### When a token is issued

A token is bound to a session, so issuing one to a new visitor means storing a session for them.
`CSRFMiddleware` therefore issues a token only when the client will use it:

- **A handler asks for it** with [`csrf_token!(req)`](@ref csrf_token!), to put it in a form or hand it to a single-page
  app. It returns the token, and the middleware sets the matching cookie on the
  response.
- **The session is saved anyway**: the visitor already has one, or this request wrote to it or
  rotated it. The token then costs nothing extra, so the middleware issues it unasked.

Anything else gets no token and no session. That covers health checks, bearer-token API clients,
uptime probes and scanners, and every other cookieless request that never touches the session. So
global placement is safe, even with a database-backed session store. It used to be otherwise:
until [#431](https://github.com/PingoLee/Nitro.jl/issues/431) the middleware issued a token on
every safe response and kept a session for each one, so every cookieless `GET` was a store write.

This is the model Django (`get_token`), Spring Security 6 (deferred CSRF tokens), Rails and
Phoenix all use. A token is created when something renders it, not on every request.

Issuing a token also **keeps the session it is bound to**. It sets
`req.context[:session_modified]`, so an anonymous visitor's session is saved and their token still
verifies on the next request.

### Server-rendered forms

Call `csrf_token!` where the form is built, and put the value in a hidden `_csrf` field. It works
on the very first visit: the token exists as soon as the handler asks for it.

```julia
function login_form(req::HTTP.Request)
    return Res.html("""
        <form method="post" action="/login">
          <input type="hidden" name="_csrf" value="$(csrf_token!(req))">
          <input name="username"> <input name="password" type="password">
          <button>Sign in</button>
        </form>""")
end

urlpatterns("",
    path("/login", login_form, method="GET"),
    path("/login", AuthHandlers.login, method="POST"),
)
```

The token is URL-safe base64 (`A-Z a-z 0-9 - _`), so it is safe to interpolate into HTML as-is.
A client that already holds a valid token gets the same one back, and its cookie is re-sent, so
the cookie's lifetime (`ttl`, seven days by default) starts again from the page that embeds it.

"The same one" means the same token under a **different mask**: `csrf_token!` returns a new
string on every call, and every one of them verifies. That is what keeps the token safe in a page
your proxy compresses. A compressed response that carries a fixed secret next to input the
attacker controls, such as a search term echoed into the page, leaks the secret through its
length, one byte at a time. This is the BREACH attack, and the proxy setups in
[the reverse-proxy guide](reverse_proxy.md) do compress. A value that changes on every response
leaves nothing to leak ([#436](https://github.com/PingoLee/Nitro.jl/issues/436)). It is the same
one-time-pad mask Django, Rails and Spring Security 6 use. So never compare two tokens with `==`:
they are equal only through the middleware.

A handler that rotates the session (a login does) must call `csrf_token!` **after**
`regenerate_session!`. Rotation retires the client's existing token, as Django's `rotate_token`
does: a token taken before the rotation is replaced in the cookie, and the copy in the page stops
working.

### Single-page apps

An SPA shell served by [`spafiles`](@ref) has no handler to call `csrf_token!`. Give the app an
endpoint that does, and call it once at startup:

```julia
csrf(req::HTTP.Request) = Res.json(Dict("token" => csrf_token!(req)))

urlpatterns("", path("/api/csrf", csrf, method="GET"))
```

```javascript
// Once, when the app boots.
const { token } = await (await fetch("/api/csrf", { credentials: "same-origin" })).json();

// On every mutation.
await fetch("/api/products", {
  method: "POST",
  credentials: "same-origin",
  headers: { "Content-Type": "application/json", "X-CSRF-Token": token },
  body: JSON.stringify({ name: "Lamp" }),
});
```

Fetch the token again in two cases:

- **after a login or a logout.** Both rotate the session, and a token belongs to the session it
  was issued for.
- **on a `403` from a mutation**, then retry the request once. The token in memory can outlive the
  session it is bound to: the session expires, or another tab logs out, while this tab sits idle.

The cookie itself lasts `ttl` seconds after the app last fetched the token: seven days by default,
the same as `SessionMiddleware`'s default `absolute_max_age`, so with default settings it does not
expire before its session. If you raise your session lifetimes, raise `ttl` with them. A longer
`ttl` costs nothing: a token stops verifying when its session ends, whatever its cookie says. The
retry on `403` is what makes the app correct, so keep it either way.

The cookie is readable by JavaScript, so an app can instead read the token from `document.cookie`
before each mutation. The raw token is the part before the first `.`, and the middleware accepts
it as well as the masked one. Masking is about response *bodies*: the cookie is never in one, so
echoing its raw token in a request header reopens nothing.

### Bearer-token API clients

An app often serves a browser UI with a session cookie and an API with bearer tokens from the
same pipeline. The API's clients have no CSRF token and no use for one, so `CSRFMiddleware`
lets an unsafe request through without one when **both** of these hold
([#438](https://github.com/PingoLee/Nitro.jl/issues/438)):

- it carries `Authorization: Bearer <token>` (the scheme in any case), and
- it carries **no `Cookie` header at all**.

CSRF exists because a browser attaches cookies to a cross-site request on its own. It never adds
an `Authorization` header that way: a page on another origin can set one only with `fetch`, after
a CORS preflight your `Cors` middleware would have to allow. A request with a bearer header and
no cookie therefore has nothing a forger could borrow. Django REST Framework draws the same line:
its token and JWT authentication skip CSRF, and only `SessionAuthentication` enforces it.

The middleware does not check the bearer token. It only decides whether a token check is needed;
`BearerAuth` or your handler still has to authenticate the request.

The reasoning assumes a request's authority comes from a credential. A route authorized by
**network position** instead, such as an intranet-only endpoint or an IP allow-list, is the
exception: if your `Cors` lets an untrusted origin send `Authorization` (it must be listed by name;
`allowed_headers = ["*"]` does not cover it), a page in a victim's browser can reach that route
from inside their network. Use `exempt_bearer = false` there.

**Any cookie keeps the check on**, even one `CSRFMiddleware` knows nothing about, such as a load
balancer's affinity cookie. The middleware cannot see your session or auth cookie names, and a
request with both a bearer header and a session cookie is exactly what a page that won a
permissive CORS policy could send. An API client that also carries cookies must send a token, or
go through routes without the session and CSRF layers.

To check bearer-only requests anyway, opt out:

```julia
CSRFMiddleware(csrf_secret; exempt_bearer = false)
```

### Placement and binding

**`SessionMiddleware` must sit outside `CSRFMiddleware`.** The token's signature covers the
session id as well as the random token value, so a token minted for one visitor does not
validate for another. That binding is read from `req.context[:session_id]`, which only exists
once `SessionMiddleware` has run. With no session available Nitro **fails closed**: it issues
no token and rejects every unsafe request with `403`, after logging a warning naming this
ordering rule. It does not silently fall back to an unbound token.

The cookie is named `__Host-csrf_token` by default. The `__Host-` prefix is what stops a sibling
subdomain from overwriting it — without it, an attacker who can write cookies for your domain can
plant their own validly-signed token as the victim's. Browsers only accept the prefix on a
`Secure`, `Path=/`, `Domain`-less cookie, so `CSRFMiddleware` throws an `ArgumentError` at
construction if the config would violate that, rather than letting the browser discard the cookie
in silence. Serving over plain HTTP in development? Pass a plain name:

```julia
CSRFMiddleware(csrf_secret;
    cookie_name = "csrf_token",
    config = CookieConfig(httponly=false, secure=false, samesite="Lax", path="/"))
```

Because the cookie is deliberately readable by JavaScript, only the *HMAC* of the session id
travels in it — never the session id itself.

A session rotation invalidates the token bound to the old session, so the middleware re-issues
whenever the presented cookie would not verify under the current session. A handler that calls
`regenerate_session!` gets a fresh, usable CSRF cookie in the same response. To put that token in
the response body too, call `csrf_token!` after the rotation.

`SessionMiddleware`'s own `rotate_on_auth` is the awkward case: it rotates *after* `CSRFMiddleware`
has returned, so the login response cannot carry the replacement and the client's token is orphaned
the moment it lands. The next mutation is therefore refused, but that `403` carries a fresh, valid
token in its cookie, so the client refetches the token (or reads the cookie) and retries once. Without that, an SPA that only ever issues unsafe
requests after login would never see a safe response and would stay locked out.

That re-issue gives nothing away: the token is bound to the *requester's own* session and travels
in the *requester's own* response, so it is exactly what a `GET` would have handed them. What keeps
it from being used to churn someone else's token is the cookie configuration — `__Host-` means an
attacker cannot plant a CSRF cookie in a victim's browser, and `SameSite=Lax` means a cross-site
unsafe request does not carry the CSRF cookie at all, so the request is refused with no token
attached. If you opt out of **both** (an unprefixed `cookie_name` *and* `samesite="None"`, which a
cross-origin SPA needs), an attacker with a cookie-write position on a sibling origin can force a
victim's CSRF token to rotate — a nuisance rather than a bypass, but weigh it before opting out.