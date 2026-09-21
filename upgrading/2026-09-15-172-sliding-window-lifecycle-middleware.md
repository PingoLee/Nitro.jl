## `RateLimiter(strategy = :sliding_window)` returns a `LifecycleMiddleware`, like the fixed one (#172)

- **Version**: 0.4.0
- **Nitro ref**: #172 (follow-up to #22 / PR #168); `src/middleware/rate_limiter.jl`,
  `docs/src/tutorial/extension_points.md`, `test/middleware/ratelimitter_tests.jl`,
  `test/middleware/ratelimitter_lru_tests.jl`, `bench/suite/ratelimiter.jl`
- **Recorded**: 2026-09-15
- **Severity**: **breaking, and it fails LOUDLY** — calling the result of
  `RateLimiter(strategy = :sliding_window, ...)` directly is now a `MethodError` (you cannot
  call a struct). There is no configuration in which the old call quietly keeps working. An app
  that only ever passes the result into `serve(middleware = [...])`, `path(...)` or
  `urlpatterns(...)` needs **no edit at all** — those already accept a `LifecycleMiddleware`.

### What changed

The two strategies returned different types from the same constructor, with the same keyword
surface:

- `:fixed_window` returned a `LifecycleMiddleware` — it owns a background cleanup sweep, so it
  needs `on_startup`/`on_shutdown`.
- `:sliding_window` returned a **bare `Function`** — its LRU evicts by size, so it has no
  background task and nothing to hook.

`strategy` is documented as a choice of *algorithm*. It was quietly also a choice of return
type, which callers composing a chain by hand had to discover and branch on:

```julia
mw = x isa Nitro.LifecycleMiddleware ? x.middleware : x
```

That idiom was real: it appeared in Nitro's own test suite and benchmark suite, and it is
exactly the kind of thing an application copies once and never revisits.

`SlidingRateLimiter` now returns a `LifecycleMiddleware` too, with **both hooks left
`nothing`**. `startup`/`shutdown` already no-op on a `nothing` hook, so the wrapper costs one
allocation at construction and nothing per request. Nothing was incorrect before — this buys a
uniform type, which is cheap to take pre-publish and expensive to take later.

`RateLimiter` also gained a docstring, so `docs/src/api.md` stops rendering an empty entry for
it.

### How to find the calls to migrate

```bash
# 1. Every construction site, qualified or not. Read each hit: the ones needing an edit are
#    those that CALL the result -- `RateLimiter(...)(handler)`, or a binding applied later.
#    Passing it to serve()/path()/urlpatterns() needs no change.
#
#    One deliberately broad grep, because no narrower regex is honest here. Matching the
#    call form directly fails on the two commonest spellings: `[^)]*` cannot cross the inner
#    paren in `RateLimiter(strategy = :sliding_window, window = Minute(1))(handler)`, and
#    most real call sites are multi-line. A qualified `Nitro.RateLimiter(` also escapes any
#    pattern anchored on the bare name -- that spelling is what Nitro's own bench file uses.
grep -rnE "(Nitro\.)?(Fixed|Sliding)?RateLimiter\(" --include=*.jl .

# 2. The unwrap idiom, now dead code: the second arm is unreachable, both strategies return
#    a LifecycleMiddleware.
grep -rnE "isa +(Nitro\.)?LifecycleMiddleware" --include=*.jl .
```

### Before → after

Passing it to `serve` or a route — unchanged, no edit needed:

```julia
serve(app, middleware = [RateLimiter(strategy = :sliding_window, rate_limit = 100)])
path("/api", handler, middleware = [RateLimiter(strategy = :sliding_window)])
```

Composing it by hand:

```julia
# before -- worked for :sliding_window only, and silently differed from :fixed_window
wrapped = RateLimiter(strategy = :sliding_window, rate_limit = 100)(handler)
# after
wrapped = RateLimiter(strategy = :sliding_window, rate_limit = 100).middleware(handler)
```

Dropping the branch, if you carried one:

```julia
# before
rl = RateLimiter(; strategy, rate_limit = 100)
mw = rl isa Nitro.LifecycleMiddleware ? rl.middleware : rl
# after -- one type, whichever strategy
mw = RateLimiter(; strategy, rate_limit = 100).middleware
```

The sliding limiter still owns no background task. Its hooks are `nothing`, so `serve()` and
`terminate()` find nothing to run — registering it is free, not a behaviour change:

```julia
rl = RateLimiter(strategy = :sliding_window)
@assert rl.on_startup === nothing && rl.on_shutdown === nothing
```
