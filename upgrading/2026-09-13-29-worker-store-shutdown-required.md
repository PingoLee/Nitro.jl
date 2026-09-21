## `shutdown!` is required of every `AbstractWorkerStore` (#29)

- **Version**: 0.4.0
- **Nitro ref**: #29; `src/Workers/registry.jl`, `ext/NitroPormGExt.jl`, `test/workers_tests.jl`,
  `test/extensions/pormg_worker_tests.jl`
- **Recorded**: 2026-09-13
- **Severity**: **breaking, and it fails LOUDLY.** A custom worker store that does not define
  `shutdown!` now raises `StoreInterfaceError` naming the method and your type, at the first
  `uninstall!` or `reset_store!`. Previously it silently did nothing — which is the bug.

### What changed

`shutdown!(::AbstractWorkerStore) = nothing` was a silent no-op fallback, so a backend that
forgot the method inherited "teardown succeeded" for free. The shipped `PormGWorkerStore` did
exactly that: `uninstall!` dispatched to the no-op, its cleanup scheduler kept issuing `DELETE`s
against `nitro_task`, and its queue processors kept blocking on `take!` after the app had
stopped. Every bootstrap/teardown cycle — tests, multi-app-per-process, a dev reload — leaked
another set.

The no-op is gone and `shutdown!` is part of the contract like every other store method.
`PormGWorkerStore` now implements it.

Two behaviour changes ride along, both to `InMemoryWorkerStore` as well:

- `shutdown!` now **empties** the sequential-queue registry rather than only closing each
  channel. A closed-but-present queue was handed straight back by `_get_or_create_queue`, so a
  store reused after shutdown threw on the next `submit_sequential_task`. Teardown is now total
  and a store can be shut down and started again.
- `reset_store!` no longer gates its whole body on `store isa InMemoryWorkerStore`, which had
  made it a complete no-op on a persistent store. It runs the teardown for every backend and
  keeps only the *discard the task records* step in-memory-specific — for a database-backed
  store those are durable rows, and deleting them on a reset would be destructive rather than a
  teardown. Persistent backends prune through `cleanup_tasks!`.

**If you use `PormGWorkerStore`, this is the part that may force an edit.** `uninstall!` and
`reset_store!` used to be no-ops on that store and now perform a real teardown, so restarting
**in the same process** while tasks are still running is no longer harmless. A run whose handle is
cleared looks dead to `recover_zombie_tasks!`, so the next `start!(recover_zombies=true)` marks it
`FAILED` and the real result is discarded when it finishes. That has always been true of
`InMemoryWorkerStore`; it is new for PormG only because PormG never tore down at all before.
`shutdown!` releases, it does not drain — nothing stops a running Julia task. If your app relies on
teardown/restart cycles in one process (a dev reload, several apps per process, a test suite that
calls `reset_store!` between cases), let in-flight tasks finish first, or start with
`recover_zombies=false`.

Cancellation is deliberately *not* affected: `PormGWorkerStore.shutdown!` leaves
`active_task_infos` populated, so `cancel_task` still reaches a run that survives a teardown, the
same way it does in memory.

### How to find the calls to migrate

```bash
grep -rn "<: AbstractWorkerStore" --include=*.jl .
```

For each custom store, check whether it defines `shutdown!`:

```julia
using Nitro.Workers
missing_store_methods(MyWorkerStore)   # :shutdown! in here means you owe a method
```

### Before → after

```julia
# BEFORE — nothing; the no-op fallback covered it
struct MyWorkerStore <: AbstractWorkerStore
    # ...
end

# AFTER — a store that owns background resources releases them
function Nitro.Workers.shutdown!(store::MyWorkerStore)
    Nitro.Workers._stop_scheduler_and_queues!(store)   # scheduler + queue channels, via the accessors
    lock(store.active_lock) do
        empty!(store.active_tasks)
    end
    return nothing
end

# AFTER — a store that genuinely owns nothing still says so out loud
Nitro.Workers.shutdown!(::MyWorkerStore) = nothing
```
