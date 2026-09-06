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
    end, Owner("user-1"))

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
end, Owner("user-1"))
```

### `submit_sequential_task`

Use `submit_sequential_task(...)` when only one job in a queue should run at a time.

- preserves order inside a named queue
- useful for per-customer jobs, report pipelines, or jobs that must not overlap

```julia
task_id = submit_sequential_task("reports", "report-42", task_info -> begin
    sleep(2)
    return Dict("queue" => "reports", "task" => task_info.id)
end, Owner("user-1"))
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
    end, Owner("user-1"))

    return Res.status(202, Res.json(Dict("task_id" => task_id)))
end

function report_status(req::HTTP.Request)
    task_id = string(req.params["task_id"])
    # Pass user_id to securely query task status
    return Res.json(get_task_status(task_id, Owner("user-1")))
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
- `:owner` — the owning user id, or `nothing` for a `:global` task
- `:status`
- `:progress`
- `:result`
- `:error`
- `:created_at`
- `:started_at`
- `:completed_at`
- `:queue_name`

Every read takes an **authority** saying who is asking — see
[User Access Control](#User-Access-Control) below.

```julia
task_id = submit_task("report-42", () -> build_report(), Owner("user-1"))
status = get_task_status(task_id, Owner("user-1"))

# Equivalent, when the returned id was not kept:
status = get_task_status(scoped_task_key("report-42", Owner("user-1")), Owner("user-1"))
```

### `get_all_tasks`

Returns the tasks the given authority may see, optionally filtered by worker status.
For an `Owner` that is the tasks they own plus any they have been granted; for
`System()` it is every task.

```julia
my_tasks = get_all_tasks(Owner("user-1"))
my_running = get_all_tasks(Owner("user-1"), RUNNING)
every_task = get_all_tasks(System())
```

### `get_queue_status`

Queue-wide introspection for sequential queues, reporting:

- current task
- pending count and the ids of everything pending
- queue state
- total load

**It is an admin surface and takes `System()` only** — an `Owner` is a `MethodError`:

```julia
queue = get_queue_status("reports", System())
```

Queue depth and the current task are facts about a *queue*, not about any one user, and
the pending-id list carries owners in the `"<owner>::<key>"` prefix. Accepting an `Owner`
and filtering that list would produce something that looks user-scoped while still
reporting another tenant's queue depth. Put it behind the same authorization you would put
in front of Sidekiq Web or a Hangfire dashboard, and keep it off user-facing routes.

To show a user their own pending work, build it from a scoped read instead:

```julia
mine_pending = get_all_tasks(Owner("user-1"), PENDING)
```

!!! note "`is_task_running` was removed"
    It took no user id at all, so any caller who could name an id learned whether it was
    live. Use `get_task_status(task_id, Owner(user_id))[:status] in ("PENDING", "RUNNING")`,
    which answers the same question with authorization applied. Note `:status` is a
    `String`, not the `TaskStatus` enum.

## Cancellation And Retries

Tasks can be cancelled by id — again, the id the submit call returned:

```julia
cancel_task(task_id, Owner("user-1"))
```

Tasks can also retry on failure by passing `TaskOptions`.

```julia
submit_task(
    "fragile-import",
    () -> begin
        error("temporary failure")
    end,
    Owner("user-1");
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
end, Owner("user-1"))
```

Clients can then poll `get_task_status(task_id, Owner("user-1"))` and read `:progress`.

## Task Keys And Deduplication Scope

Task ids are also deduplication keys, so their scope decides who can collide with whom.
Watcher membership is what grants the right to read a task's `:result` and to cancel it —
which means a key that two users can both produce is a key that leaks between them.

### `:user` scope (the default)

The key is namespaced by its owner, so `submit_task` returns `"<user_id>::<task_key>"`:

```julia
a = submit_task("export_report_42", cb, Owner("user-a"))   # "user-a::export_report_42"
b = submit_task("export_report_42", cb, Owner("user-b"))   # "user-b::export_report_42"
```

Two independent tasks. Deduplication still collapses one user's repeat submissions onto
their own running job, but nothing crosses the user boundary. This is what you want for
keys derived from resource ids, which are rarely secret.

Rebuild the id with `scoped_task_key` if you did not keep the return value:

```julia
scoped_task_key("export_report_42", Owner("user-a"))   # "user-a::export_report_42"
```

An `Owner` id may not contain `::`, and may not end in `:`. Both rules exist so that two
different `(user, key)` pairs can never resolve to the same id — without the second,
`(":report", "alice")` and `("report", "alice:")` would collide on `"alice:::report"`. A
colon anywhere else in the owner (`"google:12345"`) is fine.

### `:global` scope

Opt in when one expensive job really should be shared across users — a cache warm, a
nightly rollup, a tenant-wide index rebuild:

```julia
task_id = submit_task("warm-price-cache", cb, Owner(user_id); scope=:global)
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

!!! note "Multiple processes sharing one database"
    Because the store persists across restarts, it invites deployments where several
    processes share one database — two app instances behind a load balancer, or a web
    process plus a worker process. Writes that must not lose a concurrent update go
    through the store as single atomic operations rather than read-modify-write: watcher
    grants use a compare-and-set on the stored document, and cancellation uses a
    conditional status transition. An ordinary state save (`set_task!`) never writes the
    watcher list at all, so a task finishing in one process cannot drop a grant another
    process just added.

    The store's `lock_tasks` is a plain `ReentrantLock` and therefore **process-local** —
    it orders writes within one process and gives you nothing across processes. Do not
    build a read-modify-write on top of it and assume it is safe; use the atomic store
    operations, or add one.

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
task_id = submit_task("report-42", run_report, Owner("user-1"); store=worker_store)
status = get_task_status(task_id, Owner("user-1"); store=worker_store)
```

## User Access Control

To support multitenant backends, Nitro.jl workers include built-in authorization mechanisms.

### Who is asking: `Owner` and `System`

Every task API takes a **`TaskAuthority`**, and it is required — there is no arity that
omits it:

- **`Owner("user-123")`** — acts as that identity. It is a validated id: it may not be
  empty, contain `::`, or end in `:`, so an identity you can grant is always one that can
  be constructed again later to use the grant.
- **`System()`** — the explicit bypass. Unscoped: every task, every result.

`System()` is deliberately more to type than `Owner(...)`. Before, the bypass was an
*omitted* argument, which made the unsafe call the shorter one and left a call site that
had simply forgotten to scope indistinguishable from one that meant not to. Now the
bypass is a value you name, greppable in review and in a security audit.

```julia
using Nitro.Errors: AuthorizationError

task_id = submit_task("my-task", heavy_job, Owner("user-123"))

status = get_task_status(task_id, Owner("user-123"))     # ok
get_task_status(task_id, Owner("intruder-99"))           # AuthorizationError
get_task_status(task_id, System())                       # ok — admin path, unscoped

get_task_status(task_id)                                 # MethodError, not a bypass
get_task_status(task_id, "user-123")                     # MethodError — not an authority
```

### Where authority comes from

Two sources, and they are not equal:

1. **The task id.** Under the default `:user` scope the id is `"<owner>::<key>"`, so
   ownership is *derived*, not stored — `owner_of` reads it back. Nothing can
   revoke it: not a lost watcher entry, not a concurrent write from another process.
2. **The `watchers` list.** Additional grants layered on top. The submitter is added
   automatically.

A `:global` task is stored under its verbatim key and therefore has **no owner half**. For
those, `watchers` remains the entire gate — including for the creator. That asymmetry is
deliberate: deriving ownership adds an authority source for `:user` ids without removing
one for `:global` ids.

Because watcher membership is still the gate for `:global` tasks, a user does not become a
watcher of a task they did not create just by naming its key. Under `:user` scope they
cannot name it at all; under `:global` scope they are refused unless a watch authorizer
says otherwise.

### Granting access to a second identity

The identity that *submits* a task is not always the identity that *polls* it. A browser
may upload under a deliberately short-lived credential while your own backend, holding a
different long-lived one, drives the progress bar — and extending the browser's credential
to cover the whole job is the thing that split exists to prevent.

Pass `watchers` at submit time:

```julia
task_id = submit_task("import-42", run_import, Owner("browser-client");
                      watchers = [Owner("backend-service")])

# The backend can now poll and cancel, under its own identity:
get_task_status(task_id, Owner("backend-service"))
```

The grant is made **at submit time, by the owner**. That is the moment the owner is already
resolved and authorized, so there is no second authorization question to answer — and no
post-hoc public grant call that would become another route into the watcher list.

Two things to know before you use it:

- **A grantee can cancel, not just read.** `cancel_task` gates on the same list, so a grant
  hands over the owner's rights minus ownership. There is no read-only grant.
- **Grants do not survive a record reset.** Re-running a *finished* key replaces the record
  and resets its watchers to the resubmitter, so pass `watchers` again on each such
  resubmission. Granting an identity that is already a watcher is a no-op.

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
- pass an `Owner(...)` on submission and on every read; `System()` is the named, unscoped bypass
- use `submit_task(...)` for parallel jobs
- use `submit_sequential_task(...)` for ordered queue processing
- read and cancel with the id the submit call **returned**, not the `task_key` you passed
- use `scope=:global` only when a job is genuinely shared, and pair it with `set_watch_authorizer!`
- use `get_task_status(...)` and `get_queue_status(...)` to monitor work
- use `TaskOptions(...)` for retries and timeouts
