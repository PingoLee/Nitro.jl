## `RateLimiter` — `cleanup_threshold` is removed, the sweep never ends a window early, and `exempt_paths` match whole segments (#319)

- **Version**: Unreleased
- **Nitro ref**: [#319](https://github.com/PingoLee/Nitro.jl/issues/319) ;
  `src/middleware/rate_limiter.jl`
- **Recorded**: 2026-09-25
- **Severity**: **breaking.** `RateLimiter(cleanup_threshold = …)` is now an `ArgumentError`. An
  `exempt_paths` entry that relied on matching part of a path segment no longer exempts it.

### What changed

**The fixed-window sweep deletes a client's entry only once its window has ended.** It used to
delete every entry whose window had *started* more than `cleanup_threshold` ago (10 minutes by
default), and nothing compared that with `window`. So any window longer than the threshold was cut
short for a throttled client: their entry was deleted and the next request got a full quota. At the
default `cleanup_period`, a client that kept sending got back in 10–20 minutes after being
throttled, and then got a fresh quota about every 20 minutes.

| `RateLimiter(rate_limit = 5, …)` | Attempts a client got per window before | After |
|---|---|---|
| `window = Minute(1)` (default) | 5 | 5 |
| `window = Hour(1)` | 15–20 | 5 |
| `window = Day(1)` | about 360 | 5 |

The sweep now reaps at `window`, the same age at which a request would reset the entry anyway. An
entry past its window answers exactly like a missing one, so there is nothing left for a threshold
to set, and **`cleanup_threshold` is removed** from `RateLimiter` and `FixedRateLimiter`.
`cleanup_period` still sets how often the sweep runs. An idle client's entry is now held for up to
`window + cleanup_period`. With a long window that means more entries live at once, and that is
the memory a fixed window needs to count at all. If that many clients over a long window could
exhaust memory, key IPv6 clients more coarsely (`ipv6_prefix = 48`), or use
`strategy = :sliding_window`, whose `max_clients` caps the store.

`strategy = :sliding_window` never had `cleanup_threshold` and reaps nothing in the background. It
is affected only by the `exempt_paths` change below.

**`exempt_paths` entries match whole path segments,** the rule `serve(prefix = …)` follows. It used
to be a bare string prefix, so exempting a health check could lift the limit off a neighbouring
route:

| `exempt_paths = ["/health"]`, request to | Before | After |
|---|---|---|
| `/health`, `/health/live`, `/health?full=1` | exempt | exempt |
| `/healthz`, `/healthz-admin`, `/health-internal/x` | exempt | **limited** |

An entry ending in `/` matches what it matched before: `"/static/"` exempts `/static/app.js`, not
`/static`. Both strategies changed.

### How to find the calls to migrate

```bash
# every limiter that passes the removed keyword -- construction now throws
grep -rn 'cleanup_threshold' --include=*.jl .
# every exemption list -- check each entry is a whole path segment
grep -rn 'exempt_paths' --include=*.jl .
```

A `cleanup_threshold` call fails when it is constructed, usually at startup, with
``ArgumentError: RateLimiter: `cleanup_threshold` was removed``, or with Julia's
unsupported-keyword `MethodError` if you call `FixedRateLimiter` directly. An `exempt_paths` entry that
matched part of a segment fails silently: that route is rate-limited again.

### Migrate your app

```julia
# ✗ before: the threshold was meant to bound memory, and it also cut the 1-hour window to 10-20 minutes
RateLimiter(rate_limit = 5, window = Hour(1), cleanup_threshold = Minute(10))
# ✓ after: drop it; entries are reaped as soon as their window ends
RateLimiter(rate_limit = 5, window = Hour(1))

# ✗ before: one entry meant to cover /api/public/... and /api/public-docs
RateLimiter(exempt_paths = ["/api/public"])
# ✓ after: list every path segment you mean to exempt
RateLimiter(exempt_paths = ["/api/public", "/api/public-docs"])
```
