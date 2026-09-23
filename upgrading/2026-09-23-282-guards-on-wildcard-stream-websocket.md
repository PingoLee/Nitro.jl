## `path(...; method="*" | "STREAM" | "WEBSOCKET", middleware=[...])` — route and router middleware now runs

- **Version**: Unreleased
- **Nitro ref**: [#282](https://github.com/PingoLee/Nitro.jl/issues/282) ; `src/routerhof.jl`, `src/core/registration.jl`, `src/types.jl`
- **Recorded**: 2026-09-23
- **Severity**: behavior change. Guards and other route middleware declared on a `method="*"`,
  `STREAM` or `WEBSOCKET` route were silently skipped. They now run, so a request that used to
  reach the handler can now be refused. This was an authorization bypass.

### What changed

Route middleware is stored under the method a route was declared with, and it was looked up
under the request's method. No request carries `*`, and a `STREAM` or `WEBSOCKET` route is served
to `GET`/`POST` and `GET`. So on those three kinds of route the lookup never found anything, and
every route middleware (a `GuardMiddleware` included) was skipped with no error.
`router(...; middleware=[...])` had the same defect for routes registered under those methods.
Global middleware was not affected.

The router leaf now records its declared method, and the lookup uses it.

| Route | Before | After |
|---|---|---|
| `method="*"` with `middleware=[...]` | middleware skipped for every method | runs for every method that reaches the route |
| `method="STREAM"` with `middleware=[...]` | skipped | runs for `GET` and `POST` |
| `method="WEBSOCKET"` with `middleware=[...]` | skipped | runs for the `GET` upgrade |
| the same three under `router(...; middleware=[...])` | skipped | runs |
| one of those three with middleware, on a router built with HTTP.jl-level `middleware` (`Service(router = HTTP.Router(_, _, mw))`) | registered, middleware skipped | `ArgumentError` at registration |
| any other route | unchanged | unchanged |

**What can need an edit:**

- A client of such a route that never sent the credentials the guard asks for now gets its `401` or
  `403`. The guard was always declared; it just did not run.
- A route middleware that reads the handler's response (logging the status, auditing the body,
  computing an ETag). On a `STREAM` or `WEBSOCKET` route it now runs, and what it reads is a
  placeholder: the handler usually returns `nothing`, which the default serializer turns into a
  `200` with a `null` JSON body. Under `serve(serialize = false)` it gets the `nothing` itself.
  Neither is what the handler wrote to the socket.
- A `STREAM` or `WEBSOCKET` route registered at the same path as a guarded `GET` route, which it
  replaces, used to run that `GET` route's middleware by coincidence of keys. It now runs only its
  own. Declare the guard on the `STREAM`/`WEBSOCKET` route itself.
- The HTTP.jl-level router case above now fails at startup instead of serving unguarded.

### How to find the calls to migrate

```bash
# Routes declared with one of the three methods. Review the ones that also pass `middleware =`.
grep -rnE 'method(s)? *= *.*"(\*|STREAM|WEBSOCKET)"' --include=*.jl .
# The same methods through `route([...], ...)` and `register(app, "...", ...)`.
grep -rnE '(route\(\[|register\().*"(\*|STREAM|WEBSOCKET)"' --include=*.jl .
# Router-level middleware that such routes can sit under.
grep -rnE 'router\(.*middleware *=' --include=*.jl .
# Routers carrying HTTP.jl-level middleware (the third positional argument).
grep -rnE 'HTTP\.Router\(' --include=*.jl .
```

A route with no `middleware=` and no router-level middleware needs nothing.

### Migrate your app

If a client was relying on the missing guard, give it the credentials. Do not remove the guard.

```julia
# ✗ before — the dashboard's EventSource connected anonymously, because this guard never ran
path("/events", events; method = "STREAM",
     middleware = [GuardMiddleware(login_required())])
# ✓ after — same route; the client now sends its session cookie or bearer token
```

If a route or router middleware records or decorates the response, take it off the `STREAM` and
`WEBSOCKET` routes: what it sees there is the placeholder described above, and the headers it adds
never reach the client, because the handler has already written the response head. Let the handler
do its own reporting. For SSE, prefer `Res.sse`, which returns a real response that the chain can
see and decorate.

For the `ArgumentError`, register the route on a router without HTTP.jl-level middleware. For a
`"*"` route, you can instead list the methods it serves with `methods = ["GET", "POST", ...]`.
