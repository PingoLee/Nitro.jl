# Worker Store Interface

What a custom worker backend implements. [`AbstractWorkerStore`](@ref Nitro.Workers.AbstractWorkerStore)
lists the contract; [`missing_store_methods`](@ref Nitro.Workers.missing_store_methods) checks a type
against it. The running side of the queue is on [Workers API](@ref).

**None of these names is exported** ([#323](https://github.com/PingoLee/Nitro.jl/issues/323)). A
backend extends them qualified (`Nitro.Workers.get_task_info(s::MyStore, id::String) = …`) or
imports them by name (`using Nitro.Workers: get_task_info, add_watcher!`). They perform no
authorization — `get_task_info` hands out a whole record, `result` included, and `add_watcher!`
grants read and cancel — so an application reaches tasks through the authority-checked API on
[Workers API](@ref) instead.

```@docs
Nitro.Workers.AbstractWorkerStore
Nitro.Workers.InMemoryWorkerStore
Nitro.Workers.missing_store_methods
Nitro.Workers.TaskLocks
Nitro.Workers.task_locks
Nitro.Workers.lock_tasks
Nitro.Workers.get_task_info
Nitro.Workers.set_task!
Nitro.Workers.replace_task!
Nitro.Workers.add_watcher!
Nitro.Workers.try_transition!
Nitro.Workers.try_delete_task!
Nitro.Workers.clear_records!
Nitro.Workers.list_running_task_refs
Nitro.Workers.RunningTaskRef
Nitro.Workers.register_run!
```

## What a record carries, and which call writes it

A store persists every [`TaskInfo`](@ref Nitro.Workers.TaskInfo) field except the process-local
cancellation token. The fields fall into two groups, and the split is the store contract:

- **State** is written by `set_task!` and `try_transition!`: `status`, `progress`, `result`,
  `error` and the timestamps.
- **Identity** is written by `replace_task!` (a new submission) and by the claim operations below
  (a new run of the same submission). `set_task!` never writes it: `run_id`, `watchers`, the claim
  fields, and the named-job fields.

`job_name` and `job_args` ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)) hold a named
job's registered name and its arguments as JSON text. Both are `nothing` for a closure.
`PormGWorkerStore` keeps them in the `job_name` (`VARCHAR(255)`) and `job_args` (`TEXT`) columns,
and adds both on boot to a table created before them. A custom store that drops them still runs
named jobs **in this process**, which binds from the queued item's copy. It cannot back a queue
run by a separate consumer process, because that process has only what the store hands back.

## Claims: the optional capability for a consumer process

A queue whose runs execute in a **separate consumer process**
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)) needs five more store operations:
claim a submission, renew the lease on it, hand it back, adjudicate expired leases, and count a
queue's external submissions for its submit-time bounds. They are
**optional**. A store without them still passes `missing_store_methods`; it just cannot back such a
queue, and [`missing_claim_methods`](@ref Nitro.Workers.missing_claim_methods) says what it lacks.
Both shipped stores implement them.

Delivery through a claim is **at-least-once**. A run whose lease expires is re-queued or failed by
its queue's [`LeasePolicy`](@ref Nitro.Workers.LeasePolicy), so a job on such a queue must be
idempotent.

```@docs
Nitro.Workers.missing_claim_methods
Nitro.Workers.CLAIM_STORE_INTERFACE
Nitro.Workers.claim_next!
Nitro.Workers.renew_leases!
Nitro.Workers.LeaseRenewal
Nitro.Workers.release_claim!
Nitro.Workers.requeue_expired!
Nitro.Workers.count_external_runs
Nitro.Workers.LeasePolicy
```

A store throws [`ClaimPoisonedError`](@ref Nitro.Errors.ClaimPoisonedError) from
`claim_next!` when a second head row of a queue does not decode in one call.

```@docs
Nitro.Errors.ClaimPoisonedError
```
