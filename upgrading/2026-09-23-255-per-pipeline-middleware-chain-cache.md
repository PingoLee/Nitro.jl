## `ctx.service.middleware_cache` and `cachetag` removed — middleware chains are cached per pipeline

- **Version**: Unreleased
- **Nitro ref**: [#255](https://github.com/PingoLee/Nitro.jl/issues/255), [#250](https://github.com/PingoLee/Nitro.jl/issues/250) ; `src/routerhof.jl`, `src/types.jl`, `src/context.jl`
- **Recorded**: 2026-09-23
- **Severity**: breaking for code that reached into the old cache — in practice, app **tests**
  written to the advice in the `0.3.0` entry for #79. Serving behavior does not change, except
  that per-route middleware is now composed once per route instead of on every request in apps
  that also pass global middleware.

### What changed

A route's composed middleware chain used to be cached in one table per app,
`ctx.service.middleware_cache`, keyed on `"METHOD|path"` plus a settings tag built by
`Nitro.Core.RouterHOF.cachetag`. That table could not cache at all when the pipeline had global
middleware — `serve(middleware = [...])`, and every `revise=:lazy|:eager` session — so those apps
recomposed the chain on every request.

Each pipeline now owns its chain cache, and it is not reachable from `App`. Removed:

- the `Service` field `middleware_cache`
- `Nitro.Core.RouterHOF.cachetag` and `CACHE_TAGS`
- `cache!`, `cache_if_current!`, `delete!` and `empty!` on `Nitro.Core.Types.CopyOnWriteDict`,
  which now backs only `custommiddleware`
- the `catch_errors`/`show_errors`/`serialize` keywords of `Nitro.Core.RouterHOF.compose`

Two consequences worth knowing, neither of which needs an edit:

- `internalrequest` builds a new pipeline on every call, so it no longer reuses a chain from an
  earlier call. `serve` keeps one pipeline, so a served app is warm after the first request per
  route, as before.
- A registration anywhere makes each pipeline recompose a route's chain on that route's next
  request, once.

`custommiddleware` and `genkey` are unchanged.

### How to find the calls to migrate

```bash
rg -n 'middleware_cache|cachetag|CACHE_TAGS|cache_if_current' <app>/src <app>/test
```

A miss is loud: `FieldError: type Service has no field middleware_cache`, or an `UndefVarError`
for `cachetag` at `using` time.

### Migrate your app

Assert on what the cache is for — which middleware ran, and how often a chain was composed —
rather than on its keys. A middleware factory runs once per composition, so a counter in it is a
build counter; drive a pipeline built once, the way `serve` does, rather than `internalrequest`:

```julia
# ✗ before — the 0.3.0 advice for #79
using Nitro.Core.RouterHOF: cachetag
internalrequest(ctx, HTTP.Request("GET", "/warm"); catch_errors = false)
@test haskey(snapshot(ctx.service.middleware_cache), "GET|/warm" * cachetag(false, true, true))

# ✓ after — behavior, not keys
builds = Ref(0)
counted = handler -> (builds[] += 1; req -> handler(req))
urlpatterns(ctx, "", [path("/warm", handler, middleware = [counted])])
pipeline = Nitro.Core.setupmiddleware(ctx; catch_errors = false)
pipeline(HTTP.Request("GET", "/warm")); pipeline(HTTP.Request("GET", "/warm"))
@test builds[] == 1                     # composed once, then served from the cache
```

A test that asserted a chain was *invalidated* (a key gone after re-registration) becomes one that
asserts the new middleware runs: re-register the route, then check the response body.
