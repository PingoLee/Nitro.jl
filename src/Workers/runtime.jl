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
| `active_tasks` / `active_task_infos` / `active_lock` | Process-local run handles. Keyed by task id, but each entry describes one **run**. [`shutdown!`](@ref) drains against these and keeps whatever outlives the wait (#176) |

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

"""
    register_run!(runtime::WorkerRuntime, task_id::String, task_info::TaskInfo, task::Task)

Publish a run's live `TaskInfo` **and** its `Task` handle as one atomic step.

The two must not be published separately, and the reason is [`_deregister_run!`](@ref): it decides
whose handles it may drop by comparing `run_id` on the *info*, so the info is the fence's only
oracle. A run that had published its handle but not yet its oracle was invisible to the fence, and
a predecessor finishing in that window deleted the **successor's** handle — which
`recover_zombie_tasks!` reads as death, marking a genuinely running task `FAILED` (#167). That is
the #108 defect the fence exists to prevent, arriving through the back door.

Ordering the two writes correctly would also fix it, but only by convention, and the window is not
observable from outside the runtime — so a test cannot hold the convention in place. Publishing
both under one `active_lock` makes "a handle never exists without its info" structural instead, and
`_deregister_run!`'s `live === nothing` branch sound by construction rather than by inspection.
"""
function register_run!(runtime::WorkerRuntime, task_id::String, task_info::TaskInfo, task::Task)
    lock(runtime.active_lock) do
        runtime.active_task_infos[task_id] = task_info
        runtime.active_tasks[task_id] = task
    end
    return task_info
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

That identity guard is also what keeps this loop, which runs outside the store's task lock, from
mutating a record another reader holds. On the in-memory backend the two can never *disagree* for
one id: a run registers the very object `get_task_info(store, ·)` returned, and the one operation
that swaps the stored object for a different one — [`replace_task!`](@ref) on a re-run — evicts the
live entry in the same breath, so there is no interval in which the cache names one object and the
registry another. (`set_task!` also swaps, but only when there was no entry to disagree with.) On a
serializing backend the two always differ, and there the objects being written are fresh ones this
call just deserialized, owned by nobody else.
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
    replace_task!(runtime::WorkerRuntime, task_id::String, task_info::TaskInfo)

Publish a new run's whole record, and evict the run it displaced from the live caches.

The eviction is what keeps `get_task_info(runtime, ·)` honest. The live caches are keyed by task
id, but each entry describes one **run** — and `replace_task!` is precisely the moment a run stops
owning its key. Leaving the predecessor behind opens a window between this write and the successor's
[`register_run!`](@ref) in which the live slot holds a run that no longer owns the record, usually
a terminal one: a concurrent `cancel_task` then refuses to cancel a live successor
("already finished"), a concurrent submit concludes the key is finished and replaces the record
again, and `get_task_status` reports the predecessor's terminal status for a task that is pending.

This is the mirror image of [`_deregister_run!`](@ref)'s fence, not a contradiction of it. There, a
*predecessor* must not tear down a *successor*'s handles; here a successor displaces a predecessor,
which is safe because the store has already been told the successor owns the key. Both rules say
the same thing: the live entry belongs to whichever run currently owns the record.

The predecessor's cancellation token is set by the caller *before* this runs, and its callback
holds its own reference to the object, so evicting the cache entry does not lose the request.
"""
function replace_task!(runtime::WorkerRuntime, task_id::String, task_info::TaskInfo)
    replace_task!(runtime.store, task_id, task_info)

    lock(runtime.active_lock) do
        live = Base.get(runtime.active_task_infos, task_id, nothing)
        if live !== nothing && live.run_id != task_info.run_id
            # Both, together: `_deregister_run!` assumes the two caches agree about which run
            # owns the key, and a half-evicted pair would strand the handle until the successor
            # finished.
            delete!(runtime.active_task_infos, task_id)
            delete!(runtime.active_tasks, task_id)
        end
    end

    return task_info
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
    DrainEntry

One in-flight run as [`shutdown!`](@ref) found it: the key, the run that owned that key at
snapshot time, its live `TaskInfo`, and the `Task` handle registered for it.

`run_id` and `info` are `nothing` only for a handle registered without one — which
[`register_run!`](@ref) makes unreachable for a real run, and which in practice means the
test-only `register_active_task!`. Both halves are captured under one `active_lock` acquisition,
so an entry can never name a handle from one run and an info from another.
"""
struct DrainEntry
    id::String
    run_id::Union{Nothing, UUID}
    info::Union{Nothing, TaskInfo}
    task::Task
end

# Capture the in-flight runs in ONE critical section, so a handle and its info cannot come from
# different runs.
#
# The run that is CALLING the drain is deliberately skipped. `shutdown!` is reachable from inside a
# worker callback -- `resetstate()` (`src/methods.jl`) goes through `reset_runtime!`, and an app
# callback may call `terminate()` -- and such a run cannot finish while it is blocked here, nor
# deregister itself. Waiting for it is a guaranteed full-timeout stall followed by a warning naming
# the very run that was doing the waiting.
#
# TWO probes, because one does not cover it. `task === current_task()` catches a run whose callback
# runs directly on its registered handle, which happens only when `TaskOptions(timeout = 0)`
# disables the deadline. With a deadline -- the default -- `timeout_call` runs the callback on a
# CHILD task and the registered handle is the parent parked in `timedwait`, so the identity check
# misses. `CURRENT_RUN_KEY` (`types.jl`) is the task-local marker that survives that indirection.
function _snapshot_runs(runtime::WorkerRuntime)
    me = current_task()
    my_run = Base.get(task_local_storage(), CURRENT_RUN_KEY, nothing)
    return lock(runtime.active_lock) do
        entries = Vector{DrainEntry}()
        for (task_id, task) in runtime.active_tasks
            task === me && continue
            info = Base.get(runtime.active_task_infos, task_id, nothing)
            run_id = info === nothing ? nothing : info.run_id
            run_id !== nothing && run_id == my_run && continue
            push!(entries, DrainEntry(task_id, run_id, info, task))
        end
        return entries
    end
end

# Has this run stopped being this runtime's problem?
#
# **The info clause is what terminates every production wait.** A real run clears BOTH caches
# through `_deregister_run!` -- inside `_finish_task!`, and again in the `finally` around each
# execute path -- and it does that *before* its task completes. So for a run registered by
# `register_run!`, clause 2 always fires first and `istaskdone` never gets to decide. That holds
# for both shapes:
#
#   - The ASYNC path registers the run's OWN spawned task (`_execute_task_async`).
#   - The SEQUENTIAL path registers `current_task()` -- the long-lived, SHARED queue processor
#     (`_execute_queued_task`). `istaskdone` on that is true only once the processor has finished
#     this item, drained every item still buffered behind it, and broken out of `take!`, so here
#     the info clause is not merely first but *necessary*: narrowing this predicate to
#     `istaskdone` alone would turn every sequential teardown into a full-timeout stall.
#
# **`istaskdone` is the backstop, not the probe.** It decides only for a handle whose info nothing
# will ever remove -- the `register_active_task!` / `register_active_task_info!` pair, which has no
# production caller and exists for tests. There clause 2 is permanently false (the info is present
# and still names this run), so without `istaskdone` such an entry could never settle and every
# teardown would ride the ceiling. It also gates the delete in `_release_settled_handles!`, which
# is where it does its real work.
#
# The info clause reads "this run no longer owns its key", not "the callback returned" -- a run
# displaced mid-drain by a re-run (`replace_task!` evicts both caches) settles here while its
# callback is still going. That is correct: the drain no longer owns that run, and in the
# sequential case cannot even find its handle.
function _run_settled(runtime::WorkerRuntime, entry::DrainEntry)
    istaskdone(entry.task) && return true
    return lock(runtime.active_lock) do
        live = Base.get(runtime.active_task_infos, entry.id, nothing)
        return live === nothing || live.run_id != entry.run_id
    end
end

# Release the handles of runs that actually finished, and ONLY those.
#
# Two properties, both required; dropping either is a regression.
#
# **Fenced on `run_id`**, because this runs after a wait measured in seconds. A snapshotted run A
# can finish, and a re-run publish run B under the same key, entirely inside the drain window --
# and an id-keyed `delete!` would then evict the LIVE SUCCESSOR's handle, which
# `recover_zombie_tasks!` reads as death. That is exactly the #108/#167 defect
# [`_deregister_run!`](@ref) exists to prevent, arriving through a window far wider than the one
# it was written for.
#
# **`active_tasks` only.** `active_task_infos` is what `cancel_task` resolves a live object
# through, so clearing it would make a run that outlives a teardown uncancellable -- the rule
# `shutdown!` has always kept. A real run deregisters BOTH itself, through `_deregister_run!`,
# before its task completes; what actually reaches this loop is the leftover half of a handle
# registered with no run behind it.
#
# `live === nothing` is safe to delete for the same reason it is in `_deregister_run!`:
# `register_run!` publishes a handle and its info together, so no live run can be holding a handle
# whose info is absent.
function _release_settled_handles!(runtime::WorkerRuntime, snapshot::Vector{DrainEntry})
    lock(runtime.active_lock) do
        for entry in snapshot
            istaskdone(entry.task) || continue
            live = Base.get(runtime.active_task_infos, entry.id, nothing)
            if live === nothing || live.run_id == entry.run_id
                delete!(runtime.active_tasks, entry.id)
            end
        end
    end
    return nothing
end

"""
    shutdown!(runtime::WorkerRuntime; drain_timeout = WORKER_DRAIN_TIMEOUT_SECONDS) -> Bool

Release everything this process is running: stop the cleanup scheduler, close and discard the
sequential queues — recording their unstarted backlog as `CANCELLED` rather than executing it —
then **drain** the runs still executing here, asking them to stop, waiting up to `drain_timeout`
seconds, and releasing the handles of the ones that finished.

Returns `true` when every run that was in flight settled, `false` when the wait ran out and
something was still going. (An expired wait can still return `true`: a run that settles between the
deadline and the check counts, and then nothing is warned about either.) Abandoned backlog items
never affect that value — they are terminal by the time this returns, so they are settled by
definition; the return is about *runs*.

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

# The drain (#176)

Nothing stops a running Julia task — cancellation here is a token a callback polls — so a drain is
a *request* plus a bounded wait, never a kill. In order:

1. Every in-flight run's `cancel_requested` token is set, **before** the wait rather than after
   it, so a cooperative callback has the whole window in which to notice and return.
2. `timedwait` polls until each snapshotted run has either finished or stopped owning its key.
3. If anything is still unsettled after that, a `@warn` names it and the wait is not retried.

A run that did **not** settle keeps its handle registered, and that is the half of this which
fixes the issue. `recover_zombie_tasks!` decides liveness from exactly `get_active_task`, so the
old unconditional `empty!(active_tasks)` made a still-executing run look dead to the next
`start!(recover_zombies = true)`, which marked it `FAILED` and discarded the real result when the
run's own fenced terminal write lost. Leaving the handle in place is not a leak: `_finish_task!`
removes it when the callback eventually returns.

**That second half only helps a runtime that is reused.** `uninstall!` empties the extension slot,
so a `serve → terminate → serve` cycle with `store = …` builds a *new* `WorkerRuntime` whose
`active_tasks` is empty by construction, and an abandoned run from the previous cycle is swept as
before. For that shape the drain itself — finishing the run before teardown returns — is the whole
fix. Reuse means `worker_startup(runtime = …)`, `install!(ctx, runtime)`, or a direct
`shutdown!`-then-reuse.

`drain_timeout = 0` skips both the tokens and the wait and drops every handle: the pre-#176
behaviour for in-flight runs, exactly. It still reports honestly — `false` when it abandoned a live
run — because the return value means *was everything settled*, not *did I try*. It does **not**
opt out of the backlog handling below; see #182.

# What this does NOT bound

`drain_timeout` bounds the drain, not the call. `stop_cleanup_scheduler!` waits on the scheduler
task with no deadline of its own, and that happens first. A scheduler task that died earlier is
logged there, not rethrown, so the teardown below it always runs
([#193](https://github.com/PingoLee/Nitro.jl/issues/193)).

# The sequential backlog is abandoned, not executed (#182)

Closing a queue's channel stops new *submissions*; it never stopped the **processor**, which kept
`take!`-ing whatever was already buffered. So a teardown used to start runs that were never in the
drain's snapshot: no token, no wait, and a `RUNNING` record published into a runtime being torn
down. This now stops fetching first, the way Sidekiq's quiet-then-`-t` and River's `Client.Stop`
both do.

Every queued task still buffered when this is called is recorded **`CANCELLED`** with
`"Cancelled by worker shutdown"` — the same string an in-flight run parked in its retry backoff
gets, so one teardown produces one vocabulary. The write is a compare-and-set from `PENDING`
fenced on `run_id`, so a key re-run since it was queued keeps its successor's record.

`CANCELLED` rather than silence, because silence is not free: an abandoned record sits at
`PENDING` and `recover_zombie_tasks!` only sweeps `RUNNING`, so nothing would ever reap it.
`CANCELLED` rather than `FAILED`, because nothing failed and `FAILED` is what the zombie sweep
writes — reusing it would put two causes under one status again.

**This happens at `drain_timeout = 0` too.** That keyword means *do not wait*; abandoning the
backlog costs no wait, so declining the wait is not a request to execute the backlog on the way
out. It is the one respect in which `0` is no longer byte-for-byte the pre-#176 behaviour.

# What a drained run records

The drain itself writes no terminal state — that would race the run's own write, the #88/#108
failure mode — so the outcome is whatever the run reaches on its own:

| The run was… | It records |
|---|---|
| running its callback, which returns on the token | `COMPLETED`, carrying whatever it returned |
| running its callback, which throws | `FAILED` with that message (or a retry, if one is left) |
| **between retries**, parked in the cancellation-aware backoff | **`CANCELLED`**, error `"Cancelled by worker shutdown"` |

That third row surprises people, so it is stated rather than implied: the retry backoff polls this
very token, so a drain landing inside one ends the run as cancelled. Reaching a terminal state
there is the useful behaviour — the alternative is a job that restarts during teardown.

**The message names the shutdown, and that is new in #183.** The drain sets the token with
reason `:shutdown` ([`CANCEL_REASONS`](@ref)) and `_cancel_task!` renders the stored text from it,
so a teardown is distinguishable from a person's `cancel_task` — which is the only thing that
records `"Cancelled by user"`. Before #183 it was the other way round on the async path: a real
`cancel_task` claims `CANCELLED` first and the run's own write lost its CAS, so `"Cancelled by
user"` reached the record *only* when a drain had put it there. Alerting that reads `CANCELLED` as
"a person did this" can now filter on the message instead.

A callback that wants to do something *other* than stop — checkpoint, say — can read
[`cancel_reason`](@ref) and branch on `:shutdown`.

**The run calling this is excluded.** `_snapshot_runs` skips it (see `CURRENT_RUN_KEY`), so a
`shutdown!` invoked from inside a callback neither waits for nor reports on its own run — and can
return `true` while that one run is still going. It has to: that run cannot finish while it is
blocked here.
"""
function shutdown!(runtime::WorkerRuntime; drain_timeout::Real = WORKER_DRAIN_TIMEOUT_SECONDS)
    drain_timeout < 0 && throw(ArgumentError(
        "drain_timeout must be >= 0 (got $(drain_timeout)); 0 releases without waiting"))

    scheduler_ref = runtime.cleanup_scheduler
    scheduler = scheduler_ref[]
    if !isnothing(scheduler)
        # This wait carries no deadline, so it sits OUTSIDE `drain_timeout`'s budget. It is short
        # in practice -- the scheduler task runs no user code, only `timedwait` and a retention
        # sweep -- but `drain_timeout` is not a bound on this function's total time. A scheduler
        # whose task already died is logged in there and does NOT throw out of here (#193), so
        # everything below still runs.
        stop_cleanup_scheduler!(scheduler)
        scheduler_ref[] = nothing
    end

    # Stop the queues taking work, and collect whatever was still buffered so it can be recorded
    # as abandoned rather than executed on the way out (#182). Three steps, in this order:
    #
    #   1. `draining = true` -- covers the one item a processor may have ALREADY taken. It has to
    #      be set before the close, or that item slips through into `_execute_queued_task`.
    #   2. `close` -- `put!` on a closed channel throws, so nothing more can arrive.
    #   3. collect -- anything that raced in before the close is in the buffer, and nothing can be
    #      added after it. Closing before collecting is what makes that airtight; the reverse
    #      order leaves a window for a submit between the collect and the close.
    abandoned_items = lock(runtime.queue_lock) do
        pending = Vector{QueueItem}()
        for queue in values(runtime.sequential_queues)
            @atomic queue.draining = true
            if isopen(queue.channel)
                close(queue.channel)
            end

            # `take!` until the channel says it is empty, NEVER `while isready(...)`.
            # `isready` is `n_avail > 0`, and `n_avail` counts tasks blocked in `put!` as well as
            # buffered items -- so on a full `Channel(100)` with one submitter waiting it reports
            # 101 with 100 to take, and the last `take!` throws `InvalidStateException` on the
            # now-empty closed channel. That exception escapes this whole `lock` block: the
            # collected items are discarded (stranding every one of them `PENDING`, which is the
            # outcome this function exists to prevent), the registry is never emptied, and the
            # #176 drain below never runs at all. A closed queue with a blocked submitter is
            # exactly the state a busy deploy tears down. The processor racing us for the last
            # item reaches the same throw by a different route.
            #
            # This is the shape `_start_queue_processor`'s own loop already uses, for the same
            # reason: on a closed channel, `take!` drains what is buffered and then raises.
            while true
                item = try
                    take!(queue.channel)
                catch error
                    error isa InvalidStateException || rethrow()
                    break
                end
                push!(pending, item)
            end

            queue.running = false
            queue.current_task = nothing
            queue.processor_task = nothing
        end
        empty!(runtime.sequential_queues)
        return pending
    end

    # OUTSIDE `queue_lock`, deliberately. These are store writes, and the queue processor takes
    # the store lock (`_finish_task!`) and then `queue_lock` (its own `finally`); holding
    # `queue_lock` across a store write here is that pair in the opposite order. One `lock_tasks`
    # for the whole batch rather than one per item, which is the shape `recover_zombie_tasks!`
    # already uses for a sweep.
    #
    # Unconditional -- this runs at `drain_timeout = 0` too. That keyword means "do not WAIT", and
    # abandoning the backlog costs no wait; letting a teardown silently execute a queue's backlog
    # is not something anyone opted into by declining to wait for in-flight runs.
    if !isempty(abandoned_items)
        lock_tasks(runtime) do
            for item in abandoned_items
                try
                    _abandon_queued_item!(runtime, item)
                catch error
                    @error "Worker queued task abandoned but not recorded during teardown" exception=(error, catch_backtrace()) task_key=item.task_key
                end
            end
        end
    end

    if iszero(drain_timeout)
        # The pre-#176 path, unchanged: no tokens, no wait, every handle dropped. Setting tokens
        # without waiting would be pure harm -- it asks live callbacks to abandon work on the way
        # out of a teardown that was never going to wait for the answer.
        #
        # The return value still has to be honest, though: it means "was everything settled when
        # this returned", and dropping a live run's handle does not settle it. So this reports
        # `false` exactly when it abandoned something -- the same thing `_shutdown_server`
        # (`src/context.jl`) does on its own `iszero(timeout)` force-close branch.
        abandoned = _snapshot_runs(runtime)
        settled = all(entry -> _run_settled(runtime, entry), abandoned)
        lock(runtime.active_lock) do
            empty!(runtime.active_tasks)
        end
        return settled
    end

    snapshot = _snapshot_runs(runtime)
    isempty(snapshot) && return true

    # Ask first, THEN wait. The token is the only thing that can make a callback stop, so setting
    # it after the wait -- the shape `timeout_call` uses, where by then there is nothing left to
    # wait for -- would tell a cooperative callback to stop at the exact moment we stopped caring.
    #
    # A direct field write, NOT `cancel_task`: no store write, no authorization question, no
    # status change. This is a request aimed at the callback, not a claim about the record.
    for entry in snapshot
        entry.info === nothing && continue
        _request_cancel!(entry.info, :shutdown)
    end

    # No lock is held across the wait, and none may be. `active_lock` would deadlock against
    # `_deregister_run!`, which is how a run settles; `queue_lock` is re-acquired by the queue
    # processor's own `finally`, so holding it would block the very completion being waited for.
    # The predicate runs inside a `Timer` callback, so it stays cheap and total and touches no
    # store. The BOUND is what makes a pathological case a stall rather than a deadlock -- which
    # is why `drain_timeout` must stay finite.
    settled = timedwait(() -> all(e -> _run_settled(runtime, e), snapshot),
                        Float64(drain_timeout); pollint = 0.05) === :ok

    if !settled
        # Re-read rather than trusting the expiry: a run can settle in the moment between
        # `timedwait` giving up and this line. Reporting `false` and warning about an empty list
        # would be an operator-facing warning that names nothing, so a late settle is promoted to
        # a clean drain here rather than being rounded down.
        stragglers = [entry.id for entry in snapshot if !_run_settled(runtime, entry)]
        settled = isempty(stragglers)
    end

    if !settled
        @warn "Nitro: worker runs did not drain within $(drain_timeout)s — their handles stay " *
              "registered, so zombie recovery will not declare them dead, and their callbacks " *
              "keep a thread until they return. A callback that must honour a shutdown has to " *
              "poll `cancel_requested(task_info)`. Tune with `shutdown!(runtime; " *
              "drain_timeout = …)` or `worker_startup(...; drain_timeout = …)`." task_ids=stragglers
    end

    _release_settled_handles!(runtime, snapshot)
    return settled
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
    reset_runtime!(runtime = default_runtime(); drain_timeout = 0) -> runtime

Tear the runtime down and return it to a freshly-constructed state, discarding the store's task
records if the backend is volatile.

[`shutdown!`](@ref) does the process-local half. This adds the three things a *reset* means and a
teardown does not: the live-`TaskInfo` cache is cleared, the run handles are dropped
unconditionally, and [`clear_records!`](@ref) is called — a no-op unless the backend opts in.

**`drain_timeout` defaults to `0` here, unlike everywhere else**, and that asymmetry is the point
of the word *reset*. A teardown promises to leave a surviving run cancellable and visible to
`recover_zombie_tasks!`; a reset promises the opposite — it erases the live cache and, on a
volatile backend, the records themselves. Waiting for a run to report an outcome that is about to
be deleted buys nothing, and would make every test `finally` and every `resetstate()`
(`src/methods.jl`) pay a drain window for it. Pass `drain_timeout` explicitly to reset *after*
letting in-flight work finish.

Was `reset_store!`, which took a store. It resets a runtime and takes one, so the old name would
have named the wrong thing.
"""
function reset_runtime!(runtime::WorkerRuntime=default_runtime(); drain_timeout::Real = 0)
    shutdown!(runtime; drain_timeout)

    lock(runtime.active_lock) do
        empty!(runtime.active_task_infos)
        # `shutdown!` no longer guarantees this: with a non-zero `drain_timeout` it deliberately
        # KEEPS the handles of runs that outlived the wait (#176). A reset is total, so it drops
        # them regardless -- otherwise a reset runtime could still report a run as live.
        empty!(runtime.active_tasks)
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
    install!(ctx::App; key=:workers, store=InMemoryWorkerStore(), drain_timeout=WORKER_DRAIN_TIMEOUT_SECONDS) -> WorkerRuntime
    install!(ctx::App, runtime::WorkerRuntime; key=:workers, drain_timeout=WORKER_DRAIN_TIMEOUT_SECONDS) -> WorkerRuntime

Put a runtime in `ctx`'s extension slot. The `store=` form builds one over that backend.

The slot holds the **runtime**, not the store, because `uninstall!` is the teardown entry point and
the thing in the slot has to be the thing that owns teardown.

Registration only — nothing is started here. `start!` does that.

**A `WorkerRuntime` belongs to exactly one slot.** Displacing one shuts it down, so installing the
same runtime object into a second `App` and then displacing it there leaves the first app holding a
runtime whose queues are closed and whose scheduler is stopped, with nothing to say so. To share a
backend across apps, give each its own runtime over the same store — which is the supported pattern
and the one that makes `uninstall!` on one app leave the other running.

`drain_timeout` is handed to the displaced runtime's [`shutdown!`](@ref). Displacement is exactly
the teardown-then-restart-in-one-process shape #176 is about — `start!` runs
`recover_zombie_tasks!` against the *same store* microseconds later — so it drains by default like
every other teardown. It costs nothing when nothing is in flight.
"""
function install!(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY,
                  store::AbstractWorkerStore=InMemoryWorkerStore(),
                  drain_timeout::Real=WORKER_DRAIN_TIMEOUT_SECONDS)
    return install!(ctx, WorkerRuntime(store); key, drain_timeout)
end

function install!(ctx::App, runtime::WorkerRuntime; key::Symbol=DEFAULT_EXTENSION_KEY,
                  drain_timeout::Real=WORKER_DRAIN_TIMEOUT_SECONDS)
    # Displacing a runtime tears it down. The slot IS the ownership handle, so a runtime the app
    # no longer points at is unreachable — and an unreachable runtime with a live scheduler and
    # live queue processors is the #29 leak with one more level of indirection. `uninstall!`
    # cannot clean it up afterwards either: it only ever sees the occupant.
    existing = worker_runtime(ctx; key)
    if existing isa WorkerRuntime && existing !== runtime
        shutdown!(existing; drain_timeout)
    end

    set_extension!(ctx, key, runtime)
    return runtime
end

"""
    uninstall!(ctx::App; key=:workers, drain_timeout=WORKER_DRAIN_TIMEOUT_SECONDS)

Shut the installed runtime down and drop it from `ctx`.

This is what `worker_startup`'s `on_shutdown` calls, so `drain_timeout` is the knob that decides
how long a served app waits for in-flight background work on the way out — and `terminate` runs
every lifecycle shutdown hook *before* it closes the listener, so this budget and
`serve(shutdown_timeout = …)` add up. `0` restores the pre-#176 release-immediately behaviour.
"""
function uninstall!(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY,
                    drain_timeout::Real=WORKER_DRAIN_TIMEOUT_SECONDS)
    runtime = worker_runtime(ctx; key)
    if runtime isa WorkerRuntime
        shutdown!(runtime; drain_timeout)
    end
    delete_extension!(ctx, key)
    return nothing
end
