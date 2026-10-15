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

## Claims: the optional capability for a consumer process

A queue whose runs execute in a **separate consumer process**
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)) needs four more store operations:
claim a submission, renew the lease on it, hand it back, and adjudicate expired leases. They are
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
Nitro.Workers.LeasePolicy
```
