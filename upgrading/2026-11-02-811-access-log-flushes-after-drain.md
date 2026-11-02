## `AccessLog` stops its writer in `on_stopped`, after the drain

- **Version**: Unreleased
- **Nitro ref**: #811 ; `src/middleware/access_log.jl`
- **Recorded**: 2026-11-02
- **Severity**: behavior change. An app that serves `AccessLog` through `serve(middleware = …)` and
  stops it with `terminate` needs no edit: it now records the requests the drain finishes. Code
  that runs `AccessLog`'s hooks by hand, to flush it, has to run the new one too.

### What changed

`AccessLog`'s background writer used to stop in `on_shutdown`, which `terminate` runs before the
HTTP drain, while the listener is still accepting. Two kinds of request lost their record, and
no drop warning counted them: one still in flight when the hook ran, and one admitted while the
shutdown hooks were running.

The writer now stops in `on_stopped`, which `terminate` runs once the listener is closed and the
drain is over. `on_shutdown` stops only the retention pruner. The writer's bounded wait for its
last records, up to 5 seconds, now adds to the exit time after the drain instead of before it.

### How to find the calls to migrate

```
grep -rn 'AccessLog' src/ test/
```

Look at what each hit's value is handed to. A value passed to `serve(middleware = …)` needs no
change. One whose hooks are called by hand, with `shutdown(lf)` or `lf.on_shutdown()`, usually in
a test that flushes the log and then reads what the sink received, needs the change below.

### Migrate your app

```julia
# ✗ before: `shutdown` flushed the buffer and waited for the writer
startup(lf)
handler(HTTP.Request("GET", "/"))
shutdown(lf)
@test length(records) == 1          # now 0: the writer is still running

# ✓ after: run both teardown phases, in `terminate`'s order
startup(lf)
handler(HTTP.Request("GET", "/"))
Nitro.Core.Types.shutdown(lf)
Nitro.Core.Types.stopped(lf)        # flushes the buffer and waits for the writer
@test length(records) == 1
```
