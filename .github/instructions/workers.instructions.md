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
- **Queue authorization hooks**: Optional `queue_authorizer(queue_name, user_id)::Bool`, consulted on
  **both** submit paths — `submit_task` has no sequential queue, so it passes `DEFAULT_QUEUE_NAME`.
- **Watch authorization hooks**: Optional `watch_authorizer(task_key, watchers, user_id)::Bool`,
  consulted only when a caller submits a key that already exists and that they do not already watch.
- **Watchers**: Task submissions register the submitting `user_id` as a watcher. Read/manage APIs validate watcher access when `user_id` is supplied. Watcher membership is the *only* gate on reading a
  result and cancelling, so it is never granted implicitly — see §2.

## 2. Task API

**Every task API takes a required `TaskAuthority`.** `Owner("user_123")` is a validated identity;
`System()` is the explicit, unscoped bypass. There is no arity that omits it — a call that forgets
to scope is a `MethodError`, not a silent bypass
([#48](https://github.com/PingoLee/Nitro.jl/issues/48)). Never re-introduce an optional or
defaulted authority argument, and never let a `String` stand in for one: `user_id=nothing` **and**
`user_id=""` were both full bypasses, and the empty-string case was reachable by reading a missing
claim into an empty string.

**The submit call returns the id, and it is not the `task_key` you passed.** Task ids double as
deduplication keys, so `scope` decides who can collide with whom
([#19](https://github.com/PingoLee/Nitro.jl/issues/19)).

```julia
# scope=:user (the default) — id is "user_123::report_42"; no cross-user collision is possible
task_id = submit_task("report_42", () -> work(), Owner("user_123"))
task = get_task_status(task_id, Owner("user_123"))
cancel_task(task_id, Owner("user_123"))
user_tasks = get_all_tasks(Owner("user_123"))

# Rebuild the id when the return value was not kept
task_id == scoped_task_key("report_42", Owner("user_123"))

# scope=:global — verbatim key, system-wide dedup. A caller who is not already a watcher is
# refused (AuthorizationError) whether the task is live or finished, unless a watch authorizer
# allows it. Finished counts: replacing the record would discard the owner's result.
shared = submit_task("warm-cache", () -> work(), Owner("user_123"); scope=:global)

# The bypass, only when the app intentionally allows it — and greppable because it is named:
public_status = get_task_status(task_id, System())
```

**Authority comes from the id; `watchers` only adds to it.** `owner_of(id)` reads the owner half
back out of a `:user` id, so ownership is derived and unclobberable — a lost watcher append or a
full-row write from another process cannot evict an owner from their own task. A `:global` id has
no owner half, so for those `watchers` remains the entire gate, including for the creator. Keep
that asymmetry: it is what makes deriving ownership purely additive.

Never hand-build a scoped id by string concatenation. `Owner` rejects a `user_id` that is empty,
contains `::`, **or ends in `:`**, and `scoped_task_key` rejects a `:global` `task_key` that
contains `::`. Those rules together are what make `(user, key) → id` injective, keep the two
scopes' id spaces disjoint, and make `owner_of` a total inverse; drop any one and two distinct
pairs collide.

### Reporting progress — never assign the field

`TaskInfo.progress` is declared `@atomic`. Plain assignment from a callback throws
`ConcurrencyViolationError`:

```julia
# ✗ throws — violates the @atomic field
task_info.progress = 50

# ✓ the only supported write
update_progress!(task_info, 50)     # 0–100 scale, returns the task
```

The workers tutorial used to show the assignment form
([#54](https://github.com/PingoLee/Nitro.jl/issues/54)); it was corrected alongside the #19 fix. Do
not copy the assignment form from anywhere it survives, and fix it where you find it.

### The rest of the exported surface

`Workers` exports considerably more than the four functions above. The ones worth knowing before
you add anything:

| API | Purpose |
|-----|---------|
| `submit_sequential_task`, `SequentialQueue` | Ordered, one-at-a-time execution within a queue |
| `scoped_task_key`, `DEFAULT_QUEUE_NAME` | Resolve a `(task_key, user_id, scope)` to its stored id; the queue name `submit_task` authorizes against |
| `get_queue_status` | Queue-wide introspection — **admin only**, takes `System()`; an `Owner` is a `MethodError` |
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

## 4. Queue And Watch Authorization

Two independent store hooks. Both are `Ref{Any}` slots invoked through `Base.invokelatest`; a
`nothing` authorizer disables the queue check and **denies** every cross-user watch.

```julia
# Gates submission. Runs on both submit paths — submit_task passes DEFAULT_QUEUE_NAME
# ("default"), so an allowlist authorizer must permit it or submit_task is closed to everyone.
function my_queue_authorizer(queue_name::String, user_id::String)::Bool
    queue_name == "maintenance" && return user_id == "admin-user"
    return true
end
set_queue_authorizer!(persistent_store, my_queue_authorizer)

# Gates joining or reusing an existing key the caller does not already watch.
# `watchers` is a copy. The hook runs under the store's task lock, which also
# serializes set_task!, cancel_task, and zombie recovery — so make it a pure
# in-memory predicate. No DB queries, and never `fetch` a spawned task that
# touches the same store: the child cannot take a ReentrantLock its parent
# holds, so that deadlocks.
set_watch_authorizer!(persistent_store, function(task_key, watchers, user_id)
    return ORG_OF[first(watchers)] == ORG_OF[user_id]
end)
```

The hook is store-wide, not per-scope: it fires on *any* collision with an existing key.
In practice the id rules above make that unreachable for `:user` ids — a foreign caller
cannot produce one — so it governs `:global` keys and app-written records only. Re-running
a finished key replaces the record, so its watcher list resets to the submitter and
previously-authorized sharers must be re-approved.

A new backend must implement `get_watch_authorizer` / `set_watch_authorizer!` alongside the queue
pair — see §6.

## 5. Zombie Task Recovery

On startup, `RUNNING` tasks without a live in-memory `Task` are marked `FAILED` when `recover_zombies=true`.

## 6. Developer Rules

> **Strict core isolation**: Never import `PormG` or run DB queries in `src/Workers`. Database logic belongs in `ext/NitroPormGExt.jl`.

- Add abstract stubs in `src/Workers/registry.jl`.
- Implement in `InMemoryWorkerStore` **and** `PormGWorkerStore` — a hook implemented in only one of
  them is a store that silently behaves differently, which for the authorizer pair means a silently
  different security posture.
- **Never serialize running `Task` objects** to the database.
