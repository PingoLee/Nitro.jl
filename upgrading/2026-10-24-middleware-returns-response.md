## A middleware that returns anything but an `HTTP.Response` gets a `500`

- **Version**: Unreleased
- **Nitro ref**: `src/routerhof.jl` (`ResponseBoundary`), `src/core/transport.jl`, `src/middleware/security_headers.jl`
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
  working.
- **What a `STREAM` or `WEBSOCKET` handler returns under `serialize = false`, once it has written
  its response on the stream, is not an error**: `nothing`, or what its last `write` returned.
  Nothing more is sent. This also fixes that shape under the access log (on by default): the
  client used to lose the connection mid-response, and the server logged an error.
- **The internal `setupmiddleware(app; serialize = false)(req)`** now returns that `500` rather
  than the handler's raw value. It is not public API. Only tests that called it directly see this.

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
