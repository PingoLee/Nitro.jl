## Middleware exceptions — a logged JSON `500`, and `internalrequest` no longer re-raises them

- **Version**: Unreleased
- **Nitro ref**: [#256](https://github.com/PingoLee/Nitro.jl/issues/256) ; `src/core/framework_middleware.jl`, `src/core/pipeline.jl`
- **Recorded**: 2026-09-22
- **Severity**: **behavior change**. An exception thrown by middleware now produces the same
  response and log line as one thrown by a handler. Under `internalrequest`, that means it is
  **returned as a `500` instead of raised** to the caller.

### What changed

Nitro's error handling (`catch_errors`) used to wrap only the router. Global, router-level and
route-level middleware all sit *outside* it, so an exception from any of them skipped it:

| exception raised in | before | after |
|---|---|---|
| a route **handler** | `500` JSON body, `@error` + backtrace, access-log line | **unchanged** |
| **middleware**, under `serve` | `500` with an **empty body**, **no** `@error`, **no** access-log line | `500` JSON body, `@error` + backtrace, access-log line |
| **middleware**, a `ValidationError` | the same bodyless `500` | `400` with `{"message": "400: Bad Request"}`, as from a handler |
| **middleware**, under `internalrequest(...)` with the default `catch_errors=true` | **raised to the caller** | **returned** as the `500` (or `400`) response |
| **middleware**, an `InterruptException` | propagates | **unchanged**: still propagates, so Ctrl-C is never absorbed as a response |

It applies to every middleware: `BearerAuth`, `CookieAuthMiddleware`, `SessionMiddleware`,
`CSRFMiddleware`, the rate limiters, `Cors`, `SecurityHeaders`, and your own.

This matters most alongside [#254](https://github.com/PingoLee/Nitro.jl/issues/254), which ships
in the same release. #254 lets `StackOverflowError` and `OutOfMemoryError` propagate out of the
auth middleware. Without this change those were 500s that nothing on the server recorded.

Nothing else moves. `catch_errors=false` still raises from both handlers and middleware.
`serialize=false` still installs no error handling at all. `show_errors=false` still silences only
the log, not the response. A handler's exception is still caught *inside* the middleware chain,
so its `500` still picks up `Cors` and session headers on the way out. A middleware's `500` does
not, because it is produced above the layers the exception skipped.

### How to find the calls to migrate

Only one thing can break: code that drives `internalrequest` and **expects an exception** from
middleware. It is almost always a test.

```bash
# internalrequest calls that expect a throw -- check each one without `catch_errors = false`
rg -n -B2 -A2 '@test_throws' <app>/test | rg 'internalrequest'

# try/catch around internalrequest, relying on the throw to detect a middleware failure
rg -n -A3 'try' <app>/test <app>/src | rg 'internalrequest'
```

If you parsed server logs or alerting rules for **bodyless** 500s from middleware, those requests
now produce Nitro's standard `@error` line and access-log entry instead.

### Migrate your app

```julia
# ✗ before -- relied on middleware exceptions escaping internalrequest
@test_throws ErrorException internalrequest(app, HTTP.Request("GET", "/private"))

# ✓ after -- ask for the exception explicitly...
@test_throws ErrorException internalrequest(app, HTTP.Request("GET", "/private");
                                            catch_errors = false)

# ...or assert on the response the client actually receives
r = internalrequest(app, HTTP.Request("GET", "/private"))
@test r.status == 500
```
