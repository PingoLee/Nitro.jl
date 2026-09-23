# Path Parameters

Nitro.jl supports Django-style path parameters. You can declare variables inside your path using brackets `<type:name>` or just the variable name `{name}`. 

The values extracted from the URL are passed directly to your request handler as arguments.

## Django-style paths (Recommended)

The recommended way to define paths is using the Django-style syntax `<converter:name>`. Nitro converts the incoming value using the converter type before calling your handler, even when the handler parameter itself is untyped. If you also annotate the handler parameter, Nitro checks that the route converter and handler type are compatible during registration.

```julia
using HTTP
using Nitro

function multiply(req::HTTP.Request, a::Float64, b::Float64)
    return Res.json(Dict("result" => a * b))
end

function get_user(req::HTTP.Request, id)
    return Res.json(Dict(
        "id" => id,
        "type" => string(typeof(id)),
    ))
end

# src/Routes.jl
function urlpatterns()
    return [
        path("/multiply/<float:a>/<float:b>", multiply, method="POST"),
        path("/user/<int:id>", get_user, method="GET"),
    ]
end
```

That means `/user/42` reaches `get_user` with `id == 42` and `typeof(id) == Int`. A mismatched definition such as `function get_user(req::HTTP.Request, id::String)` with `path("/user/<int:id>", get_user)` now fails during route registration instead of drifting into runtime parsing errors.

The available converters are:
- `<int:name>` (e.g., `123`)
- `<float:name>` (e.g., `3.14`)
- `<str:name>` (e.g., `"hello"`)
- `<bool:name>` (e.g., `true`)
- `<uuid:name>` (e.g., `550e8400-e29b-41d4-a716-446655440000`)

### Invalid Values

A value the converter cannot parse returns **`400 Bad Request`**, not a 404:

```
GET /user/abc      ->  400 {"message": "400: Bad Request"}
```

This is a deliberate divergence from Django. In Nitro a converter is a **binding declaration, not a
routing filter** — `/user/abc` still matches `path("/user/<int:id>", get_user)`, and the request is
rejected when the value fails to bind to `Int`. That keeps the converter and the handler's own type
annotation as one rule with one failure mode, and it catches values a route-level pattern could not
(`/user/99999999999999999999` matches "digits" but overflows `Int`).

The same applies to every scalar parameter, converter or not: an unparseable value is a `400`,
whether it came from `<int:id>`, from a bare `{id}` whose handler declares `id::Int`, or from a query
string. Rejections are logged at `@debug` level with no stack trace, because they are client input
rather than server faults — only a genuine handler error produces a `500` and a backtrace.

## Named Routes And Reverse URLs

Use the `name=` keyword when you want to refer to a route later without hard-coding the path string again.

```julia
using HTTP
using Nitro
using UUIDs

function get_user(req::HTTP.Request, id::Int)
    return Res.json(Dict("id" => id))
end

function urlpatterns()
    return [
        path("/users/<int:id>", get_user, method="GET", name="user-detail"),
    ]
end

user_path = url("user-detail"; id=42)
# "/users/42"
```

Nitro substitutes the `{param}` placeholders from the registered route pattern. It raises an `ArgumentError` if the route name does not exist, if a required parameter is missing, or if extra keyword arguments are provided.

## Using brackets `{name}`

You can also use the older bracket syntax. Without a converter, Nitro uses the handler annotation to decide how to parse the value. If you leave the handler parameter untyped, Nitro treats the value as a `String`.

```julia
# Route: /greet/{name}
function greet(req::HTTP.Request, name::String)
    return Res.send("Hello $name")
end
```

## Advanced: The `Path` Extractor

For more complex scenarios, or when you want to group all path parameters into a custom struct, use the `Path{T}` extractor.

```julia
struct ProductSearch
    category::String
    id::Int
end

# Route: /shop/<str:category>/<int:id>
function handle_search(req, params::Path{ProductSearch})
    query = params.payload
    return "Searching in $(query.category) for item $(query.id)"
end
```

## Percent-encoding

Path parameters are **percent-decoded exactly once**, before your handler sees them. This holds
for every spelling — a scalar argument, `getparams(req)`, and `Path{T}` fields —
so all three observe the same value:

```
GET /files/my%20report.pdf   →  "my report.pdf"
GET /files/a%2Fb             →  "a/b"
GET /files/a%252Bb           →  "a%2Bb"      # decoded once, not twice
```

Query parameters are decoded once as well. Nothing downstream decodes again, so a value
containing a literal `%` reaches you exactly as the client encoded it.

A malformed escape (`%ZZ`, a trailing `%`) or one decoding to invalid UTF-8 is rejected with
`400 Bad Request` before your handler runs.

!!! warning "Decoded values can contain `/` and `..`"

    Because decoding happens for you, a parameter can carry path separators and traversal
    sequences: `/files/..%2F..%2Fetc%2Fpasswd` arrives as `"../../etc/passwd"`. Never join a
    path parameter into a filesystem path directly.

    ```julia
    # unsafe — traversal reachable
    readfile(joinpath(UPLOAD_DIR, params.payload.name))

    # safe — strip any directory component first
    readfile(joinpath(UPLOAD_DIR, basename(params.payload.name)))
    ```

    Nitro's own `staticfiles`/`spafiles` mounts are unaffected: they enumerate the folder at
    mount time and register one literal route per file, so no path parameter reaches a path
    join inside the framework.

## Autogenerated Docs

When you open your browser at `http://127.0.0.1:8080/docs`, Nitro uses these type annotations to generate the OpenAPI spec. This means:
1. The documentation knows exactly what types are expected.
2. The interactive UI enforces these types.
3. Your API contract stays in sync with your code automatically.

## Additional Type Support

Beyond primitives, Nitro can parse more complex types from path parameters (usually by assuming they are JSON-encoded if they are complex):

```julia
using Dates
using Nitro

@enum Fruit apple=1 orange=2 kiwi=3

# Handlers
function get_fruit(req, fruit::Fruit)
    return fruit
end

function get_date(req, date::Date)
    return date
end

function get_list(req, list::Vector{Int})
    # Nitro will try to parse this as a JSON array from the URL
    return length(list)
end
```

A `Union{...}` annotation binds to the **first member type that parses**; if no member accepts the
value, the request is a `400`.

```julia
# /thing/42   -> id === 42        (Int)
# /thing/<a valid uuid>           (UUID)
# /thing/abc  -> 400 Bad Request
function get_thing(req, id::Union{Int, UUID})
    return string(typeof(id))
end
```

`Nothing` is never a parse target, so `Nullable{T}` (that is, `Union{T, Nothing}`) does **not** mean
"parse this loosely" — it means the parameter may be *absent*. Give it a default to say what absence
should produce:

```julia
# ?cursor=5 -> cursor === 5 ;  no ?cursor -> cursor === nothing ;  ?cursor=abc -> 400
function list_items(req, cursor::Nullable{Int} = nothing)
    return isnothing(cursor) ? "first page" : "after $cursor"
end
```

Note that a literal `?cursor=null` is a `400`, not `nothing` — `null` is not an `Int`, and `Nothing`
is not a parse target. To say "absent", omit the parameter rather than sending the string `null`.

## Per-Route Middleware (Guards)

The most important pattern for real applications is attaching middleware on a per-route basis.
This is how authentication guards are applied selectively in production apps.

```julia
# src/Routes.jl
function urlpatterns(config::AppConfig)
    auth_guard     = [auth_middleware(config)]
    biclient_guard = [auth_middleware(config; allowed_kids=["biclient"])]

    return [
        # Public endpoint — no middleware
        path("/health",          SystemHandlers.health_check,  method="GET"),

        # Protected endpoint — auth required
        path("/api/patients",    PatientHandlers.list,         method="GET",  middleware=auth_guard),
        path("/api/import/data", ImportHandlers.submit_import, method="POST", middleware=auth_guard),

        # Endpoint restricted to a specific client type
        path("/api/sync/units",  SyncHandlers.sync_units,      method="POST", middleware=biclient_guard),

        # Path parameter in a protected route
        path("/api/worker/status/<str:task_id>", WorkerHandlers.task_status, method="GET", middleware=auth_guard),
    ]
end
```

## Factory-style Handlers

When a handler needs access to server configuration (database connection strings, feature flags, etc.),
define it as a **factory function** — a function that returns a handler function.
This keeps handlers pure and testable.

```julia
# src/Handlers/SystemHandlers.jl
module SystemHandlers

using Nitro
using ..Config: AppConfig

export health_check

# Factory — captures `config` at route-registration time
function health_check(config::AppConfig)
    return function(req)
        return Res.json(Dict(
            "status" => "ok",
            "env"    => config.env,
        ))
    end
end

end # module SystemHandlers
```

```julia
# src/Routes.jl
path("/health", SystemHandlers.health_check(config), method="GET"),
#                                           ^^^^^^^^ called once here, returns a handler
```

## Multiple HTTP Methods on One Route

Use `methods=` (plural) when one handler needs to serve both reads and writes on the same URL.
The handler can branch on `req.method` to differentiate:

```julia
# src/Routes.jl
path("/api/report/<int:report_id>", ReportHandlers.report, methods=["GET", "POST"], middleware=auth_guard)

# src/Handlers/ReportHandlers.jl
function report(req, report_id::Int)
    if req.method == "POST"
        data = getjson(req)
        # ... save / trigger generation
        return Res.json(Dict("status" => "queued", "id" => report_id))
    end
    # GET — return existing report
    return Res.json(Dict("id" => report_id, "data" => fetch_report(report_id)))
end
```

> **Note:** For most Nitro.jl applications, `"GET"` and `"POST"` cover all real-world needs.
> HTML forms only support these two verbs natively, and action-oriented APIs
> (import, sync, trigger) are naturally expressed as `POST`.

## `HEAD` Requests

Every `GET` route also answers `HEAD`, with no extra declaration. Nitro calls the `GET` handler,
sends its status and headers (`Content-Type`, `Content-Length`, …) and drops the body. This is
what RFC 9110 §9.3.2 asks for, and what Django, Express and Go's `net/http` do. `curl -I` works
against any `GET` route.

```julia
# src/Routes.jl
path("/api/products/<int:id>", ProductHandlers.get_product)   # answers GET and HEAD
```

The rules:

- **An explicit `HEAD` route wins**, whichever order the two are registered in. Declare one when
  `HEAD` has a cheaper answer than building the body:

  ```julia
  path("/api/reports/<int:id>", ReportHandlers.download)
  path("/api/reports/<int:id>", ReportHandlers.report_exists; method="HEAD")
  ```

  An explicit `HEAD` handler that returns an empty body (`Res.status(200)`) gets no
  `Content-Length`. Nitro cannot know the size of the `GET` body, and a wrong length is worse
  than none. `methods=["GET", "HEAD"]` still works and means the same one handler serves both.
- **The handler sees `req.method == "HEAD"`**, so a `GET` handler can skip a side effect that
  should only happen on a real read:

  ```julia
  function get_product(req, id::Int)
      req.method == "HEAD" || record_view!(id)       # a HEAD is not a view
      return Res.json(Dict("id" => id, "name" => product_name(id)))
  end
  ```

  Return the **same** body either way. Nitro sets the `HEAD`'s `Content-Length` from the body the
  handler returned, so a smaller body on `HEAD` would announce the wrong length. To avoid building
  the body at all, use an explicit `HEAD` route that returns an empty one (above). Without any
  branch the handler runs in full and only the body is discarded. A streamed body (`Res.sse`,
  `Res.file(...; stream=true)`) is closed, never read.
- **The `GET` route's middleware and guards apply to its `HEAD`.** A route behind
  `GuardMiddleware(login_required())` refuses an anonymous `HEAD` exactly as it refuses the `GET`.
  An explicit `HEAD` route uses only its own `middleware=`.
- **Only `method="GET"` gets it.** `"STREAM"` and `"WEBSOCKET"` routes do not, and other
  methods on a `GET` route are still refused with `405`, whose `Allow` lists `GET, HEAD` (see
  below).
- **`internalrequest` does not drop the body.** The body is removed by the server's write path,
  so an in-process `HEAD` returns what the handler built.

## Method Not Allowed (`405`)

A request whose path matches a route, but whose method matches none of that path's routes, gets
`405 Method Not Allowed`. The response carries an `Allow` header naming the methods the path does
answer, which RFC 9110 §15.5.6 requires:

```julia
path("/api/products", ProductHandlers.list_products)                   # GET
path("/api/products", ProductHandlers.create_product; method="POST")
```

```
DELETE /api/products  →  405, Allow: GET, HEAD, POST
```

- **The list is what the router would actually serve**, sorted. It includes the automatic `HEAD`
  of a `GET` route, every method of every route whose pattern matches the path (`/users/me` and
  `/users/<str:name>` both match `/users/me`), and custom method names given to `path()`.
- **`OPTIONS` is listed only when a route declares it.** `Cors()` answers `OPTIONS` itself, before
  routing, so the router cannot see it and does not list it.
- **A path that matches no route at all is still a `404`**, with no `Allow`.
- **Under a `staticfiles`/`spafiles`/`dynamicfiles` mount this does not hold yet.** The mount's
  catch-all turns a method mismatch on an app route under its prefix (every path, for a root
  mount) into a `404`, and a mount's own `405` always says `Allow: GET, HEAD`. Tracked in
  [#284](https://github.com/PingoLee/Nitro.jl/issues/284).
- **A custom 405 handler still decides the response.** With
  `Service(router = HTTP.Router(my404, my405))`, Nitro calls `my405` and adds `Allow` to the
  `HTTP.Response` it returns, as a new response, so a shared `const` response is safe. If `my405`
  sets its own `Allow`, Nitro leaves it alone. Any other return value passes through unchanged.

## Modular Route Inclusion with `include_routes`

For large applications split across multiple handler modules, use `include_routes` to
mount a sub-module's routes under a common prefix:

```julia
# src/Routes.jl
function urlpatterns(config::AppConfig)
    auth_guard = [auth_middleware(config)]

    return [
        path("/health", SystemHandlers.health_check(config), method="GET"),

        # Mount all worker routes under /api/worker
        include_routes("/api/worker", WorkerRoutes.urlpatterns(config, auth_guard))...,

        # Mount all sync routes under /api/sync  
        include_routes("/api/sync", SyncRoutes.urlpatterns(config, auth_guard))...,
    ]
end
```

```julia
# src/WorkerRoutes.jl
module WorkerRoutes
using Nitro
using ..WorkerHandlers

function urlpatterns(config, guard)
    return [
        path("/status/<str:task_id>", WorkerHandlers.task_status, method="GET",  middleware=guard),
        path("/cancel/<str:task_id>", WorkerHandlers.cancel_task, method="POST", middleware=guard),
        path("/tasks",                WorkerHandlers.list_tasks,   method="GET",  middleware=guard),
    ]
end
end
```

The final registered paths will be `/api/worker/status/<str:task_id>`, `/api/worker/cancel/<str:task_id>`, etc.

## Wiring Everything into `serve()`

In the application entry point, pass the routes and config to Nitro:

```julia
# src/BI.jl / main.jl
function start_server(env::String = "development")
    config = load_config(env)

    # Register all routes
    Nitro.urlpatterns("", Routes.urlpatterns(config))

    serve(
        host       = config.server[:host],
        port       = config.server[:port],
        context    = config,          # read it with getcontext(req) in middleware
        middleware = [startup_middleware(config)],
    )
end
```