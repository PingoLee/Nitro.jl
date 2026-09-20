## `SessionMiddleware` returns a `LifecycleMiddleware`; `prune_probability` is gone (#36)

- **Version**: Unreleased
- **Nitro ref**: #36; `src/middleware/session_middleware.jl`, `src/types.jl`, `src/cookies.jl`,
  `src/Nitro.jl`, `docs/src/tutorial/sessions_and_auth.md`,
  `docs/src/tutorial/cookies/sessions.md`
- **Recorded**: 2026-09-14
- **Severity**: **breaking, and it fails LOUDLY** — a `prune_probability` keyword is now an
  `UndefKeywordError`-style unsupported-keyword error, and calling the result of
  `SessionMiddleware(...)` directly is a `MethodError`. An app that only ever passes the result
  into `serve(middleware = [...])` or `urlpatterns(...)` needs **no change at all**: those
  already accept `LifecycleMiddleware`.

### What changed

Session pruning moved off the request path. `SessionMiddleware` used to run
`cleanup_expired_sessions!` inline on a `prune_probability` fraction of requests (default
`0.01`), so ~1 request in 100 paid a full O(N) scan of the store — and under `MemoryStore` that
scan holds the single lock every other session read and write also needs. At 100k live sessions
every concurrent request blocked behind it: periodic p99 spikes from the component that sits on
every stateful request.

Pruning is now a background janitor tied to the server lifecycle, which is why
`SessionMiddleware` had to start returning a `LifecycleMiddleware` (the same type
`RateLimiter` and `AccessLog` already return) — it needs `on_startup`/`on_shutdown` hooks to
own a task. The janitor starts on `serve()` and stops on `terminate()`.

Two things this does **not** change: expiry was already enforced lazily on read, so an unpruned
store never served a stale session — this is about reclaiming memory, not correctness. And
`prune_interval` is a `Period`, not a probability.

New in the same change, and purely additive: `SessionPruner(store; interval)` is a
pass-through `LifecycleMiddleware` that runs only the janitor, for apps that reach sessions
through the `Session{T}` extractor without installing `SessionMiddleware` — that path never
pruned at all.

### How to find the calls to migrate

```bash
# 1. The removed keyword — always needs an edit.
grep -rn "prune_probability" --include=*.jl .

# 2. Calling the middleware directly. Composing it by hand is what breaks; passing it to
#    serve()/urlpatterns() is fine. This finds the single-line call form ONLY -- multi-line
#    calls are caught by (3), which is how most call sites are actually written:
grep -rnE "SessionMiddleware\([^)]*\)\s*\(" --include=*.jl .

# 3. And the two-step form, where the result is bound and then applied.
grep -rn "= SessionMiddleware(" --include=*.jl .
```

### Before → after

Passing it to `serve` — unchanged, no edit needed:

```julia
serve(app, middleware = [SessionMiddleware(store = store)])
```

Dropping `prune_probability`, and setting the janitor period instead:

```julia
# before
SessionMiddleware(store = store, prune_probability = 0.01)
# after — a Period, not a probability. Omit it for the 10-minute default.
SessionMiddleware(store = store, prune_interval = Minute(10))
```

Composing the middleware by hand:

```julia
# before
wrapped = SessionMiddleware(store = store)(handler)
# after
wrapped = SessionMiddleware(store = store).middleware(handler)
```

If you disabled pruning in tests with `prune_probability = 0.0`, just delete the keyword: the
janitor only runs between `on_startup()` and `on_shutdown()`, and neither fires unless you
start a server or call them yourself.

Apps that use a store without `SessionMiddleware` never pruned and now can:

```julia
# after — the store is otherwise reached only through Session{T}
serve(app, middleware = [SessionPruner(store; interval = Minute(5))], context = store)
```
