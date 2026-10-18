## `App(not_found = …, method_not_allowed = …)` — the custom 404/405 move off the router, and `Service` accepts only Nitro's own router

- **Version**: Unreleased
- **Nitro ref**: [#625](https://github.com/PingoLee/Nitro.jl/issues/625) ; `src/types.jl`, `src/context.jl`, `src/core/pipeline.jl`, `src/core/staticfiles.jl`, `src/core/registration.jl`
- **Recorded**: 2026-10-17
- **Severity**: breaking. An app that passed its own `HTTP.Router` to `Service` fails at
  construction with a `MethodError`. A custom 404/405 is now a fixed response, not a handler.

### What changed

A custom 404 or 405 used to ride in the router's type: `Service(router = HTTP.Router(my404,
my405))`. That made `Service.router` an abstract field, and every pipeline closure that captured
it abstract too, which is what blocked compiling an app with `juliac --trim`
(docs/design/juliac-trim.md §3.1). Every `App` now holds one concrete router type, and:

| Before | After |
|---|---|
| `App(service = Service(router = HTTP.Router(my404)))` | `App(not_found = Res.json(…; status = 404))` |
| `App(service = Service(router = HTTP.Router(my404, my405)))` | `App(not_found = …, method_not_allowed = …)` |
| `my404`/`my405` are **functions** of the request | **fixed `HTTP.Response` values**: every request they answer gets a copy, which shares the value's body |
| any body the handler built | the body is none (`HTTP.Response(404)`), a `String` or a `Vector{UInt8}` (what `Res.json` and `Res.send` build); another string or byte vector is copied into one |
| a streaming or cursor body (`HTTP.BytesBody`) | `ArgumentError` at `App` construction, naming the keyword: only the first miss could have sent it |
| `my405` could return a non-`Response` (a `Dict` for the serializer) | a value is always an `HTTP.Response`; `nothing`, a `Dict` or anything else is the same `ArgumentError` |
| HTTP.jl router-level middleware, `HTTP.Router(_, _, mw)` | gone: a `Service` accepts only Nitro's own router |
| `Service(router = <any other HTTP.Router>)` | `MethodError` at construction |

What did **not** change: the custom 405 still decides the response; Nitro adds `Allow` only when
it has none, on a copy, so the value is never mutated; static mounts (`staticfiles`, `spafiles`,
`dynamicfiles`) answer their misses with the same two values; the defaults are still a bare `404`
and a `405` with `Allow`. A path outside `serve(prefix = …)` still gets the prefix layer's own
`404`, as it did before, because that layer answers before routing.

The refusal #282 added (an `ArgumentError` for a guarded `"*"`, `STREAM` or `WEBSOCKET` route on a
router carrying HTTP.jl-level middleware) is gone with that middleware, because no such router can
be registered on any more.

### How to find the calls to migrate

```bash
# Every Service your app builds (the `router =` keyword may be on the next line), and every
# router it constructs, qualified (`HTTP.Router(`) or imported (`using HTTP: Router`).
grep -rnE 'Service\(|\bRouter\(' --include=*.jl .
```

An app with neither needs nothing.

### Migrate your app

A fixed custom page moves to the `App` keywords:

```julia
# ✗ before
my404(req) = Res.json(Dict("error" => "not found"); status = 404)
app = App(mod = @__MODULE__, service = Service(router = HTTP.Router(my404)))

# ✓ after
app = App(mod = @__MODULE__, not_found = Res.json(Dict("error" => "not found"); status = 404))
```

A 404/405 that varied **per request** becomes a global middleware that rewrites the miss on its
way out. `route_missed(req)` is `true` exactly when Nitro answered "no route here":

```julia
# ✗ before
my404(req) = accepts_html(req) ? Res.html(NOT_FOUND_PAGE; status = 404) :
                                 Res.json(Dict("error" => "not found"); status = 404)
app = App(mod = @__MODULE__, service = Service(router = HTTP.Router(my404)))

# ✓ after
function miss_page(handler)
    return function (req)
        res = handler(req)
        (route_missed(req) && res isa HTTP.Response && res.status == 404) || return res
        return accepts_html(req) ? Res.html(NOT_FOUND_PAGE; status = 404) : res
    end
end
app = App(mod = @__MODULE__, not_found = Res.json(Dict("error" => "not found"); status = 404))
serve(app; middleware = [miss_page])
```

HTTP.jl router-level middleware moves into Nitro's own chain: `serve(middleware = [mw])` for
every request, or `router(prefix; middleware = [mw])` / `path(…; middleware = [mw])` for a group
or a route. Nitro's chain also covers the routes HTTP.jl-level middleware could not guard.
