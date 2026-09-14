"""
    WorkerRuntime(store::AbstractWorkerStore)

The live half of the worker subsystem: the sequential queues and their processor `Task`s, the
cleanup scheduler, and the process-local handles for runs executing **right now**.

`AbstractWorkerStore` used to own all of that as well as the durable records, and that double role
is the whole of [#29](https://github.com/PingoLee/Nitro.jl/issues/29): a backend that forgot
`shutdown!` leaked its scheduler and processors, silently.
[#166](https://github.com/PingoLee/Nitro.jl/pull/166) closed the *instance* by making `shutdown!`
required — a backend that owns nothing must now say so out loud. This closes the *class*: a storage
backend cannot forget to tear down background work, because it never owns any.

That is the split Sidekiq draws between its `Launcher` and Redis, and Go's River between
`river.Client` and `riverpgxv5`. The dividing question is:

> The store is asked **"what does the record say?"**. The runtime is asked **"what is this process
> doing right now?"**.

# One store may back several runtimes

Two `App`s sharing one `PormGWorkerStore` get their own queues and scheduler each, and
`uninstall!` on one cannot stop the other's processors. That was not representable while the
resources lived on the store, and it is the reason lifecycle belongs to an object rather than to a
process-wide singleton — the application-context model `nitro-general` names as the tiebreaker.

Policy stays on the store: the queue and watch authorizers and the error redactor are about the
data and the tenant, so two runtimes over one store correctly share one security posture.

# Fields

| Field | What it holds |
|---|---|
| `store` | The backend. Concrete via the type parameter, so store calls stay statically dispatched |
| `sequential_queues` / `queue_lock` | `SequentialQueue` per queue name, each owning a `Channel` and a processor `Task` |
| `cleanup_scheduler` | The retention sweep, or `nothing` |
| `active_tasks` / `active_task_infos` / `active_lock` | Process-local run handles. Keyed by task id, but each entry describes one **run** |

`active_task_infos` is the live-`TaskInfo` cache, and it lives here for **both** backends. It was
previously a `PormGWorkerStore` field with no in-memory counterpart — the in-memory store answered
`get_active_task_info` by aliasing `get_task_info`, so the "live object" and "the record" were the
same object by accident of backend rather than by design. Treating the two as equivalent is what
caused a real cancellation regression in #166. They are now one mechanism.

The in-memory guarantee survives **by object identity, not by an alias**: a run registers the very
object it read from the store, and for `InMemoryWorkerStore` that object *is*
`store.task_registry[id]`.
"""
struct WorkerRuntime{S <: AbstractWorkerStore}
    store::S

    sequential_queues::Dict{String, SequentialQueue}
    queue_lock::ReentrantLock

    cleanup_scheduler::Ref{Union{Nothing, CleanupScheduler}}

    active_tasks::Dict{String, Task}
    active_task_infos::Dict{String, TaskInfo}
    active_lock::ReentrantLock

    function WorkerRuntime(store::S) where {S <: AbstractWorkerStore}
        return new{S}(
            store,
            Dict{String, SequentialQueue}(),
            ReentrantLock(),
            Ref{Union{Nothing, CleanupScheduler}}(nothing),
            Dict{String, Task}(),
            Dict{String, TaskInfo}(),
            ReentrantLock(),
        )
    end
end

"""
    worker_store(runtime::WorkerRuntime) -> AbstractWorkerStore

The backend this runtime reads and writes records through.
"""
worker_store(runtime::WorkerRuntime) = runtime.store

get_sequential_queues(runtime::WorkerRuntime) = runtime.sequential_queues
get_queue_lock(runtime::WorkerRuntime) = runtime.queue_lock
get_cleanup_scheduler(runtime::WorkerRuntime) = runtime.cleanup_scheduler

# The task lock is the STORE's — it serializes store operations, and two runtimes over one store
# must contend on the same one or `_register_or_watch!` stops being mutually exclusive.
lock_tasks(callback::Function, runtime::WorkerRuntime) = lock_tasks(callback, runtime.store)

# ============================================================================
# Process-local run handles
# ============================================================================

function get_active_task(runtime::WorkerRuntime, task_id::String)
    lock(runtime.active_lock) do
        return Base.get(runtime.active_tasks, task_id, nothing)
    end
end

function register_active_task!(runtime::WorkerRuntime, task_id::String, task::Task)
    lock(runtime.active_lock) do
        runtime.active_tasks[task_id] = task
    end
    return task
end

function deregister_active_task!(runtime::WorkerRuntime, task_id::String)
    lock(runtime.active_lock) do
        delete!(runtime.active_tasks, task_id)
    end
    return nothing
end

function get_active_task_info(runtime::WorkerRuntime, task_id::String)
    lock(runtime.active_lock) do
        return Base.get(runtime.active_task_infos, task_id, nothing)
    end
end

function register_active_task_info!(runtime::WorkerRuntime, task_id::String, task_info::TaskInfo)
    lock(runtime.active_lock) do
        runtime.active_task_infos[task_id] = task_info
    end
    return task_info
end

function deregister_active_task_info!(runtime::WorkerRuntime, task_id::String)
    lock(runtime.active_lock) do
        delete!(runtime.active_task_infos, task_id)
    end
    return nothing
end

# ============================================================================
# Reads that prefer the live object
# ============================================================================

"""
    get_task_info(runtime::WorkerRuntime, task_id::String) -> Union{Nothing, TaskInfo}

The record as a **reader** should see it: the live object if a run is executing here, the durable
record otherwise.

A worker writes the store at RUNNING-start and again on completion, so between those a durable read
reports stale progress. Preferring the live object is what makes `get_task_status` report a
callback's `update_progress!` without a round-trip.

`get_task_info(runtime.store, task_id)` is the **durable** read, and the two are not
interchangeable. The rule:

> A call about to **claim** a run reads the store. A call that is **reporting** reads the runtime.

Run-start must read durable. Re-running a key whose record is terminal while its previous run is
still executing is reachable — cancellation is cooperative, so `cancel_task` writes `CANCELLED`
while the callback keeps going — and a live-preferring read there hands the new run its
*predecessor's* `TaskInfo`. Its `try_transition!` then fails its own `run_id` fence
([#108](https://github.com/PingoLee/Nitro.jl/issues/108)) and the task sits `PENDING` forever with
nothing left to drain it. That was live on `PormGWorkerStore`, whose store-level `get_task_info`
preferred the live cache while `replace_task!` never refreshed it.
"""
function get_task_info(runtime::WorkerRuntime, task_id::String)
    live = get_active_task_info(runtime, task_id)
    live === nothing || return live
    return get_task_info(runtime.store, task_id)
end

"""
    get_all_tasks(runtime::WorkerRuntime, authority::TaskAuthority; status, queue_name) -> Vector{TaskInfo}

The store's listing with live progress overlaid onto whichever rows are running here.

Was `PormGWorkerStore`-only; every serializing backend now inherits it. The filtering and the
authorization gate stay in the store — the overlay writes only volatile fields (`status`,
`progress`, `result`, `error`, and the two timestamps), and `_is_authorized` reads only `id` and
`watchers`, so running afterwards cannot widen what a caller sees.

When the live object *is* the stored record — `InMemoryWorkerStore`, where the registry holds the
same objects — the overlay is skipped rather than assigning each field to itself.
"""
function get_all_tasks(runtime::WorkerRuntime, authority::TaskAuthority;
                       status::Union{Nothing, TaskStatus}=nothing,
                       queue_name::Union{Nothing, String}=nothing)
    tasks = get_all_tasks(runtime.store, authority; status, queue_name)

    live = lock(runtime.active_lock) do
        isempty(runtime.active_task_infos) ? nothing : copy(runtime.active_task_infos)
    end
    live === nothing && return tasks

    for task_info in tasks
        running = Base.get(live, task_info.id, nothing)
        (running === nothing || running === task_info) && continue
        task_info.status = running.status
        @atomic task_info.progress = running.progress
        task_info.result = running.result
        task_info.error = running.error
        task_info.started_at = running.started_at
        task_info.completed_at = running.completed_at
    end

    return tasks
end

"""
    add_watcher!(runtime::WorkerRuntime, task_id::String, user_id::String) -> Bool

Grant through the store, then mirror onto the live object if a run is executing here.

Durable record first: a crash between the two leaves the row correct, and the row is what a read
falls back to. Without the mirror, a grant made while a task runs would stay invisible on this
process until the task terminated, because reads prefer the live object.

Performs **no authorization** — see workers §2. The authorized path is `submit_task(...; watchers)`.
"""
function add_watcher!(runtime::WorkerRuntime, task_id::String, user_id::String)
    add_watcher!(runtime.store, task_id, user_id) || return false

    lock(runtime.active_lock) do
        live = Base.get(runtime.active_task_infos, task_id, nothing)
        if live !== nothing && !(user_id in live.watchers)
            push!(live.watchers, user_id)
        end
    end

    return true
end

# ============================================================================
# Teardown
# ============================================================================

"""
    shutdown!(runtime::WorkerRuntime)

Release everything this process is running: stop the cleanup scheduler, close and discard the
sequential queues, and drop the run handles.

**A concrete method on a concrete type.** There is no abstract dispatch here and no fallback, so
there is nothing a backend author can forget — which is the difference between this and the
required-`shutdown!` contract it replaces (#29, #166). A store contributes nothing to teardown
because it owns nothing that runs.

The queue registry is **emptied, not just drained.** A queue whose channel is closed is dead, but
`_get_or_create_queue` uses `get!` — leaving the entry behind would hand a reused runtime the dead
queue, spawn a processor that immediately breaks, and then throw on `put!`. Emptying makes the
teardown total, so a runtime can be shut down and started again.

`active_task_infos` is deliberately **not** cleared: `cancel_task` resolves the live `TaskInfo`
through it, so clearing it would make a run that outlives a teardown uncancellable. Nothing leaks
by leaving it — each run removes its own entry when it finishes. [`reset_runtime!`](@ref) does
clear it, because a reset is total where a teardown is not.

# This releases; it does not drain

Nothing stops a running Julia task — cancellation here is a token a callback polls — so this
returns without waiting for in-flight runs, and clearing `active_tasks` makes a run that is still
executing look dead to `recover_zombie_tasks!`, which decides liveness from exactly
`get_active_task`. A teardown-then-restart **in one process** (a dev reload, several apps per
process, a test suite resetting between cases) therefore marks such a run `FAILED`, and its real
result is discarded when its own run-fenced terminal write loses.

Closing that means a graceful drain — waiting for, or re-registering, in-flight runs — which is a
lifecycle design decision rather than a teardown fix. It is now *buildable*, which it was not
before: the object that owns the tasks is the object being shut down. `active_tasks` is the set to
wait on and `active_task_infos` the set of tokens to set first.
"""
function shutdown!(runtime::WorkerRuntime)
    scheduler_ref = runtime.cleanup_scheduler
    scheduler = scheduler_ref[]
    if !isnothing(scheduler)
        stop_cleanup_scheduler!(scheduler)
        scheduler_ref[] = nothing
    end

    lock(runtime.queue_lock) do
        for queue in values(runtime.sequential_queues)
            if isopen(queue.channel)
                close(queue.channel)
            end
            queue.running = false
            queue.current_task = nothing
            queue.processor_task = nothing
        end
        empty!(runtime.sequential_queues)
    end

    # A graceful drain would go HERE, before the handles are dropped.
    lock(runtime.active_lock) do
        empty!(runtime.active_tasks)
    end

    return nothing
end

"""
    clear_records!(store) -> nothing

Discard every task record. **Optional, and the default is a no-op.**

The default goes in the safe direction on purpose. For a durable backend the registry is rows that
outlive the process, so wiping them on a reset would be a destructive delete of live data rather
than a teardown — a backend that never implements this gets *"my reset did not wipe"*, never *"my
reset deleted production"*. Persistent backends prune through [`cleanup_tasks!`](@ref) on their own
retention policy instead.

This replaces the `store isa InMemoryWorkerStore` branch `reset_store!` used to carry. The check
was never merely a predicate — the reset reaches into the backend's own registry, so the *how* has
to live in the backend regardless.
"""
clear_records!(::AbstractWorkerStore) = nothing

"""
    reset_runtime!(runtime = default_runtime()) -> runtime

Tear the runtime down and return it to a freshly-constructed state, discarding the store's task
records if the backend is volatile.

[`shutdown!`](@ref) does the process-local half. This adds the two things a *reset* means and a
teardown does not: the live-`TaskInfo` cache is cleared, and [`clear_records!`](@ref) is called —
a no-op unless the backend opts in.

Was `reset_store!`, which took a store. It resets a runtime and takes one, so the old name would
have named the wrong thing.
"""
function reset_runtime!(runtime::WorkerRuntime=default_runtime())
    shutdown!(runtime)

    lock(runtime.active_lock) do
        empty!(runtime.active_task_infos)
    end

    clear_records!(runtime.store)
    return runtime
end

# ============================================================================
# App integration
# ============================================================================

# Deliberately `Ref(WorkerRuntime(...))` rather than `Ref{WorkerRuntime}(...)`: the former infers
# `RefValue{WorkerRuntime{InMemoryWorkerStore}}`, so `default_runtime()` has a concrete return type
# and the store calls behind it devirtualize. A widened `Ref` would make every default-argument
# `submit_task` a dynamic dispatch on the request path — the nitro-core §7 hard stop. Choosing a
# different backend is `install!`'s job, not this slot's.
const DEFAULT_RUNTIME = Ref(WorkerRuntime(InMemoryWorkerStore()))

"""
    default_runtime() -> WorkerRuntime

The process-wide runtime used when no `runtime=` is passed and no app has one installed.
"""
default_runtime() = DEFAULT_RUNTIME[]

"""
    default_store() -> AbstractWorkerStore

The backend behind [`default_runtime`](@ref).
"""
default_store() = DEFAULT_RUNTIME[].store

"""
    worker_runtime(ctx::App; key=:workers) -> Union{Nothing, WorkerRuntime}

The runtime installed on `ctx`, or `nothing`.
"""
function worker_runtime(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY)
    return get_extension(ctx, key, nothing)
end

"""
    worker_store(ctx::App; key=:workers) -> Union{Nothing, AbstractWorkerStore}

The backend of the runtime installed on `ctx`, or `nothing`.

Unchanged in meaning: this is still how an app reaches its store to install policy, as in
`set_queue_authorizer!(worker_store(app), f)`.
"""
function worker_store(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY)
    runtime = worker_runtime(ctx; key)
    return runtime isa WorkerRuntime ? runtime.store : nothing
end

"""
    install!(ctx::App; key=:workers, store=InMemoryWorkerStore()) -> WorkerRuntime
    install!(ctx::App, runtime::WorkerRuntime; key=:workers) -> WorkerRuntime

Put a runtime in `ctx`'s extension slot. The `store=` form builds one over that backend.

The slot holds the **runtime**, not the store, because `uninstall!` is the teardown entry point and
the thing in the slot has to be the thing that owns teardown.

Registration only — nothing is started here. `start!` does that.
"""
function install!(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY,
                  store::AbstractWorkerStore=InMemoryWorkerStore())
    return install!(ctx, WorkerRuntime(store); key)
end

function install!(ctx::App, runtime::WorkerRuntime; key::Symbol=DEFAULT_EXTENSION_KEY)
    set_extension!(ctx, key, runtime)
    return runtime
end

"""
    uninstall!(ctx::App; key=:workers)

Shut the installed runtime down and drop it from `ctx`.
"""
function uninstall!(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY)
    runtime = worker_runtime(ctx; key)
    if runtime isa WorkerRuntime
        shutdown!(runtime)
    end
    delete_extension!(ctx, key)
    return nothing
end
