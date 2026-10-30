# Middleware API

A middleware is a function `handle -> req -> resp`, and a middleware list accepts one directly.
Several of the factories below instead return a [`LifecycleMiddleware`](@ref Nitro.Core.Types.LifecycleMiddleware) — a request function bundled with `on_startup`/`on_shutdown`/`on_stopped` hooks
that `serve()` and `terminate()` run, so the middleware can own a background task or a connection
pool for as long as the server is up. `serve()`, `path()` and `urlpatterns()` take either form; only code composing
a chain by hand needs the `.middleware` field. The type is not exported, so construct one as
`Nitro.LifecycleMiddleware(...)`.

**A middleware returns an `HTTP.Response`.** Nitro checks that once, where the global middleware
chain hands its result to the framework's own outer layers (the error handling, `SecurityHeaders`,
the access log, the transport). A value that is anything else is answered with a `500`
(`{"message": "500: Internal Server Error"}`). One `@error` record names the value's type and the
matched route's pattern, never the value. Inside the chain nothing is checked, so under
`serve(serialize = false)` route and global middleware still receive a handler's raw value and
may turn it into a response. Nitro's own layers that add headers to the response (`Cors`,
`SessionMiddleware`, `CSRFMiddleware`, `RateLimiter`, `SecurityHeaders`) pass such a value through
untouched. The one exception is a `STREAM` or `WEBSOCKET` handler under
`serialize = false` that has already written its response on the stream: whatever it returns
(usually `nothing`) is not an error.

**A middleware that throws** is handled the same way as a handler that throws, as long as
`catch_errors=true` (the default for both `serve()` and `internalrequest()`). The exception is
logged with its backtrace and the client receives `{"message": "500: Internal Server Error"}`.
A `ValidationError` is answered with a `400` instead, an `UnsupportedMediaTypeError` with a
`415`, and an `AuthorizationError` with a `403` (`{"message": "403: Forbidden"}`); all three are
recorded at `@debug` only, and the `403`'s log line leaves out the error's message, which can
name a caller-chosen queue or task key. A `WorkerUnavailableError` (an App-first worker call on
an `App` with no worker runtime installed) is a `503`, logged at `@warn` without a backtrace. A
`WorkerCapacityError` (a worker limit reached) is a `503`, or a `429` for a per-owner quota,
logged at `@debug`. The access log records the status either way. An `InterruptException` is not converted; it propagates.

**What the error log record carries.** Its `exception` is `(e, backtrace)`, where `e` is a
`Nitro.Errors.LoggedException` and not the exception that was thrown. It has two fields: `type`,
the original's type name (`:MethodError`), and `text`, what `showerror` printed for it. Its `show`
prints the same `text`, without colour. So a JSON or structured log sink records exactly what the console shows,
and never the arguments of a `MethodError` or the value in a `TypeError`. Those used to reach any
sink that `show`ed the record: a request's query string, a parsed body, a token. Every other log
line Nitro writes with an exception carries the same type. On a request's path, that means the
warnings that `AccessLog` and `access_log_skip` log when a hook or the sink throws, a failed
[`Res.sse`](@ref) producer, a failed streamed response body, and a rate limiter whose decision
threw. Off it, it means a background janitor's failed tick (the session prune of
[`SessionMiddleware`](@ref) or [`SessionPruner`](@ref), the rate limiter's sweep, `AccessLog`'s
retention prune), the serve task's failure, a shutdown that threw, and the eager-Revise hooks. A
prune that runs your own store's code can throw an error whose fields hold a session id; the log
gets its `showerror` text, not those fields. Every worker log line is covered too: see the
[Workers](../tutorial/workers.md) guide.

A [`Claims`](@ref) refusal is not on this list because it is not converted at all: the `401` or
`403` its denial factory built is the route's response, served under `catch_errors=false` and
`serialize=false` too, the way a guard's `403` is.

There is one difference: a handler's `500` still passes back out through every middleware, but a
middleware's `500` is produced *above* the chain. It therefore carries no headers from layers the exception skipped,
such as `Cors` or the session cookie, so a cross-origin browser client sees a CORS failure
rather than the `500` itself.

The authorization guards (`GuardMiddleware` and friends) are on
[Authorization And Secrets](@ref); the session middleware is on [Cookies And Sessions API](@ref).

## Authentication Middleware

```@docs
BearerAuth
CookieAuthMiddleware
```

## Headers, CORS And CSRF

```@docs
Cors
SecurityHeaders
CSRFMiddleware
csrf_token!
Nitro.Core.Middleware.CSRFMiddleware_.issue_csrf_token!
Nitro.Core.Middleware.CSRFMiddleware_.validate_csrf_token
CrossOriginProtection
```

## Rate Limiting And Client IP

```@docs
RateLimiter
Nitro.Core.Middleware.RateLimiterMiddleware.FixedRateLimiter
Nitro.Core.Middleware.RateLimiterMiddleware.SlidingRateLimiter
ExtractIP
extract_ip
getpeerip
```

## WebSocket Origins

```@docs
WebSocketOrigins
```

## Access Log

```@docs
AccessLog
AccessRecord
route_missed
```

## Lifecycle Middleware

```@docs
Nitro.Core.Types.LifecycleMiddleware
Nitro.Core.Types.startup
Nitro.Core.Types.shutdown
Nitro.Core.Types.stopped
```
