## Workers — runs are capped, a full queue refuses instead of blocking, and queue names must be declared (#324)

- **Version**: Unreleased
- **Nitro ref**: [#324](https://github.com/PingoLee/Nitro.jl/issues/324) ;
  `src/Workers/runtime.jl`, `src/Workers/api.jl`, `src/Workers/queue.jl`, `src/errors.jl`
- **Recorded**: 2026-09-25
- **Severity**: **breaking.** A sequential submit to a queue name that was never declared is an
  `AuthorizationError` (a `403`). Beyond 64 concurrent async runs, and on a full queue, a submit
  throws `WorkerCapacityError` (a `503`) instead of running or blocking.

### What changed

Worker runs share the `:default` thread pool with HTTP, and nothing bounded them:

- **Each fresh key started a run immediately, with no runtime-wide cap.** One owner submitting 500
  unique keys ran 500 callbacks at once on the server's threads.
- **A full sequential queue blocked the submitter in `put!` with no timeout.** One owner filled the
  100 slots, and every other user's request then hung until teardown.
- **Every distinct queue name minted a queue plus a permanent processor task.** A handler that took
  the name from request data minted one per name.

Now a `WorkerRuntime` enforces limits, and a submit that would exceed one is refused before
anything is written (no record, no queued item, no displaced predecessor):

| Limit | Default | Refused as |
|---|---|---|
| async runs in flight, runtime-wide | `max_concurrent_runs = 64` | `WorkerCapacityError(:runtime, …)`, a `503` |
| a sequential queue's buffer | 100 per queue | `WorkerCapacityError(:queue, …)`, a `503`, immediately |
| one owner's live runs, both paths | `max_runs_per_owner = nothing` (off) | `WorkerCapacityError(:owner, …)`, a `429` |
| queue names | only names declared through `queues` | `AuthorizationError`, a `403` |

A queue name is declared by `worker_startup(app; queues = [...])`, `start!(app; queues = [...])`, or
`WorkerRuntime(store; queues = [...])`. `allow_undeclared_queues = true` restores the old
behavior. The first refusal of each undeclared name is logged at `@warn`. The in-memory store's
listing also no longer holds the task lock while it scans.

A callback abandoned by `TaskOptions(timeout = …)` keeps counting against `max_concurrent_runs`
until it actually returns, on either path. While the runtime is at that cap, sequential queues
**hold** their next item instead of starting it; their submitters are not held.

### How to find the calls to migrate

Sequential submits, then check that each queue name appears in your `queues = [...]`:

```bash
rg -n --type julia 'submit_sequential_task\(' .
rg -n --type julia 'queues\s*=' .
```

A queue name computed from request data: it must now be one of a declared set, or you must opt in:

```bash
rg -U -n --type julia 'submit_sequential_task\([^)]*(getparams|getquery|getjson|payload)'
```

Code that relied on a submit blocking until the queue had room, or on more than 64 async runs at
once. Search for handlers that call `submit_task` in a loop:

```bash
rg -U -n --type julia 'for .*\n(.*\n){0,5}.*submit_(sequential_)?task\('
```

### Migrate your app

```julia
# ✗ before — "exports" was never declared; it worked because every name minted a queue
serve(app; middleware = [worker_startup(app; queues = ["reports"])])
submit_sequential_task(app, "exports", key, cb, Owner(uid))       # now: AuthorizationError (403)

# ✓ after — declare every queue you submit to
serve(app; middleware = [worker_startup(app; queues = ["reports", "exports"])])
submit_sequential_task(app, "exports", key, cb, Owner(uid))
```

```julia
# ✓ a different cap, a per-owner quota, or the old open queue namespace: build the runtime
runtime = WorkerRuntime(persistent_store; max_concurrent_runs = 200, max_runs_per_owner = 10,
                        allow_undeclared_queues = true)
serve(app; middleware = [worker_startup(app; runtime = runtime)])
```

```julia
# ✓ a client-facing route: a refusal is back-pressure, so let the client retry
function start_export(req)
    id = submit_task(app, "export-$(uuid4())", run_export, owner_for(req))  # 503/429 on a limit
    return Res.json(Dict("task_id" => id); status = 202)
end
```
