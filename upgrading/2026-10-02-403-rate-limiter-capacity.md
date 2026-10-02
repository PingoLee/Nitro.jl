## `RateLimiter` — both strategies cap their store at `max_clients` and refuse new clients when full, instead of growing or evicting (#403)

- **Version**: Unreleased
- **Nitro ref**: [#403](https://github.com/PingoLee/Nitro.jl/issues/403) ;
  `src/middleware/rate_limiter.jl`
- **Recorded**: 2026-10-02
- **Severity**: **behavior change.** No call stops compiling. An app that sees more than
  `max_clients` (default 10 000) distinct clients within one `window` now answers the overflow with
  `503` where it used to admit it.

### What changed

The limiter keys on a /64 for IPv6 (#22), but a client holding many /64s gets a bucket for each
one, and a /48 holds 65 536 of them. The two strategies broke under that in different ways:

| | Before | After |
|---|---|---|
| `:fixed_window` store | unbounded between sweeps: one entry per prefix seen per `cleanup_period` | capped at `max_clients` (**new keyword**, default 10 000) |
| `:sliding_window` store | LRU capped at `max_clients`; a new client **evicted** the least-recently-used one, resetting its quota | capped at `max_clients`; nothing live is evicted |
| New client, store full | fixed: admitted · sliding: admitted, someone else evicted | buckets whose window has ended are reaped; if it is still full, **`503` + `Retry-After`** |
| …with `fail_open = true` | same as above | admitted **unrecorded**: no bucket, no `X-RateLimit-*` headers |
| Clients already counted | sliding: could be evicted onto a fresh quota | unaffected |

The first time a store fills, a one-time warning is logged, so an operator hears about address
rotation, or about a `max_clients` that is too small for real traffic, before a user does.

`max_clients` is split across the store's lock stripes, as the sliding limiter's always was. A
stripe can therefore fill and refuse slightly before the whole store does, and the total can
overshoot by less than one entry per stripe. Stores under 128 entries use one stripe, and there
the bound is exact.

### How to find the calls to migrate

```bash
# every limiter -- decide whether `max_clients` covers your distinct clients per window
grep -rn 'RateLimiter(\|FixedRateLimiter(\|SlidingRateLimiter(' --include=*.jl .
```

In production, the sign that a limit is too low is the one-time warning
`RateLimiter: the client store is full`, and `503` responses with `Retry-After` going to clients
that had sent nothing before. Behind a reverse proxy without `trusted_proxies`, every client shares
one bucket, so this cannot fire. Directly exposed, or with `trusted_proxies` set, count distinct
client addresses (IPv6 /64s) per `window`.

### Migrate your app

```julia
# ✗ before: 30 000 distinct clients a minute were all admitted (fixed window, unbounded store)
RateLimiter(rate_limit = 100, window = Minute(1))
# ✓ after: give the store room for them, or the overflow gets 503
RateLimiter(rate_limit = 100, window = Minute(1), max_clients = 50_000)

# ✓ or prefer availability over enforcement when the store is full
RateLimiter(rate_limit = 100, window = Minute(1), fail_open = true)
```
