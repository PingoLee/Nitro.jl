# Sessions and Auth

Nitro treats session storage and authenticated user resolution as separate concerns.

- `SessionMiddleware` manages server-side session state via `req.session`.
- `BearerAuth` extracts credentials and attaches the authenticated principal.
- Guards read `req.user`, so they work the same way for session-backed and JWT-backed routes.

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
    payload = req.json
    username = get(payload, "username", "")
    password = get(payload, "password", "")

    user = M.User.objects.filter("username" => username).first()
    if isnothing(user) || !check_password(password, user[:password])
        return Res.json(Dict("error" => "Invalid credentials"); status=401)
    end

    # Store data in the session — like Django's request.session
    req.session["user_id"]  = user[:id]
    req.session["username"] = user[:username]
    req.session["role"]     = user[:is_staff] ? "staff" : "user"

    # Rotate the session ID after authentication to prevent fixation.
    regenerate_session!(req, store; ttl=3600)

    return Res.json(Dict("message" => "Welcome $(user[:username])!"))
end

function me_handler(req::HTTP.Request)
    user_id = get(req.session, "user_id", nothing)
    if isnothing(user_id)
        return Res.json(Dict("error" => "Not authenticated"); status=401)
    end
    return Res.json(Dict(
        "user_id"  => user_id,
        "username" => req.session["username"],
        "role"     => req.session["role"],
    ))
end

function logout_handler(req::HTTP.Request)
    empty!(req.session)
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
serve(urlpatterns, middleware=[
    SessionMiddleware(store=store, cookie_name="nitro_sess", secure=false, samesite="Lax"),
])
```

The `secure=false` example is for local HTTP development only. Keep `secure=true` in production.

With the default `rotate_on_auth=true` and `auth_key="user_id"`, `SessionMiddleware`
also rotates an existing session automatically when `req.session["user_id"]` is added,
removed, or changed. Keep `regenerate_session!` in login/logout flows when you want the
rotation to happen immediately inside the handler or when your authenticated principal
uses a different session key.

## Session Stores

### In-Memory (development)

The built-in `MemoryStore` keeps sessions in a process-local dictionary.
Sessions are lost on restart.

```julia
store = MemoryStore{String, Dict{String,Any}}()

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

### Custom Stores

Implement these four methods for your store type `S <: AbstractSessionStore{String, Dict{String,Any}}`:

```julia
Base.get(store::S, session_id::String, default)       # → SessionPayload or default
set_session!(store::S, session_id::String, data; ttl)  # → persist data with TTL
delete_session!(store::S, session_id::String)           # → remove a session
cleanup_expired_sessions!(store::S)                     # → prune expired entries
```

## Using `req.session` — Django-style

`req.session` is a `Dict{String, Any}` injected by `SessionMiddleware`.
It works exactly like Django's `request.session`:

| Django (Python) | Nitro (Julia) |
|---|---|
| `request.session["user_id"] = 42` | `req.session["user_id"] = 42` |
| `request.session.get("role", "guest")` | `get(req.session, "role", "guest")` |
| `del request.session["cart"]` | `delete!(req.session, "cart")` |
| `request.session.flush()` | `empty!(req.session); regenerate_session!(req, store; ttl=3600)` |
| `"user_id" in request.session` | `haskey(req.session, "user_id")` |

Changes are automatically detected and persisted at the end of the request.
You do not need to call a save method.

`empty!(req.session)` only clears the current payload. For the default `user_id`-based flow,
`SessionMiddleware` now rotates an existing session automatically when auth state changes.
Call `regenerate_session!` explicitly if you want that rotation to happen immediately in the
current handler or if your authenticated principal uses a different session key.

### Store data

```julia
function login_handler(req::HTTP.Request)
    # ... validate credentials ...
    req.session["user_id"]   = user[:id]
    req.session["username"]  = user[:username]
    req.session["logged_in"] = string(Dates.now())
    return Res.json(Dict("status" => "ok"))
end
```

### Read data

```julia
function dashboard_handler(req::HTTP.Request)
    user_id = get(req.session, "user_id", nothing)
    if isnothing(user_id)
        return Res.json(Dict("error" => "Login required"); status=401)
    end
    return Res.json(Dict("user_id" => user_id))
end
```

### Update / append data

Because `req.session` is a plain `Dict{String, Any}`, you update or append with
the same Julia idioms you would use on any dictionary.

**Overwrite a key:**

```julia
function update_role_handler(req::HTTP.Request)
    req.session["role"] = "admin"       # replaces previous value
    return Res.json(Dict("status" => "role updated"))
end
```

**Append to a list stored in the session:**

```julia
function add_to_cart_handler(req::HTTP.Request, product_id::Int)
    cart = get(req.session, "cart", Int[])   # default to empty list
    push!(cart, product_id)
    req.session["cart"] = cart               # write back
    return Res.json(Dict("cart" => cart))
end
```

**Merge a sub-dict (bulk update):**

```julia
function update_prefs_handler(req::HTTP.Request)
    patch = req.json                         # e.g. Dict("theme" => "dark")
    prefs = get(req.session, "prefs", Dict{String,Any}())
    merge!(prefs, patch)
    req.session["prefs"] = prefs
    return Res.json(Dict("prefs" => prefs))
end
```

All changes are automatically persisted at the end of the request by `SessionMiddleware`.

### Delete keys

```julia
function remove_cart_handler(req::HTTP.Request)
    delete!(req.session, "cart")
    return Res.json(Dict("status" => "cart cleared"))
end
```

### Flush / logout

```julia
function logout_handler(req::HTTP.Request)
    empty!(req.session)
    regenerate_session!(req, store; ttl=3600)
    return Res.json(Dict("message" => "Logged out"))
end
```

This invalidates the previous authenticated session on the server side and writes a fresh anonymous session cookie on the response.

## Session Regeneration

After login or any privilege change, regenerate the session ID to prevent session-fixation attacks:

```julia
function login_handler(req::HTTP.Request)
    # ... validate credentials ...
    req.session["user_id"] = user[:id]

    # Cycle the session ID — works with any store backend.
    regenerate_session!(req, store; ttl=3600)

    return Res.json(Dict("status" => "ok"))
end
```

`regenerate_session!` copies the current session data to a new ID, deletes the old
session, and updates the request context so `SessionMiddleware` writes the new
cookie automatically. In practice, use the same `ttl` you want for the rotated session.

If you keep the default `auth_key="user_id"`, `SessionMiddleware` also performs this
rotation automatically for existing sessions whose auth state changes during the request.
Use explicit `regenerate_session!` calls for custom auth keys or for flows where you want
the rotation to happen before the handler finishes.

## Unified Auth Context

`SessionMiddleware` manages state (`req.session`) but does not automatically
populate `req.user`. Write a small middleware to bridge them:

```julia
function SessionAuthMiddleware(handle)
    return function(req::HTTP.Request)
        session = req.session
        if !isnothing(session) && haskey(session, "user_id")
            req.context[:user] = Dict(
                "id"   => session["user_id"],
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
    return Res.json(Dict("sub" => req.user["sub"]))
end

urlpatterns("",
    path("/profile", profile, method="GET", middleware=[BearerAuth(validator)]),
)
```

`jwt_validator` returns a normalized [`Principal`](authentication.md): the
verified claims stay readable dict-style (`req.user["sub"]`, as above), and the resolved
identity is available as a typed field — `req.user.id` is the `sub` claim by default
(configurable via `identity_claim`, or derive it from the verified key id with
`identity_from=:kid`). See [Authentication](authentication.md) for the full contract.

You can also pass a keyset with `kid` values for rotation:

```julia
required_env(name::String) = get(ENV, name, nothing) === nothing ? error("$name must be set") : ENV[name]

keys = Dict(
    "default" => required_env("JWT_SECRET_PRIMARY"),
    "rotated" => required_env("JWT_SECRET_ROTATED"),
)
token = encode_jwt(Dict("sub" => "42", "exp" => trunc(Int, time()) + 300), keys; kid="rotated")
claims = decode_jwt(token, keys)
```

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
claims as `req.user`. Because the claims *are* the identity here, `req.user` has no
`sub`/`user_id` — and that is fine:

- **`login_required` only checks that a validly-signed token is present.** It trusts any
  principal an auth middleware attached, so an `action`-keyed token (no `user_id`) passes.
  The `user_id` marker is required only on the raw-`req.session` fallback, never on a
  principal that `BearerAuth` already authenticated.

To authorize the specific action, declare it with `claim_required`:

```julia
# 403 unless req.user["action"] == "reports:generate"
authorize_generate = claim_required("action", "reports:generate")

function generate_report(req::HTTP.Request)
    return Res.json(Dict("status" => "queued", "requested_by" => req.user["app"]))
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
# 403 unless "reports:read" in req.user["scopes"]
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
reads the header's `kid` to select the matching key:

```julia
keys = Dict("primary" => primary_secret, "rotated" => rotated_secret)
validator = jwt_validator(keys)
```

With a keyset, the *verified* key id is exposed as `req.user.kid`, which unlocks two more
patterns (both covered in depth in [Authentication](authentication.md)):

```julia
# Authorize by signer: only tokens signed by these keys may reach this route.
GuardMiddleware(kid_required(["service-a", "service-b"]))

# One key per caller? Make the signer the principal: req.user.id == verified kid.
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
set_auth_cookie!(res, "jwt-token"; secure=false)
```

For cookie-authenticated browsers, load the CSRF secret from the environment and add `CSRFMiddleware` to unsafe routes:

```julia
csrf_secret = get(ENV, "CSRF_SECRET", nothing)
isnothing(csrf_secret) && error("CSRF_SECRET must be set")

serve(urlpatterns, middleware=[
    CSRFMiddleware(csrf_secret; config=CookieConfig(httponly=false, secure=true, samesite="Lax")),
])
```

The middleware uses a signed double-submit cookie. Safe requests receive a CSRF cookie
automatically; unsafe requests must echo the token in the `X-CSRF-Token` header.