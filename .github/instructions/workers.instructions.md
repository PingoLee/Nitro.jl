---
description: Workers module — persistent stores, user_id/watchers, queue authorizers, zombie recovery
applyTo: "src/Workers/**/*.jl,ext/NitroPormGExt.jl,test/**/*worker*.jl,test/extensions/**/*.jl"
---

# Nitro.jl Workers Module

This rule applies when changing the Workers queue, `NitroPormGExt` worker storage, or worker tests.

## 1. Context & Architecture

The worker system supports both volatile in-memory queues and persistent database stores with access control.

### Storage backends
- **`AbstractWorkerStore`**: Interface for storage backends.
- **`InMemoryWorkerStore`**: Volatile, thread-safe store in `src/Workers/`.
- **`PormGWorkerStore`**: Persistent store in `ext/NitroPormGExt.jl`.
- **Volatile execution handles**: Running `Task` objects stay in `active_tasks::Dict{UUID, Task}`; metadata lives in the store.
- **Queue authorization hooks**: Optional `queue_authorizer(queue_name, user_id)::Bool`.
- **Watchers**: Task submissions register the submitting `user_id` as a watcher. Read/manage APIs validate watcher access when `user_id` is supplied.

## 2. Task API

Task submission requires `user_id`. Read/manage APIs accept optional `user_id`.
Passing a non-empty `user_id` enforces watcher-based access (`AuthorizationError` when denied). Omitting `user_id` is a deliberate system/public-endpoint bypass for routes that intentionally expose shared task visibility, not the default for user-scoped APIs.

```julia
task_id = submit_task("default_queue", () -> work(), "user_123")
task = get_task_status(task_id, "user_123")
cancel_task(task_id, "user_123")
user_tasks = get_all_tasks(nothing, "user_123")

# System/public endpoint bypass, only when the app intentionally allows it:
public_status = get_task_status(task_id)
```

### Reporting progress — never assign the field

`TaskInfo.progress` is declared `@atomic`. Plain assignment from a callback throws
`ConcurrencyViolationError`:

```julia
# ✗ throws — violates the @atomic field
task_info.progress = 50

# ✓ the only supported write
update_progress!(task_info, 50)     # 0–100 scale, returns the task
```

This is a live documentation bug in the workers tutorial
([#54](https://github.com/PingoLee/Nitro.jl/issues/54)) — do not copy the assignment form from
existing docs, and fix it where you find it.

### The rest of the exported surface

`Workers` exports considerably more than the four functions above. The ones worth knowing before
you add anything:

| API | Purpose |
|-----|---------|
| `submit_sequential_task`, `SequentialQueue` | Ordered, one-at-a-time execution within a queue |
| `is_task_running`, `get_queue_status` | Introspection without mutating |
| `update_progress!` | The only safe write to `TaskInfo.progress` |
| `cleanup_old_tasks`, `start_cleanup_scheduler`, `stop_cleanup_scheduler!` | Retention |
| `shutdown!` | Graceful teardown — stop the cleanup scheduler and queue processors |
| `reset_store!`, `install!`, `uninstall!`, `worker_store`, `default_store` | Store lifecycle |

**`shutdown!` is part of the store contract, not an optional extra.** A store that does not
implement it leaks its cleanup scheduler and queue processors on shutdown — which is exactly what
`PormGWorkerStore` does today ([#29](https://github.com/PingoLee/Nitro.jl/issues/29)). Any new
backend must implement it.

## 3. Database Persistence

Configure PormG, then bootstrap the store:

```julia
# db_key defaults to "db"; "workers" below is an explicit override, not the default.
persistent_store = pormg_nitro_worker(db_key="workers")
serve(middleware=[worker_startup(queues=["reports"], store=persistent_store, recover_zombies=true)])
```

## 4. Queue Authorization

```julia
function my_queue_authorizer(queue_name::String, user_id::String)::Bool
    queue_name == "maintenance" && return user_id == "admin-user"
    return true
end
set_queue_authorizer!(persistent_store, my_queue_authorizer)
```

## 5. Zombie Task Recovery

On startup, `RUNNING` tasks without a live in-memory `Task` are marked `FAILED` when `recover_zombies=true`.

## 6. Developer Rules

> **Strict core isolation**: Never import `PormG` or run DB queries in `src/Workers`. Database logic belongs in `ext/NitroPormGExt.jl`.

- Add abstract stubs in `src/Workers/registry.jl`.
- Implement in `InMemoryWorkerStore` and `PormGWorkerStore`.
- **Never serialize running `Task` objects** to the database.
