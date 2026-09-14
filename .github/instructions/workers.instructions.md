---
description: Workers module — persistent stores, user_id/watchers, queue authorizers, zombie recovery
applyTo: "src/Workers/**/*.jl,ext/NitroPormGExt.jl,test/**/*worker*.jl,test/extensions/**/*.jl"
---

# Nitro.jl Workers Module

This rule applies when changing the Workers queue, `NitroPormGExt` worker storage, or worker tests.

## 1. Context & Architecture

The worker system supports both volatile in-memory queues and persistent database stores with access control.

### Two objects: the store and the runtime

Split in [#167](https://github.com/PingoLee/Nitro.jl/issues/167). One question decides which one a
change belongs to: **the store answers *"what does the record say?"*; the runtime answers *"what is
this process doing right now?"***.

- **`AbstractWorkerStore`** (`src/Workers/registry.jl`): data access plus policy hooks, 15 required
  methods. It owns **nothing that runs** — no queue, no scheduler, no `Task` handle — which is what
  makes the #29 leak unrepresentable rather than merely fixed.
- **`WorkerRuntime`** (`src/Workers/runtime.jl`): the sequential queues and their processor tasks,
  the cleanup scheduler, and `active_tasks` / `active_task_infos`. `shutdown!` takes one. It is
  parametric on the store type so `rt.store` stays concrete.
- **One store may back several runtimes.** Two `App`s over one `PormGWorkerStore` get their own
  queues and scheduler, and `uninstall!` on one cannot stop the other's processors. Policy stays on
  the store, so they correctly share one security posture.
- **`InMemoryWorkerStore`**: Volatile, thread-safe store in `src/Workers/registry.jl`. Its records
  *are* the objects callbacks hold, so it is the one backend that implements `clear_records!`.
- **`PormGWorkerStore`**: Persistent store in `ext/NitroPormGExt.jl`.
- **Volatile execution handles**: running `Task` objects and the live `TaskInfo` cache live on the
  **runtime**, in `active_tasks` / `active_task_infos`. Entries are keyed by task id but describe one
  **run** — only the run that registered one may tear it down (see §6).
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

**Grant a second identity at submit time, never after.** `submit_task(...; watchers=[Owner("svc")])`
is the supported way to let a different identity poll or cancel a task
([#96](https://github.com/PingoLee/Nitro.jl/issues/96)) — the owner is already resolved and
authorized there, so no second authorization question arises. Do not add a public post-hoc
`add_watcher!(task_id, ...)`: that would be a second route into the watcher list, which is the
surface [#19](https://github.com/PingoLee/Nitro.jl/issues/19) closed. The store-level
`add_watcher!` performs no authorization and is not that API. A grantee gets read, list **and**
cancel, because `cancel_task` gates on the same list.

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
| `shutdown!`, `reset_runtime!` | Teardown — takes a `WorkerRuntime`, never a store |
| `WorkerRuntime`, `default_runtime`, `worker_runtime`, `install!`, `uninstall!`, `worker_store`, `default_store` | Lifecycle and resolution |

**`runtime=` is the public keyword; `store=` only selects a backend.** Every read and submit call
takes `runtime::WorkerRuntime=default_runtime()`, or resolves one from an `App` first argument.
`store=` survives on exactly four entry points — `install!`, `start!`, `startup`, `worker_startup`
— because that is where a backend is *chosen*. A `store=` on a submission call would be a lie: a
store cannot run anything.

**A new backend implements no teardown method at all.** `shutdown!` is a concrete method on
`WorkerRuntime`, so there is no fallback to forget — which is what closes
[#29](https://github.com/PingoLee/Nitro.jl/issues/29) as a *class* rather than an instance. Two
optional store methods exist, both no-op by default: `clear_records!` (volatile backends only;
`reset_runtime!` calls it, and the default must stay a no-op so a reset can never delete durable
rows) and nothing else.

**`get_task_info(store, id)` is the DURABLE read.** A store must not cache live objects. Serving a
running callback's own object to a reader is `get_task_info(runtime, id)`, and the split is
load-bearing: run-start reads durably, because a live-preferring read there hands a re-run its
predecessor's `TaskInfo` and the `run_id` fence then strands it at `PENDING` forever. That was a
real `PormGWorkerStore` defect (#167). The rule: **a call about to *claim* a run reads the store; a
call that is *reporting* reads the runtime.**

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

- **`lock_tasks` is process-local, so never build a read-modify-write on it.** For a
  database-backed store it is a plain `ReentrantLock` in the struct: two processes sharing one
  database each take their own and neither sees the other
  ([#88](https://github.com/PingoLee/Nitro.jl/issues/88)). A write that must not lose a concurrent
  update belongs in the store as a single atomic *intent* operation — `add_watcher!` (a
  compare-and-set on the stored document) and `try_transition!` (a conditional status change) are
  the pattern. Composing `get_task_info` + mutate + `set_task!` under the lock is exactly the bug.
- **`set_task!` writes state; `replace_task!` writes the whole record.** `set_task!` must never
  write `watchers` **or `run_id`** — neither is volatile state, and carrying them on every
  transition is how grants got clobbered. `replace_task!` has exactly one caller: re-running a
  finished key, which by design resets the watcher list and publishes the new run's identity.
- **A terminal write is addressed to a RUN, not to a task id.** A task id outlives the run writing
  under it: re-running a finished key builds a fresh record while the previous run may still be in
  flight, and a status-only precondition cannot tell the two apart
  ([#108](https://github.com/PingoLee/Nitro.jl/issues/108)). `try_transition!` therefore takes a
  **required** `run_id` — `nothing` is the named opt-out, never a default — and so does the runtime
  handle teardown: only the run that owns the runtime's `active_tasks[id]` may deregister it,
  because `recover_zombie_tasks!` reads liveness from exactly that entry. One `TaskInfo` object is
  one run; a re-run is a new object, never a mutated one.
- **`shutdown!` releases; it does not drain.** It drops the run handles without waiting, so a run
  still executing across a teardown/restart in one process looks dead to `recover_zombie_tasks!`.
  `active_task_infos` is deliberately left populated, or such a run would also be uncancellable.
  A graceful drain is now *buildable* — the object that owns the tasks is the object being shut
  down — but it is a separate lifecycle decision, not a teardown patch.
- Add abstract stubs in `src/Workers/registry.jl` — **for data and policy only.** Anything that
  runs, schedules, or holds a `Task` belongs on `WorkerRuntime`, where there is one implementation
  and no way for a backend to get it wrong.
- Implement in `InMemoryWorkerStore` **and** `PormGWorkerStore` — a hook implemented in only one of
  them is a store that silently behaves differently, which for the authorizer pair means a silently
  different security posture. Assert cross-backend parity in a shared test body rather than by
  inspection: #166's cancellation regression came from two backends whose live-object handling
  looked equivalent and was not.
- **Nothing may inject an exception into a worker task.** `schedule(t, exc; error=true)` does
  not check whether `t` is running, and injecting into a task executing on another thread aborts
  the process in `jl_finish_task` — which is what blocked worker bodies from moving to
  `Threads.@spawn` ([#127](https://github.com/PingoLee/Nitro.jl/issues/127),
  [#30](https://github.com/PingoLee/Nitro.jl/issues/30)). Cancellation is a **token** the callback
  polls (`cancel_requested`), set by `cancel_task` and by an expired `TaskOptions(timeout=…)`.
  Never reintroduce the injection, and do not add a public setter for the token: `cancel_task` is
  the authorized path, and a second route into it would bypass both the authorization check and
  the status CAS. The token is process-local and never reset — a re-run gets a fresh `TaskInfo`.
- **A timeout bounds the wait, not the work, and is never retried.** Nothing stops the attempt
  that timed out, so retrying it runs a second copy of the callback beside the first against one
  `task_info`. `TaskTimeoutError` is terminal on the first attempt.
- **Never serialize running `Task` objects** to the database.
