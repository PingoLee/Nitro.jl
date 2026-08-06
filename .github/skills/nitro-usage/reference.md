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

Shorthand properties installed on `HTTP.Request`. Prefer these over `req.context` lookups.

| Property | Type | Notes |
|----------|------|-------|
| `req.params` | `Dict` | Path parameters, converted to the declared type |
| `req.query` | `Dict` | Query-string parameters |
| `req.json` | parsed JSON | **Cached** per request |
| `req.form` | `Dict` | urlencoded body — **cached** |
| `req.post` | `Dict{String, Union{String, Vector{String}}}` | Multipart *text* fields (Django `request.POST`) — **cached** |
| `req.files` | `Dict{String, Union{FormFile, Vector{FormFile}}}` | Multipart *file* parts (Django `request.FILES`) — **cached** |
| `req.input` / `req.data` | `Dict` | Merged: `params > post > form > json > query` |
| `req.session` | `Dict` or `nothing` | Needs `SessionMiddleware` |
| `req.user` | `Principal` or `nothing` | Set by an auth middleware |
| `req.ip` | IP or `nothing` | Needs `ExtractIP` |
| `req.context` | metadata view | HTTP.jl v2 semantics, preserved |

Helper functions over the same data: `getparams`, `getquery`, `getsession`, `setsession!`, `getip`,
`setip!`, `getcontext(req)` / `getcontext(req, T)`, `payload(req)`.

---

## Responses

### `Res` — status/content builders (five, and only five)

```julia
Res.json(data;  status::Int=200, headers::Vector=[])
Res.status(code::Int;            headers::Vector=[])
Res.send(body::String; status::Int=200, headers::Vector=[])
Res.file(path::String;  status::Int=200, headers::Vector=[],
         filename=nothing, disposition::String="attachment", loadfile=nothing)
Res.redirect(url::String; status::Int=302, headers::Vector=[])
```

**`Res.html` and `Res.js` do not exist.**

### Top-level content-type constructors

All take `(content; status=200, headers=[])`.

| Function | Content-Type | Input |
|----------|-------------|-------|
| `html(s)` | `text/html` | `String` — **markup sink, escape first** |
| `js(s)` | JavaScript | `String` — **script sink, escape first** |
| `xml(s)` | `application/xml` | `String` — **markup sink** |
| `css(s)` | `text/css` | `String` — **markup sink** |
| `text(s)` | `text/plain` | `String` |
| `json(x)` | `application/json` | any, or `Vector{UInt8}` |
| `binary(b)` | octet-stream | `Vector{UInt8}` |
| `file(p)` | sniffed from path | `String` path; `loadfile=` hook |

> `json`, `file`, and `redirect` exist in **both** namespaces with different defaults —
> `Res.file` defaults to `disposition="attachment"`, the `render.jl` `file` does not. Qualify the
> call. Reconciliation is tracked in [#28](https://github.com/PingoLee/Nitro.jl/issues/28).

### Request body parsers (same names, opposite direction)

`text(req)`, `json(req)`, `json(req, T)`, `binary(req)`, `formdata(req)`, `multipart(req)`. Dispatch
is on the argument type — an `HTTP.Request` parses, anything else constructs a response.

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
| `Session` | Session data |
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
`ValidationError` → HTTP 422.

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
                     secret_key  = nothing)

CSRFMiddleware(secret::String;
               cookie_name = "csrf_token",
               header_name = "X-CSRF-Token",
               form_field  = "_csrf",
               ttl::Int    = 3600,
               config      = CookieConfig(httponly=false, secure=true,
                                          samesite="Lax", path="/", maxage=ttl))

SessionMiddleware(; cookie_name      = "nitro_session",
                    secret_key       = nothing,
                    max_age::Int     = 86400,
                    store            = DEFAULT_STORE,
                    prune_probability= 0.01,
                    secure           = true,
                    httponly         = true,
                    samesite         = "Lax",
                    path             = "/",
                    domain           = nothing,
                    rotate_on_auth   = true,
                    auth_key         = "user_id")

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
| `external_url` | `nothing` | Advertised base URL |
| `revise` | `:none` | `:lazy` / `:eager` with the Revise extension |
| `secret_key`, `httponly`, `secure`, `samesite` | `nothing` | Cookie defaults |

Lifecycle: `terminate()`, `resetstate()`, `internalrequest(req; …)` (in-process request, no socket),
`instance(...)` for a self-contained router isolated from the global one.

---

## Static and SPA serving

```julia
staticfiles(folder::String, mountdir::String="static"; headers=[], loadfile=nothing)
spafiles(folder::String,    mountdir::String="static"; headers=[], loadfile=nothing)
dynamicfiles(folder::String, mountdir::String="static"; headers=[], loadfile=nothing)
```

`staticfiles` snapshots contents at startup (fast, needs a restart to pick up changes).
`dynamicfiles` re-reads per request. `spafiles` adds the history-mode fallback to `index.html`.

---

## Workers

```julia
submit_task(task_key, callback::Function, user_id;            # user_id REQUIRED
            options::TaskOptions = TaskOptions(), store = default_store())
get_task_status(task_id, user_id = nothing; store = default_store())
cancel_task(task_id,     user_id = nothing; store = default_store())
get_all_tasks(filter_status = nothing, user_id = nothing; store = default_store())

worker_startup(; queues, store, recover_zombies)              # a middleware
set_queue_authorizer!(store, authorizer)                      # (queue, user_id) -> Bool
pormg_nitro_worker(; db_key = "db")                           # needs `using PormG`
update_progress!(task_info, value)                            # NEVER assign .progress directly
```

Every one of these also has a `(ctx::ServerContext, …)` method — use it to avoid the global
singleton in tests. Submission registers the submitting `user_id` as a watcher; passing a non-empty
`user_id` to a read/manage call enforces watcher access and raises `AuthorizationError` when denied.
Omitting it is a deliberate system/public-endpoint bypass.

---

## Cookies, crypto, and secrets

`configcookies`, `get_cookie`, `set_cookie!`, `regenerate_session!(req, store; ttl=3600)`,
`SecretString`, `reveal`.

Wrap anything sensitive in `SecretString` so it does not print in logs or reprs — but note it
currently still leaks through JSON response serialization
([#25](https://github.com/PingoLee/Nitro.jl/issues/25)); never place one in a response body.

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
