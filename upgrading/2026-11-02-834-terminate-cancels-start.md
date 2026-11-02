## `terminate(app)` cancels a start in progress and waits for a stop in progress

- **Version**: Unreleased
- **Nitro ref**: #834 ; `src/core/lifecycle.jl` (`terminate`, `startserver`), `src/context.jl`
  (`Service.phase`), `src/methods.jl` (`serve`, `terminate`)
- **Recorded**: 2026-11-02
- **Severity**: behavior change. A `terminate` that used to return at once now cancels or waits,
  and a `serve` whose start it cancels returns `nothing`. Code that calls `terminate` only on an
  app that is serving, from one task, is unaffected.

### What changed

`terminate` used to act only on an app that was serving. Called in either of two other phases, it
returned normally without doing anything:

- **While `serve` was still running its `on_startup` hooks.** The start then finished, opened the
  port and served until something else stopped it. `terminate` now cancels the start. The startup
  hooks run to their end, every hook that ran gets its `on_shutdown` and `on_stopped`, the server
  is never handed over (a listener the bind had just opened is force-closed), and `terminate`
  returns once the app is idle. The cancelled `serve` returns `nothing`, in blocking and
  `async = true` mode alike.
- **While another `terminate` of the same app was still stopping it.** A caller that then served
  the app again, as `serve`'s refusal tells it to, was refused with *still stopping*. The second
  `terminate` now waits until the first has returned.

`terminate` called from inside a `LifecycleMiddleware` hook never waits, because the run it would
wait for is the one running the hook. From `on_startup` it aborts the start. A task the hook
spawns inherits that, and never waits either.

A blocking `serve` also no longer stops a run that is not its own. It used to decide whether its
cleanup was its own by reading the app's phase before starting, and two blocking `serve` calls of
the same app could both read it as idle. The one that was refused then stopped the other's
running server.

### How to find the calls to migrate

```
grep -rnE 'serve\(.*async *= *true' src/ test/
grep -rn 'terminate(' src/ test/
```

For each hit of the first, check whether the returned value is used as an `HTTP.Server` (`close`,
`wait`, `HTTP.forceclose`, `port`) on a path where another task can call `terminate` during the
start. For the second, check whether the `terminate` runs where waiting for the app to finish
starting or stopping would block something that start or stop needs: a task the app's own
`on_startup` or `on_shutdown` hook waits on, which was started outside the hook (a task the hook
spawns itself never waits), or a request handler, which now holds the drain open for the whole
`shutdown_timeout` when it calls `terminate` during another stop.

### Migrate your app

```julia
# ✗ before: assumed `serve(async = true)` always returns the server
srv = serve(app; async = true, port = 8080)
wait(srv)                                    # MethodError when a `terminate` cancelled the start

# ✓ after: a cancelled start returns `nothing`; wait through the app
srv = serve(app; async = true, port = 8080)
isnothing(srv) || wait(srv)
```
