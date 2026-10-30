## `RateLimiter` no longer sends `Retry-After` on an admitted response (#560)

- **Version**: 0.7.0
- **Nitro ref**: [#560](https://github.com/PingoLee/Nitro.jl/issues/560) ; `src/middleware/rate_limiter.jl`
- **Recorded**: 2026-10-21
- **Severity**: behavior change (response headers)

### What changed

`RateLimiter` added `Retry-After` to every response it let through, set to the seconds until a
slot frees. On a `200` that header means nothing: `Retry-After` tells a client how long to wait
before retrying a refused request (RFC 9110 §10.2.3, RFC 6585 §4). It was written by the same
helper as the `X-RateLimit-*` headers, so admitted responses got it too.

Now only a refusal carries it: the `429` for a client over its limit, and the `503` for a new
client at a full store. Admitted responses keep `X-RateLimit-Limit`, `X-RateLimit-Remaining` and
`X-RateLimit-Reset`, which are unchanged. `X-RateLimit-Reset` carries the same number the admitted
`Retry-After` did.

Both strategies are affected. A `Retry-After` an inner layer or the handler set is still kept as
it was.

**Your own error responses lose the limiter's value too.** The old helper ran on everything the
handler returned, not just on `200`s. So a `503` or `429` the handler built itself without a
`Retry-After` got the limiter's reset time added. It now goes out without one. If a client relied
on it, set `Retry-After` in the handler.

### How to find the calls to migrate

On the server, find handlers that return a `429` or `503` of their own behind a `RateLimiter`,
and give each one an explicit `Retry-After` if its clients need one:

```bash
grep -rn -E 'Res\.status\((429|503)|Response\((429|503)|status *= *(429|503)' --include=*.jl .
```

On the client, find code that reads `Retry-After` from a successful response, for example to
pace its next request:

```bash
grep -rniE 'retry-after|retry_after|retryafter' --include=*.js --include=*.ts --include=*.jsx --include=*.tsx --include=*.vue --include=*.jl --include=*.py .
```

For each hit, check whether it reads the header only on the limiter's own `429`/`503`, which is
unchanged, or also on a `2xx` or on one of your handlers' error responses, which now find nothing
unless the handler sets it.

### Migrate your app

```js
// ✗ before: read on every response, so a 200 also paced the client
const wait = Number(res.headers.get("Retry-After") ?? 0);

// ✓ after: on a success, read X-RateLimit-Reset; on a refusal, Retry-After
const wait = res.ok
  ? Number(res.headers.get("X-RateLimit-Reset") ?? 0)
  : Number(res.headers.get("Retry-After") ?? 0);
```
