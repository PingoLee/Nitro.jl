# Middleware API

A middleware is a function `handle -> req -> resp`, and a middleware list accepts one directly.
Several of the factories below instead return a [`LifecycleMiddleware`](@ref Nitro.Core.Types.LifecycleMiddleware) — a request function bundled with `on_startup`/`on_shutdown` hooks
that `serve()` and `terminate()` run, so the middleware can own a background task for as long as
the server is up. `serve()`, `path()` and `urlpatterns()` take either form; only code composing
a chain by hand needs the `.middleware` field. The type is not exported, so construct one as
`Nitro.LifecycleMiddleware(...)`.

**A middleware that throws** is handled the same way as a handler that throws, as long as
`catch_errors=true` (the default for both `serve()` and `internalrequest()`). The exception is
logged with its backtrace and the client receives `{"message": "500: Internal Server Error"}`.
A `ValidationError` is answered with a `400` instead, an `UnsupportedMediaTypeError` with a
`415`, and an `AuthorizationError` with a `403` (`{"message": "403: Forbidden"}`); all three are
recorded at `@debug` only, and the `403`'s log line leaves out the error's message, which can
name a caller-chosen queue or task key. A `WorkerUnavailableError` (an App-first worker call on
an `App` with no worker runtime installed) is a `503`, logged at `@warn` without a backtrace. The
access log records the status either way. An `InterruptException` is not converted; it propagates.

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
Nitro.Core.Middleware.CSRFMiddleware_.issue_csrf_token!
Nitro.Core.Middleware.CSRFMiddleware_.validate_csrf_token
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

## Access Log

```@docs
AccessLog
AccessRecord
```

## Lifecycle Middleware

```@docs
Nitro.Core.Types.LifecycleMiddleware
Nitro.Core.Types.startup
Nitro.Core.Types.shutdown
```
