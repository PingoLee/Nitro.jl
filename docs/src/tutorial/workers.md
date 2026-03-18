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

## Immediate vs Sequential Tasks

Nitro supports two worker patterns.

### `submit_task`

Use `submit_task(...)` when jobs can run independently.

- suitable for parallel work
- deduplicates by `task_key`
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

The recommended app-level entrypoint is `worker_startup(...)`.

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
    return Res.json(get_task_status(task_id))
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

Worker jobs are identified by task id. You can inspect them through the worker API.

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
status = get_task_status("report-42")
```

### `get_all_tasks`

Returns all tasks, optionally filtered by worker status.

```julia
all_tasks = get_all_tasks()
running_tasks = get_all_tasks(RUNNING)
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

Tasks can be cancelled by id:

```julia
cancel_task("report-42")
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

```julia
task_id = submit_task("report-99", task_info -> begin
    task_info.progress = 10.0
    sleep(1)
    task_info.progress = 60.0
    sleep(1)
    task_info.progress = 100.0
    return "done"
end, "user-1")
```

Clients can then poll `get_task_status(task_id)` and read `:progress`.

## Choosing Good Task Keys

Task ids are also deduplication keys.

If you submit the same `task_key` while the task is already `PENDING` or `RUNNING`, Nitro attaches the caller as another watcher instead of starting duplicate work.

Use stable keys when duplicate work should collapse into one job:

- `refresh-dashboard`
- `report-2026-03-17`
- `customer-42-sync`

Use unique keys when every request must create a distinct job.

## When Not To Use Workers

Do not use `Nitro.Workers` as a substitute for a separate worker service when you need:

- jobs that must survive server restarts
- cross-process or cross-machine execution
- durable queues backed by Redis, Postgres, or another external broker
- long-running scheduled infrastructure outside the web server lifecycle

For those cases, keep Nitro as the API layer and move heavy or durable job execution into a separate worker process.

## Summary

Use `Nitro.Workers` when you need lightweight in-process background execution for Nitro requests.

- use `worker_startup(...)` to bootstrap workers with the server
- use `submit_task(...)` for parallel jobs
- use `submit_sequential_task(...)` for ordered queue processing
- use `get_task_status(...)` and `get_queue_status(...)` to monitor work
- use `TaskOptions(...)` for retries and timeouts

For most apps, that gives you a simple async job model without introducing a second service.