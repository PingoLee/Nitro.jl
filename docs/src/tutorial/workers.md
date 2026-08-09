# Workers

`Nitro.Workers` provides an in-process task runtime for work that should not block the request/response path.

Use it when a request needs to trigger work that may take longer than you want to keep the client waiting, such as:

- generating reports
- importing data files
- sending webhook batches
- refreshing cached aggregates
- enforcing sequential execution for one logical queue

It is not a separate worker service or distributed job system. The runtime lives inside the same Nitro server process and is tied to the server lifecycle.

## What Workers Are For

Without workers, a handler like this keeps the HTTP request open until the slow work finishes:

```julia
using HTTP
using Nitro

function slow_report(req::HTTP.Request)
    sleep(10)
    return Res.json(Dict("status" => "done"))
end
```

That is fine for very short work, but it becomes a poor fit when the job takes seconds or minutes.

With `Nitro.Workers`, the handler can submit the work and return immediately:

```julia
using HTTP
using Nitro
using Nitro.Workers

function start_report(req::HTTP.Request)
    task_id = submit_task("report-42", task_info -> begin
        sleep(10)
        return Dict("report_id" => 42, "status" => "ready")
    end, "user-1")

    return Res.status(202, Res.json(Dict("task_id" => task_id)))
end
```

The client gets a task id right away and can poll for status later.

!!! warning "The returned id is not the key you passed in"
    `submit_task` and `submit_sequential_task` namespace the key by its owner, so the
    id above is `"user-1::report-42"`, not `"report-42"`. Always poll and cancel with the
    **returned** value. See [Task Keys And Deduplication Scope](@ref).

## Immediate vs Sequential Tasks

Nitro supports two worker patterns.

### `submit_task`

Use `submit_task(...)` when jobs can run independently.

- suitable for parallel work
- deduplicates by `task_key`, within one user by default
- subject to the queue authorizer under the name `DEFAULT_QUEUE_NAME` (`"default"`)
- useful for imports, exports, notifications, and one-off background processing

```julia
task_id = submit_task("refresh-dashboard", () -> begin
    sleep(2)
    return "ok"
end, "user-1")
```

### `submit_sequential_task`

Use `submit_sequential_task(...)` when only one job in a queue should run at a time.

- preserves order inside a named queue
- useful for per-customer jobs, report pipelines, or jobs that must not overlap

```julia
task_id = submit_sequential_task("reports", "report-42", task_info -> begin
    sleep(2)
    return Dict("queue" => "reports", "task" => task_info.id)
end, "user-1")
```

Different queues can still run independently.

## Start Workers With The Server

The recommended app-level entrypoint is the exported `worker_startup(...)` middleware.

Add it to the `serve(middleware=[...])` list so Nitro starts the worker runtime on server startup and shuts it down when the server stops.

```julia
using HTTP
using Nitro
using Nitro.Workers

function create_report(req::HTTP.Request)
    report_id = string(req.params["id"])
    task_id = submit_sequential_task("reports", "report-" * report_id, task_info -> begin
        sleep(3)
        return Dict("report_id" => report_id, "status" => "ready")
    end, "user-1")

    return Res.status(202, Res.json(Dict("task_id" => task_id)))
end

function report_status(req::HTTP.Request)
    task_id = string(req.params["task_id"])
    # Pass user_id to securely query task status
    return Res.json(get_task_status(task_id, "user-1"))
end

urlpatterns("",
    path("/reports/<str:id>", create_report, method="POST"),
    path("/tasks/<str:task_id>", report_status, method="GET"),
)

serve(
    middleware=[
        worker_startup(
            queues=["reports"],
            cleanup_interval_hours=24,
            cleanup_retain_days=7,
            recover_zombies=true, # Automatically fails tasks stuck in RUNNING on process crashes
        ),
    ],
)
```

This is the simplest setup for most Nitro applications.

## Manual Startup

If your app needs explicit bootstrap control, use `Nitro.Workers.start!(ctx; ...)` with a `ServerContext`.

```julia
using Nitro

ctx = Nitro.CONTEXT[]

Nitro.Workers.start!(
    ctx;
    queues=["reports", "imports"],
    cleanup_enabled=true,
    cleanup_interval_hours=24,
    cleanup_retain_days=7,
)
```

That is useful in custom bootstraps, test setup, or app wrappers that manage the Nitro context directly.

## Polling Task Status

Worker jobs are identified by the task id **returned by the submit call** — not by the
`task_key` you passed in. Hold onto that value (or rebuild it with `scoped_task_key`) and
use it for every read and cancel.

### `get_task_status`

Returns a dictionary with fields such as:

- `:id`
- `:status`
- `:progress`
- `:result`
- `:error`
- `:created_at`
- `:started_at`
- `:completed_at`
- `:queue_name`

```julia
task_id = submit_task("report-42", () -> build_report(), "user-1")
status = get_task_status(task_id, "user-1")

# Equivalent, when the returned id was not kept:
status = get_task_status(scoped_task_key("report-42", "user-1"), "user-1")
```

### `get_all_tasks`

Returns all tasks, optionally filtered by worker status.

```julia
all_tasks = get_all_tasks(nothing, "user-1")
running_tasks = get_all_tasks(RUNNING, "user-1")
```

### `get_queue_status`

Useful for sequential queues.

```julia
queue = get_queue_status("reports")
```

It reports information like:

- current task
- pending count
- queue state
- total load

## Cancellation And Retries

Tasks can be cancelled by id — again, the id the submit call returned:

```julia
cancel_task(task_id, "user-1")
```

Tasks can also retry on failure by passing `TaskOptions`.

```julia
submit_task(
    "fragile-import",
    () -> begin
        error("temporary failure")
    end,
    "user-1";
    options=TaskOptions(retry_on_failure=true, max_retries=3, timeout=300),
)
```

## Progress Updates

If your callback accepts `task_info`, you can update progress while the job runs.

`TaskInfo.progress` is an atomic field, so assigning it raises `ConcurrencyViolationError`.
Write it through `update_progress!`, which is the only supported path:

```julia
task_id = submit_task("report-99", task_info -> begin
    update_progress!(task_info, 10)
    sleep(1)
    update_progress!(task_info, 60)
    sleep(1)
    update_progress!(task_info, 100)
    return "done"
end, "user-1")
```

Clients can then poll `get_task_status(task_id)` and read `:progress`.

## Task Keys And Deduplication Scope

Task ids are also deduplication keys, so their scope decides who can collide with whom.
Watcher membership is what grants the right to read a task's `:result` and to cancel it —
which means a key that two users can both produce is a key that leaks between them.

### `:user` scope (the default)

The key is namespaced by its owner, so `submit_task` returns `"<user_id>::<task_key>"`:

```julia
a = submit_task("export_report_42", cb, "user-a")   # "user-a::export_report_42"
b = submit_task("export_report_42", cb, "user-b")   # "user-b::export_report_42"
```

Two independent tasks. Deduplication still collapses one user's repeat submissions onto
their own running job, but nothing crosses the user boundary. This is what you want for
keys derived from resource ids, which are rarely secret.

Rebuild the id with `scoped_task_key` if you did not keep the return value:

```julia
scoped_task_key("export_report_42", "user-a")   # "user-a::export_report_42"
```

A `user_id` may not contain `::`, and may not end in `:`. Both rules exist so that two
different `(user, key)` pairs can never resolve to the same id — without the second,
`(":report", "alice")` and `("report", "alice:")` would collide on `"alice:::report"`. A
colon anywhere else in the owner (`"google:12345"`) is fine.

### `:global` scope

Opt in when one expensive job really should be shared across users — a cache warm, a
nightly rollup, a tenant-wide index rebuild:

```julia
task_id = submit_task("warm-price-cache", cb, user_id; scope=:global)
```

The key is stored verbatim, so any user can name it. A caller who is **not already a
watcher** is refused with `AuthorizationError`, whether the task is still running (joining
it would hand over read and cancel rights) or already finished (re-running it would discard
the owner's stored result). To allow sharing, install a watch authorizer — see
[Queue And Watch Authorization](@ref).

A `:global` key may not contain `::`. That keeps the two namespaces disjoint: without the
restriction, submitting `"victim::export_42"` globally would produce exactly the id
`victim`'s own `:user`-scoped `"export_42"` resolves to, and squat it.

### Picking keys

Use stable keys when duplicate work should collapse into one job:

- `refresh-dashboard`
- `report-2026-03-17`
- `customer-42-sync`

Use unique keys when every request must create a distinct job.

## Database Persistence

By default, Nitro.jl uses an `InMemoryWorkerStore` to hold worker tasks in memory. If your server restarts, volatile tasks are lost.

To make your queues **durable and survive server restarts**, you can configure the database-backed `PormGWorkerStore` using the `NitroPormGExt` extension.

### 1. Configure the PormG connection
Configure PormG with the connection key you want workers to use:

```julia
using Nitro
using PormG

PormG.Configuration.load("workers")
```

The default key is `"db"`. Use a different `db_key` when your worker database uses another PormG connection, for example `db_key="db_bs"`.

### 2. Bootstrap the worker store
Create the task table and indexes, then keep the returned store for worker calls or startup middleware:

```julia
using Nitro
using Nitro.Workers

worker_store = pormg_nitro_worker(db_key="workers")
```

Task metadata will now be persisted to that database, while live running threads are managed safely in memory to prevent serialization issues.

### 3. Start workers with the persistent store
Pass the store into the worker startup middleware:

```julia
serve(
    middleware=[
        worker_startup(
            queues=["reports"],
            store=worker_store,
            recover_zombies=true,
        ),
    ],
)
```

For direct calls, pass the same store explicitly:

```julia
task_id = submit_task("report-42", run_report, "user-1"; store=worker_store)
status = get_task_status(task_id, "user-1"; store=worker_store)
```

## User Access Control

To support multitenant backends, Nitro.jl workers include built-in authorization mechanisms.

### Task Ownership & Watchers
Task submission functions require a `user_id`, and that user is registered as the task's first **watcher**.
- Status, cancellation, and listing functions accept an optional `user_id` parameter.
- Passing a non-empty `user_id` enforces watcher-based access. Only task owners or designated watchers can query or cancel a task; unauthorized users get an `AuthorizationError`.
- Omitting `user_id` bypasses watcher checks and should be reserved for explicit system/admin paths or app-level public worker endpoints.

```julia
using Nitro.Errors: AuthorizationError

try
    # Submit task with ownership
    task_id = submit_task("my-task", heavy_job, "user-123")

    # Authorized checks succeed
    status = get_task_status(task_id, "user-123")

    # Unauthorized checks throw an error
    unauthorized = get_task_status(task_id, "intruder-99")
catch err
    if err isa AuthorizationError
        println("Access denied!")
    end
end
```

Because watcher membership is the whole gate, a user does not become a watcher of a task
they did not create just by naming its key. Under the default `:user` scope they cannot
name it at all; under `:global` scope they are refused unless a watch authorizer says
otherwise.

## Queue And Watch Authorization

Two independent hooks, installed on the store.

### Queue authorization
Restrict who may submit to a queue:

```julia
function my_queue_authorizer(queue_name::String, user_id::String)::Bool
    # Only admins can push tasks to the maintenance queue
    if queue_name == "maintenance"
        return user_id == "admin-user"
    end
    return true
end

set_queue_authorizer!(worker_store, my_queue_authorizer)
```

This runs on **both** submit paths. `submit_sequential_task` passes the queue it was given;
`submit_task` has no sequential queue, so it passes `DEFAULT_QUEUE_NAME` (`"default"`),
following the convention every comparable queue uses. An authorizer written as an allowlist
must therefore permit `"default"`, or `submit_task` is closed to everyone:

```julia
set_queue_authorizer!(worker_store, (queue_name, user_id) ->
    queue_name == DEFAULT_QUEUE_NAME || queue_name in queues_for(user_id))
```

### Watch authorization
Decide who may join or reuse a `:global` task key someone else already owns:

```julia
# Decide from data already in memory — see the warning below.
set_watch_authorizer!(worker_store, function(task_key, watchers, user_id)
    return ORG_OF[first(watchers)] == ORG_OF[user_id]
end)
```

Without this hook, cross-user submission of an existing `:global` key is refused. `watchers`
is a copy, so mutating it has no effect.

!!! warning "The hook runs under the store's task lock"
    That lock also serializes `set_task!`, `cancel_task`, and zombie recovery, so blocking
    inside the hook stalls the whole worker subsystem. Make it a pure in-memory predicate:
    no database queries, and never `fetch` a spawned task that touches the same store — the
    child cannot take a `ReentrantLock` its parent holds, so that deadlocks. Resolve
    org/tenant membership into memory before installing the hook.

!!! note "Re-running a finished shared key resets its watchers"
    A terminal task is replaced, not resumed, so the new submitter becomes the only watcher.
    Everyone else holding that id starts getting `AuthorizationError` until the hook
    re-approves them — and a pure status-polling route never re-submits, so it cannot
    re-approve itself. Give shared ids a short life, or re-submit rather than only poll.

## Startup Zombie Task Recovery (Option B)

To protect databases from stuck `RUNNING` tasks when a server or worker process crashes unexpectedly, Nitro.jl implements **automatic startup recovery**.
* When the server starts up (via the `worker_startup(...)` middleware), it sweeps the database store for all tasks marked as `RUNNING`.
* For each task, it checks if there is a live, in-memory execution thread running in the current process.
* If there is no live execution (meaning the task is a "zombie" orphaned by a previous crash), it marks the task status as `FAILED` with the error: `"Worker process terminated unexpectedly mid-execution."`
* By default, automatic recovery is enabled (`recover_zombies=true`).

## When Not To Use Workers

Do not use `InMemoryWorkerStore` for jobs that must survive server restarts. For durable in-process queues, always configure the `PormGWorkerStore` extension.

Even with database persistence, keep in mind that `Nitro.Workers` is an in-process runner. Move to a dedicated external queue cluster (like Celery or Sidekiq) if you need:
- cross-machine execution or horizontal scaling across separate nodes
- extremely heavy CPU-bound job queues that should not compete with your web server thread pool

## Summary

Use `Nitro.Workers` when you need lightweight or persistent background execution for Nitro requests.

- use `worker_startup(...)` to bootstrap workers with the server
- use `PormGWorkerStore` to persist task state to your database
- use `user_id` on submission, and pass it to read/manage APIs when routes are user-scoped
- use `submit_task(...)` for parallel jobs
- use `submit_sequential_task(...)` for ordered queue processing
- read and cancel with the id the submit call **returned**, not the `task_key` you passed
- use `scope=:global` only when a job is genuinely shared, and pair it with `set_watch_authorizer!`
- use `get_task_status(...)` and `get_queue_status(...)` to monitor work
- use `TaskOptions(...)` for retries and timeouts
