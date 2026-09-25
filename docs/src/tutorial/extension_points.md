# Extension Points

Nitro is built so a feature can ship as its **own package** — carrying its own routes, its own
middleware, and its own optional dependencies — and a host application mounts it in a few lines.
This page documents the seams that make that possible, so you can build a reusable app without
reading framework source.

| Seam | What you provide | When Nitro uses it |
|------|------------------|--------------------|
| **Route modules** | a function returning `RouteDefinition`s | at startup, when the host calls `urlpatterns()` |
| **Middleware** | a function that wraps a handler | once per request, top-down |
| **Package extensions** | an `ext/` module that fills in a stub | automatically, when a weak dependency loads |

Configuration is a fourth seam with its own page — see [BI App Config Example](@ref).

---

## Route modules

`path()` registers nothing. It **returns** a `RouteDefinition`, so a vector of them is an
ordinary value: build it, pass it around, return it from a function.

Three functions divide the work, and keeping them straight is what makes a package reusable:

| Function | Returns | Effect |
|---|---|---|
| `path(pattern, handler; method)` | one `RouteDefinition` | none — pure value |
| `include_routes(prefix, routes)` | a **new** `Vector{RouteDefinition}` | none — prefixes copies |
| `urlpatterns(prefix, routes)` | `nothing` | **registers** the routes on the context |

Only `urlpatterns()` touches global state. A reusable package should therefore stop at
`include_routes` and hand the vector back — **let the host application decide the prefix and the
moment of registration.** A package that calls `urlpatterns()` itself has taken that choice away
and can only ever be mounted once, in one place.

### A reusable app package

```julia
# CatalogApp/src/CatalogApp.jl
module CatalogApp

using HTTP
using Nitro

export routes

# Handlers stay internal to the package — the host never imports them.
list_products(req::HTTP.Request) = Res.json(Dict("products" => ["widget", "gadget"]))
get_product(req::HTTP.Request, id::Int) = Res.json(Dict("id" => id))

"""
    routes(; prefix = "/products") -> Vector{RouteDefinition}

The routes this package contributes. Returns a value; registers nothing.
"""
function routes(; prefix::String = "/products")
    return include_routes(prefix, [
        path("/",         list_products, method="GET"),
        path("/<int:id>", get_product,   method="GET"),
    ])
end

end # module
```

The host application mounts it:

```julia
# src/App.jl
using Nitro
using CatalogApp

urlpatterns("/api", CatalogApp.routes(prefix = "/products"))
serve()
```

That registers `/api/products/` and `/api/products/<int:id>`. The host chose `/api`, the package
chose `/products`, and neither had to know the other's decision.

### Composing several packages

`include_routes` returns a `Vector{RouteDefinition}`, so combine groups with `vcat` — nesting them
in a plain `[...]` builds a vector *of vectors*, which `urlpatterns()` does not accept.

```julia
using Nitro
using CatalogApp, BillingApp

urlpatterns("/api", vcat(
    CatalogApp.routes(prefix = "/products"),
    BillingApp.routes(prefix = "/invoices"),
))
serve()
```

!!! tip "Route names must stay unique"
    Passing `name=` to `path()` registers a reverse-lookup name for [`url`](@ref). Two packages
    mounted under different prefixes still share one name table, so prefix your package's route
    names (`"catalog.product_detail"`) rather than claiming a bare `"detail"`.

---

## Middleware

A middleware is a function that **takes a handler and returns a handler**. Nothing more — there is
no type to subtype and no interface to implement.

```julia
function TraceRequests(handler)
    return function(req::HTTP.Request)
        @info "request in"  method=req.method target=req.target
        res = handler(req)          # call inward
        @info "response out" status=res.status
        return res
    end
end
```

Pass it wherever middleware is accepted:

```julia
serve(middleware = [TraceRequests])
```

### Configurable middleware

To take options, write a **factory** — a function whose *return value* is the middleware above.
This is the shape every middleware Nitro ships uses (`SessionMiddleware(store=store)`,
`RateLimiter()`, `ExtractIP()`), which is why they appear **called** in a middleware list.

Several of them (`RateLimiter`, `AccessLog`, `SessionMiddleware`, `SessionPruner`) go one step
further and wrap that function in a [`LifecycleMiddleware`](@ref Nitro.Core.Types.LifecycleMiddleware),
which can own a background task that starts with `serve()` and stops with `terminate()`. The
hooks are optional — `RateLimiter` returns the same type for both strategies so that `strategy`
picks the algorithm and nothing else, but only `:fixed_window` has a task to hook. A middleware
list accepts either form. Only code that composes a middleware **by hand** has to care: the
request function is then the `.middleware` field, not the value itself.

```julia
serve(middleware = [SessionMiddleware(store = store)])          # either form works here
wrapped = SessionMiddleware(store = store).middleware(handler)  # composing by hand
```


```julia
function RequireApiKey(; header::String = "X-Api-Key", key::String)
    return function(handler)                       # the middleware
        return function(req::HTTP.Request)         # the handler it produces
            HTTP.header(req, header, "") == key ||
                return Res.json(Dict("error" => "unauthorized"); status = 401)
            return handler(req)
        end
    end
end

serve(middleware = [RequireApiKey(key = ENV["API_KEY"])])
```

!!! warning "`RateLimiter` and `RateLimiter()` are not the same thing"
    Nitro's built-in middleware are keyword-only factories. Listing one **uncalled** passes the
    factory itself, and the chain then tries to apply it to a handler — a `MethodError` when the
    pipeline is built, not a quiet no-op. Write
    `middleware = [SessionMiddleware(store=MemoryStore()), RateLimiter()]`.

### Execution order

Every middleware list runs **top-down**: the first entry is outermost, sees the request first, and
therefore sees the response last. That holds for the global list, a `router(...; middleware)`
list and a `path(...; middleware)` list alike.

```julia
serve(middleware = [A, B])
# A before  →  B before  →  handler  →  B after  →  A after

path("/admin", handler; middleware = [BearerAuth(validator), GuardMiddleware(login_required())])
# authenticate  →  authorize  →  handler
```

The full nesting, outermost to innermost, is:

```
global middleware  →  router middleware  →  route middleware  →  handler
```

So a guard placed on a *router* runs before an auth layer placed on one of its *routes*.
Authenticate at the same level as the guard, or at an outer one.

!!! note "Route and router lists ran bottom-up before #312"
    Before that fix, only the global list ran top-down. A route or router list ran in reverse,
    so `[BearerAuth(v), GuardMiddleware(...)]` checked its guards before authenticating. If you
    reversed a list to work around that, put it back in the order you mean.

Global middleware runs on **every** request, including ones that match no route (404) and ones
whose path matches but whose method does not (405). A route cannot opt out of it: passing
`middleware = []` on a `path()` call means "no *extra* middleware", not "skip the global chain".

The `req.target` global middleware reads is the path the router will match. An absolute-form
request line (`GET http://host/admin/users`) arrives reduced to `/admin/users`, and a path with
an empty segment (`//admin/users`, `/admin//users`) is answered `400` before any middleware
runs. HTTP.jl's router drops empty segments, so without that refusal `//admin/users` would reach
`/admin/users` past a `startswith(req.target, "/admin/")` test.

The path is also in **one canonical percent-encoding**. A static or SPA mount and a path
parameter decode the path after global middleware has run, so any other spelling would reach them
past your test. Every escape of a character that may stand unencoded in a path is decoded, and
everything else is written as an uppercase escape. So `/%61dmin/users` arrives as `/admin/users`,
`/files/%70rivate/x` as `/files/private/x`, and `caf%c3%a9` or a raw `café` as `caf%C3%A9`. A dot
segment (`/a/../b`, `/a/%2E%2E/b`) is answered `400`, like an empty one, and a malformed escape
(`%ZZ`) gets the same JSON `400` a mount or a path parameter gives it. The query string is left as
the client sent it.

That makes `startswith(req.target, "/files/private/")` hold for a directory inside a mount, not
only for the literal segments of a route. Write the prefix you test in canonical form too:
`"/caf%C3%A9/"`, not `"/caf%c3%a9/"` or `"/café/"`. Guards on the route or router are still the
better place to authorize: they run on the route that was actually matched, not on a URL pattern
that has to be kept in step with `urlpatterns`.

### Rewriting the method or the target

The route, and with it the router and route middleware, is chosen **after** global middleware
runs and **before** router middleware runs. A layer that rewrites `req.method` or `req.target`
therefore belongs in the global list. An `X-HTTP-Method-Override` layer, a legacy path alias
and a locale prefix are the usual cases. From there the rewritten request gets the new route's
own middleware and guards:

```julia
# Only a POST may be overridden, as with Express's `methodOverride`: letting a GET become a
# DELETE would turn a link or an <img> into a state-changing request.
method_override = handler -> function (req::HTTP.Request)
    m = HTTP.header(req, "X-HTTP-Method-Override", "")
    (req.method == "POST" && !isempty(m)) && (req.method = uppercase(m))
    return handler(req)
end

# FIRST in the list, so every layer after it — CSRFMiddleware included — sees the final method.
serve(app; middleware = [
    method_override,
    SessionMiddleware(store = store),
    CSRFMiddleware(csrf_secret),
])
```

Order inside the global list still matters. A global layer listed *before* the rewrite made its
decision on the original request: `CSRFMiddleware` skips its check for `GET`, so a `GET`
rewritten into a `DELETE` after it has already passed.

A router- or route-level layer runs after the route was chosen, and after every global layer. If
it rewrites the request onto a route with **different** middleware, Nitro refuses the request
with a `500` and logs an error naming both routes, because serving it would skip the new route's
guards. A rewrite that stays on the same route is served, and so is one onto a route that has no
router or route middleware. Stripping a trailing slash and mapping `HEAD` onto its `GET` are both
fine. The global layers still ran on the original request, which is one more reason to put the
rewrite in the global list.

### Rules a middleware must follow

- **Never mutate a `Response` an inner layer returned — build a new one.** The inner layer may be
  handing you a shared or `const` response, and mutating it corrupts every later request that
  receives the same object.
- **Return a `Response` on every path**, including the ones where you reject the request.
- **Do not keep per-request state in the factory.** The factory runs once; only the innermost
  closure runs per request. Anything assigned outside that innermost function is shared by every
  request on every thread.
- **Keep it type-stable.** Middleware sits in the request hot path — annotate `req::HTTP.Request`,
  and avoid returning different types from different branches.

---

## Package extensions

An **extension** lets Nitro gain a capability only when an optional package is present, without
taking a hard dependency on it. Nitro uses this for PormG, Revise, Mustache, OteraEngine, ProtoBuf
and TimeZones.

The mechanism is Julia's, and it has three parts.

**1. Declare the stub in the core.** `src/exts.jl` holds a function with no methods — a name the
core can export and document while owning no implementation:

```julia
# src/exts.jl
export pormg_nitro_session
function pormg_nitro_session end
```

**2. Declare the weak dependency.** In `Project.toml`, `[weakdeps]` names the optional package and
`[extensions]` maps an extension module to the dependency that triggers it:

```toml
[weakdeps]
Mustache = "ffc61752-8dc7-55ee-8c37-f3e9cdd09e70"

[extensions]
MustacheExt = "Mustache"
```

**3. Implement it in `ext/`.** The file name must match the `[extensions]` key. It imports the stub
and adds methods to it:

```julia
# ext/MustacheExt.jl
module MustacheExt

using Mustache
import Nitro: mustache          # the stub declared in src/exts.jl

function mustache(template::String; kwargs...)
    # ... real implementation
end

end
```

`mustache` now throws a `MethodError` until the user writes `using Mustache`, at which point Julia
loads `MustacheExt` and the method appears. No branch in the core, and no optional import.

!!! danger "Registration goes in `__init__()`, never the module body"
    A module body runs **only in the precompile worker**. Loading from cache does not re-run it, so
    a registry write, an `ENV` mutation, or any service wiring placed at top level silently never
    happens at runtime. Put load-time wiring in `__init__()`:

    ```julia
    module NitroReviseExt

    using Nitro
    import Revise

    function __init__()
        Nitro.register_revise_hooks!(; revise = () -> Revise.revise())
    end

    end
    ```

This seam is for extending **Nitro itself**. An application that merely *uses* an optional package
does not need it — a plain `using` in your own code is enough.

---

## Checklist for a reusable Nitro package

- Export a **function returning routes**, not a registered side effect — the host owns the prefix.
- Prefix your route `name=` values so two packages can be mounted together.
- Ship middleware as **keyword-only factories**, so options are explicit at the call site.
- Keep handlers unexported; the host should need only your `routes` and your middleware.
- Take configuration as **arguments**, not from a global — see [BI App Config Example](@ref).
- Reach for a package extension only when you are extending Nitro's own surface.
