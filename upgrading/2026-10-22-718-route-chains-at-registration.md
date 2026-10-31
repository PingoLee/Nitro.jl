## Route middleware is folded once, at registration; a leaf not registered through Nitro is refused (#718)

- **Version**: 0.7.0
- **Nitro ref**: [#718](https://github.com/PingoLee/Nitro.jl/issues/718) ; `src/routeendpoint.jl`, `src/routerhof.jl`, `src/core/pipeline.jl`, `src/core/registration.jl`
- **Recorded**: 2026-10-22
- **Severity**: breaking (a route put on the app's router with `HTTP.register!`); behavior (when a route middleware factory runs)

### What changed

Each route now has one erasure point, a `RouteEndpoint`, for its middleware chain and one for its
handler, so a `juliac --trim=safe` build can call them without a dynamic call
(docs/design/juliac-trim.md §3.2). Two things follow that an application can observe.

**A route middleware factory runs once per route, when the route is registered.** A middleware is
a factory, `handler -> (req -> response)`, and Nitro calls it to build a route's chain. It used to
call it once per route *per pipeline*: once for `serve`, and once more for every `internalrequest`,
each of which builds its own pipeline (#255). It now calls it once, inside `urlpatterns` (or
`router(...)`), and every pipeline runs that one chain. So **whatever the factory creates is
shared** between `serve` and every `internalrequest`: a counter, a cache, a store a rate limiter
keeps in the closure. Code that keeps its state in the returned `req -> response` function, or
in a middleware object built outside the factory (the usual shape), sees no difference. The
per-request order of layers is unchanged (global, then group, then route, each top-down), and so
is what reaches the handler.

This applies to route and group middleware (`path(...; middleware)`, `include_routes(...;
middleware)`, `router(...; middleware)`). Global middleware, `serve(middleware = ...)`, is still
folded once per pipeline. Precisely, the factory runs once per method and path a route is
registered under: `methods = ["GET", "POST"]` builds two chains, and a `GET` route's automatic
`HEAD` shares the `GET` chain. Three consequences of running at registration:

- **A factory that throws makes `urlpatterns` throw**, where it used to fail the route's first
  request.
- **The `handler` a factory receives can only be called with a request.** It is the route's
  continuation into whichever pipeline later runs the chain, so calling it while the chain is
  being built (from the factory body itself) throws.
- **A route middleware must pass the request it was given downstream**, modified or not. One that
  builds a new `HTTP.Request` and calls `handler` with it fails with a `500`: the new object
  carries no route resolution, so the chain has nowhere to continue. Before, the router re-resolved
  the new request and served it.

**A leaf put on the app's router with `HTTP.register!` is refused.** Routes are declared with
`path()` and registered with `urlpatterns()` or `include_routes()` (nitro-core §3); a direct
`HTTP.register!(app.service.router, …)` was never part of that surface, but it used to work. Now:

- `serve` refuses to start when the router holds such a leaf, before it changes anything, with an
  `ArgumentError` naming the method and path and pointing at `path()`;
- a request that reaches one anyway (through `internalrequest`, or a leaf added after `serve`)
  gets a `500`, and an `@error` naming the route; the leaf never runs.

### How to find the calls to migrate

```bash
# Direct registrations on an app's router:
grep -rn -E 'register!\(' --include=*.jl . | grep -v -E '\bpath\('
# Route middleware factories that create state when CALLED (look inside each match for a
# counter, a Dict, a store or a Ref created before the inner `req ->` function):
grep -rn -E 'middleware *= *\[' --include=*.jl .
# Middleware that hands a NEW request downstream:
grep -rn -E '(handler|next|h)\(HTTP\.Request\(' --include=*.jl .
```

### Before → after

A direct registration becomes a `path()`:

```julia
# before
HTTP.register!(app.service.router, "GET", "/health", req -> HTTP.Response(200, "ok"))

# after
urlpatterns(app, "", path("/health", req -> Res.send("ok"); method = "GET"))
```

A factory whose state must not be shared between `serve` and `internalrequest` now creates it
per request (or keys it by something it can see on the request) instead of once per call:

```julia
# before: one counter per pipeline -- serve's and each internalrequest's were separate
counting = handler -> begin
    hits = Ref(0)
    req -> (hits[] += 1; handler(req))
end

# after: the factory runs once per route, so that counter is now shared by every pipeline.
# Keep it if sharing is what you want; otherwise create the state where it belongs, e.g. per
# request on the request's context:
counting = handler -> (req -> (req.context[:hits] = get(req.context, :hits, 0) + 1; handler(req)))
```
