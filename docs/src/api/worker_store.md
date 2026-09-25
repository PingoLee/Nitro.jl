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
