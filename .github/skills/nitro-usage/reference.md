# Nitro.jl — API Reference

Exhaustive signatures and defaults for application authors. Load this from
[`SKILL.md`](SKILL.md) only when you need an exact keyword or default; the common path is covered
there.

Everything here is the **public** surface exported by `using Nitro`. Internals (`HOFRouter`,
`register_internal`, `LazyRequest`) are not covered and are not stable.

---

## Routing

```julia
path(pattern::String, handler::Function;
     method::String     = "GET",
     methods            = nothing,        # Vector{String}; overrides `method`
     name               = nothing,        # for reverse lookup via url()
     middleware         = nothing)        # Vector; route-scoped
```

```julia
urlpatterns(prefix::String, routes...)                 # prefix is REQUIRED — "" for root
urlpatterns(prefix::String, routes::Vector{RouteDefinition})
include_routes(prefix::String, routes::Vector{RouteDefinition})
include_routes(prefix::String, routes::RouteDefinition...)
url(name::String; kwargs...)                           # reverse lookup by route name
```

### Path converters

Exactly five. An unknown name throws at `path()` time.

| Converter | Julia type | Example |
|-----------|-----------|---------|
| `<int:id>` | `Int` | `/products/<int:id>` |
| `<str:slug>` | `String` | `/posts/<str:slug>` |
| `<float:rate>` | `Float64` | `/fx/<float:rate>` |
| `<bool:flag>` | `Bool` | `/toggle/<bool:flag>` |
| `<uuid:key>` | `UUID` | `/tokens/<uuid:key>` |

---

## The request object

Exported accessor **functions** over the request. Prefer these over `req.context` lookups. The
param and body accessors (`getparams`, `getquery`, `getjson`, `getform`, `getpost`, `getfiles`,
`payload`) parse once per request and cache, returning a live handle — treat it as read-only.
`getsession`, `getuser` and `getip` are plain context lookups, not parsed or cached.

| Accessor | Type | Notes |
|----------|------|-------|
| `getparams(req)` | `Dict` or `nothing` | Path parameters, percent-decoded once; `nothing` before the router runs |
| `getquery(req)` | `Dict` | Query-string parameters |
| `getjson(req)` | parsed JSON or `nothing` | **Cached** per request; `nothing` unless the `Content-Type` is JSON (#327) |
| `getform(req)` | `Dict` | urlencoded body — **cached** |
| `getpost(req)` | `Dict{String, Union{String, Vector{String}}}` | Multipart *text* fields (Django `request.POST`) — **cached** |
| `getfiles(req)` | `Dict{String, Union{FormFile, Vector{FormFile}}}` | Multipart *file* parts (Django `request.FILES`) — **cached** |
| `payload(req)` | `Dict{String,Any}` | Merged: `params > post > form > json > query` |
| `getsession(req)` | `Dict` or `nothing` | Needs `SessionMiddleware` |
| `getuser(req)` | anything, or `nothing` | Set by an auth middleware; a `Principal` only when `jwt_validator` ran without a `user_validator` |
| `getip(req)` | IP or `nothing` | Needs `ExtractIP`; `getpeerip(req)` for the socket peer |
| `getcontext(req)` / `getcontext(req, T)` | app context | The object passed to `serve(context = …)`; use the typed form on the request path |
| `setsession!(req, v)` / `setip!(req, v)` | — | The two writers |

**There are no `req.<property>` shorthands.** `req.params`, `req.json`, `req.session` and the rest
were removed in #151 — a same-signature `Base.getproperty(::HTTP.Request, ::Symbol)` replaced
HTTP.jl's own method process-wide, which is type piracy on a foreign type. `req.<prop>` now raises
`FieldError`.

What still works on the request, because it is HTTP.jl's own: `req.context` (the metadata view —
the sanctioned place to pass values down a request), `req.version`, and the real fields
`req.method`, `req.target`, `req.body`, `req.headers`.

---

## Responses

### `Res` — the response builders

```julia
Res.json(data;                status::Int=200, headers::Vector=[])
Res.json(data::Vector{UInt8}; status::Int=200, headers::Vector=[])   # already-serialized JSON
Res.html(content::String;     status::Int=200, headers::Vector=[])
Res.send(body::String;        status::Int=200, headers::Vector=[],
         content_type::String="text/plain; charset=utf-8")
Res.send(body::Vector{UInt8}; status::Int=200, headers::Vector=[],
         content_type::String="application/octet-stream")
Res.status(code::Int;         headers::Vector=[])
Res.file(path::String;        status::Int=200, headers::Vector=[], filename=nothing,
         disposition::Union{Nothing,String}=nothing, loadfile=nothing)
Res.redirect(url::String;     status::Int=302, headers::Vector=[])
```

| Call | Content-Type | Notes |
|------|-------------|-------|
| `Res.html(s)` | `text/html` | **markup sink, escape first** |
| `Res.send(s)` | `text/plain` | |
| `Res.send(s; content_type=c)` | `c` | **markup sink when `c` is a markup/script type** |
| `mustache(...)` / `otera(...)` | sniffed, or `mime_type=` | **markup sink** — `{{x}}` escapes by default; `{{{x}}}`, `{{&x}}`, `\|> safe` and `autoescape = false` do not |
| `Res.send(b)` | octet-stream | `Vector{UInt8}`; **also a markup sink with `content_type=`** |
| `Res.json(x)` | `application/json` | any value; `Vector{UInt8}` is sent verbatim |
| `Res.file(p)` | sniffed from path | **inline**; `loadfile=` hook |
| `Res.file(p; disposition="attachment")` | sniffed | forced download; `filename=` alone implies attachment |
| `Res.status(n)` | — | empty body |
| `Res.redirect(u)` | — | **302**; `status=307` preserves method + body |

Caller-supplied `headers` are applied **last** and override the defaults, `Content-Type` included.

Only `Res.file` sets `Content-Length` explicitly; the others leave it to HTTP.jl, which computes it
from the body when the response is serialized.

### Request body parsers (same names, opposite direction)

`text(req)`, `json(req)`, `json(req, T)`, `binary(req)`, `formdata(req)`, `multipart(req)`, and the
`HTTP.Response` forms of each. These bare names are **parsers only** — response building lives in
`Res` (#28), so there is no longer a same-name builder to disambiguate against.

They differ from the `get*` accessors above in that they **re-parse on every call**, accept keyword
arguments, and also take an `HTTP.Response`. In a handler reach for `getjson(req)` / `getform(req)`;
reach for `json(req; …)` when you need a one-off parse with options. `multipart(req)` returns files
and text fields *together*, so it is not a substitute for `getfiles` or `getpost`.

---

## Extractors

Declared as a handler parameter. Unwrap with `.payload`.

| Extractor | Binds from |
|-----------|-----------|
| `Path{T}` | Path parameters |
| `Query{T}` | Query string |
| `Header{T}` | Request headers |
| `Json{T}` | Whole JSON body |
| `JsonFragment{T}` | One named object *inside* the JSON body (parameter name = key) |
| `Form{T}` | urlencoded form body |
| `Body` | Raw body |
| `Cookie` | A cookie (name = parameter name unless set) |
| `Session` | The app context, which must be an `AbstractSessionStore{String}` (e.g. `MemoryStore`); any other context binds no session |
| `Files{FormFile}` / `Files{Vector{FormFile}}` | Multipart file parts |
| `MultipartForm{T}` | Mixed multipart — text fields *and* files into one struct |

Two forms, and the difference matters:

```julia
# Type annotation — bind only
function handler(req, body::Json{Person}) ... end

# Default argument — bind AND validate (predicate returns Bool)
path("/x", function(req, body = Json{Person}(p -> p.age >= 18))
    body.payload
end, method="POST")
```

`T` must be constructible from its fields in declaration order (a plain `struct`) or by keyword (a
`@kwdef struct`, which also honors field defaults for absent keys). A failing predicate raises
`ValidationError` → HTTP 400.

### Binding rules that hold for every extractor

- **Fields are looked up by name**, from `T`'s field list (never the client's keys). Each binds
  like a scalar parameter of its type: `Nullable{T}`, `UUID`, `Date`, an `@enum` by integer
  **or** name. StructTypes customizations (`StructTypes.names`) are not consulted (#306).
- **No `Symbol` from request input.** A `::Symbol` parameter, `Body{Symbol}`, or a `Symbol`
  (or `Vector{Symbol}`, `Dict{Symbol,…}`, enum-keyed `Dict`) field of a bound struct is refused
  when the route is declared (`ArgumentError`): Julia never frees an interned `Symbol`. Use an
  `@enum` or a `String` checked against an allow-list (#306).
- **Content types are enforced.** `Json{T}`/`JsonFragment{T}` need `Content-Type:
  application/json` or `application/*+json` — anything else, including none, is **415**.
  `MultipartForm{T}` needs `multipart/form-data`, also 415. `getjson(req)` and `payload(req)`
  ignore a body that does not declare JSON (#327).
- **Floats must be finite.** `NaN`, `inf`, `1e999` are a 400 on every path (#327).
- **Field count is capped**: `serve(max_fields = 1000)` per source (query, form, multipart
  parts, JSON keys) → 400 over it; `0` lifts it (#327).
- `json(req, T)` raises a `ValidationError` for a body that does not bind — a 400 in a handler
  (#326).
- A validation message names the parameter, its type and the validator (`Module.name`), never a
  value or a source path, so returning `err.msg` is safe.

---

## Middleware

Order in the pipeline is top-down: global middleware → framework defaults → router.

```julia
ExtractIP(; forwarded_header::Symbol = :none,   # :x_forwarded_for | :x_real_ip |
            trusted_proxies = nothing)          #   :cf_connecting_ip | :true_client_ip
                                                # trusted_proxies: IPAddr and/or CIDR strings.
                                                # Both required together, or neither.

RateLimiter(; strategy::Symbol = :fixed_window, # or :sliding_window
              kwargs...)                        # forwarded to the strategy
# Returns a LifecycleMiddleware for BOTH strategies (#172) -- `strategy` picks the
# algorithm, never the return type. A middleware list accepts it as-is; only
# hand-composition needs `.middleware`:
#     RateLimiter(rate_limit=100).middleware(handler)
# :fixed_window owns a background sweep that reaps buckets whose window has ended (never
# earlier), started by serve() and stopped by terminate(). :sliding_window has no task -- its
# LRU evicts by size -- so both of its hooks are `nothing`, which startup()/shutdown() treat
# as a no-op.
# Period keywords (window, cleanup_period) must be fixed-length;
# Month/Quarter/Year are an ArgumentError.

Cors(; allowed_origins   = ["*"],
       allowed_headers   = ["*"],
       allowed_methods   = ["GET","POST","OPTIONS"],
       allow_credentials = false,
       max_age           = nothing,
       extra_headers     = Pair{String,String}[],
       paths             = nothing)             # Vector{String} or predicate Function

BearerAuth(validate_token::Function;
           header      = "Authorization",
           scheme      = "Bearer",
           cookie_name = nothing)

CookieAuthMiddleware(validate_token::Function;
                     cookie_name = "auth_token",
                     secret_key  = nothing)          # String or SecretString, >= 32 bytes

CSRFMiddleware(secret::Union{AbstractString, SecretString};  # needs SessionMiddleware OUTSIDE it
               cookie_name = "__Host-csrf_token",   # prefix => Secure + Path=/ + no Domain
               header_name = "X-CSRF-Token",
               form_field  = "_csrf",
               ttl::Int    = 3600,
               config      = CookieConfig(httponly=false, secure=true,
                                          samesite="Lax", path="/", maxage=ttl))
# Tokens are HMAC'd over (raw_token | req.context[:session_id]). No session id => no token
# issued and 403 on every unsafe method. Throws ArgumentError if a __Host-/__Secure- name is
# paired with a config browsers would reject.

SessionMiddleware(; store,                           # REQUIRED -- no default (#171)
                    cookie_name      = nothing,      # => __Host-nitro_session (#329); see below
                    secret_key       = nothing,      # accepted, never used (#339)
                    max_age::Int     = 86400,
                    prune_interval   = Minute(10),   # background janitor period (#36)
                    secure           = true,
                    httponly         = true,
                    samesite         = "Lax",
                    path             = "/",
                    domain           = nothing,
                    rotate_on_auth   = true,
                    auth_key         = "user_id")
# Returns a LifecycleMiddleware, not a bare function: expired sessions are pruned by a
# background janitor that starts on serve() and stops on terminate(). A middleware list
# accepts it as-is; only hand-composition needs `.middleware`:
#     SessionMiddleware(store=store).middleware(handler)
# `prune_probability` was REMOVED -- pruning no longer runs on the request path.
# `prune_interval` must be a fixed-length Period; Month/Quarter/Year are an ArgumentError.
# Default cookie_name follows the attributes: secure + path "/" + no domain => __Host-nitro_session;
# secure with a domain or another path => __Secure-nitro_session; secure=false => nitro_session.
# An explicit __Host-/__Secure- name the attributes cannot carry is an ArgumentError.

SessionPruner(store; interval = Minute(10))
# Janitor only, pass-through middleware. For apps that reach sessions through the Session{T}
# extractor without installing SessionMiddleware -- that path never prunes on its own.

GuardMiddleware(guards::Function...)

AccessLog(sink::Function; capacity::Integer=10_000, batch::Integer=500, …)
```

**Behind a reverse proxy**, `ExtractIP` and `RateLimiter` ignore every forwarding header by
default — every client otherwise collapses onto the proxy's IP and shares one bucket. Declare
**both** `trusted_proxies=[…]` (IPAddr and/or CIDR strings) and the single `forwarded_header` your
proxy writes; setting either alone is an `ArgumentError` at construction. Only the named header is
read, `X-Forwarded-For` is walked right-to-left with trusted hops peeled, and the socket peer stays
available via `getpeerip(req)`.

---

## Guards

Return `403` when the caller is authenticated but not authorized. `login_required` returns `302` for
browsers.

```julia
login_required(;      redirect_url::String = "/login", session_key::String = "user_id")
role_required(role::String;             role_key::String = "role")
permission_required(permission::String; permissions_key::String = "permissions")
claim_required(claim::String, value;    kind::Symbol = :equals)   # or :contains
kid_required(allowed)
```

`role_required` and `permission_required` are thin aliases over `claim_required`.

`Principal` — immutable, dict-like wrapper over *verified* claims, with typed `id` and `kid` and a
`source` of `:claim` or `:kid`. Claims read dict-style; JSON serialization is exactly the claims
object. A `kid` header on a single-secret token is never trusted — only keyset-verified kids count.

### Error contract

| Status | Meaning |
|--------|---------|
| `401` | Unauthenticated — auth middleware, including a validator that **throws** |
| `403` | Authenticated but not authorized — guards |
| `302` | `login_required` browser redirect |

---

## `serve()`

Keyword-only. Register routes with `urlpatterns(...)` first.

| Keyword | Default | Notes |
|---------|---------|-------|
| `host` | `"127.0.0.1"` | Use `"0.0.0.0"` in containers |
| `port` | `8080` | |
| `middleware` | `[]` | Global pipeline, applied top-down |
| `async` | `false` | `true` returns immediately (tests, REPL) |
| `parallel` | `true` | `Threads.@spawn` per request |
| `serialize` | `true` | Auto-format raw handler returns |
| `catch_errors` | `true` | Generic 500 body; never leaks stack traces |
| `show_errors` | `true` | **Server-side logging only** — off does not harden the response |
| `show_banner` | `true` | |
| `access_log` | `true` | Logs the path only |
| `access_log_query` | `false` | Turning on logs query strings — leaks tokens in URLs |
| `context` | `missing` | Your typed app config; read with `getcontext(req)` |
| `prefix` | `nothing` | Global path prefix |
| `shutdown_timeout` | `10.0` | Seconds `terminate()` drains in-flight requests before force-closing; `0` skips the graceful phase |
| `reuseaddr` | platform | `true` on Linux/macOS, `false` on Windows (where `SO_REUSEADDR` lets another process hijack a live port) |
| `external_url` | `nothing` | Advertised base URL |
| `revise` | `:none` | `:lazy` / `:eager` with the Revise extension |
| `secret_key`, `httponly`, `secure`, `samesite` | `nothing` | Cookie defaults. `secret_key` is a `String` or `SecretString` of ≥ 32 bytes, validated before `serve` changes anything |

Lifecycle: `terminate(; timeout=…)`, `resetstate()`, `internalrequest(req; …)` (in-process request,
no socket), `App(mod = @__MODULE__)` for a self-contained router isolated from the global one.

`terminate` is a **bounded** graceful shutdown: the listener is released immediately, in-flight
requests get up to `timeout` seconds (default 10, or `serve(shutdown_timeout=…)`), then whatever is
left is force-closed. Long-lived WebSocket/SSE/STREAM handlers hold their connection for their whole
lifetime and are therefore always cut at the timeout — if one must finish cleanly, notify it from a
`LifecycleMiddleware`'s `on_shutdown`, which runs before the drain. Calling `serve()` on a context
that is already serving throws; terminate THAT app first, or give the second listener its own `App`.

---

## Static and SPA serving

```julia
staticfiles(folder::String,  mountdir::String="static"; headers=[], loadfile=nothing,
            include_hidden::Bool=false, allow_symlink_escape::Bool=false)
spafiles(folder::String,     mountdir::String="static"; headers=[], loadfile=nothing,
         include_hidden::Bool=false, allow_symlink_escape::Bool=false)
dynamicfiles(folder::String, mountdir::String="static"; headers=[], loadfile=nothing,
             include_hidden::Bool=false, allow_symlink_escape::Bool=false)
```

`staticfiles` snapshots contents at startup (fast, needs a restart to pick up changes).
`dynamicfiles` re-reads per request. `spafiles` adds the history-mode fallback to `index.html`.

**What a mount refuses.** Evaluated **once, at mount time**, for all three — `dynamicfiles` re-reads
file *contents* per request, not the rules. A directory untrusted users can write to belongs behind a
proxy, not behind these checks (`docs/design/static-serving-boundary.md`):

| Refused | Opt-out |
|---|---|
| Hidden entries: any path component starting with `.`, **relative to the mounted folder** (`.env`, all of `.git/`). Interior dots (`file.min.js`) are unaffected | `include_hidden=true` |
| Symlinks resolving outside the folder (Windows directory junctions included) | `allow_symlink_escape=true` |
| Filenames the router reads as patterns: `*`/`**` (HTTP.jl wildcards — they shadow sibling URLs) and any name containing `{` or `}` (parsed as a path parameter, which threw at registration and stopped `serve()` booting) | none |
| Anything that is not a regular file — symlinked directories, FIFOs, devices | none |

The folder's own name is never tested, so `staticfiles("public/.well-known", ".well-known")` works.
Enumeration is `Nitro.Core.Util.mountable_files(root; include_hidden, allow_symlink_escape)`.
All three mount functions return `Vector{Pair{String,String}}` — `route => filepath`, in registration
order; `first.(result)` gives the routes alone. `spafiles` registers its history-mode fallback only
if `index.html` is itself servable, decided by looking that file up in what the mount registered
rather than by re-probing the filesystem — so the fallback serves exactly the bytes the mount chose.
The fallback route (`/<prefix>/**`) is not in the returned vector. Only files present at startup get
a route.

**`mountdir` is canonicalized to path segments**, so surrounding whitespace and `/` are stripped:
`"static"`, `"/static"`, `"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and
whitespace all mount at the router root. An `index.html` also claims its bare directory route —
`/docs/index.html` registers `/docs` too, and a top-level one registers `/`.

**`mountdir` is validated too**, and throws `ArgumentError` at mount time. A segment is refused when
it is a router pattern (`*`, `**`, `{`/`}` — the filename rule above, so a mount cannot claim URLs a
file may not), a relative dot-segment (`.`, `..`, which clients strip before sending), or contains
anything outside RFC 3986 `pchar`. The router compares path segments byte for byte and never
percent-decodes, so `"my static"` is refused while `"my%20static"` mounts and serves — the encoded
spelling is the one a conforming client sends. Triplets are validated, never re-encoded: `"%2f"`
stays `"%2f"`. Note only `" "`, `"?"` and control characters were *strictly* unreachable; `"café"`,
`"a#b"`, `"a|b"` and friends did serve a raw-byte client (curl), so refusing them is a real
capability change, and the encoded spelling is a different byte string that will not answer that
client.

---

## Workers

```julia
Owner(user_id)                                                # a validated identity; rejects "", "::", trailing ":"
System()                                                      # the named, unscoped bypass
owner_of(task_id)                                             # "user-a" | nothing (:global has no owner)

submit_task(task_key, callback::Function, owner::Owner;       # RETURNS the stored id
            scope::Symbol = :user,                            # :user namespaces the key by owner
            watchers::Vector{Owner} = Owner[],                # grant a 2nd identity read/list/cancel
            options::TaskOptions = TaskOptions(), runtime = default_runtime())
get_task_status(task_id, authority::TaskAuthority; runtime = default_runtime())
cancel_task(task_id,     authority::TaskAuthority; runtime = default_runtime())
get_all_tasks(authority::TaskAuthority, filter_status = nothing; runtime = default_runtime())
# The authority is REQUIRED on all three — omitting it is a MethodError, not a bypass.

scoped_task_key(task_key, owner::Owner; scope = :user)        # "user-a::report_42"
worker_startup(app; queues, store, recover_zombies)           # a middleware; installs on `app` when built (#322)

# `store=` selects a BACKEND and appears only on worker_startup / start! / startup / install!.
# Every call above takes `runtime=`, or an `App` first argument that resolves one (#167):
submit_task(app, task_key, callback, owner)                   # preferred in a handler
set_queue_authorizer!(worker_store(app), f)                   # policy stays on the store
set_queue_authorizer!(store, authorizer)                      # (queue, user_id) -> Bool
set_watch_authorizer!(store, authorizer)                      # (task_key, watchers, user_id) -> Bool
pormg_nitro_worker(; db_key = "db")                           # needs `using PormG`
update_progress!(task_info, value)                            # NEVER assign .progress directly
```

Every one of these also has an `(app::App, …)` method — use it to avoid the global
singleton in tests. Submission registers the submitting `user_id` as a watcher; passing a non-empty
`user_id` to a read/manage call enforces watcher access and raises `AuthorizationError` when denied.
Omitting it is a deliberate system/public-endpoint bypass.

**`submit_task` returns the stored id, which under the default `:user` scope is
`"<user_id>::<task_key>"` — not the key you passed.** Read and cancel with the returned value.
`scope=:global` stores the key verbatim for cross-user deduplication; a caller who is not already a
watcher is then refused unless `set_watch_authorizer!` allows it. The queue authorizer runs on
`submit_task` too, under `DEFAULT_QUEUE_NAME` (`"default"`).

---

## Cookies, crypto, and secrets

`configcookies`, `get_cookie`, `set_cookie!`, `regenerate_session!(req, store; ttl=3600)`,
`SecretString`, `reveal`.

```julia
configcookies(app; secret_key = SecretString(ENV["COOKIE_SECRET"]))   # returns nothing
set_cookie!(app, res, "cart", "item-17"; maxage = 86400)   # encrypted: a key is configured
get_cookie(app, req, "cart", "")                           # "" when absent OR when it does not open
```

- **Key:** a `String` or `SecretString` of **≥ 32 random bytes**, read from the environment; stored
  as a `SecretString`. Shorter, empty, bytes or a `Base.SecretBuffer` → `ArgumentError`.
  Generate once: `bytes2hex(Nitro.Crypto.secure_random_bytes(32))`.
- **Encrypted value:** AES-256-GCM under an HKDF-derived key, **bound to the cookie name** (a value
  set as `language` does not open as `session_user`) and to its `Max-Age` (wins) or `Expires`,
  which the server enforces. Neither set → no server-side expiry; `configcookies(maxage = …)`
  bounds every cookie. Changing the key invalidates every cookie.
- **A cookie that does not open reads as the default** (`nothing` for `Cookie{T}`), logged at
  `@debug` with the name only. Encrypting with no key at all is still a `CookieError`.
- **Which app:** `get_cookie(req, …)` / `set_cookie!(res, …)` without `app` use the `App` serving
  the request (#308), and the global app only outside a request. A key set on the global app does
  not reach an explicit `App`; `serve(app)` warns once when that is the setup.
- **Parsing:** cookie names match **exactly**; the first occurrence wins; a request's `Set-Cookie`
  is ignored (only a `Response` is read from `Set-Cookie`). `Domain` must be `[A-Za-z0-9.-]`.
- **Values:** `set_cookie!` refuses a `SecretString` value — pass `reveal(x)` if a secret really
  belongs in a cookie. Keep identity in the session or a JWT with `exp`, never in a cookie.

Wrap anything sensitive in `SecretString`: it is masked in `show`/`repr`/logs **and** serializes to
`"****"` through `Res.json` and struct returns (#25). `reveal` is the only unwrap.

---

## Response reuse — safe in Nitro, unsafe outside it

A module-level `const` `Response` can be returned from many requests. Nitro's write path emits
`HTTP.BytesBody.data` non-destructively, so shared responses are an **endorsed** pattern (see
`docs/design/response-body-lifecycle.md`). Two rules follow for application code:

- **Never mutate a `Response` you got back from an inner middleware layer** — it may be a shared
  `const`, and Nitro is multithreaded. Use `add_response_headers(resp, extra)` or
  `own_response_headers(resp)`; never `append!` / `setheader` / `set_cookie!` on a returned response.
- If you hand a `Response` to raw `HTTP.serve!` outside Nitro, give it a `Vector{UInt8}` body — a
  `String` body is a single-use read cursor upstream.
