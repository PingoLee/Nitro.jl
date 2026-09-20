## `internalrequest`'s `catch_errors`/`serialize` are no longer ignored on a warm route (#79)

- **Version**: 0.3.0
- **Nitro ref**: #79; `src/routerhof.jl`, `src/core.jl`, `src/types.jl`
- **Recorded**: 2026-09-01
- **Severity**: **behavior (a call that returned a `500` now throws)** — bug fix.

### What changed

`middleware_cache` lives on `ctx.service` and outlives any one pipeline, but the chain it stores
closes over the serializer — `DefaultSerializer(catch_errors; show_errors)`, present only when
`serialize` is true. Those three settings were baked into the cached value while the key named only
the route, so the **first** pipeline to warm a route won permanently and every later pipeline's
kwargs were silently ignored:

```julia
ctx = ServerContext()
urlpatterns(ctx, "", [path("/boom", req -> error("kaboom"), middleware = [mw])])

internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = true)   # 500, warms the cache
internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = false)  # ALSO 500 — ignored
```

The cache key now carries those settings (`"GET|/boom|cES"`), so each pipeline gets its own chain.
The second call above **throws**, as it always should have.

**This is not a `serve` change.** One pipeline lives for the server's lifetime there, so its baked
settings were always the correct ones. It reaches code that drives `internalrequest` with varying
kwargs against a shared context — in practice, test suites.

`serve`'s and `setupmiddleware`'s `show_errors` kwargs are now declared `::Bool` (they were
untyped), so that a truthy non-`Bool` cannot bake one behaviour into the chain while the key records
another. One previously-working combination now throws: `serve(…; serialize = false,
show_errors = <non-Bool>)` used to slip through — with `serialize = false` no serializer was built,
so the value was never converted — and is now a `MethodError` at the `serve` boundary.

### How to find the calls to migrate

```bash
# Two or more internalrequest calls against ONE context with differing kwargs — the shape whose
# outcome changes. Worth reading each hit rather than trusting the count.
rg -n -U 'internalrequest[\s\S]{0,200}?(catch_errors|serialize)' <app>/src <app>/test

# Assertions on cache key spelling, which gained a 4-character settings suffix.
rg -n 'middleware_cache' <app>/src <app>/test

# Non-Bool show_errors, which is now a MethodError rather than a silent conversion.
rg -n 'show_errors\s*=' <app>/src <app>/test
```

### Migrate your app

Only tests that leaned on the bug need an edit, and the edit is to assert the correct thing:

```julia
# ✗ before — the second call silently reused the first call's catch_errors = true
internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = true)
@test internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = false).status == 500

# ✓ after — catch_errors = false means the handler's error propagates
internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = true)
@test_throws Exception internalrequest(ctx, HTTP.Request("GET", "/boom"); catch_errors = false)
```

If a test asserted on cache keys directly, add the settings tag. Build it with `cachetag` rather
than hard-coding the four characters:

```julia
# ✗ before
@test haskey(snapshot(ctx.service.middleware_cache), "GET|/warm")

# ✓ after — catch_errors = false, show_errors and serialize defaulted
using Nitro.Core.RouterHOF: cachetag
@test haskey(snapshot(ctx.service.middleware_cache), "GET|/warm" * cachetag(false, true, true))
```

`custommiddleware` is **unchanged** — it still keys on the bare route. The two tables no longer
share a key space.
