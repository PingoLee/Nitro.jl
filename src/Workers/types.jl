@enum TaskStatus PENDING=1 RUNNING=2 COMPLETED=3 FAILED=4 CANCELLED=5

current_time_utc() = Dates.now(Dates.UTC)

"""
    DEFAULT_QUEUE_NAME

Queue name that [`submit_task`](@ref) authorizes against. Unqueued tasks do not
run through a `SequentialQueue`, but they are still submissions, so they are
still subject to the store's queue authorizer — under this name, following the
default-queue convention every comparable queue uses (Sidekiq `default`, River
`QueueDefault`).

A `TaskInfo.queue_name` stays `nothing` for these tasks: that field records the
*sequential* queue a task belongs to, and an unqueued task belongs to none.
"""
const DEFAULT_QUEUE_NAME = "default"

"""
    WORKER_DRAIN_TIMEOUT_SECONDS

Default ceiling, in seconds, on [`shutdown!`](@ref)'s graceful drain before it stops waiting for
in-flight runs and warns.

**Half of `Nitro.Core.SHUTDOWN_TIMEOUT_SECONDS`, on purpose.** The HTTP drain only has to reap idle
keep-alive connections, so ten seconds is an outer bound it essentially never approaches. A worker
drain is the opposite: background jobs are long by definition, so a callback that does not poll
[`cancel_requested`](@ref) will sit against this ceiling as a matter of course rather than as a
pathology. And the two budgets **add** — `terminate` runs every `LifecycleMiddleware` shutdown hook,
`worker_startup`'s among them, *before* it closes the listener, so worst-case process exit is this
plus the HTTP timeout. Five seconds keeps that sum inside a default container stop grace period.

Override per teardown with `shutdown!(runtime; drain_timeout = …)`, or for a served app with
`worker_startup(...; drain_timeout = …)`. `0` restores the pre-#176 behaviour: release the handles
and return without waiting.
"""
const WORKER_DRAIN_TIMEOUT_SECONDS :: Float64 = 5.0

"""
    ZOMBIE_SWEEP_BATCH

How many `RUNNING` records [`recover_zombie_tasks!`](@ref) reads per page (its `batch_size`
default). It bounds what one step of the boot-time sweep holds in memory, not how many records the
sweep reaches: it keeps paging until the backlog is exhausted
([#237](https://github.com/PingoLee/Nitro.jl/issues/237)).
"""
const ZOMBIE_SWEEP_BATCH :: Int = 500

"""
    CURRENT_RUN_KEY

Task-local key naming the run whose callback is executing on the current task.

It has exactly one reader — `_snapshot_runs` (`runtime.jl`), which must not make a drain wait for
the run that is *calling* that drain. `shutdown!` is reachable from inside a callback:
`resetstate()` goes through `reset_runtime!`, and an app callback may call `terminate()`. Such a
run can never settle while it is blocked in the wait, so without this the call stalls for the whole
`drain_timeout` and then warns about itself (#176).

A bare `task === current_task()` check does not find it. `timeout_call` runs the callback on a
**child** task, so the handle in `active_tasks` is the parent wrapper parked in `timedwait`, not
the task the callback is running on — the identity comparison misses on every path that has a
deadline, which is the default. Marking the run is what survives that indirection.

Written by `_invoke_task_callback` (`execution.jl`) rather than in `_claim_run!` or at the two
execute paths, because that is the single point both of them funnel through, with or without a
deadline.

Task-local storage is per-task and is **not** inherited by a spawned child, so two runs can never
see each other's marker. It is **not** enough on its own to keep the marker current, though: a
sequential queue processor with `TaskOptions(timeout=0)` runs many callbacks on one long-lived
task, so `_invoke_task_callback` saves and restores the previous value around each invocation.
Staleness is prevented by that `finally`, not by the language — do not remove it on the theory that
one task runs one callback.

Non-inheritance does bound what the marker covers: a callback that spawns its own task and calls
`shutdown!` from *there* is not recognised, and waits out the window. That is a deliberate floor,
not an oversight — the wait is bounded, so the cost is a slow teardown rather than a hang.
"""
const CURRENT_RUN_KEY = :nitro_worker_run_id

"""
    TASK_KEY_DELIMITER

Separator between the owner and the caller-supplied key in a `:user`-scoped task
id. `user_id` may not contain it; see [`scoped_task_key`](@ref).
"""
const TASK_KEY_DELIMITER = "::"

# Sentinel for "this field was not supplied", where `nothing` is itself a legal value.
# `try_transition!` needs it for `result`: a task that completes with `nothing` is not the
# same as one whose transition should leave the stored result alone.
struct _Unsupplied end
const UNSUPPLIED = _Unsupplied()

"""
    TaskAuthority

Who is asking, and with what rights. Read and manage APIs dispatch on this instead
of accepting an optional `user_id` whose *absence* meant "skip the ownership check"
— the shape that made the unsafe call the shorter one
([#48](https://github.com/PingoLee/Nitro.jl/issues/48)).

Two implementations: [`Owner`](@ref), a validated task identity, and [`System`](@ref),
the explicit bypass.
"""
abstract type TaskAuthority end

# One definition of a legal owner, shared by `Owner` and by `scoped_task_key`, so the
# rules that make `(user, key) -> id` injective cannot drift apart.
function _validate_owner_id(uid::String)
    isempty(uid) && throw(ArgumentError(
        "an owner id must not be empty: \"\" used to mean \"skip the ownership check\", " *
        "which is exactly the bypass this type exists to remove — use System() to be explicit"))
    if occursin(TASK_KEY_DELIMITER, uid) || endswith(uid, ":")
        throw(ArgumentError(
            "user_id '$uid' must not contain '$TASK_KEY_DELIMITER' or end in ':': that would " *
            "make the owner half of a :user-scoped task id ambiguous"))
    end
    return uid
end

"""
    Owner(user_id) <: TaskAuthority

A validated task identity. It acts wherever an identity appears — submitting, granting,
reading, cancelling — so an identity that can be *granted* access is always one that can
later be constructed to *use* that access.

Rejects the three shapes that would break the id invariant proved by
[`scoped_task_key`](@ref): an empty id, one containing `$(TASK_KEY_DELIMITER)`, and one
ending in `:`. Rejecting the empty id is what lets [`owner_of`](@ref) be trusted —
`owner_of(id) == u` is equivalent to `startswith(id, u * "$(TASK_KEY_DELIMITER)")` only
because `Owner("")` cannot exist.
"""
struct Owner <: TaskAuthority
    user_id::String

    Owner(user_id::AbstractString) = new(_validate_owner_id(String(user_id)))
end

"""
    System() <: TaskAuthority

The explicit authorization bypass: every read or action it accompanies is unscoped.

It is deliberately something you have to name. The previous bypass was an *omitted*
argument, so the unsafe call was also the shortest one, and a call site that had simply
forgotten to scope was indistinguishable from one that meant not to. Passing `System()`
is greppable in review and in a security audit; forgetting an argument is not.
"""
struct System <: TaskAuthority end

"""
    owner_of(task_id) -> Union{Nothing, String}

The owner half of a `:user`-scoped task id, or `nothing` when the id has none.

[`scoped_task_key`](@ref) builds `"<user_id>$(TASK_KEY_DELIMITER)<task_key>"`, and its
three rules — an owner may not contain `$(TASK_KEY_DELIMITER)`, may not end in `:`, and
a `:global` key may not contain `$(TASK_KEY_DELIMITER)` at all — make that mapping
injective. So the **first** `$(TASK_KEY_DELIMITER)` is always the delimiter and
everything before it is the owner, even when the key itself contains more of them.

A `:global` id is stored verbatim and therefore has no owner half. For those tasks
`watchers` remains the whole gate, exactly as before.
"""
function owner_of(task_id::AbstractString)
    id = String(task_id)
    range = findfirst(TASK_KEY_DELIMITER, id)
    range === nothing && return nothing   # :global, or a pre-#19 unscoped id
    first(range) == 1 && return nothing   # "::key" — an empty owner half is not an identity
    return id[1:prevind(id, first(range))]
end

"""
    TaskInfo(id; queue_name=nothing)

One task record — and, crucially, **one run of it**.

`id` names the task; `run_id` names *this attempt*. The two are not the same thing, because
re-running a finished key replaces the record with a brand-new `TaskInfo` while keeping the id
([`replace_task!`](@ref)). The previous run's worker task may still be in flight at that moment,
and a terminal write that only names the id is indistinguishable from one belonging to the run
that replaced it ([#108](https://github.com/PingoLee/Nitro.jl/issues/108)).

So the invariant is: **one `TaskInfo` object is one run.** A re-run constructs a new object; it is
never a mutation of the old one. Everything that identifies a run — `run_id` today — may therefore
be set exactly once, in this constructor, and read freely without synchronisation.
"""
mutable struct TaskInfo
    id::String
    # Identity of this run, not state of the task. Written only by `replace_task!`, never by
    # `set_task!` — the same split that protects `watchers`, and for the same reason: a value
    # carried along on every state transition is a value that gets clobbered.
    #
    # `uuid4()`, deliberately NOT `Crypto.secure_uuid4()`. A run id is an internal correlation
    # value: it is never returned to a caller and is never a capability, so guessing one buys
    # nothing — forging a terminal write also requires being inside the process that calls
    # `try_transition!`. `src/crypto.jl` documents the opposite trade-off for session ids,
    # which ARE capabilities.
    run_id::UUID
    status::TaskStatus
    @atomic progress::Float64
    result::Any
    error::Union{Nothing, String}
    created_at::DateTime
    started_at::Union{Nothing, DateTime}
    completed_at::Union{Nothing, DateTime}
    watchers::Vector{String}
    queue_name::Union{Nothing, String}
    # The cancellation token, and the CAUSE of the cancellation in one field. Process-local and
    # NOT persisted: it is a request aimed at a callback running *here*, and the durable `status`
    # is what carries a cancellation between processes. Read it with `cancel_requested` /
    # `cancel_reason`; write it only through `_request_cancel!`.
    #
    # `:none` means "not cancelled", so the flag and the reason cannot disagree. This was
    # `@atomic cancel_requested::Bool` until #183, with the reason nowhere — four different causes
    # all rendered as one of two strings, neither of which named the cause. Keeping them as two
    # fields was the obvious shape and is the worse one: a reader that observed the flag could
    # observe a reason not yet written, so every setter would owe a write ORDER, enforced by
    # review across four sites and every future one. One field makes a set token with no cause
    # unrepresentable instead.
    #
    # Excluded from `set_task!`'s field copy for the same reason `watchers` is: a stale
    # caller object carrying `:none` would ERASE a cancel that had already been requested,
    # which is the #88 clobber with the sign flipped.
    @atomic cancel_reason::Symbol

    function TaskInfo(id::String; queue_name::Union{Nothing, String}=nothing)
        created_at = current_time_utc()
        return new(
            id,
            uuid4(),
            PENDING,
            0.0,
            nothing,
            nothing,
            created_at,
            nothing,
            nothing,
            String[],
            queue_name,
            :none,
        )
    end
end

# Authority comes from the id; `watchers` is a list of ADDITIONAL grants layered on top
# of it. For a `:global` id `owner_of` is `nothing`, so the first disjunct is always
# false and `watchers` remains the whole gate there — unchanged from before.
_is_authorized(::System, ::TaskInfo) = true

function _is_authorized(authority::Owner, task_info::TaskInfo)
    owner = owner_of(task_info.id)
    owner !== nothing && owner == authority.user_id && return true
    return authority.user_id in task_info.watchers
end

# There is deliberately no raising `_authorize_task!` any more (#323). The read and cancel paths
# answer a task the caller may not see exactly as a missing one, so a denial there is a
# `nothing` from `_visible_record`, never an exception. `AuthorizationError` is left to the
# SUBMIT paths -- queue, join, grant -- where the caller already named the task and learns nothing.

"""
    update_progress!(task_info::TaskInfo, value::Real)

Atomically set a task's progress (0–100 scale) and return the task.

Call this from task callbacks instead of assigning `task_info.progress`
directly. The field is atomic, so a plain assignment raises
`ConcurrencyViolationError`; routing writes through this function keeps progress
updates race-free with the status readers that poll a running task.
"""
function update_progress!(task_info::TaskInfo, value::Real)
    @atomic task_info.progress = Float64(value)
    return task_info
end

"""
    CANCEL_REASONS

The four things that can request a cancellation, as the symbols [`cancel_reason`](@ref) reports.

| Reason | Who set it | What it already did to the record |
|---|---|---|
| `:user` | `cancel_task` | claimed `CANCELLED` **before** setting the token |
| `:timeout` | an expired `TaskOptions(timeout=…)` | nothing yet — it throws [`TaskTimeoutError`](@ref), which is terminal `FAILED` |
| `:superseded` | re-running a key whose predecessor is still executing | replaced the record, so the predecessor's `run_id` fence now fails |
| `:shutdown` | a teardown drain ([`shutdown!`](@ref), #176) | **nothing** — a terminal write there would race the run's own, the #88/#108 failure mode |

That last column is why the reason exists. Three of the four have already decided the record by
the time the callback notices, so only a drain leaves the run to write its own terminal state —
and before #183 it wrote `"Cancelled by user"` for a shutdown no user asked for. See
[`cancel_reason`](@ref).
"""
const CANCEL_REASONS = (:user, :timeout, :superseded, :shutdown)

# The ONLY write path into the token. Deliberately not exported and not public: workers §6 keeps
# `cancel_task` the authorized route into a cancellation, because it is the one that performs the
# authorization check and the status CAS. A public setter for the reason would be a second route
# into the token that skipped both.
#
# **First cause wins**, via CAS rather than assignment. A user cancel followed a second later by a
# teardown must still read `:user` — the person did cancel it, and the shutdown merely arrived
# afterwards. Last-write-wins would rewrite that attribution, and the drain is the write most
# likely to land last, since it fires on every in-flight run at once.
#
# Returns whether THIS call was the one that set it, which is what makes the rule testable.
function _request_cancel!(task_info::TaskInfo, reason::Symbol)
    @assert reason in CANCEL_REASONS "unknown cancellation reason :$reason"
    _, won = @atomicreplace task_info.cancel_reason :none => reason
    return won
end

# One renderer, so no call site can invent a string. `_cancel_task!` reads the reason off the
# `TaskInfo` rather than taking a message, which is what structurally closed the api.jl/queue.jl
# split -- there is no longer a parameter to pass differently on the two paths (#183).
#
# `:none` is reachable here: the durable-read branches of the retry loop cancel on a record that
# another process wrote, so nothing set a local token. Those writes always lose their CAS, so the
# text is never stored -- but it must still be a sentence rather than an error.
function _cancel_message(reason::Symbol)
    reason === :user && return "Cancelled by user"
    reason === :timeout && return "Cancelled by timeout"
    reason === :superseded && return "Cancelled by a re-run of this task key"
    reason === :shutdown && return "Cancelled by worker shutdown"
    return "Cancelled"
end

"""
    cancel_requested(task_info::TaskInfo) -> Bool

`true` once cancellation has been requested for **this run**, in **this process**.

Poll it from any long-running callback. It is the whole of Nitro's cancellation mechanism, and
four things set it — see [`CANCEL_REASONS`](@ref). None of them can stop a callback that never
looks ([#127](https://github.com/PingoLee/Nitro.jl/issues/127)).

```julia
submit_task("import", task_info -> begin
    for chunk in chunks
        cancel_requested(task_info) && return "cancelled"
        process(chunk)
        update_progress!(task_info, 100 * done / total)
    end
end, Owner("user-1"))
```

Nitro used to throw an `InterruptException` into the worker task as well. That is what Java's
`Thread.stop()` and .NET's `Thread.Abort()` did, and both were withdrawn as unfixable; in Julia
`schedule(t, exc; error=true)` against a task that is *already executing* aborts the process in
`jl_finish_task`. Go's `context.Context`, Sidekiq and River are all cooperative for the same
reason, and a single-process framework has no isolation boundary to kill across.

**It is process-local, and never reset.** A cancel issued on another node writes the durable
row and sets nothing here, so a cross-process callback must poll the record instead —
`get_task_status(task_info.id, System())[:status] == "CANCELLED"`, sparingly, since it is a
round-trip. Re-running a key builds a fresh `TaskInfo`, so the token starts unset by
construction rather than by being cleared; see [`TaskInfo`](@ref).

`true` on a `FAILED` task means the deadline fired, mirroring Go's `ctx.Err() ==
DeadlineExceeded` — and [`cancel_reason`](@ref) now says so outright rather than leaving it to
be inferred from the status.

**This is a function, not a field read.** It was `task_info.cancel_requested` until #183, which
replaced the `Bool` field with `@atomic cancel_reason::Symbol`; the accessor is unchanged in
name and meaning, the field is gone.
"""
cancel_requested(task_info::TaskInfo) = (@atomic task_info.cancel_reason) !== :none

"""
    cancel_reason(task_info::TaskInfo) -> Symbol

*Why* this run was asked to stop — one of [`CANCEL_REASONS`](@ref) — or `:none` if it was not.

`cancel_requested(t)` is exactly `cancel_reason(t) !== :none`; this is the same token read for
its cause instead of its truth value, so polling either costs one atomic load.

Use it to make a callback react differently to a deploy than to a person:

```julia
submit_task("import", task_info -> begin
    for chunk in chunks
        if cancel_requested(task_info)
            # A shutdown will restart us; checkpoint and let the next process resume.
            cancel_reason(task_info) === :shutdown && return checkpoint(done)
            return "cancelled"
        end
        process(chunk)
    end
end, Owner("user-1"))
```

**The first cause wins.** A run cancelled by a user and then caught by a teardown reports
`:user`, because that is who stopped it; the shutdown merely arrived afterwards.

It is process-local, exactly like the flag: a cancel issued on another node sets nothing here, so
a cross-process callback reads `:none` and must poll the record. And it says nothing about what
was *stored* — three of the four causes have already written the record, or will never write a
cancellation at all. [`shutdown!`](@ref) has the table.
"""
cancel_reason(task_info::TaskInfo) = @atomic task_info.cancel_reason

"""
    TaskTimeoutError(timeout)

A task callback outran its `TaskOptions(timeout=…)`.

Distinct from a plain `ErrorException` because it is the one failure that must **not** be
retried: nothing can stop the attempt that timed out, so retrying would run a second copy of the
callback beside the first, against the same `task_info` and the same external state. Its
`showerror` text is unchanged from the message this used to throw, so anything matching on the
rendered string still matches.
"""
struct TaskTimeoutError <: Exception
    timeout::Int
end

Base.showerror(io::IO, e::TaskTimeoutError) = print(io, "Timeout of $(e.timeout)s exceeded")

@kwdef struct TaskOptions
    priority::Int = 5
    timeout::Int = 3600
    retry_on_failure::Bool = false
    max_retries::Int = 3
end

struct QueueItem
    task_key::String
    # The run this item was queued FOR, not merely the key it was queued under. A queued item can
    # sit in the buffer while its key moves on — `cancel_task` makes the record terminal, a
    # re-submit then replaces it with a fresh run — so by the time a teardown abandons the backlog
    # the record under `task_key` may belong to somebody else. Writing a terminal state addressed
    # to the key rather than to the run is the #108/#167 defect, and workers §6 forbids it
    # outright; `_abandon_queued_item!` fences on this ([#182](https://github.com/PingoLee/Nitro.jl/issues/182)).
    #
    # `_execute_queued_task` fences on it too, and the comment here used to say the opposite --
    # that run-start "deliberately does NOT use it" because re-reading the record durably is the
    # correct claiming read (#167). That was #191, a bug recorded as design. The two rules are
    # ORTHOGONAL: the durable read decides WHICH RECORD to consult, this value decides WHOSE RUN
    # is consulting it. Claiming from whatever the read finds agrees with whoever currently owns
    # the key -- precisely the successor the fence exists to distinguish this run from -- so a
    # superseded item ran its callback against the successor's record and stored the result
    # under it, silently.
    #
    # The identity therefore has to be CARRIED from where it was minted, which is the general
    # rule workers §6 states: a fence value must come from before the window it guards, never
    # from inside it.
    run_id::UUID
    callback::Function
    options::TaskOptions
    created_at::DateTime

    function QueueItem(task_key::String, run_id::UUID, callback::Function, options::TaskOptions)
        return new(task_key, run_id, callback, options, current_time_utc())
    end
end

mutable struct SequentialQueue
    channel::Channel{QueueItem}
    running::Bool
    current_task::Union{Nothing, String}
    exec_lock::ReentrantLock
    processor_task::Union{Nothing, Task}
    # Set by `shutdown!` before it closes the channel: this queue is being torn down, so the
    # processor must record whatever it has already taken as abandoned rather than start it
    # ([#182](https://github.com/PingoLee/Nitro.jl/issues/182)).
    #
    # **On the QUEUE, not on the runtime**, and that placement is the whole design. A
    # runtime-level flag would have to be RESET for the documented shutdown-then-reuse case, and
    # the reset races a concurrent `submit_sequential_task` -- clearing it mid-teardown re-opens
    # exactly the window this closes. `shutdown!` empties the queue registry, so a reused runtime
    # mints fresh `SequentialQueue`s that are not draining *by construction*, and the only reader
    # of a dead queue's flag is its own processor, which is precisely who should see it.
    #
    # `@atomic` because the writer is `shutdown!` and the reader is the processor task.
    @atomic draining::Bool

    function SequentialQueue(size::Int=100)
        return new(Channel{QueueItem}(size), false, nothing, ReentrantLock(), nothing, false)
    end
end

mutable struct CleanupScheduler
    task::Task
    stop_signal::Channel{Nothing}
end