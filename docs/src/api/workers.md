# Workers API

The background task queue. `Nitro.Workers` is exported as a module, so these names are reached
qualified (`Nitro.Workers.submit_task`) or through `using Nitro.Workers`. The walkthrough —
identities, deduplication, cancellation, authorization — is the [Workers](../tutorial/workers.md) guide.

## Installing And Running

```@docs
worker_startup
Nitro.Workers.install!
Nitro.Workers.uninstall!
Nitro.Workers.start!
Nitro.Workers.worker_runtime
Nitro.Workers.WorkerRuntime
Nitro.Workers.worker_store
Nitro.Workers.default_runtime
Nitro.Workers.default_store
Nitro.Workers.shutdown!
Nitro.Workers.reset_runtime!
Nitro.Workers.WORKER_DRAIN_TIMEOUT_SECONDS
Nitro.Workers.DEFAULT_QUEUE_NAME
Nitro.Errors.WorkerUnavailableError
Nitro.Errors.WorkerCapacityError
Nitro.pormg_nitro_worker
```

## Submitting Tasks

```@docs
Nitro.Workers.submit_task
Nitro.Workers.submit_sequential_task
Nitro.Workers.TaskAuthority
Nitro.Workers.Owner
Nitro.Workers.System
Nitro.Workers.owner_of
Nitro.Workers.scoped_task_key
```

## Inspecting And Controlling Tasks

```@docs
Nitro.Workers.TaskInfo
Nitro.Workers.get_task_status
Nitro.Workers.cancel_task
Nitro.Workers.release_task!
Nitro.Workers.get_all_tasks
Nitro.Workers.get_queue_status
Nitro.Workers.update_progress!
Nitro.Workers.cancel_requested
Nitro.Workers.cancel_reason
Nitro.Workers.CANCEL_REASONS
Nitro.Workers.TaskTimeoutError
Nitro.Workers.format_error
Nitro.Workers.MAX_STORED_ERROR_CHARS
Nitro.Workers.set_watch_authorizer!
Nitro.Workers.set_error_redactor!
```

## Maintenance

```@docs
Nitro.Workers.start_cleanup_scheduler
Nitro.Workers.recover_zombie_tasks!
Nitro.Workers.ZOMBIE_SWEEP_BATCH
```

A custom storage backend implements the contract on [Worker Store Interface](@ref). Those
methods — `get_task_info`, `add_watcher!` and the rest — are not exported: they read and write
records with no authority check, so an application calls the task API above instead
([#323](https://github.com/PingoLee/Nitro.jl/issues/323)).
