## `RateLimiter` — an exception from below the limiter propagates once, instead of becoming its `503` or running the chain twice (#421)

- **Version**: Unreleased
- **Nitro ref**: [#421](https://github.com/PingoLee/Nitro.jl/issues/421) ;
  `src/middleware/rate_limiter.jl`
- **Recorded**: 2026-10-02
- **Severity**: **behavior change.** No call stops compiling. A failure *below* a `RateLimiter`
  now gets Nitro's error response, usually `500`. With the default `fail_open = false` it used to
  be the limiter's `503`.

### What changed

Both strategies wrapped the whole request in the `try` meant for their own bookkeeping, and that
included the call into the rest of the chain. So an exception from anything the limiter wraps was
treated as a limiter failure. The limiter wraps a session store, a guard, CSRF, auth's
`StackOverflowError` rethrow, or the handler itself when the middleware is composed by hand.

Whether a route handler's own exception was affected depends on `catch_errors`:

- **`catch_errors = true` (the default): not affected.** The serializer turns the exception into a
  `500` before it reaches user middleware.
- **`serve(...; catch_errors = false)` or `serialize = false`: affected.** Nothing catches the
  exception early, so it reached the limiter like any other. Under `fail_open = true` that meant
  the **route handler itself ran twice**. Those apps changed the most.

| A layer below the limiter throws | Before | After |
|---|---|---|
| `fail_open = false` (default) | `503 Service Unavailable`, logged as `"… Rate limiter error"` | the exception propagates: Nitro's logged JSON `500` (or `400` for a `ValidationError`), or re-raised to a hand-composed caller |
| `fail_open = true` | the chain ran **a second time** for the same request, and its side effects (DB writes, emails, worker submissions) ran again; the second exception then escaped | the chain runs **once**, and the exception propagates as above |
| either, with `catch_errors = false` | as above. The chain includes the route handler, so with `fail_open = true` the handler ran twice | the exception reaches HTTP.jl unhandled, as it would with no limiter: a bodyless `500`, and no Nitro error log (only an access-log record, if that is on) |

`fail_open` now means only what its docstring says. A request the limiter cannot key (no client
address), an error in the limiter's own bookkeeping, and a new client at a full store still fail
closed with `503`, or pass through once under `fail_open = true`. `InterruptException`,
`StackOverflowError` and `OutOfMemoryError` raised inside the limiter are no longer turned into a
`503`. They propagate, the same as at every other middleware `catch` (#254).

### How to find the calls to migrate

```bash
# every limiter, and every one that opted into fail-open
grep -rn 'RateLimiter(\|FixedRateLimiter(\|SlidingRateLimiter(' --include=*.jl .
grep -rn 'fail_open' --include=*.jl .
# apps where a route handler's exception reached the limiter too
grep -rn 'catch_errors *= *false\|serialize *= *false' --include=*.jl .
# tests that read a 503 as "a layer below the limiter failed"
grep -rn 'status == 503' --include=*.jl test/
```

There is no code edit to make. What to review is anything that relied on the old status: a test
asserting `503` when a session store or a guard behind the limiter fails, or an alert on `503`s
that was really counting those failures. They are `500`s now, logged by Nitro's error handling
instead of under the limiter's label.

### Migrate your app

```julia
# a session store behind the limiter that fails
serve(app, middleware = [RateLimiter(), SessionMiddleware(store = flaky_store)])

# ✗ before: the client got 503, the log said "Fixed Rate limiter error"
@test r.status == 503
# ✓ after: the client gets Nitro's 500, the log names the session store's exception
@test r.status == 500
```
