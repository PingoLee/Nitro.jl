---
name: nitro-usage
description: >-
  Write, refactor, or debug application code that runs on Nitro.jl — Django-style routing and path
  converters, handlers and the request object, Res/render response builders, typed extractors and
  validation, auth guards and middleware order, sessions and CSRF, static/SPA serving, background
  workers, and the serve() bootstrap.
---

# Nitro.jl — Application Usage Guide

## Purpose

Use this skill whenever you write, refactor, or debug code in a project that **depends on**
Nitro.jl — a Julia web framework with Django-style routing, Go-style threading, Express-style
response builders, and Spring-style typed binding.

**Audience: you are a Nitro consumer.** Changing Nitro's own `src/`, `ext/`, in-repo `docs/`, or
`test/`? Read [`nitro-general.instructions.md`](../../instructions/nitro-general.instructions.md)
and the area rule file instead — this skill teaches the public surface, not the internals.

Default posture:

- Routes are declared, never registered imperatively — `path()` / `urlpatterns()` /
  `include_routes()` only.
- Responses go through a builder so status and content type are explicit.
- Anything the client controls is *extracted and validated* before it reaches business logic.
- Authorization is a guard on the route, not an `if` inside the handler.

## Supporting files (load on demand)

This skill keeps the common path lean. Read the sibling file **only when the task needs it**:

- **[`reference.md`](reference.md)** — exhaustive tables: every path converter, extractor, response
  constructor in both namespaces, `req.*` property, middleware constructor with its keyword
  arguments, guard, `serve()` keyword, and the Workers API. Load when you need an exact signature or
  default.

---

## 1. Project layout

Nitro apps follow the Django separation: route declarations in one place, handler logic in modules.

```
src/
├── App.jl                  # entry point: config, middleware, serve()
├── Routes.jl               # every path() declaration
└── Handlers/
    └── ProductHandlers.jl  # handler logic, one module per domain
db/                         # outside src/ — PormG models, if used
```

Route declarations belong exclusively in `src/Routes.jl` (or sub-files under `src/Routes/`).
Compose groups with `include_routes(prefix, routes)`.

---

## 2. Routing

```julia
using Nitro

routes = [
    path("/api/products",            ProductHandlers.list_products,  method="GET"),
    path("/api/products/<int:id>",   ProductHandlers.get_product,    method="GET", name="product-detail"),
    path("/api/products",            ProductHandlers.create_product, method="POST",
         middleware=[CSRFMiddleware(SECRET)]),
    path("/api/products/<int:id>",   ProductHandlers.update_product, methods=["PUT", "PATCH"]),
]

urlpatterns("", routes)                  # register at the root — the prefix argument is REQUIRED
urlpatterns("/api", api_routes)          # or under a prefix
include_routes("v2/", v2_routes)         # compose a sub-router into a route vector
```

There is **no single-argument `urlpatterns(routes)`** — the prefix comes first, `""` for root.
Registration is a separate step from starting the server: declare routes, call `urlpatterns(...)`,
*then* call `serve()`.

**Path converters — there are exactly five**: `<int:…>`, `<str:…>`, `<float:…>`, `<bool:…>`,
`<uuid:…>`. An unknown converter name throws at `path()` time, not at request time.

`path()` keywords: `method` (default `"GET"`), `methods` (a vector, overrides `method`), `name` (for
reverse lookup with `url()`), `middleware` (route-scoped).

**Never** use `@get` / `@post` / `@route` macros or `get()` / `post()` functions — they do not exist
in Nitro. Neither does `serveparallel()`. If you find them in an Oxygen.jl example, they were removed
on purpose.

---

## 3. Handlers and the request object

A handler takes `req::HTTP.Request` first, then path parameters in declaration order, typed to match
the converter:

```julia
module ProductHandlers
using Nitro
using HTTP

function get_product(req::HTTP.Request, id::Int)
    product = find_product(id)
    isnothing(product) && return Res.status(404)
    return Res.json(product)
end
end
```

The request exposes Django-style shorthands — prefer these over digging into `req.context`:

| Property | Gives you |
|----------|-----------|
| `req.params` | Path parameters, already converted to the declared type |
| `req.query` | Query-string parameters |
| `req.json` | Parsed JSON body (cached per request) |
| `req.form` | Parsed urlencoded form body (cached) |
| `req.post` | Text fields of a multipart body (Django `request.POST`, cached) |
| `req.files` | File parts of a multipart body (Django `request.FILES`, cached) |
| `req.input` / `req.data` | Merged input — `params > post > form > json > query` |
| `req.session` | Session dict, when `SessionMiddleware` is in the pipeline |
| `req.user` | The authenticated `Principal`, when an auth middleware ran |
| `req.ip` | Client IP, when `ExtractIP` is in the pipeline (`getpeerip(req)` for the socket peer) |

`req.json`, `req.form`, `req.post`, and `req.files` are **cached per request** — reading them twice
is free, so don't hand-roll your own caching.

---

## 4. Responses

Two namespaces, and they are not interchangeable:

**`Res` — the status/content builders.** Exactly five: `Res.json`, `Res.status`, `Res.send`,
`Res.file`, `Res.redirect`. **`Res.html` and `Res.js` do not exist.**

```julia
Res.json(Dict("id" => 1, "name" => "Widget"))       # 200 application/json
Res.json(payload; status=201)
Res.status(404)                                      # bare status
Res.send("plain body"; status=200)                   # text/plain
Res.redirect("/login"; status=302)
Res.file("report.pdf"; disposition="attachment")     # note: attachment by default
```

**Top-level constructors — the content-type builders** (exported by `Nitro`): `html`, `text`, `json`,
`xml`, `js`, `css`, `binary`, `file`.

```julia
html("<h1>$(escape(title))</h1>")   # ONLY use with escaped input
text("plain")
xml(feed_string)
binary(bytes)
```

> **The XSS rule.** `html`, `js`, `xml`, and `css` are the framework's **only** markup/script sinks.
> Everything else — raw `String` returns, `Res.send`, `Res.json` — is served as `text/plain` or
> `application/json` with no content-sniffing, so an attacker-influenced value can never be
> reclassified as HTML. Escape before those four, always. Nowhere else needs escaping.

Returning a raw `Dict` or `String` from a handler works (auto-formatted to JSON / `text/plain`) and
is **safe**, but prefer a builder so status and content type are explicit rather than inferred.

`json`, `file`, and `redirect` currently exist in *both* namespaces with different defaults. Name the
namespace explicitly (`Res.file(...)` vs `Nitro.file(...)`) rather than relying on scope.

---

## 5. Typed extraction and validation

For anything beyond a scalar path parameter, bind the request to a struct instead of reaching into
dicts. This is Nitro's Spring-style binding layer.

```julia
struct ProductCreate
    name::String
    category::String
    price::Float64
end

function create_product(req::HTTP.Request, body::Json{ProductCreate})
    product = body.payload          # `.payload` is how every extractor unwraps
    return Res.json(save(product); status=201)
end
```

Available extractors: `Path{T}`, `Query{T}`, `Header{T}`, `Json{T}`, `JsonFragment{T}`, `Form{T}`,
`Body`, `Cookie`, `Session`, `Files{...}`, `MultipartForm{T}`. Full binding rules in
[`reference.md`](reference.md).

**Validation** attaches a predicate by writing the extractor as a *default argument* rather than a
type annotation:

```julia
path("/api/products", function(req, body = Json{ProductCreate}(p -> p.price > 0))
    return Res.json(save(body.payload); status=201)
end, method="POST")
```

A failing predicate raises `ValidationError` and Nitro answers 422 — do not catch it to build your
own response unless you need a custom body.

> **Mass assignment.** Binding a request body straight to a struct that carries privileged fields
> (`is_admin`, `role`, `user_id`, ownership keys) lets a client set them. Use a separate input struct
> without those fields and assign them server-side.

---

## 6. Auth: middleware authenticates, guards authorize

```julia
serve(middleware=[
    ExtractIP(forwarded_header=:x_forwarded_for, trusted_proxies=[ip"127.0.0.1"]),
    SessionMiddleware(secret_key=ENV["SECRET_KEY"]),
    BearerAuth(jwt_validator(secret; issuer="myapp", audience="api", profile=:strict)),
    CSRFMiddleware(ENV["CSRF_SECRET"]),
])

# Route-scoped authorization:
path("/api/admin/users", AdminHandlers.list_users, method="GET",
     middleware=[GuardMiddleware(login_required(), role_required("admin"))])
```

**The error contract, and it is not negotiable:**

| Status | Meaning | Produced by |
|--------|---------|-------------|
| `401` | Unauthenticated | Auth middleware — including a validator that *throws* |
| `403` | Authenticated but not authorized | Guards |
| `302` | Browser redirect to login | `login_required()` |

Guards: `login_required(; redirect_url, session_key)`, `role_required(role; role_key)`,
`permission_required(permission; permissions_key)`, `claim_required(claim, value; kind=:equals|:contains)`,
`kid_required(allowed)`. `role_required` and `permission_required` are thin aliases over
`claim_required`.

The authenticated principal is a `Principal` — an immutable, dict-like wrapper over *verified* claims
with typed `id` and `kid` fields. Read it from `req.user`.

> **Authentication is not authorization.** A route that loads a record by a client-supplied id must
> verify the caller *owns* it. `login_required()` alone is an IDOR waiting to happen.

---

## 7. Sessions and CSRF

```julia
SessionMiddleware(
    secret_key = ENV["SECRET_KEY"],
    max_age    = 86400,
    secure     = true,      # keep true in production
    httponly   = true,      # never lower this
    samesite   = "Lax",
    rotate_on_auth = true,  # regenerates the session id on login — leave on
)
```

Read and write through `req.session`. Call `regenerate_session!(req, store)` on any privilege
change you perform manually. `CSRFMiddleware(secret)` is required for cookie-authenticated
mutations; its cookie is deliberately **not** `httponly` so the SPA can read and echo the token in
the `X-CSRF-Token` header.

---

## 8. Static files and SPA

```julia
staticfiles("public", "static")   # serve ./public at /static
spafiles("dist", "/")             # SPA history-mode fallback to index.html
dynamicfiles("uploads", "media")  # re-read from disk per request
```

`staticfiles` snapshots file contents at startup; `dynamicfiles` reads per request. Use `spafiles`
for a Vue/React/Quasar build so client-side routes fall back to `index.html`.

---

## 9. Background work

Task submission **requires** a `user_id`; read and manage APIs take it optionally, and passing a
non-empty one enforces watcher-based access:

```julia
serve(middleware=[
    worker_startup(queues=["reports"], store=persistent_store, recover_zombies=true),
])

task_id = submit_task("reports", () -> build_report(id), user_id)
status  = get_task_status(task_id, user_id)
cancel_task(task_id, user_id)
```

Omitting `user_id` on a read is a deliberate system/public-endpoint bypass — never the default for a
user-scoped route. For persistence, `pormg_nitro_worker(db_key="workers")` needs `using PormG` in the
**application** so the extension loads.

---

## 10. Bootstrap

Explicit startup only: **load config → resolve secrets → run initializers → build routes and
middleware → `serve(context=…)`.**

```julia
config = AppConfig(...)                  # your struct — Nitro has no config global

urlpatterns("", Routes.routes(config))   # register routes FIRST

serve(host="0.0.0.0", port=8080,         # serve() is keyword-only — no positional routes
      middleware=[...],
      context=config)                    # reach it from a handler with getcontext(req)
```

There is **no `Nitro.config`**. Applications own their typed config structs; inject through the app
context, never a hidden global. Config must be swappable in tests without mutating framework state.

Errors never leak: a throwing handler returns a generic `{"message": "500: Internal Server Error"}`.
`serve(...; show_errors=true)` (the default) controls **server-side logging only** — turning it off
does not harden the response, it just blinds your logs. Keep it on.

Client input errors are **400**, not 500: a malformed or missing scalar path/query parameter, and any
extractor or `validate` failure, return `{"message": "400: Bad Request"}` and are logged at `@debug`
with no stack trace. Only a genuine handler fault is a 500. So a path converter is a *binding*
declaration, not a routing filter — `/user/abc` against `<int:id>` is a 400, not a 404 — and a scalar
query parameter with no default is **required**: omitting it is a 400, not `nothing`.

---

## Anti-patterns

| Anti-pattern | Preferred |
|--------------|-----------|
| `@get "/x" function ...` / `get("/x", handler)` | `path("/x", handler, method="GET")` |
| `serveparallel()` | `serve()` — already multithreaded via `Threads.@spawn` |
| `Res.html(...)` / `Res.js(...)` | `html(...)` / `js(...)` — the `Res` versions don't exist |
| Unescaped interpolation into `html()` / `js()` | Escape first; or return JSON and render client-side |
| `req.context[:session]` | `req.session` (likewise `req.user`, `req.ip`, `req.params`) |
| Reaching into `req.json["field"]` for a typed body | `Json{T}` extractor + `validate` |
| Binding a request body to a struct with `is_admin` / `user_id` | A separate input struct; assign privileged fields server-side |
| `if user.role == "admin"` inside a handler | `role_required("admin")` guard on the route |
| `login_required()` on a route that loads a record by client id | Also verify ownership — otherwise IDOR |
| `submit_task(key, cb)` without `user_id` | `submit_task(key, cb, user_id)` |
| Mutating a `Response` returned by inner middleware | `add_response_headers(resp, extra)` |
| A global mutable config object | A typed struct passed via `serve(context=…)` |
| `show_errors=false` "for security" | Leave it on — the client response is already generic |
