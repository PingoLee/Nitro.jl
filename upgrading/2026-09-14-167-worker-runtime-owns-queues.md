## `WorkerRuntime` owns the queues, scheduler and run handles; worker calls take `runtime=` (#167)

- **Version**: 0.4.0
- **Nitro ref**: #167 (follow-up to #29); `src/Workers.jl`, `src/Workers/runtime.jl` (new),
  `src/Workers/registry.jl`, `src/Workers/api.jl`, `src/Workers/queue.jl`, `src/Workers/types.jl`,
  `src/methods.jl`, `ext/NitroPormGExt.jl`, `docs/src/tutorial/workers.md`
- **Recorded**: 2026-09-14
- **Severity**: **breaking, and it fails LOUDLY** — every changed name is a `MethodError` or an
  `UndefVarError` at the call site, never a silent behaviour change. An app that bootstraps with
  `worker_startup(queues = […], store = …)` and calls the `(app, …)` task methods needs **no edit
  at all**; the work is proportional to how much you passed `store=` by hand.

### What changed

`AbstractWorkerStore` was two interfaces wearing one hat: data access — records, watchers, status
transitions — **and** ownership of live background resources: the cleanup scheduler, the
sequential-queue `Channel`s and their processor `Task`s, and the process-local run-handle caches.

That second role is why #29's leak was possible at all. Making `shutdown!` a required store method
closed the *instance* — a backend that owns nothing must say so out loud — but not the *class*:
every future backend still had to re-implement teardown correctly, and the shared
`_stop_scheduler_and_queues!` helper was a mitigation rather than a fix.

The live resources now belong to a new `WorkerRuntime`, and the store is data access plus policy
hooks. That is the split Sidekiq draws between its `Launcher` and Redis, and Go's River between
`river.Client` and `riverpgxv5`: the storage driver cannot forget to tear down background work,
because it never owned any.

Six things a consuming app can observe:

- **The public keyword is `runtime=`, not `store=`**, on `submit_task`, `submit_sequential_task`,
  `get_task_status`, `cancel_task`, `get_all_tasks`, `cleanup_old_tasks`, `get_queue_status`,
  `recover_zombie_tasks!` and `start_cleanup_scheduler`. `stop_cleanup_scheduler!` takes its
  runtime **positionally** — `stop_cleanup_scheduler!(store)` becomes
  `stop_cleanup_scheduler!(runtime)` — so grep for the call, not for a keyword. `store=`
  survives only where it *selects a backend* — `install!`, `Workers.start!`, `Workers.startup` and
  therefore `worker_startup` — so the documented bootstrap line is unchanged. There is **no
  compatibility alias**: Nitro is pre-registry, and `store=` on a submission call would now be a
  lie, because a store cannot run anything.
- **`reset_store!(store)` is now `reset_runtime!(runtime)`**, and `Workers.start!` returns a
  `WorkerRuntime` rather than a store. The `App` extension slot (`:workers`) holds the runtime —
  it has to, because `uninstall!` is the teardown entry point. `worker_store(app)` and
  `default_store()` still return the *store*, unchanged, which is what installing a policy hook
  needs: `set_queue_authorizer!(worker_store(app), f)` is untouched.
- **`shutdown!` is no longer part of the store contract** — it takes a `WorkerRuntime`. A custom
  backend must **delete** its `shutdown!` method. It is a concrete method on a concrete type now,
  so there is no fallback to forget and nothing for a backend to contribute.
- **`WORKER_STORE_INTERFACE` went from 26 required methods to 15.** A custom backend must delete
  `shutdown!`, `reload_task`, `get_active_task`, `register_active_task!`,
  `deregister_active_task!`, `get_active_task_info`, `register_active_task_info!`,
  `deregister_active_task_info!`, `get_sequential_queues`, `get_queue_lock` and
  `get_cleanup_scheduler`, and drop the fields behind them. `missing_store_methods` reports
  against the new rows, so `@test isempty(missing_store_methods(MyStore))` is still the
  conformance check.

  The four `*_active_task*` **registrars are also no longer exported** from `Nitro.Workers` —
  reach them as `Nitro.Workers.register_active_task!(…)` if you need them. A run publishes its
  handle and its live record together through the exported `register_run!`, and writing one
  without the other is the state that makes a late-finishing predecessor delete its successor's
  handle. `get_active_task` and `get_active_task_info` stay exported; they only read.
- **`get_task_info(store, id)` is now defined as the DURABLE read** — which is what `reload_task`
  was, and why `reload_task` is gone: once no store caches live objects the two are the same
  function. Serving a running callback's own object to a reader is the runtime's job, through
  `get_task_info(runtime, id)`. A backend that keeps a live-preferring `get_task_info` still
  works, because the runtime consults its own cache first — but it is no longer required to, and
  see the fixes below for why it was actively harmful.
- **`reset_store!`'s `store isa InMemoryWorkerStore` special case is gone**, replaced by the
  optional `clear_records!(store)`. Its default is a no-op, deliberately in the safe direction:
  for a durable backend the registry is rows that outlive the process, so wiping them on a reset
  would be a destructive delete of live data. A volatile custom store that wants `reset_runtime!`
  to clear it must implement `clear_records!`.

`TaskInfo.sys_task` is also removed. It held a live `Task` handle on the record the data layer
serializes, and nothing read it — `recover_zombie_tasks!` has always decided liveness from
`get_active_task`. Code that read the field gets an `ErrorException` naming it.

Two behaviour fixes ride along, both on `PormGWorkerStore` only, both caused by its store-level
`get_task_info` preferring a process-local live cache:

- **A re-run could strand a task at `PENDING` forever.** A record can be terminal while its run is
  still executing, because cancellation is cooperative — `cancel_task` writes `CANCELLED` and the
  callback keeps going. Re-running the key in that window handed the new run its *predecessor's*
  `TaskInfo`, so the new run failed its own `run_id` fence (#108) and nothing was left to drain
  it. Run-start now reads durably.
- **The "one durable read per attempt" during retry backoff never reached the database.** It does
  now, so a cancellation issued on another node is observed between attempts.

### How to find the calls to migrate

```bash
# 1. The keyword rename. A hit on a SUBMIT/READ call migrates to `runtime=`; a hit on
#    worker_startup / Workers.start! / Workers.startup / install! stays exactly as it is.
grep -rn "store *=" --include=*.jl . | grep -E "submit_task|submit_sequential_task|get_task_status|cancel_task|get_all_tasks|cleanup_old_tasks|get_queue_status|recover_zombie_tasks!|cleanup_scheduler"

# 2. The renamed reset, the removed field, and the calls that take a store POSITIONALLY --
#    `stop_cleanup_scheduler!(store)` and `shutdown!(store)` have no `store =` for grep 1 to find.
grep -rn "reset_store!\|shutdown!\|stop_cleanup_scheduler!\|sys_task" --include=*.jl .

# 3. Custom backends: every one of these must be deleted, along with its fields.
grep -rn "<: AbstractWorkerStore" --include=*.jl .
grep -rn "reload_task\|_active_task\|get_sequential_queues\|get_queue_lock\|get_cleanup_scheduler\|_stop_scheduler_and_queues!" --include=*.jl .
```

```julia
using Nitro.Workers: missing_store_methods
missing_store_methods(MyWorkerStore)   # empty means conforming -- now 15 rows, not 26
```

### Before → after

```julia
# BEFORE -- bootstrap. UNCHANGED: `store=` here selects the backend.
store = pormg_nitro_worker(db_key = "workers")
serve(middleware = [worker_startup(queues = ["reports"], store = store, recover_zombies = true)])

# BEFORE -- direct calls
task_id = submit_task("report-42", run_report, Owner("user-1"); store = store)
status  = get_task_status(task_id, Owner("user-1"); store = store)
reset_store!(store)

# AFTER -- prefer the App-first form; it needs no keyword at all
task_id = submit_task(app, "report-42", run_report, Owner("user-1"))
status  = get_task_status(app, task_id, Owner("user-1"))

# AFTER -- or hold the runtime `start!` hands back
rt      = Nitro.Workers.start!(app; queues = ["reports"], store = store)
task_id = submit_task("report-42", run_report, Owner("user-1"); runtime = rt)
status  = get_task_status(task_id, Owner("user-1"); runtime = rt)
reset_runtime!(rt)

# AFTER -- policy hooks are still installed on the STORE, unchanged
set_queue_authorizer!(worker_store(app), my_queue_authorizer)
```

```julia
# BEFORE -- a custom backend owned its own background work
struct MyStore <: AbstractWorkerStore
    rows::Dict{String, TaskInfo}
    active_tasks::Dict{String, Task}
    sequential_queues::Dict{String, SequentialQueue}
    queue_lock::ReentrantLock
    cleanup_scheduler::Ref{Union{Nothing, CleanupScheduler}}
    # ...
end
Nitro.Workers.get_active_task(s::MyStore, id::String) = get(s.active_tasks, id, nothing)
Nitro.Workers.get_sequential_queues(s::MyStore) = s.sequential_queues
Nitro.Workers.get_queue_lock(s::MyStore) = s.queue_lock
Nitro.Workers.get_cleanup_scheduler(s::MyStore) = s.cleanup_scheduler
Nitro.Workers.reload_task(s::MyStore, id::String) = read_row(s, id)
function Nitro.Workers.shutdown!(s::MyStore)
    Nitro.Workers._stop_scheduler_and_queues!(s)
    empty!(s.active_tasks)
end

# AFTER -- the fields and every one of those methods are DELETED; the runtime owns them
struct MyStore <: AbstractWorkerStore
    rows::Dict{String, TaskInfo}
    # ...
end
Nitro.Workers.get_task_info(s::MyStore, id::String) = read_row(s, id)   # the durable read
Nitro.Workers.clear_records!(s::MyStore) = (empty!(s.rows); nothing)    # optional, volatile only

rt = WorkerRuntime(MyStore(...))   # queues, scheduler and run handles live here
```
