"""
    AbstractWorkerStore

The storage contract behind Nitro's worker queue. Two backends ship — [`InMemoryWorkerStore`](@ref)
and `PormGWorkerStore` (in `NitroPormGExt`) — and an application may add its own.

Every method below is **required**. Each has a fallback defined on this abstract type that raises
`StoreInterfaceError` naming the missing method, so an incomplete backend fails with a message
saying what to implement rather than a bare `MethodError` from deep inside task execution.
[`missing_store_methods`](@ref) lists what a type still owes and is the intended conformance check
for a backend's own test suite:

```julia
using Nitro.Workers    # the contract names are not re-exported from `Nitro`
@test isempty(missing_store_methods(MyWorkerStore))
```

# Durable task records

| Method | Contract |
|---|---|
| `get_task_info(store, task_id::String)` | `TaskInfo` or `nothing`; may serve a live object, see *Live objects* |
| `reload_task(store, task_id::String)` | `TaskInfo` or `nothing`, bypassing any in-process cache |
| `set_task!(store, task_id::String, task_info::TaskInfo)` | Write volatile state; must never write `watchers` or `run_id` |
| `replace_task!(store, task_id::String, task_info::TaskInfo)` | Write the whole record, `watchers` and `run_id` included |
| `add_watcher!(store, task_id::String, user_id::String)` | Atomic compare-and-set append, returns `Bool` |
| `try_transition!(store, task_id::String, from, to::TaskStatus; run_id, …)` | Atomic conditional status change, returns `Bool` |
| `delete_task!(store, task_id::String)` | Remove one record |
| `cleanup_tasks!(store, retain_days::Int)` | Prune finished records, returns how many went |
| `get_all_tasks(store, authority::TaskAuthority; status, queue_name)` | `Vector{TaskInfo}` |

# Process-local runtime handles

These describe one **run** on this process, never durable state, and must not be serialized.

| Method | Contract |
|---|---|
| `get_active_task(store, task_id::String)` | The running `Task`, or `nothing`. This is the whole zombie-recovery criterion |
| `register_active_task!(store, task_id::String, task::Task)` | Record the handle for the current run |
| `deregister_active_task!(store, task_id::String)` | Drop it — only the run that registered it may |
| `get_active_task_info(store, task_id::String)` | The live `TaskInfo` the callback holds, or `nothing` |
| `register_active_task_info!(store, task_id::String, task_info::TaskInfo)` | Publish that object |
| `deregister_active_task_info!(store, task_id::String)` | Drop it; a no-op is valid when the store has no such cache |

# Authorization hooks

Both are plain slots the application writes and the framework reads through `Base.invokelatest`.

| Method | Contract |
|---|---|
| `get_queue_authorizer(store)` / `set_queue_authorizer!(store, f)` | `f(queue_name::String, user_id::String)::Bool`, or `nothing` |
| `get_watch_authorizer(store)` / `set_watch_authorizer!(store, f)` | `f(task_key, watchers, user_id)::Bool`, or `nothing` |

# Queues, locking and lifecycle

| Method | Contract |
|---|---|
| `get_sequential_queues(store)` | The `Dict{String, SequentialQueue}` itself — callers mutate it in place |
| `get_queue_lock(store)` | The `ReentrantLock` guarding that dict |
| `get_cleanup_scheduler(store)` | An **assignable** `Ref{Union{Nothing, CleanupScheduler}}`; callers write through it |
| `lock_tasks(callback::Function, store)` | **Callback-first**, so it is called `lock_tasks(store) do … end` |

# Obligations that are not methods

- **Live objects.** `get_task_info` and `get_active_task_info` may return the very `TaskInfo` a
  running callback holds, and callers mutate it expecting other in-process readers to see the
  change. A store that reconstructs a fresh object on every read must mirror terminal writes onto
  the live one, or progress and cancellation stop propagating.
- **`run_id` round-trips, but `try_transition!` never writes it.** It is a precondition, not state.
- **`watchers` is populated on every read path.** Authorization reads it off whatever
  `get_task_info` and `reload_task` return, so a store that omits it silently denies everyone.
- **`lock_tasks` is process-local.** For a database-backed store it guards this process only, so
  never build a read-modify-write on it; express such a write as a single atomic store operation.

# `TaskInfo.error` is application-controlled free text

A failed task's `error` is rendered from the exception the **application's** callback threw. If that
callback interpolates user data into an exception message, that data reaches this store. Nitro
bounds the text and offers a redaction hook — see `set_error_redactor!` — but the store is where it
lands, so a backend that persists it is persisting attacker-influenceable input.
"""
abstract type AbstractWorkerStore end

# -- Storage and Registry interface functions (Abstract protocols) --
function get_task_info end

"""
    set_task!(store, task_id::String, task_info::TaskInfo)

Persist a task's **volatile runtime state**: status, progress, result, error, timestamps.

**It must not write `watchers` or `run_id`.** Neither is volatile state, and a store that
carries them along on every state transition loses them: `PormGWorkerStore` rewrote the whole row
on each save, so a task completing in one process clobbered a watcher another process had
appended since that process last read the row
([#88](https://github.com/PingoLee/Nitro.jl/issues/88)). State transitions are far more
frequent than watcher appends, so this was the dominant way a grant went missing.

`run_id` is excluded for a second, sharper reason: it is the precondition
[`try_transition!`](@ref) fences terminal writes with, so a `set_task!` that carried it would let a
re-run's identity be overwritten by whichever run wrote last — defeating the mechanism entirely
([#108](https://github.com/PingoLee/Nitro.jl/issues/108)).

Use [`add_watcher!`](@ref) to add a grant and [`replace_task!`](@ref) to write a whole
record, watchers and run id included.

The return value is **unspecified** — a store may return the caller's object or the record
it holds. Do not rely on it, and do not rely on it being the same across backends.
"""
function set_task! end

"""
    replace_task!(store, task_id::String, task_info::TaskInfo)

Write a task record **in full, `watchers` and `run_id` included**, replacing whatever is
stored.

The counterpart to [`set_task!`](@ref), and the only sanctioned way to reset a watcher
list — or to publish a new run's identity. There is exactly one caller: re-running a *finished* task key, which by documented
design replaces the record and resets its watchers to the resubmitter.

A store that cannot distinguish this from `set_task!` has not implemented `set_task!`
correctly — the whole point of the split is that ordinary saves leave grants alone.
"""
function replace_task! end

"""
    add_watcher!(store, task_id::String, user_id::String) -> Bool

Grant `user_id` watch access to `task_id`. Returns `true`, or `false` when no such task
exists. Idempotent.

**This is an atomic intent operation, and implementing it as read + `push!` + `set_task!`
defeats its purpose.** `_register_or_watch!` used to compose it exactly that way under
`lock_tasks`, which for a database-backed store is a *process-local* `ReentrantLock`: two
processes sharing one database each took their own and neither saw the other, so the
read-modify-write was last-write-wins and an append could vanish
([#88](https://github.com/PingoLee/Nitro.jl/issues/88)). A backend must make this a single
atomic step against its own storage — a compare-and-set, a conditional update, or a lock
the storage engine itself honours.

Performs **no** authorization. The authorized public path for granting access is the
`watchers=` keyword on `submit_task` / `submit_sequential_task`.
"""
function add_watcher! end

"""
    try_transition!(store, task_id::String, from, to::TaskStatus;
                    run_id, error=nothing, completed_at=nothing) -> Bool

Move `task_id` from any status in `from` to `to`, atomically. Returns `true` if this call
made the transition, `false` if the task was absent, had already left `from`, or belongs to a
run other than `run_id` — in which case **nothing was written**.

The compare-and-set counterpart to `set_task!` for the one write where losing the race
matters: cancellation. `cancel_task` used to read the status, decide, and then save the
whole record under `lock_tasks`; against a shared database that lock does not span
processes, so a task completing in one process could overwrite a cancellation another
process had just recorded ([#88](https://github.com/PingoLee/Nitro.jl/issues/88)).

`from` is any iterable of `TaskStatus`. Like `set_task!`, this must not write `watchers` or
`run_id` — it *compares* the latter, it never sets it.

It is not only for terminal states. **Starting** a task is a claimed transition too
(`(PENDING,) → RUNNING`, carrying `started_at`), because an unconditional start write can land
*after* a cancellation that already claimed the record and silently undo it
([#142](https://github.com/PingoLee/Nitro.jl/issues/142)).

# `run_id` — the precondition names a run, not just a status

A task id outlives the run writing under it. Re-running a finished key replaces the record with a
fresh `PENDING` one ([`replace_task!`](@ref)) while the previous run's worker task may still be in
flight; its terminal write then satisfies `status in (PENDING, RUNNING)` against a record it never
ran, and stamps its stale result onto the new run
([#108](https://github.com/PingoLee/Nitro.jl/issues/108)).

`run_id` is therefore **required, with no default**. Passing `nothing` is legal and means "no run
precondition — write whichever run owns the record", but you have to write it. A default would
rebuild the shape [#48](https://github.com/PingoLee/Nitro.jl/issues/48) removed: the unfenced call
would be the *shorter* one, and a new terminal-write call site that merely forgot the keyword would
be indistinguishable in review from one that meant to skip the fence.

A store that accepts `run_id` and ignores it is **not a conforming store** — it reintroduces #108
for its own backend, exactly as a store that reads the status and then saves reintroduces #88. An
un-updated third-party store fails loudly instead — but by a different route than you might expect,
so it is worth stating exactly.

A stale store whose `try_transition!` still takes the *other* keywords wins dispatch normally and
rejects `run_id` itself, with Julia's "does not support all of the given keyword arguments". A
stale store whose method has **no keyword parameters at all** is invisible to keyword dispatch —
Julia only considers methods that accept keywords — so the call reaches the contract fallback
instead. `store_contract_error` recognizes that the store did implement the method and raises a
`MethodError` carrying the positional arguments rather than mislabelling the backend as
unimplemented. Both routes throw; neither silently accepts a call that would reintroduce #108.

The second route's message is the one to be careful with. It cannot name `run_id`, because a
`MethodError` built from positional arguments has no keywords to report — and Julia appends *"This
error has been manually thrown, explicitly, so the method may exist but be intentionally marked as
unimplemented"* to any hand-built `MethodError`, which reads as a flat contradiction of the
situation: the method does exist, and the problem is a keyword it cannot accept. If you are
diagnosing one of these, check for a missing `run_id` parameter before believing that sentence.
"""
function try_transition! end

"""
    reload_task(store, task_id::String) -> Union{Nothing, TaskInfo}

Read the **durable** record, bypassing any in-process cache.

Distinct from [`get_task_info`](@ref), which is free to serve a live in-memory object for a
running task so callers see fresh progress without a round-trip. That cache is per process,
so its `watchers` can be stale the moment another process issues a grant — and an
authorization check that consults only the cache refuses a user who *is* authorized in the
durable record. Read paths therefore fall back to this before denying.

Used only on the denial path, so the common case still costs nothing.
"""
function reload_task end

function delete_task! end
function cleanup_tasks! end
function get_all_tasks end

# -- Active task / local runtime cache interface functions --
function get_active_task end
function register_active_task! end
function deregister_active_task! end
function get_active_task_info end
function register_active_task_info! end
function deregister_active_task_info! end

# -- Queue permission checks interface functions --
function get_queue_authorizer end
function set_queue_authorizer! end

# -- Cross-user task-key permission checks interface functions --
function get_watch_authorizer end

"""
    set_watch_authorizer!(store, authorizer)

Install the hook that decides whether a user may join or reuse a task key someone
else already owns, and return it.

    authorizer(task_key::String, watchers::Vector{String}, user_id::String)::Bool

Watcher membership is the only thing gating `get_task_status` and `cancel_task`, so
adding a watcher hands out the owner's read and cancel rights. Submitting a key that
already exists and that the caller does not already watch is therefore refused with
`AuthorizationError` unless this hook returns `true`. That covers both the live task
(joining it) and the finished one (replacing it, which discards the owner's result).

`watchers` is a copy, so mutating it has no effect.

**The hook runs while the store's task lock is held.** That lock also serializes
`set_task!`, `cancel_task`, and zombie recovery, so blocking in the hook stalls the whole
worker subsystem — make it a pure in-memory predicate over data the app already has.
Do not query a database from it, and never `fetch` a spawned task that touches the same
store: the child cannot take a `ReentrantLock` its parent holds, so that deadlocks.

**Re-running a finished key resets its watcher list to the submitter.** An authorized
reuse therefore drops the previous watchers, who must be re-authorized to rejoin. Hand out
long-lived ids for a shared task only if the app is prepared for that.

With `:user`-scoped keys (the default) this cannot trigger between two ordinary
callers, because their ids never collide. Set it when an app deliberately uses
`scope=:global` to share one expensive task across users.

```julia
# Resolve the sharing rule from data already in memory, not from a query.
set_watch_authorizer!(store, function(task_key, watchers, user_id)
    return ORG_OF[first(watchers)] == ORG_OF[user_id]
end)
```
"""
function set_watch_authorizer! end

# -- Stored-error redaction --

function get_error_redactor end

"""
    set_error_redactor!(store, redactor)

Install the hook that rewrites a failed task's error text before it is stored, and return it.

    redactor(exception, rendered::String)::String

A task's stored `error` is rendered from the exception the **application's** callback threw, and
exceptions quote their input. A callback that parses user-submitted data hands its parser's
`ArgumentError` the offending bytes, and those bytes land in the store — for `PormGWorkerStore`,
in a `TEXT` column, kept until the retention sweep removes the row
([#140](https://github.com/PingoLee/Nitro.jl/issues/140)).

Nitro cannot know which parts of an app's exception messages are sensitive, so it bounds the
text (see `MAX_STORED_ERROR_CHARS`) and offers this hook for the rest. `nothing`, the default,
means no redaction.

`rendered` is the **full** text, before truncation, so a redactor sees what it is deciding about
rather than a prefix. The cap is applied to whatever it returns, so a redactor cannot exceed it.

```julia
# Keep the exception type, drop everything it quoted.
set_error_redactor!(store, (exc, rendered) -> string(nameof(typeof(exc))))

# Or redact selectively, leaving ordinary failures diagnosable.
set_error_redactor!(store, function(exc, rendered)
    exc isa MyApp.UserDataError ? "UserDataError (details withheld)" : rendered
end)
```

The hook runs on the failure path of a task that has already failed, so a redactor that throws
must not lose the failure as well: Nitro catches it, logs that it threw **without the text it
was handed**, and stores the exception type alone.

Like the authorizer hooks, this is invoked through `Base.invokelatest`, so a redactor defined
after the worker started is still seen.
"""
function set_error_redactor! end

# -- Queue management helper functions --
function get_sequential_queues end
function get_queue_lock end

# -- Lifecycle --

"""
    shutdown!(store)

Release everything the store owns on this process: stop its cleanup scheduler, close its
sequential-queue channels, and drop its process-local runtime handles.

**Required, not an optional extra.** This used to have a no-op fallback on
`AbstractWorkerStore`, and `PormGWorkerStore` never overrode it — so `uninstall!` on a
PormG-backed app dispatched to the no-op and the scheduler kept issuing DB `DELETE`s while
queue processors kept blocking on `take!`, after the app had stopped
([#29](https://github.com/PingoLee/Nitro.jl/issues/29)). Every bootstrap/teardown cycle
leaked another set. A backend that genuinely owns nothing still has to say so, with
`shutdown!(::MyStore) = nothing`; the point is that it is written down rather than inherited
by accident.

Most of the work is backend-independent and lives in [`_stop_scheduler_and_queues!`](@ref),
which reaches everything it needs through the contract accessors. An implementation is
usually that call plus clearing whatever active-task caches the store itself holds.

Called by `uninstall!` and `reset_store!`.

# This releases; it does not drain

`shutdown!` does not wait for runs still executing, and nothing can stop them — a Julia task
cannot be killed, which is why cancellation here is a token a callback polls. What it does do is
clear the process-local handle caches, and that has a consequence worth knowing before relying on
teardown-then-restart *within one process* (a dev reload, or several apps sharing a process):

`recover_zombie_tasks!` decides liveness purely from `get_active_task(store, id)`. Clearing the
handle cache therefore makes a run that is still executing look dead, so the next
`start!(recover_zombies=true)` marks it `FAILED`; when the real callback finishes, its run-fenced
terminal write loses against that record and the result is discarded.

That consequence is **parity, not a regression**: `InMemoryWorkerStore` has always emptied
`active_tasks` in `shutdown!`, and
[#29](https://github.com/PingoLee/Nitro.jl/issues/29) asked for a backend that behaves like it.
Closing it means a graceful drain — waiting for, or re-registering, in-flight runs — which is a
design change rather than a teardown fix. Until then, treat a restart in the same process as
unsafe for tasks that are still running.

Cancellation is a **separate** question, and the answer there is the opposite, which is why the
two must not be stated together. `cancel_task` resolves the live `TaskInfo` through
`get_active_task_info`, and the in-memory store answers that from `task_registry`, which
`shutdown!` does *not* empty — so cancellation survives an in-memory teardown. Any backend keeping
a distinct live-object cache must therefore leave it alone in `shutdown!`, or it becomes the only
store on which a surviving run cannot be cancelled. `PormGWorkerStore` does exactly that.
"""
function shutdown! end

# -- Cleanup and Locking helper functions --
function get_cleanup_scheduler end
function lock_tasks end

# ============================================================================
# The contract, as data
# ============================================================================

"""
    WORKER_STORE_INTERFACE

The [`AbstractWorkerStore`](@ref) contract as data: one row per required method, holding the
function and its **documented** positional argument types, with `AbstractWorkerStore` standing in
the store slot.

Two consumers read it and must not drift apart — the fallback methods generated directly below, and
[`missing_store_methods`](@ref). Adding a method to the contract means adding a row here; nothing
else.

The types here document the contract and fix each method's **arity** and store position; the
generated fallbacks widen every non-store parameter to `Any`. That widening is not laziness. A
fallback pinned to these exact types is *ambiguous* with a backend that types one of its own
parameters more loosely — `(::MyStore, ::AbstractString)` against a contract that says `::String`,
which is how Nitro's own public API is written — and Julia may then resolve the call to the
fallback rather than to the store's method. The imprecision that widening costs is bought back at
runtime by `store_contract_error`, which tells a missing backend method apart from a caller who
passed the wrong argument.
"""
const WORKER_STORE_INTERFACE = (
    # -- Durable task records --
    (get_task_info,                 (AbstractWorkerStore, String)),
    (reload_task,                   (AbstractWorkerStore, String)),
    (set_task!,                     (AbstractWorkerStore, String, TaskInfo)),
    (replace_task!,                 (AbstractWorkerStore, String, TaskInfo)),
    (add_watcher!,                  (AbstractWorkerStore, String, String)),
    (try_transition!,               (AbstractWorkerStore, String, Any, TaskStatus)),
    (delete_task!,                  (AbstractWorkerStore, String)),
    (cleanup_tasks!,                (AbstractWorkerStore, Int)),
    (get_all_tasks,                 (AbstractWorkerStore, TaskAuthority)),
    # -- Process-local runtime handles --
    (get_active_task,               (AbstractWorkerStore, String)),
    (register_active_task!,         (AbstractWorkerStore, String, Task)),
    (deregister_active_task!,       (AbstractWorkerStore, String)),
    (get_active_task_info,          (AbstractWorkerStore, String)),
    (register_active_task_info!,    (AbstractWorkerStore, String, TaskInfo)),
    (deregister_active_task_info!,  (AbstractWorkerStore, String)),
    # -- Authorization hooks --
    (get_queue_authorizer,          (AbstractWorkerStore,)),
    (set_queue_authorizer!,         (AbstractWorkerStore, Any)),
    (get_watch_authorizer,          (AbstractWorkerStore,)),
    (set_watch_authorizer!,         (AbstractWorkerStore, Any)),
    # -- Queues, locking and lifecycle --
    (get_sequential_queues,         (AbstractWorkerStore,)),
    (get_queue_lock,                (AbstractWorkerStore,)),
    (get_cleanup_scheduler,         (AbstractWorkerStore,)),
    (lock_tasks,                    (Function, AbstractWorkerStore)),
    (get_error_redactor,            (AbstractWorkerStore,)),
    (set_error_redactor!,           (AbstractWorkerStore, Any)),
    (shutdown!,                     (AbstractWorkerStore,)),
)

_store_arg_index(argtypes) = something(findfirst(T -> T === AbstractWorkerStore, argtypes))

# Generate one fallback per row: the store slot typed at the abstract type, every other parameter
# widened to `Any` so a backend's own method is strictly more specific in every slot and can never
# be ambiguous with this one. See `store_contract_error` for why the width is required and how the
# precision is recovered.
#
# `kwargs...` is accepted and ignored on purpose. It never swallows a keyword mistake: a store that
# defines the method at all is more specific on the positional arguments, so it is the one that
# gets to reject the keyword.
for (f, argtypes) in WORKER_STORE_INTERFACE
    local idx = _store_arg_index(argtypes)
    local names = [Symbol("a", i) for i in eachindex(argtypes)]
    local params = [i == idx ? Expr(:(::), names[i], AbstractWorkerStore) : names[i]
                    for i in eachindex(argtypes)]
    @eval @noinline function $(nameof(f))($(params...); kwargs...)
        store_contract_error($f, AbstractWorkerStore, $idx, $(names...))
    end
end

"""
    missing_store_methods(S::Type{<:AbstractWorkerStore}) -> Vector{Symbol}

The [`AbstractWorkerStore`](@ref) methods `S` has not implemented, in contract order. Empty means
`S` is conforming.

This is the conformance check a backend runs in its own test suite. It uses no test framework on
purpose, so it ships with the package and costs a third-party store nothing to call:

```julia
@test isempty(missing_store_methods(MyWorkerStore))
```

A name appears here when `S` contributed no method of its own for it. It answers about a *type*, so
it runs at load time, in a test, or in a REPL, without constructing a store.

It asks about presence, not signature compatibility — see `implements_contract_method` for why
checking the exact call signature is the less useful question.
"""
function missing_store_methods(S::Type{<:AbstractWorkerStore})
    names = Symbol[]
    for (f, argtypes) in WORKER_STORE_INTERFACE
        idx = _store_arg_index(argtypes)
        if !implements_contract_method(f, S, AbstractWorkerStore, idx)
            push!(names, nameof(f))
        end
    end
    return names
end

# ============================================================================
# InMemoryWorkerStore Implementation
# ============================================================================

mutable struct InMemoryWorkerStore <: AbstractWorkerStore
    task_registry::Dict{String, TaskInfo}
    task_lock::ReentrantLock
    sequential_queues::Dict{String, SequentialQueue}
    queue_lock::ReentrantLock
    cleanup_scheduler::Ref{Union{Nothing, CleanupScheduler}}
    active_tasks::Dict{String, Task}
    active_lock::ReentrantLock
    queue_authorizer::Ref{Any}
    watch_authorizer::Ref{Any}
    error_redactor::Ref{Any}

    function InMemoryWorkerStore()
        return new(
            Dict{String, TaskInfo}(),
            ReentrantLock(),
            Dict{String, SequentialQueue}(),
            ReentrantLock(),
            Ref{Union{Nothing, CleanupScheduler}}(nothing),
            Dict{String, Task}(),
            ReentrantLock(),
            Ref{Any}(nothing),
            Ref{Any}(nothing),
            Ref{Any}(nothing),
        )
    end
end

# -- Implement interface methods for InMemoryWorkerStore --

function get_task_info(store::InMemoryWorkerStore, task_id::String)
    lock(store.task_lock) do
        return get(store.task_registry, task_id, nothing)
    end
end

function set_task!(store::InMemoryWorkerStore, task_id::String, task_info::TaskInfo)
    lock(store.task_lock) do
        existing = Base.get(store.task_registry, task_id, nothing)
        # Callers almost always save the very object they read, so there is nothing to
        # reconcile and the record simply stands.
        if existing === nothing || existing === task_info
            store.task_registry[task_id] = task_info
            return task_info
        end

        # A different object: copy the volatile state across and keep the *stored*
        # record's watchers, run_id AND cancel_requested — precisely what the serializing
        # store achieves by omitting those columns. The list below is otherwise "copy every
        # field", so those three absences ARE the rule.
        #
        # `run_id` is the value `try_transition!` fences on, so copying it off a caller's
        # object would let a stale run adopt the current run's identity (#108).
        # `cancel_requested` is worse: a stale object still carrying `false` would ERASE a
        # cancel already requested, which is the #88 watcher clobber with the sign flipped
        # (#127). The caller's object is left untouched, so both backends agree on
        # that too; a rule honoured by only one of them is a store that silently behaves
        # differently, which for this pair means a different security posture.
        existing.status = task_info.status
        @atomic existing.progress = task_info.progress
        existing.result = task_info.result
        existing.error = task_info.error
        existing.created_at = task_info.created_at
        existing.started_at = task_info.started_at
        existing.completed_at = task_info.completed_at
        existing.sys_task = task_info.sys_task
        existing.queue_name = task_info.queue_name
        return existing
    end
end

function replace_task!(store::InMemoryWorkerStore, task_id::String, task_info::TaskInfo)
    lock(store.task_lock) do
        store.task_registry[task_id] = task_info
    end
    return task_info
end

function add_watcher!(store::InMemoryWorkerStore, task_id::String, user_id::String)
    lock(store.task_lock) do
        task_info = Base.get(store.task_registry, task_id, nothing)
        task_info === nothing && return false
        # Mutating the registered object *is* the store write — no round-trip, and so
        # no window between the mutation and its publication.
        user_id in task_info.watchers || push!(task_info.watchers, user_id)
        return true
    end
end

function try_transition!(store::InMemoryWorkerStore, task_id::String, from, to::TaskStatus;
                         run_id::Union{Nothing, UUID},
                         error::Union{Nothing, String}=nothing,
                         completed_at::Union{Nothing, DateTime}=nothing,
                         started_at::Union{Nothing, DateTime}=nothing,
                         result=UNSUPPLIED,
                         progress::Union{Nothing, Real}=nothing)
    lock(store.task_lock) do
        task_info = Base.get(store.task_registry, task_id, nothing)
        task_info === nothing && return false
        task_info.status in from || return false
        # The run fence. `nothing` is the named opt-out, never a default (#108).
        run_id === nothing || task_info.run_id == run_id || return false

        error === nothing || (task_info.error = error)
        completed_at === nothing || (task_info.completed_at = completed_at)
        started_at === nothing || (task_info.started_at = started_at)
        result === UNSUPPLIED || (task_info.result = result)
        progress === nothing || (@atomic task_info.progress = Float64(progress))
        task_info.status = to        # last, so no reader sees the new status early
        return true
    end
end

# Nothing is cached: the registry *is* the durable record.
reload_task(store::InMemoryWorkerStore, task_id::String) = get_task_info(store, task_id)

function delete_task!(store::InMemoryWorkerStore, task_id::String)
    lock(store.task_lock) do
        delete!(store.task_registry, task_id)
    end
    return nothing
end

function cleanup_tasks!(store::InMemoryWorkerStore, retain_days::Int)
    cutoff = current_time_utc() - Dates.Day(retain_days)
    removed = String[]

    lock(store.task_lock) do
        for (task_id, task_info) in store.task_registry
            if task_info.completed_at !== nothing && task_info.completed_at < cutoff && task_info.status in (COMPLETED, FAILED, CANCELLED)
                push!(removed, task_id)
            end
        end

        for task_id in removed
            delete!(store.task_registry, task_id)
        end
    end

    return length(removed)
end

function get_all_tasks(store::InMemoryWorkerStore, authority::TaskAuthority; status::Union{Nothing, TaskStatus}=nothing, queue_name::Union{Nothing, String}=nothing)
    lock(store.task_lock) do
        tasks = TaskInfo[]
        for task_info in values(store.task_registry)
            if status !== nothing && task_info.status != status
                continue
            end
            # Deliberately no owner -> ids index: the registry is already in RAM, so this
            # is a Dict scan either way, and an index would be new mutable state to keep
            # consistent across set_task!, delete_task!, cleanup_tasks! and reset_store!.
            _is_authorized(authority, task_info) || continue
            if queue_name !== nothing && task_info.queue_name != queue_name
                continue
            end
            push!(tasks, task_info)
        end
        return tasks
    end
end

function get_active_task(store::InMemoryWorkerStore, task_id::String)
    lock(store.active_lock) do
        return get(store.active_tasks, task_id, nothing)
    end
end

function get_active_task_info(store::InMemoryWorkerStore, task_id::String)
    return get_task_info(store, task_id)
end

function register_active_task!(store::InMemoryWorkerStore, task_id::String, task::Task)
    lock(store.active_lock) do
        store.active_tasks[task_id] = task
    end
    lock(store.task_lock) do
        task_info = get(store.task_registry, task_id, nothing)
        if task_info !== nothing
            task_info.sys_task = task
        end
    end
    return task
end

function register_active_task_info!(store::InMemoryWorkerStore, task_id::String, task_info::TaskInfo)
    return set_task!(store, task_id, task_info)
end

function deregister_active_task!(store::InMemoryWorkerStore, task_id::String)
    lock(store.active_lock) do
        delete!(store.active_tasks, task_id)
    end
    lock(store.task_lock) do
        task_info = get(store.task_registry, task_id, nothing)
        if task_info !== nothing
            task_info.sys_task = nothing
        end
    end
    return nothing
end

function deregister_active_task_info!(store::InMemoryWorkerStore, task_id::String)
    return nothing
end

function get_queue_authorizer(store::InMemoryWorkerStore)
    return store.queue_authorizer[]
end

function set_queue_authorizer!(store::InMemoryWorkerStore, authorizer)
    store.queue_authorizer[] = authorizer
    return authorizer
end

function get_error_redactor(store::InMemoryWorkerStore)
    return store.error_redactor[]
end

function set_error_redactor!(store::InMemoryWorkerStore, redactor)
    store.error_redactor[] = redactor
    return redactor
end

function get_watch_authorizer(store::InMemoryWorkerStore)
    return store.watch_authorizer[]
end

function set_watch_authorizer!(store::InMemoryWorkerStore, authorizer)
    store.watch_authorizer[] = authorizer
    return authorizer
end

function get_sequential_queues(store::InMemoryWorkerStore)
    return store.sequential_queues
end

function get_queue_lock(store::InMemoryWorkerStore)
    return store.queue_lock
end

function get_cleanup_scheduler(store::InMemoryWorkerStore)
    return store.cleanup_scheduler
end

function lock_tasks(callback::Function, store::InMemoryWorkerStore)
    return lock(store.task_lock) do
        callback()
    end
end

# -- Core extension management (App integration) --

const DEFAULT_STORE = Ref(InMemoryWorkerStore())

default_store() = DEFAULT_STORE[]

function worker_store(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY)
    return get_extension(ctx, key, nothing)
end

function install!(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY, store::AbstractWorkerStore=InMemoryWorkerStore())
    return set_extension!(ctx, key, store)
end

function uninstall!(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY)
    store = worker_store(ctx; key)
    if store isa AbstractWorkerStore
        shutdown!(store)
    end
    delete_extension!(ctx, key)
    return nothing
end

"""
    _stop_scheduler_and_queues!(store)

The backend-independent half of [`shutdown!`](@ref), written entirely against the contract
accessors so every store inherits it instead of copying it.

Stops the cleanup scheduler and clears its `Ref`, then closes every sequential queue's channel
and clears the queue registry. Closing the channel is the stop signal for a queue processor:
its `take!` throws `InvalidStateException`, which the processor loop catches and breaks on.

**The queue dict is emptied, not just drained.** A queue whose channel is closed is dead, but
`_get_or_create_queue` uses `get!` — so leaving the entry behind means a store reused after
shutdown hands back the dead queue, spawns a processor that immediately breaks, and then throws
on `put!`. Emptying makes the teardown total, so a store can be shut down and started again.
"""
function _stop_scheduler_and_queues!(store::AbstractWorkerStore)
    scheduler_ref = get_cleanup_scheduler(store)
    scheduler = scheduler_ref[]
    if !isnothing(scheduler)
        stop_cleanup_scheduler!(scheduler)
        scheduler_ref[] = nothing
    end

    lock(get_queue_lock(store)) do
        queues = get_sequential_queues(store)
        for queue in values(queues)
            if isopen(queue.channel)
                close(queue.channel)
            end
            queue.running = false
            queue.current_task = nothing
            queue.processor_task = nothing
        end
        empty!(queues)
    end

    return nothing
end

function shutdown!(store::InMemoryWorkerStore)
    _stop_scheduler_and_queues!(store)

    lock(store.active_lock) do
        empty!(store.active_tasks)
    end

    return nothing
end

"""
    reset_store!(store = default_store()) -> store

Tear the store down and discard its task records, returning it to a freshly-constructed state.

[`shutdown!`](@ref) does the process-local half — scheduler, queue channels, active-task caches
— for every backend. What stays conditional here is discarding the task records themselves,
because only a volatile store *has* records to discard: for a database-backed store the registry
is durable rows that outlive the process, and wiping them on a reset would be a destructive
delete of live data rather than a teardown. A persistent backend prunes through
`cleanup_tasks!`, on its own retention policy.

This used to gate the whole body on `store isa InMemoryWorkerStore`, which — combined with
`shutdown!` having a silent no-op fallback — made `reset_store!` on a PormG store a complete
no-op that returned the store unchanged ([#29](https://github.com/PingoLee/Nitro.jl/issues/29)).
"""
function reset_store!(store::AbstractWorkerStore=default_store())
    shutdown!(store)

    if store isa InMemoryWorkerStore
        lock(store.task_lock) do
            empty!(store.task_registry)
        end
    end

    return store
end
