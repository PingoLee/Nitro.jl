## `terminate()` force-closes after a bounded drain; `serve()` refuses to start over a live server (#73)

- **Version**: 0.2.0
- **Nitro ref**: #73; `src/core.jl`, `src/context.jl`, `src/methods.jl`, `src/constants.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior (shutdown semantics, a new error on a previously-silent call, and a
  Windows socket-option default)** — bug fix.

### What changed

Three defects let a Nitro process outlive `terminate()` still holding its port.

- **`terminate()` is now bounded.** It was `HTTP.close(::Server)`, which releases the listener and
  then loops until every tracked connection is gone — force-closing only *idle* ones. HTTP 2.4
  declares a `HIJACKED` connection state and never assigns it, so a WebSocket, SSE, or STREAM
  handler pins its connection for its whole lifetime and that loop **never ends**; `terminate()`
  called from inside a request handler deadlocks against its own connection. `terminate()` now waits
  `timeout` seconds for in-flight work and then calls `HTTP.forceclose`, modeled on Go's
  `http.Server.Shutdown(ctx)`. The default is **10 s** (`Nitro.Core.SHUTDOWN_TIMEOUT_SECONDS`),
  settable per server with `serve(shutdown_timeout = …)` and per call with `terminate(timeout = …)`;
  `timeout = 0` skips the graceful phase. **Long-lived connections are now cut at the timeout** — if
  a streaming handler must finish cleanly, signal it from a `LifecycleMiddleware`'s `on_shutdown`,
  which runs before the drain.
- **`serve()` on a context that is already serving now throws.** It used to overwrite
  `ctx.service.server[]`, leaving the previous `HTTP.Server` unreachable and its port bound until the
  process exited — with nothing left that could close it. Call `terminate()` first, or give the
  second listener its own context (`instance()` / `ServerContext()`). Relatedly, `terminate()` now
  resets `ctx.service.server[]` to `nothing`; code reading that field after shutdown gets `nothing`
  instead of a dead handle.
- **`reuseaddr` now defaults to `false` on Windows** (`true` on Linux/macOS, unchanged). On Windows
  `SO_REUSEADDR` lets a second process bind a port another process is *actively listening on*, with
  indeterminate delivery — so an orphaned server silently answered some requests from its own router
  instead of the bind failing. An explicit `serve(reuseaddr = …)` still wins.

### How to find the calls to migrate

```bash
# Shutdown sites that may now cut a long-lived connection, and any terminate() reachable from a
# handler (that one used to hang, and is now a guaranteed forced shutdown).
rg -n 'terminate\(' <app>/src <app>/test

# A second serve() on the same context — now an error instead of a silent leak.
rg -n 'serve\(' <app>/src

# Streaming handlers that will be force-closed at the timeout.
rg -n 'method\s*=\s*"(STREAM|WEBSOCKET)"|::HTTP\.Stream|::WebSocket' <app>/src

# Reads of the server handle after shutdown — now `nothing`.
rg -n 'service\.server\[\]' <app>/src

# Windows deployments that relied on the old reuseaddr default.
rg -n 'reuseaddr' <app>/src
```

### Migrate your app

```julia
# ✗ before — unbounded: hung forever if any streaming connection was open
serve(port = 8080, async = true)
terminate()

# ✓ after — bounded; give slow requests room, or cut immediately
serve(port = 8080, async = true, shutdown_timeout = 30)
terminate()              # waits up to 30 s, then force-closes
terminate(timeout = 0)   # no graceful phase at all
```

```julia
# ✗ before — silently orphaned the first listener; its port stayed bound for the process's life
serve(port = 8080, async = true)
serve(port = 9090, async = true)

# ✓ after — the second call throws ArgumentError. Terminate first …
serve(port = 8080, async = true)
terminate()
serve(port = 9090, async = true)

# … or run the second listener on its own context
app2 = instance()
app2.serve(port = 9090, async = true)
```

```julia
# ✓ after — a streaming handler that must finish cleanly needs its own shutdown signal, because
# the drain cannot wait out a connection that never closes itself
# `Nitro.LifecycleMiddleware`, qualified: the type is not in Nitro's export list, so a bare
# name fails with UndefVarError under `using Nitro`.
const STOPPING = Base.Event()
serve(middleware = [Nitro.LifecycleMiddleware(middleware = identity,
                                              on_shutdown = () -> notify(STOPPING))],
      shutdown_timeout = 15)
```
