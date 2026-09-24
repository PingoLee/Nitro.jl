# Worker Store Interface

What a custom worker backend implements. [`AbstractWorkerStore`](@ref Nitro.Workers.AbstractWorkerStore)
lists the contract; [`missing_store_methods`](@ref Nitro.Workers.missing_store_methods) checks a type
against it. The running side of the queue is on [Workers API](@ref).

```@docs
Nitro.Workers.AbstractWorkerStore
Nitro.Workers.InMemoryWorkerStore
Nitro.Workers.missing_store_methods
Nitro.Workers.set_task!
Nitro.Workers.replace_task!
Nitro.Workers.try_transition!
Nitro.Workers.clear_records!
Nitro.Workers.list_running_task_refs
Nitro.Workers.RunningTaskRef
Nitro.Workers.register_run!
```
