## `serve` runs the startup hooks before it opens the listener

- **Version**: Unreleased
- **Nitro ref**: #799 ; `src/core/lifecycle.jl` (`startserver`, `_teardown!`);
  `docs/src/tutorial/workers.md`, `docs/src/tutorial/deployment.md`
- **Recorded**: 2026-11-02
- **Severity**: behavior change. A request can no longer reach the app before every `on_startup`
  hook has returned. An app whose hooks do not need the server to be listening is unaffected.

### What changed

`serve` used to open the listening socket and then run the `on_startup` hooks. From the moment
the port opened, a TCP probe, a proxy's upstream check or a client could reach an app that was
still initialising: its worker runtime not running yet, its janitors not started, whatever a
hook's first query compiles still compiling.

`serve` now runs every `on_startup` hook first and opens the listener once they have all
returned. `serve(async = true)` therefore returns only after the hooks too, and the banner is
printed once the port is open. If the listener then fails to start (an address already in use),
every hook that ran gets its `on_shutdown` and `on_stopped` before `serve` throws, and the app can
be served again. An interrupt in a hook unwinds the same way, with no listener ever opened.

A `terminate` called while the hooks are running finds nothing to stop and returns; it does not
cancel the start.

### How to find the calls to migrate

```
grep -rn 'on_startup' src/ test/
```

For each hook, check whether it connects to its own server (an HTTP request to its own port, a
WebSocket to itself) or waits for that port to accept. Such a hook now waits for a listener that
opens only after it returns. Separately, check any start-up script or probe that waited for the
port and assumed the hooks were still running then: an open port now means they are done.

### Migrate your app

```julia
# ✗ before: the hook warmed the app through its own port
warm = LifecycleMiddleware(middleware = identity,
    on_startup = () -> HTTP.get("http://127.0.0.1:8080/health"))   # now: connection refused
serve(app; port = 8080, middleware = [warm])

# ✓ after: warm in-process, which needs no listener, or after `serve` returns
warm = LifecycleMiddleware(middleware = identity,
    on_startup = () -> internalrequest(app, HTTP.Request("GET", "/health")))
serve(app; port = 8080, middleware = [warm])
```
