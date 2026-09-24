## Middleware that rewrites `req.method` or `req.target` — the rewritten route's own middleware now runs

- **Version**: Unreleased
- **Nitro ref**: [#291](https://github.com/PingoLee/Nitro.jl/issues/291) ; `src/routerhof.jl`, `src/core/pipeline.jl`, `src/types.jl`
- **Recorded**: 2026-09-23
- **Severity**: behavior change. A middleware that rewrote `req.method` or `req.target` could run a
  different route's handler without that route's middleware or guards. A guarded route that used
  to answer such a rewritten request now refuses it. This was an authorization bypass.

### What changed

Nitro chose a request's route middleware from the request **as it arrived**, and global
middleware ran inside that chain. When a middleware then rewrote the method (an
`X-HTTP-Method-Override` layer) or the target (a legacy alias, a locale prefix), the router
dispatched the rewritten request to its new route. That route's handler ran, but its own
middleware had never been chosen, so its guards were skipped. This hit requests that matched a
route, and also requests that matched nothing (`404`) or matched the path under another method
(`405`). The usual HTML-form case is `POST` plus an override header.

Global middleware now runs **before** the route is chosen, as it does in Express and Django. A
rewrite made there is resolved together with the new route's middleware. Router- and route-level
middleware still run after selection. A rewrite made there is served only if the new route's
middleware is what already ran, or the new route has none. Anything else gets a `500` and an
`@error` log line naming both routes.

| Where the rewriting layer is | Rewritten onto | Before | After |
|---|---|---|---|
| global (`serve(middleware = [...])`, `internalrequest(...; middleware = [...])`) | any route | the new route's handler, without its middleware | the new route's handler, **with** its middleware |
| router- or route-level | the same route (trailing slash, query string, `HEAD` → `GET`) | served | served |
| router- or route-level | a route with no router or route middleware | served | served |
| router- or route-level | another route under the same `router(...; middleware)`, where neither route adds route middleware of its own | served | served |
| router- or route-level | a route with different middleware | the new route's handler, without its middleware | `500`, and an `@error` log line |

No request that nothing rewrites is affected. Global middleware still runs exactly once per
request, including on `404` and `405`, and in the same order relative to router and route
middleware.

One structural change is visible to hand-written global middleware: its **factory** (the outer
`handler -> ...` function) used to be called once per route chain plus once for unmatched
requests. It is now called once per pipeline, so everything it closes over is shared by every
request on every route. Nitro's own middleware keeps no state there. A global factory of yours
that did, and relied on getting a separate copy per route, needs to move that state into a
per-route key.

**What can need an edit:**

- A client that reached a guarded route through a rewrite without the credentials the guard asks
  for now gets its `401` or `403`.
- A router- or route-level middleware that sends requests to a route with different middleware
  now produces a `500`. Move it into global middleware, **first** in the list, so that layers
  which read the method, such as `CSRFMiddleware`, see the rewritten one.

### How to find the calls to migrate

```bash
# Middleware that assigns the method or the target.
grep -rnE 'req\.(method|target) *=' --include=*.jl .
# For each hit, check whether that middleware is passed as `middleware = [...]` on a `path(...)`
# or `router(...)` call rather than to `serve(...)`.
grep -rnE '(path|router)\(.*middleware *=' --include=*.jl .
```

A rewriting layer passed to `serve(middleware = [...])` needs no edit. It now gets the rewritten
route's guards, which is the fix.

### Migrate your app

```julia
# ✗ before — the override sat on the form's POST route. It ran only after that route was chosen,
#   and a POST carrying `X-HTTP-Method-Override: DELETE` now answers 500 instead of reaching the
#   guarded DELETE without its guard.
urlpatterns(app, "",
    path("/items/<int:id>", show_item),
    path("/items/<int:id>", update_item; method = "POST", middleware = [method_override]),
    path("/items/<int:id>", delete_item; method = "DELETE",
         middleware = [GuardMiddleware(login_required())]),
)

# ✓ after — the override is global and first, so it runs before the route is chosen and before
#   every layer that reads the method; the DELETE route's guard runs on the overridden request.
urlpatterns(app, "",
    path("/items/<int:id>", show_item),
    path("/items/<int:id>", update_item; method = "POST"),
    path("/items/<int:id>", delete_item; method = "DELETE",
         middleware = [GuardMiddleware(login_required())]),
)
serve(app; middleware = [method_override, SessionMiddleware(store = store), CSRFMiddleware(csrf_secret)])
```

While moving it, check what it overrides. Honour the header on `POST` only, as Express's
`methodOverride` does. Letting a `GET` become a `DELETE` turns a link into a state-changing request.

If a client relied on the missing guard, give it the credentials. Do not remove the guard.
