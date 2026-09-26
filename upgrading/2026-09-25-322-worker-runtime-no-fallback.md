## Workers — no silent fallback to the process-wide runtime; `worker_startup` installs when it is built (#322)

- **Version**: Unreleased
- **Nitro ref**: [#322](https://github.com/PingoLee/Nitro.jl/issues/322) ;
  `src/Workers/api.jl`, `src/methods.jl`, `src/errors.jl`
- **Recorded**: 2026-09-25
- **Severity**: **breaking.** An App-first worker call on an App with no runtime installed now
  throws `WorkerUnavailableError` (a `503` over HTTP). A bare `worker_startup(store = …)` or
  `worker_startup(runtime = …)` is an `ArgumentError`.

### What changed

The App-first task API (`submit_task(app, …)`, `get_task_status(app, …)` and the rest) used to fall
back to `default_runtime()` whenever `app` had no runtime installed. That runtime has **none of the
app's policy**: no queue authorizer, no error redactor, no retention. Three ways to reach it:

1. **The startup window.** `serve()` opens the listener before it runs the startup hooks, and the
   runtime used to be installed by the hook. A request in that window skipped the app's queue
   authorizer: an admin-only queue accepted a non-admin's job, and the record was never pruned.
2. **The tutorial's shape.** A bare `worker_startup(...)` installed on the global `CONTEXT[]` app,
   while a bare `submit_task(...)` used `default_runtime()`. Those are two runtimes, so policy set
   on `worker_store(app)` never applied.
3. **A failed `start!`**, for example with both `store =` and `runtime =`, left the fallback in
   place for the life of the process.

Now:

- `worker_startup(app; …)` / `Workers.startup(app; …)` **install the runtime when the middleware is
  built**, so it exists before the listener opens. Its hook then only starts it. `worker_store(app)`
  is therefore set right after the middleware is built, before `serve`. Passing both `store =` and
  `runtime =` fails there too, instead of inside a hook where it was only logged.
- An App-first call on an App with **no** runtime installed throws `WorkerUnavailableError`. Over
  HTTP it is a `503`, logged once per request at `@warn`, with no backtrace. That includes the gap
  between `terminate` and a later `serve` in the same process.
- The bare `worker_startup(; …)` uses `default_runtime()`, the same runtime the bare task API uses.
  It refuses `store =`, a `runtime =` other than `default_runtime()`, and a different runtime
  already installed on `CONTEXT[]`, because the bare task API could never see that runtime.

### How to find the calls to migrate

A bare `worker_startup` given a backend, which now throws:

```bash
rg -n --type julia 'worker_startup\((\s*;)?\s*(queues|store|runtime|cleanup|recover|zombie|key|drain)' .
rg -U -n --type julia 'worker_startup\([^)]*(store|runtime)\s*='
```

Code paired with a bare `worker_startup(...)` that calls the bare task API
(`submit_task(key, …)`, `get_task_status(id, …)` with no `app` first). It keeps working, but it
now shares the default runtime with that startup, so move both to one `App`:

```bash
rg -n --type julia '\b(submit_task|submit_sequential_task|get_task_status|cancel_task|get_all_tasks)\(' .
```

An App-first call on an App that never had `worker_startup(app)`, `install!` or `start!`. It used
to run on the default runtime and now throws `WorkerUnavailableError`.

### Migrate your app

```julia
# ✗ before — two runtimes: the startup installs one on CONTEXT[], the submit uses another
serve(middleware = [worker_startup(queues = ["reports"], store = persistent_store)])
task_id = submit_sequential_task("reports", key, cb, Owner(uid))

# ✓ after — one App, one runtime, one policy
app = App(mod = @__MODULE__)
serve(app; middleware = [worker_startup(app; queues = ["reports"], store = persistent_store)])
task_id = submit_sequential_task(app, "reports", key, cb, Owner(uid))

# policy can be installed as soon as the middleware is built
set_queue_authorizer!(worker_store(app), my_authorizer)
```

```julia
# ✗ before — an App-first call on an App with nothing installed quietly used default_runtime()
app = App(mod = @__MODULE__)
submit_task(app, key, cb, Owner(uid))                   # now WorkerUnavailableError

# ✓ after — install (and start) a runtime on it first
install!(app; store = InMemoryWorkerStore())           # or worker_startup(app) in serve's middleware
submit_task(app, key, cb, Owner(uid))
```
