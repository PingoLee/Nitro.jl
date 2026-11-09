## A failed hook runner no longer skips the rest of the lifecycle — `serve`/`terminate` raise it afterwards

- **Version**: Unreleased
- **Nitro ref**: #892 (follow-up to #883 and #846); `src/routeendpoint.jl` (`_run_lifecycle`),
  `src/core/lifecycle.jl` (`_broadcast_lifecycle`, `_raise_runner_failure`, `_startup_hooks`,
  `_teardown!`)
- **Recorded**: 2026-11-09
- **Severity**: **behavior change** — no Nitro API changes. It matters only when Nitro's own hook
  runner fails, which is a bug in Nitro, never in your hook.

### What changed

A hook that throws was already logged and swallowed, and the rest of the lifecycle ran. That
stays the same. This entry is about a failure **one level down**: Nitro's own runner (`startup`,
`shutdown` or `stopped` on a `LifecycleMiddleware`) failing past the catch around your hook. In a
trimmed executable that happens when the runner's own catch misses (#846). Under the JIT it would
take a bug in the runner.

- **Before:** the failure was raised on the spot. Every later hook of the lifecycle was skipped.
  A runner failure during `on_shutdown` also skipped the listener close and every `on_stopped`.
  `terminate` or `serve` raised the failure.
- **Now:** the failure is treated like a hook's own failure, and the lifecycle goes on:
  - on startup, every remaining `on_startup` hook (route-owned and serve-owned) runs, then `serve`
    unwinds them and raises the failure;
  - on `terminate`, every remaining `on_shutdown` hook runs, then the listener close, then every
    `on_stopped`, and `terminate` raises the failure at its end.

  `serve`/`terminate` still raise **the same exception**, the first runner failure, but only after
  the lifecycle has finished. Each runner failure is also reported when it happens, before the
  lifecycle goes on: under the JIT as an `@error` record carrying the runner's backtrace, in a
  trimmed build as the stderr line `Nitro: the <phase> hook runner failed: <Type>`.
- **With Ctrl-C in the same lifecycle:** the interrupt is re-raised as before, and the runner
  failure is logged instead of raised.

### How to find the calls to migrate

You are affected only if your code relied on the hooks after a failed runner **not** running.
Look for code that catches what `serve` or `terminate` raise and assumes the remaining hooks were
skipped:

```bash
grep -rnE "on_(startup|shutdown|stopped)" src/ bin/ *.jl
grep -rnB3 -A6 "terminate(" src/ bin/ *.jl | grep -n "catch"
```

Nothing to migrate otherwise.

### Migrate your app

```julia
# ✗ before: a later hook skipped after a runner failure, so it was redone by hand
try
    terminate(app)
catch
    close_my_pool()          # the on_stopped that closes it never ran
end

# ✓ after: every hook has run by the time terminate raises; do not close twice
try
    terminate(app)
catch err
    @error "terminate failed" exception = err
end
```
