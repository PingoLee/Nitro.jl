# Bigger Applications — Multiple Files

As your application grows you will spread logic across many files. Nitro uses the same
**Handlers / Routes** separation that Django popularised: view-logic lives in handler
modules, URL declarations live in a single routes file.

## Start from `Nitro.newapp`

`Nitro.newapp` writes the layout below and the boot that runs it, the way Django's
`startproject` does. It is public but not exported, so call it qualified:

```julia
julia> using Nitro, PormG

julia> Nitro.newapp("MyApp"; path = "myapp")
```

With PormG loaded it runs PormG's interactive `PormG.setup` to write `db/connection.yml`, then adds
the database driver for the adapter you chose: `SQLite` for SQLite, `LibPQ` for PostgreSQL. Pass
`pormg = false` for an app with an in-memory worker store and no database. `path` must not exist
yet, or must be an empty directory.

```
$ cd myapp
$ julia --project -e 'using Pkg; Pkg.instantiate()'
$ export API_SECRET_KEY=$(openssl rand -hex 32)   # at least 32 bytes
$ julia --project main.jl
```

`main.jl` is the program: it calls `MyApp.main()` and catches a failed start-up, and it is the
file a JuliaC build compiles (see *The entry point `newapp` writes* below).

## Recommended project layout

```
myapp/
├── Project.toml            # Nitro and PormG by URL, plus HTTP and the database driver
├── Manifest.toml           # written by the first Pkg.instantiate()
├── .gitignore              # excludes db/connection.yml: it holds the database password
├── main.jl                 # the entry point: `julia --project main.jl`, or a JuliaC build
├── db/
│   ├── connection.yml      # written by PormG.setup
│   └── models.jl           # your PormG models
├── src/
│   ├── MyApp.jl            # the module and its main() boot
│   ├── Routes.jl           # all path() declarations
│   └── Handlers/
│       └── HealthHandlers.jl
└── test/
    └── runtests.jl         # one internalrequest test
```

The `src/` tree is a Julia package. Its module body only defines code: the `using` lines, the
`App` and the `include`s. Everything that connects or starts runs in `main()`, shown in full
under *The boot `newapp` writes* below. As the app grows, add a handler module per domain
(`ProductHandlers.jl`, `OrderHandlers.jl`) and declare its routes in `Routes.jl`.

---

## Setting up PormG models

PormG models live in `db/models.jl`, outside `src/`, as a module named `models`. `include` that
file in the module body: it creates a plain Julia module you can alias and pass down to handlers
via `import`. Including only defines code, so it belongs in the module body.

**Loading and binding do not.** `PormG.Configuration.load_many` reads `db/connection.yml`, password
included, and `PormG.Models.set_models` binds the models to the connection it loaded. A package's
module body runs once, when it is precompiled, and loading the cached package does not run it
again: PormG's configuration set up there does not exist at runtime, and a JuliaC image would
carry the file's contents. Keep both calls in `main()`, where `newapp` puts the first and shows
the second.

This is also why the module body does not use PormG's `@import_models`. It registers the models
as it includes them, and PormG refuses to register models whose folder no `load` has loaded yet,
outside a REPL. A precompile is never a REPL, so a package with `@import_models` in its module
body and `load_many` in `main()` fails to precompile.

```julia
# src/MyApp.jl
module MyApp

using Nitro, PormG, SQLite

const app = App(mod = @__MODULE__)

# Include the model file: defines a module named `models`, bound to nothing yet
include("../db/models.jl")

# Alias for convenience: handlers do `import ..appM`
const appM = models

include("Handlers/ProductHandlers.jl")
include("Handlers/OrderHandlers.jl")
include("Routes.jl")

function main(; root::AbstractString = pkgdir(@__MODULE__), kwargs...)
    # At runtime: load db/, then bind the models to it.
    env = something(sync_pormg_env!(), current_env())
    PormG.Configuration.load_many(["db"]; root, env)
    PormG.Models.set_models(models, joinpath(root, "db"))
    # ...the rest of main() as `newapp` wrote it
end

end # module
```

Handlers import the alias and use `appM.Product.objects` for queries:

```julia
# src/Handlers/ProductHandlers.jl
module ProductHandlers

using HTTP
using Nitro
using PormG
import ..appM   # the alias defined in MyApp.jl

export list_products, get_product

function list_products(req::HTTP.Request)
    query = appM.Product.objects
    return Res.json(list(query))
end

function get_product(req::HTTP.Request, id::Int)
    query = appM.Product.objects
    query.filter("id" => id)
    result = list(query)
    isempty(result) && return Res.json(Dict("error" => "not found"); status=404)
    return Res.json(first(result))
end

end # module
```

---

## Defining handlers

Handler functions live in plain Julia modules — one file per domain area.

```julia
# src/Handlers/MathHandlers.jl
module MathHandlers

using HTTP
using Nitro

export multiply, divide

function multiply(req::HTTP.Request, a::Float64, b::Float64)
    return Res.json(a * b)
end

function divide(req::HTTP.Request, a::Float64, b::Float64)
    a == 0 && return Res.json(Dict("error" => "divisor cannot be zero"); status=400)
    return Res.json(a / b)
end

end # module
```

---

## Declaring routes

All `path()` calls are collected in `Routes.jl`. This is the only place that
wires handler functions to URL patterns.

```julia
# src/Routes.jl
module Routes

using Nitro: path, RouteDefinition
import ..MathHandlers
import ..ProductHandlers

urlpatterns() = RouteDefinition[
    path("/api/math/multiply/<float:a>/<float:b>", MathHandlers.multiply, method="GET"),
    path("/api/math/divide/<float:a>/<float:b>",   MathHandlers.divide,   method="GET"),

    path("/api/products",               ProductHandlers.list_products,  method="GET"),
    path("/api/products/<int:id>",      ProductHandlers.get_product,    method="GET"),
    path("/api/products",               ProductHandlers.create_product, method="POST"),
]

end # module
```

`urlpatterns` is a function, so the list is built when `main()` registers it. The module takes only
`path` and `RouteDefinition` from Nitro: under a blanket `using Nitro`, defining its own
`urlpatterns` would silently shadow Nitro's.

---

## Splitting routes across files with `include_routes`

For larger apps, split `urlpatterns` into per-domain files and compose them with
`include_routes`.

```
src/
└── Routes/
    ├── math_routes.jl
    └── product_routes.jl
```

```julia
# src/Routes/math_routes.jl  (included into `Routes`)
import ..MathHandlers

const math_routes = [
    path("/multiply/<float:a>/<float:b>", MathHandlers.multiply, method="GET"),
    path("/divide/<float:a>/<float:b>",   MathHandlers.divide,   method="GET"),
]
```

```julia
# src/Routes.jl
module Routes

using Nitro: path, include_routes, RouteDefinition
include("Routes/math_routes.jl")
include("Routes/product_routes.jl")

urlpatterns() = vcat(
    include_routes("/api/math",     math_routes),
    include_routes("/api/products", product_routes),
)

end # module
```

The prefix passed to `include_routes` is prepended to every path in the included list,
so `/multiply/<float:a>/<float:b>` becomes `/api/math/multiply/<float:a>/<float:b>`.

`include_routes` returns a `Vector{RouteDefinition}`, not a single route, so compose several
groups with `vcat` — nesting them in a plain `[...]` would build a vector of vectors, which
`urlpatterns()` does not accept.

---

## The boot `newapp` writes

This is `src/MyApp.jl` exactly as `Nitro.newapp("MyApp")` writes it when you choose SQLite. A test
generates the app and compares the file with this page, so the two cannot drift apart.

<!-- newapp:src/MyApp.jl -->
```julia
module MyApp

using Nitro, PormG, SQLite

const app = App(mod = @__MODULE__)

# Once db/models.jl defines models, include them here for the handlers (`import ..appM`).
# Including only defines them: `main` binds them to the connection.
#   include("../db/models.jl")
#   const appM = models

include("Handlers/HealthHandlers.jl")
include("Routes.jl")

"""
    main(; root::AbstractString = pkgdir(@__MODULE__), kwargs...)

Boot the app and serve it. Reads `PORT` (default 8000) and `API_SECRET_KEY` (at least
32 bytes); keyword arguments go to `serve` (tests pass `async = true`).

`root` is the folder that holds `db/`. `main.jl` passes `APP_ROOT`, else the working
directory: in a JuliaC executable `pkgdir` names the folder it was built from.
"""
function main(; root::AbstractString = pkgdir(@__MODULE__), kwargs...)
    # PormG reads `root`/db/connection.yml in the environment `PORMG_ENV` names,
    # else `NITRO_ENV` (or `GENIE_ENV`), else "dev"
    env = something(sync_pormg_env!(), current_env())
    PormG.Configuration.load_many(["db"]; root, env)
    # Once the models are included above, bind them to that connection:
    #   PormG.Models.set_models(models, joinpath(root, "db"))
    workers = worker_startup(app; queues = ["reports"], store = pormg_nitro_worker(db_key = "db"))
    urlpatterns(app, "", Routes.urlpatterns())
    serve(app; port = parse(Int, get(ENV, "PORT", "8000")), middleware = [workers],
          secret_key = SecretString(ENV["API_SECRET_KEY"]), kwargs...)
end

end # module
```
<!-- /newapp -->

Line by line:

- `using Nitro, PormG, SQLite`: `SQLite` is the driver for the adapter in `db/connection.yml`. A
  PostgreSQL app loads `LibPQ` instead.
- `const app = App(mod = @__MODULE__)`: the application handle that every routing and serving call
  takes. `mod = @__MODULE__` is what `serve(revise = …)` tracks.
- `env = something(sync_pormg_env!(), current_env())` is the environment PormG reads
  `connection.yml` in. [`sync_pormg_env!`](@ref) publishes `NITRO_ENV` (or `GENIE_ENV`) to
  `PORMG_ENV` when one is set, and returns `PORMG_ENV`, so a `PORMG_ENV` the deployment set
  still wins. With none of the three set, it is [`current_env`](@ref)'s `"dev"`. It has to be
  named, because outside a REPL PormG refuses a `load` with no environment rather than guess one,
  and with it named, `default_env:` in `connection.yml` is not read. Set `NITRO_ENV=prod` in
  production and give `connection.yml` a `prod:` block.
- `main(; root = pkgdir(@__MODULE__), …)`: `root` is the folder that holds `db/`. Called from the
  REPL, it defaults to the package's own directory, so `MyApp.main()` works from any working
  directory. `main.jl` passes another one, for the reason given under *The entry point `newapp`
  writes* below.
- `load_many(["db"]; root, env)`: PormG parses `root/db/connection.yml` and validates it; the
  first query connects. The connection key stays `"db"`.
- `set_models(models, joinpath(root, "db"))` binds the models you included to that connection,
  once there are any. Until then the line stays commented out.
- `worker_startup(app; …, store = pormg_nitro_worker(db_key = "db"))`: background tasks are
  stored in the database, on the same connection. See [Workers](workers.md).
- `urlpatterns(app, "", Routes.urlpatterns())` registers the routes. The prefix comes first, and
  `""` is the root.
- `serve(app; …)` is keyword-only. `PORT` defaults to `8000`, and `API_SECRET_KEY` must hold at
  least 32 bytes. Keyword arguments to `main` go through to `serve`, which is how a test starts the
  server with `async = true`.

Global middleware goes in `serve`'s `middleware` list, next to `workers`, and runs before every
route, whichever handler it targets:

```julia
serve(app; port = parse(Int, get(ENV, "PORT", "8000")),
      middleware = [workers, SessionMiddleware(store = MemoryStore()), RateLimiter()],
      secret_key = SecretString(ENV["API_SECRET_KEY"]))
```

## The entry point `newapp` writes

`main.jl` is the program. `julia --project main.jl` runs it, and it is the file a JuliaC build
compiles into an executable. The same test pins it to this page:

<!-- newapp:main.jl -->
```julia
# The program: `julia --project main.jl` runs it, and a JuliaC build compiles it into an
# executable. In an executable an exception that escapes `@main` is printed field by field,
# secrets included, so a failed start-up is caught here and reported without its values.
using MyApp, Nitro

function (@main)(args::Vector{String})::Cint
    try
        # The folder that holds db/. Not `pkgdir`: in a JuliaC executable that is the
        # temporary copy of the project it was built from, gone by the time it runs.
        MyApp.main(; root = get(ENV, "APP_ROOT", pwd()))
    catch e
        e isa InterruptException && rethrow()
        # Not `@error "…" exception = e`: a trimmed image cannot show an arbitrary
        # exception, and an untrimmed one would print its values.
        println(Core.stderr, "start-up failed: ", Nitro.startup_failure_text(e))
        return Cint(1)
    end
    return Cint(0)
end
```
<!-- /newapp -->

- `(@main)` is what Julia runs after the file is loaded, as a script or as an executable's entry.
  It returns the exit code.
- `root = get(ENV, "APP_ROOT", pwd())`: an executable cannot use `pkgdir`. JuliaC builds from a
  temporary copy of the project and deletes it afterwards, and `pkgdir` (like `@__DIR__`) still
  names that copy when the executable runs. So the program takes the folder that holds `db/` from
  `APP_ROOT`, else from the working directory: start it from the app's directory, or set
  `APP_ROOT`.
- The `try` covers the whole life of the server, and the `catch` prints one line and exits with
  `1`. In a compiled executable an exception that escapes `main` is printed field by field, so a
  password or a key it holds would reach the log.
  [`Nitro.startup_failure_text`](@ref Nitro.Core.Errors.startup_failure_text) names the exception
  without its values. `serve` already does this for its own errors, but what `main` runs before it
  (`load_many`, `worker_startup`, `urlpatterns`) is outside `serve`. Never put a secret into the
  message of an `error(...)` or an `ArgumentError` you throw at start-up: those messages are
  printed verbatim. The *Compiling with juliac* section of [Deployment](deployment.md) has the
  details.

---

## Middleware layers

Nitro supports middleware at three levels: **global** (via `serve()`), **group** (via the
`middleware=` keyword on `include_routes()`), and **route-level** (via the `middleware=` keyword
on `path()`).

Execution order is always:

```
global middleware → group middleware (outer group first) → route middleware → handler
```

Each list runs top-down, in the order written. The route is chosen between the global list and
the rest. A middleware that rewrites the method or the path
(`X-HTTP-Method-Override`, a legacy alias) therefore belongs in the global list, where the
rewritten request still gets its new route's guards. See
[Rewriting the method or the target](extension_points.md#Rewriting-the-method-or-the-target).

### Global middleware

```julia
serve(app; middleware=[SessionMiddleware(store=MemoryStore()), RateLimiter()])
```

### Route-level middleware

Apply middleware to individual routes by passing a `middleware=` vector to `path()`.

```julia
const routes = [
    # public — no extra middleware
    path("/api/products", ProductHandlers.list_products, method="GET"),

    # protected — requires authentication. Guards reach a route through `GuardMiddleware`;
    # they are not middleware themselves.
    path("/api/products", ProductHandlers.create_product,
         method="POST", middleware=[GuardMiddleware(login_required())]),

    path("/api/products/<int:id>", ProductHandlers.delete_product,
         method="DELETE",
         middleware=[GuardMiddleware(login_required(), role_required("admin"))]),
]
```

### Group middleware

`include_routes` can give a whole group of routes the same middleware
([#439](https://github.com/PingoLee/Nitro.jl/issues/439)). It runs on every route in the group,
ahead of each route's own list. The common use is an app that serves a browser UI and a
bearer-token API: sessions and CSRF belong on the browser routes only.

```julia
browser = include_routes("", [
    path("/login", AuthHandlers.login_form, method="GET"),
    path("/login", AuthHandlers.login, method="POST"),
    path("/account", AccountHandlers.show, method="GET",
         middleware=[GuardMiddleware(login_required())]),
]; middleware=[SessionMiddleware(store=store), CSRFMiddleware(csrf_secret)])

api = include_routes("/api", [
    path("/products", ProductHandlers.list_products, method="GET"),
    path("/products", ProductHandlers.create_product, method="POST"),
]; middleware=[BearerAuth(validator)])

urlpatterns(app, "", vcat(browser, api))
```

A `POST /login` meets `SessionMiddleware`, then `CSRFMiddleware`, then its handler. `GET /account`
meets the same two, then its own `GuardMiddleware`. A `POST /api/products` never meets the
session or the CSRF check.

Groups nest. An `include_routes` around another puts its own list first:

```julia
admin = include_routes("/admin", admin_routes; middleware=[GuardMiddleware(role_required("admin"))])
api   = include_routes("/api", vcat(public_routes, admin); middleware=[BearerAuth(validator)])
# GET /api/admin/users: BearerAuth → the admin guard → the route's own list → handler
```

Every route in a group shares the same middleware **instances**. One `SessionMiddleware` keeps
one store, and its prune janitor starts once when `serve()` starts. Do not list the same layer at
two levels, such as globally and in a group: the lifecycle is registered once, but the layer
itself runs once per list it appears in, on every request.

Group middleware runs only on a request that matched one of the group's routes. A request that
matches nothing (404), or matches a path but not its method (405), never reaches it. Keep layers
that must see every request, such as rate limiting, access logging or `ExtractIP`, in the global
list.

### Per-route middleware and global middleware

Global middleware — the `middleware=[...]` you pass to [`serve`](@ref) — runs on **every**
request, including requests that match no route (404) and requests whose path matches but
whose method does not (405).  A route cannot opt out of it.

Passing `middleware=[]` on a `path()` call means "this route adds no middleware of its own".
It does **not** bypass the global chain:

```julia
# Global middleware still runs here — `middleware=[]` only means "no *extra* middleware",
# which is the same as omitting the kwarg. Prefer omitting it.
path("/health", HealthHandlers.ping, method="GET")
```

If a health-check endpoint must respond even when a dependency the global middleware needs is
unavailable, make that middleware tolerate the failure — for example by skipping its work for
specific paths — rather than expecting the route to escape it.

---

## Internal requests

Use `internalrequest` to call one of your own endpoints from within another
handler — for example, to reuse validation logic or chain computations:

```julia
using HTTP
import ..app   # the handle src/MyApp.jl defines before it includes the handlers

function process_and_fetch(req::HTTP.Request, id::Int)
    # call another endpoint inside the same server. `/api/products` sits behind the `api`
    # group's BearerAuth above, which still runs, so pass the caller's credentials along.
    inner = internalrequest(app, HTTP.Request("GET", "/api/products/$id",
                                              ["Authorization" => HTTP.header(req, "Authorization", "")]))
    data  = JSON3.read(inner.body)
    # ... further processing
    return Res.json(data)
end
```

!!! warning "An internal request skips your global middleware"
    `internalrequest` runs only the middleware you pass to that call, not the global list given
    to `serve(app; middleware = …)`. Authentication, sessions, CSRF and rate limiting installed
    globally do not apply to it. Group and route middleware still run. Unless the request
    already carries a client IP, it is `127.0.0.1`.

    Build the target yourself, as above, from values you have already validated (`id` is an
    `Int` here). A handler that passes a client-supplied path to `internalrequest` lets that
    client reach every route guarded only by global middleware, as loopback.