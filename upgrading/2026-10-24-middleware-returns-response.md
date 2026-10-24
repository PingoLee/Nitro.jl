## A middleware that returns anything but an `HTTP.Response` gets a `500`

- **Version**: Unreleased
- **Nitro ref**: `src/routerhof.jl` (`ResponseBoundary`), `src/core/transport.jl`, `src/middleware/security_headers.jl`, `src/middleware/cors_middleware.jl`, `src/middleware/rate_limiter.jl`, `src/middleware/session_middleware.jl`, `src/middleware/csrf_middleware.jl`
- **Recorded**: 2026-10-24
- **Severity**: behavior (a middleware, or a handler under `serialize = false`, whose value reaches the outside of the global middleware chain without being an `HTTP.Response`)

### What changed

A middleware is `handle -> req -> resp`: it returns an `HTTP.Response`. Nitro now checks that
once, where the global middleware chain hands its result to the framework's outer layers (the
error boundary, `SecurityHeaders`, the access log, the transport). Those layers can then read the
response at a known type, which a `juliac --trim` build needs and which takes a dynamic call off
every request under the JIT (docs/design/juliac-trim.md §3.7).

A value that is not a response is answered with a `500` and the usual
`{"message": "500: Internal Server Error"}` body. One `@error` record names the value's type and
the matched route's pattern. It never includes the value itself or the request's target. Before,
the same value:

- made the access log or `SecurityHeaders` throw: the client got a `500` with an empty body, and
  the log said "Request failed outside the error handler";
- with neither layer installed, went out as an empty `200`, with the handler's data lost;
- made `internalrequest` throw a `MethodError` instead of returning.

No configuration delivered the value itself to the client. One answered with something an app
could rely on, though: with `serialize = false` and the access log off, a handler returning a
`String` (or any non-response) got an empty `200`. A health check that reads only the status, or
a `HEAD` route, worked that way, and now gets a `500`. Every other case was already a failure,
now a logged `500` instead.

Three things are unchanged:

- **Route, router and global middleware still see the handler's raw value under
  `serialize = false`.** The check is at the outside of the global chain, not on each layer. A
  global middleware that formats raw values into responses (the Oxygen-era pattern) keeps
  working. What Nitro's own layers do with such a value, inside that formatter, is below.
- **What a `STREAM` or `WEBSOCKET` handler returns under `serialize = false`, once it has written
  its response on the stream, is not an error**: `nothing`, or what its last `write` returned.
  Nothing more is sent. This also fixes that shape under the access log (on by default): the
  client used to lose the connection mid-response, and the server logged an error.
- **The internal `setupmiddleware(app; serialize = false)(req)`** now returns that `500` rather
  than the handler's raw value. It is not public API. Only tests that called it directly see this.

**Nitro's own layers and a raw value.** Under `serialize = false`, a `SecurityHeaders`, `Cors`,
`RateLimiter`, `SessionMiddleware` or `CSRFMiddleware` placed inside a formatting middleware (route
middleware, say) can receive the handler's raw value. Each used to raise a `MethodError` on it,
which was a `500`. Now:

- `SecurityHeaders`, `Cors` and `RateLimiter` pass it through untouched. The formatter outside
  them turns it into a response, without their headers: no security headers, no
  `Access-Control-Allow-Origin`, no rate-limit headers on that response.
- `SessionMiddleware` and `CSRFMiddleware` pass it through only while none of their cookies is
  due. When one is (a session was written, a CSRF token was handed out or refreshed), they raise
  an `ArgumentError` that names the layer and the value's type, still a `500`. Passing the value
  on without the cookie would answer as if all were well while the client holds no cookie for the
  session just stored, or for the token in the body, whose next `POST` is then refused. The
  session is stored before the cookie step, as it was before this change, so a raw value can still
  leave a session row behind; return a response from such a route.

### How to find the calls to migrate

```bash
# Apps that turn the serializer off: each route's handler (or a global middleware) must
# then return a response. Look first at status-only routes (health checks) and HEAD routes,
# which may have relied on the empty 200 a plain value used to get.
grep -rn -E 'serialize *= *false' --include=*.jl .
# Middleware factories, to read what their inner function returns. A value built from the
# handler's result (a String, a Dict, `nothing`) rather than `Res.*` or the handler's own
# response is what now gets a 500:
grep -rn -E 'handler *-> *\(?req' --include=*.jl .
grep -rn -E 'middleware *= *\[' --include=*.jl .
# Nitro's own header and cookie layers, which inside a formatter now pass a raw value through
# (or, for the session and CSRF layers, raise when their cookie is due):
grep -rn -E '(SecurityHeaders|Cors|RateLimiter|SessionMiddleware|CSRFMiddleware)\(' --include=*.jl .
```

### Before → after

A middleware that returns something other than a response now returns one:

```julia
# before: a String reached the outer layers (a bodyless 500, or an empty 200)
maintenance = handler -> (req -> "down for maintenance")

# after
maintenance = handler -> (req -> Res.send("down for maintenance"; status = 503))
```

Under `serialize = false`, a handler that returns a plain value needs a global middleware that
turns it into a response, or must return one itself:

```julia
# before: serve(app; serialize = false) with
path("/items", req -> Dict("a" => 1))

# after: return the response
path("/items", req -> Res.json(Dict("a" => 1)))
# or keep the raw value and format it in global middleware
formatting = handler -> (req -> (v = handler(req); v isa HTTP.Response ? v : Res.json(v)))
serve(app; serialize = false, middleware = [formatting])
```

A route behind one of Nitro's header or cookie layers, under `serialize = false`, returns a
response itself, so the layer can add its headers or its cookie:

```julia
# before: a raw value; Cors raised a MethodError (500), and now adds no CORS headers
path("/items", req -> Dict("a" => 1); middleware = [Cors(allowed_origins = ["https://app.example"])])

# after
path("/items", req -> Res.json(Dict("a" => 1)); middleware = [Cors(allowed_origins = ["https://app.example"])])
```
