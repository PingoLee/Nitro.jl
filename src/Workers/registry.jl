abstract type AbstractWorkerStore end

# -- Storage and Registry interface functions (Abstract protocols) --
function get_task_info end

"""
    set_task!(store, task_id::String, task_info::TaskInfo)

Persist a task's **volatile runtime state**: status, progress, result, error, timestamps.

**It must not write `watchers`.** Grants are not volatile state, and a store that carries
them along on every state transition loses them: `PormGWorkerStore` rewrote the whole row
on each save, so a task completing in one process clobbered a watcher another process had
appended since that process last read the row
([#88](https://github.com/PingoLee/Nitro.jl/issues/88)). State transitions are far more
frequent than watcher appends, so this was the dominant way a grant went missing.

Use [`add_watcher!`](@ref) to add a grant and [`replace_task!`](@ref) to write a whole
record, watchers included.
"""
function set_task! end

"""
    replace_task!(store, task_id::String, task_info::TaskInfo)

Write a task record **in full, `watchers` included**, replacing whatever is stored.

The counterpart to [`set_task!`](@ref), and the only sanctioned way to reset a watcher
list. There is exactly one caller: re-running a *finished* task key, which by documented
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
                    error=nothing, completed_at=nothing) -> Bool

Move `task_id` from any status in `from` to `to`, atomically. Returns `true` if this call
made the transition, `false` if the task was absent or had already left `from` — in which
case **nothing was written**.

The compare-and-set counterpart to `set_task!` for the one write where losing the race
matters: cancellation. `cancel_task` used to read the status, decide, and then save the
whole record under `lock_tasks`; against a shared database that lock does not span
processes, so a task completing in one process could overwrite a cancellation another
process had just recorded ([#88](https://github.com/PingoLee/Nitro.jl/issues/88)).

`from` is any iterable of `TaskStatus`. Like `set_task!`, this must not write `watchers`.
"""
function try_transition! end

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

# -- Queue management helper functions --
function get_sequential_queues end
function get_queue_lock end

# -- Cleanup and Locking helper functions --
function get_cleanup_scheduler end
function lock_tasks end

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
        # record's watchers — precisely what the serializing store achieves by omitting
        # the column. The caller's object is left untouched, so both backends agree on
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
                         error::Union{Nothing, String}=nothing,
                         completed_at::Union{Nothing, DateTime}=nothing,
                         result=UNSUPPLIED,
                         progress::Union{Nothing, Real}=nothing)
    lock(store.task_lock) do
        task_info = Base.get(store.task_registry, task_id, nothing)
        task_info === nothing && return false
        task_info.status in from || return false

        error === nothing || (task_info.error = error)
        completed_at === nothing || (task_info.completed_at = completed_at)
        result === UNSUPPLIED || (task_info.result = result)
        progress === nothing || (@atomic task_info.progress = Float64(progress))
        task_info.status = to        # last, so no reader sees the new status early
        return true
    end
end

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

# -- Core extension management (ServerContext integration) --

const DEFAULT_STORE = Ref(InMemoryWorkerStore())

default_store() = DEFAULT_STORE[]

function worker_store(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY)
    return get_extension(ctx, key, nothing)
end

function install!(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY, store::AbstractWorkerStore=InMemoryWorkerStore())
    return set_extension!(ctx, key, store)
end

function uninstall!(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY)
    store = worker_store(ctx; key)
    if store isa AbstractWorkerStore
        shutdown!(store)
    end
    delete_extension!(ctx, key)
    return nothing
end

shutdown!(::AbstractWorkerStore) = nothing

function shutdown!(store::InMemoryWorkerStore)
    scheduler = store.cleanup_scheduler[]
    if !isnothing(scheduler)
        stop_cleanup_scheduler!(scheduler)
        store.cleanup_scheduler[] = nothing
    end

    lock(store.queue_lock) do
        for queue in values(store.sequential_queues)
            if isopen(queue.channel)
                close(queue.channel)
            end
            queue.running = false
            queue.current_task = nothing
            queue.processor_task = nothing
        end
    end

    lock(store.active_lock) do
        empty!(store.active_tasks)
    end

    return nothing
end

function reset_store!(store::AbstractWorkerStore=default_store())
    shutdown!(store)

    if store isa InMemoryWorkerStore
        lock(store.task_lock) do
            empty!(store.task_registry)
        end
        lock(store.queue_lock) do
            empty!(store.sequential_queues)
        end
        lock(store.active_lock) do
            empty!(store.active_tasks)
        end
    end

    return store
end
