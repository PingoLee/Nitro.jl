@enum TaskStatus PENDING=1 RUNNING=2 COMPLETED=3 FAILED=4 CANCELLED=5

current_time_utc() = Dates.now(Dates.UTC)

"""
    DEFAULT_QUEUE_NAME

Queue name that [`submit_task`](@ref) authorizes against. Unqueued tasks do not
run through a `WorkerQueue`, but they are still submissions, so they are
still subject to the store's queue authorizer — under this name, following the
default-queue convention every comparable queue uses (Sidekiq `default`, River
`QueueDefault`).

A `TaskInfo.queue_name` stays `nothing` for these tasks: that field records the
*declared* queue a task belongs to, and an unqueued task belongs to none.
"""
const DEFAULT_QUEUE_NAME = "default"

"""
    WORKER_DRAIN_TIMEOUT_SECONDS

Default ceiling, in seconds, on [`shutdown!`](@ref)'s graceful drain before it stops waiting for
in-flight runs and warns.

**Half of `Nitro.Core.SHUTDOWN_TIMEOUT_SECONDS`, on purpose.** The HTTP drain only has to reap idle
keep-alive connections, so ten seconds is an outer bound it essentially never approaches. A worker
drain is the opposite: background jobs are long by definition, so a callback that does not poll
[`cancel_requested`](@ref cancel_requested(::TaskInfo)) will sit against this ceiling as a matter of course rather than as a
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
**child** task, so the handle in `active_tasks` is the parent wrapper parked in its wait, not
the task the callback is running on — the identity comparison misses on every path that has a
deadline, which is the default. Marking the run is what survives that indirection.

Written by `_invoke_task_callback` (`execution.jl`) rather than in `_claim_run!` or at the two
execute paths, because that is the single point both of them funnel through, with or without a
deadline.

Task-local storage is per-task and is **not** inherited by a spawned child, so two runs can never
see each other's marker. It is **not** enough on its own to keep the marker current, though: a
queue processor with `TaskOptions(timeout=0)` runs many callbacks on one long-lived
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
    TaskInfo(id; queue_name=nothing, external=false, job_name=nothing, job_args=nothing)

One task record — and, crucially, **one run of it**.

`id` names the task; `run_id` names *this attempt*. The two are not the same thing, because
re-running a finished key replaces the record with a brand-new `TaskInfo` while keeping the id
([`replace_task!`](@ref)). The previous run's worker task may still be in flight at that moment,
and a terminal write that only names the id is indistinguishable from one belonging to the run
that replaced it ([#108](https://github.com/PingoLee/Nitro.jl/issues/108)).

So the invariant is: **one `TaskInfo` object is one run.** A re-run constructs a new object; it is
never a mutation of the old one. Everything that identifies a run — `run_id` today — may therefore
be set exactly once, in this constructor, and read freely without synchronisation.

A run is published in two ways, and both go through this constructor. A **new submission** is
published by [`replace_task!`](@ref). A **new run of the same submission** is published by the
claim operations ([`claim_next!`](@ref), [`release_claim!`](@ref), [`requeue_expired!`](@ref),
[#514](https://github.com/PingoLee/Nitro.jl/issues/514)): a store that keeps objects installs a new
one, and a serializing store writes a fresh `run_id` in the same fenced statement. Neither ever
assigns `run_id` on an object a caller may already hold — that would hand a stale holder the
current run's identity, and every fence it then reaches would pass.

`external` is identity too: whether the submission was queued for a consumer process rather than
for this one, written once at submit. `claimed_by`, `lease_expires_at` and `attempt` describe the
current claim on an external submission and are written only by the claim operations;
`replace_task!` resets them, since a new submission has never been claimed.

`job_name` and `job_args` are identity as well: the registered name and the JSON text of the
arguments of a submission made as a [`Job`](@ref), both `nothing` for a closure. They are written
once at submit, so `replace_task!` publishes them and `set_task!` never writes them.
"""
mutable struct TaskInfo
    id::String
    # Identity of this run, not state of the task. Minted only by this constructor, and published
    # by `replace_task!` or a claim operation (see the docstring) — never written by `set_task!` or
    # `try_transition!`, which is the same split that protects `watchers`, for the same reason: a
    # value carried along on every state transition is a value that gets clobbered.
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
    # The claim fields (#514). `external` is fixed at submit; the other three belong to the
    # current claim and, like `run_id`, are written only by the store's claim operations, so
    # `set_task!` never carries them. All four are inert on a submission this process runs itself.
    external::Bool
    claimed_by::Union{Nothing, String}
    lease_expires_at::Union{Nothing, DateTime}
    attempt::Int
    # A named job (#514): the name it was registered under and its arguments as JSON text, fixed at
    # submit, `nothing` for a closure. Submission identity like `external`, so a claim, a hand-back
    # and a requeue carry them and `set_task!` never writes them. This process runs its own named
    # submissions from the queue item's copy; the row is what a consumer process will read.
    job_name::Union{Nothing, String}
    job_args::Union{Nothing, String}
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

    function TaskInfo(id::String; queue_name::Union{Nothing, String}=nothing, external::Bool=false,
                      job_name::Union{Nothing, String}=nothing, job_args::Union{Nothing, String}=nothing)
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
            external,
            nothing,
            nothing,
            0,
            job_name,
            job_args,
            :none,
        )
    end
end

# A new run of the same submission (#514): what a claim, a hand-back or a lease requeue publishes.
# A NEW object, so a holder of the previous run's object keeps the previous `run_id` and loses
# every fence from here on -- the #108 rule, for a store whose records are the objects. Identity of
# the submission (`id`, `created_at`, `queue_name`, `external`, `job_name`, `job_args`) is carried; the watcher list is
# copied, never shared, because `add_watcher!` swaps it copy-on-write and a shared vector would
# make two records' grants one. The claim and run state are the caller's to set.
function _successor_run(t::TaskInfo)
    s = TaskInfo(t.id; queue_name = t.queue_name, external = t.external,
                 job_name = t.job_name, job_args = t.job_args)
    s.created_at = t.created_at
    s.watchers = copy(t.watchers)
    s.status = t.status
    @atomic s.progress = t.progress
    s.result = t.result
    s.error = t.error
    s.started_at = t.started_at
    s.completed_at = t.completed_at
    s.claimed_by = t.claimed_by
    s.lease_expires_at = t.lease_expires_at
    s.attempt = t.attempt
    return s
end

"""
    LeasePolicy(on_expiry::Symbol; max_attempts::Int = 3)

What [`requeue_expired!`](@ref) does with a run on an external queue whose lease expired
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)).

- `:requeue` puts the run back to `PENDING` under a fresh `run_id`, while its `attempt` count is
  below `max_attempts`, and records it `FAILED` once it reaches the bound. That makes delivery
  **at-least-once**: the job must be idempotent.
- `:fail` records it `FAILED` on the first expiry; `max_attempts` does not apply.

There is no default `on_expiry`. Whether a lost run may run again depends on whether the job is
idempotent, which only the application knows, and a default of `:requeue` would let an email or a
charge repeat silently.
"""
struct LeasePolicy
    on_expiry::Symbol
    max_attempts::Int

    function LeasePolicy(on_expiry::Symbol, max_attempts::Int)
        on_expiry in (:requeue, :fail) || throw(ArgumentError(
            "`on_expiry` must be :requeue or :fail, got :$on_expiry"))
        max_attempts >= 1 || throw(ArgumentError(
            "`max_attempts` must be at least 1, got $max_attempts"))
        return new(on_expiry, max_attempts)
    end
end

LeasePolicy(on_expiry::Symbol; max_attempts::Int = 3) = LeasePolicy(on_expiry, max_attempts)

# Authority comes from the id; `watchers` is a list of ADDITIONAL grants layered on top
# of it. For a `:global` id `owner_of` is `nothing`, so the first disjunct is always
# false and `watchers` remains the whole gate there — unchanged from before.
_is_authorized(::System, ::TaskInfo) = true

function _is_authorized(authority::Owner, task_info::TaskInfo)
    _owns(authority, task_info.id) && return true
    return authority.user_id in task_info.watchers
end

# The half of `_is_authorized` the id alone decides: a `:user`-scoped id names its owner. Split out
# so a store can authorize before it reads the record (`_may_read_durable`, #565).
function _owns(authority::Owner, task_id::String)
    owner = owner_of(task_id)
    return owner !== nothing && owner == authority.user_id
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

The five things that can request a cancellation, as the symbols [`cancel_reason`](@ref cancel_reason(::TaskInfo)) reports.

| Reason | Who set it | What it already did to the record |
|---|---|---|
| `:user` | `cancel_task` | claimed `CANCELLED` **before** setting the token |
| `:timeout` | an expired `TaskOptions(timeout=…)` | nothing yet — it throws [`TaskTimeoutError`](@ref), which is terminal `FAILED` |
| `:superseded` | re-running a key whose predecessor is still executing | replaced the record, so the predecessor's `run_id` fence now fails |
| `:shutdown` | a teardown drain ([`shutdown!`](@ref), #176), or a consumer process's drain (#514) | **nothing** — a terminal write there would race the run's own, the #88/#108 failure mode. On a consumer the run is **handed back** to the queue, not recorded |
| `:lease_lost` | a consumer process's heartbeat, finding its lease taken back and the same submission re-queued or re-claimed (#514) | taken the run back: another run of it will happen. The run is handed back, which loses its fence and writes nothing |

That last column is why the reason exists. Most causes have already decided the record by the
time the callback notices, so only a drain leaves the run to write its own terminal state — and
before #183 it wrote `"Cancelled by user"` for a shutdown no user asked for. A job on an external
queue reads `:lease_lost` as *stop, and assume the run will happen again*, never as a person's
cancel: a cancel a person asked for always reads `:user`. See [`cancel_reason`](@ref cancel_reason(::TaskInfo)).
"""
const CANCEL_REASONS = (:user, :timeout, :superseded, :shutdown, :lease_lost)

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
    reason === :lease_lost && return "Cancelled: the consumer lost its lease on this run"
    return "Cancelled"
end

# The inverse, for a record read back from the store: which cause cancelled it (#514). A
# consumer process reads it to tell "a person cancelled this run" from "it was taken back", and
# that cause is not stored anywhere else -- the token above is process-local.
#
# Exact, because `_cancel_message` is the ONLY renderer of a CANCELLED record's `error`: every
# write that claims CANCELLED passes its text straight through (`cancel_task`, `_cancel_task!`,
# `_abandon_queued_item!`), and the error redactor and truncation reach only the FAILED path
# (`_store_error_text`). A text it does not recognise -- `nothing`, or a record written before
# #183 -- answers `:none`.
function _cancel_reason_from_error(err::Union{Nothing, AbstractString})
    err === nothing && return :none
    for reason in CANCEL_REASONS
        err == _cancel_message(reason) && return reason
    end
    return :none
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
DeadlineExceeded` — and [`cancel_reason`](@ref cancel_reason(::TaskInfo)) now says so outright rather than leaving it to
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
            # A shutdown will restart us; save how far we got, so the next process resumes from it.
            cancel_reason(task_info) === :shutdown && return save_position(done)
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

Distinct from a plain `ErrorException` because it is the one callback failure that must **not**
be retried: nothing can stop the attempt that timed out, so retrying would run a second copy of
the callback beside the first, against the same `task_info` and the same external state. (The
executor does not retry `StackOverflowError`, `OutOfMemoryError` or `InterruptException` either,
since #367, but those are reports on the process, not failures of the callback.) Its
`showerror` text is unchanged from the message this used to throw, so anything matching on the
rendered string still matches.
"""
struct TaskTimeoutError <: Exception
    timeout::Int
end

Base.showerror(io::IO, e::TaskTimeoutError) = print(io, "Timeout of $(e.timeout)s exceeded")

"""
    TaskCancelledError(reason::Symbol)

What [`checkpoint!`](@ref) throws once the run has been asked to stop. `reason` is the
[`cancel_reason`](@ref cancel_reason(::TaskInfo)) it found, one of [`CANCEL_REASONS`](@ref).

Both executors recognise it: the run is recorded through the same compare-and-set as every other
cancellation, and it is **never retried**, since the token is never reset and a retry would start
already cancelled. A callback that catches it to clean up should rethrow it.
"""
struct TaskCancelledError <: Exception
    reason::Symbol
end

Base.showerror(io::IO, e::TaskCancelledError) = print(io, _cancel_message(e.reason))

"""
    checkpoint!(task_info::TaskInfo) -> Nothing

A yield point for a long-running callback ([#513](https://github.com/PingoLee/Nitro.jl/issues/513)):
give the thread back to whatever is waiting for it, then throw [`TaskCancelledError`](@ref) if this
run has been asked to stop.

```julia
submit_queued_task(app, "compute", "fit-42", task_info -> begin
    for (i, batch) in enumerate(batches)
        train!(model, batch)                  # a few milliseconds of computation
        checkpoint!(task_info)                # yield, and stop here if cancelled
        update_progress!(task_info, 100 * i / length(batches))
    end
    return summary(model)
end, Owner(uid))
```

**Why it exists.** Julia's tasks are cooperative and Julia 1.12 has no preemption: a callback that
computes without reaching `yield`, `sleep`, `wait` or I/O holds its thread until it returns. Worker
callbacks share the `:default` thread pool with every request handler, so a request scheduled onto
that thread waits for the whole computation. `checkpoint!` is the explicit point at which it
stops waiting. Call it every few milliseconds of work. When nothing else is waiting to run, a call
costs about a microsecond, almost all of it the `yield` (0.6 µs on the main task and 1.1 µs inside
a worker run, measured on Julia 1.12), so a call per millisecond of work costs about 0.1%.

**It is the task API's `yield()` plus the cancellation check, in one call.** After the yield it
reads the same token [`cancel_requested`](@ref cancel_requested(::TaskInfo)) does, so it honours every cause in
[`CANCEL_REASONS`](@ref): a `cancel_task`, an expired `TaskOptions(timeout=…)`, a re-run of the key,
and a teardown drain. The throw unwinds the callback, and the executor records the run as the
cancellation it was. A callback that would rather finish its current unit of work first can still
poll `cancel_requested` itself and return; the two compose.

**What it does not do:**

- It does not preempt anything. A callback that never calls it gains nothing.
- It does not bound garbage collection: a job that allocates heavily still triggers stop-the-world
  pauses that stop handlers too.
- It reads the **in-process** token, exactly like `cancel_requested`. A cancel issued on another
  node writes the durable record and sets nothing here.
"""
function checkpoint!(task_info::TaskInfo)
    yield()
    # After the yield, not before: a cancel that lands while this run is off its thread is seen at
    # once rather than one checkpoint later.
    reason = cancel_reason(task_info)
    reason === :none || throw(TaskCancelledError(reason))
    return nothing
end

@kwdef struct TaskOptions
    priority::Int = 5
    timeout::Int = 3600
    retry_on_failure::Bool = false
    max_retries::Int = 3
end

# An in-process queue's buffer, and the default backlog bound of an external one: the same 100, so
# moving a queue out of process does not change how many runs it admits.
const _DEFAULT_QUEUE_BUFFER = 100

"""
    External(; on_lease_expiry, max_attempts = 3, max_pending = 100, options = TaskOptions())

The placement of a queue whose runs execute in a **separate consumer process**, not in the process
that submits them ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)). Declare it with
[`declare_queues!`](@ref), in a setup function that the web process and the consumer both call:

```julia
declare_queues!(app, ["email", "heavy" => External(on_lease_expiry = :requeue)])
```

The web process only records a submit to `"heavy"`. A consumer process claims the run from the
shared store, under a lease, and runs it.

- **`on_lease_expiry` has no default.** It decides what happens to a run whose consumer died
  mid-run, so that its lease expired: `:requeue` runs it again (at-least-once delivery, so **the
  job must be idempotent**), and `:fail` records it `FAILED`. Omitting it is an `ArgumentError`,
  because only the application knows whether its job may run twice, and a default of `:requeue`
  would let an email or a charge repeat silently. See [`LeasePolicy`](@ref).
- **`max_attempts`** bounds `:requeue`: a run claimed that many times is recorded `FAILED`.
- **`max_pending`** bounds the backlog: a submit is refused with `WorkerCapacityError(:queue, …)`
  (a `503`) once the store holds that many `PENDING` runs of the queue. The default, 100, is an
  in-process queue's buffer size, so moving a queue out of process admits the same backlog;
  `max_pending = nothing` removes the bound. The count is read before
  the insert, so concurrent submits can overshoot it by a few rows. It bounds runaway callers; it
  is not an exact quota.
- **`options`** are the queue's `TaskOptions`: the consumer runs every run of the queue
  with them. A submit cannot pass its own, because the consumer never sees the submit call.

Only a **named job** can run on an external queue ([`register_job!`](@ref), [`Job`](@ref)): a
closure cannot cross a process boundary, so submitting one is an `ArgumentError`.
"""
struct External
    policy::LeasePolicy
    max_pending::Union{Nothing, Int}
    options::TaskOptions

    function External(policy::LeasePolicy, max_pending::Union{Nothing, Integer}, options::TaskOptions)
        max_pending === nothing || max_pending >= 1 || throw(ArgumentError(
            "`max_pending` must be at least 1 or `nothing`, got $max_pending"))
        return new(policy, max_pending === nothing ? nothing : Int(max_pending), options)
    end
end

function External(; on_lease_expiry::Union{Nothing, Symbol} = nothing, max_attempts::Integer = 3,
                  max_pending::Union{Nothing, Integer} = _DEFAULT_QUEUE_BUFFER,
                  options::TaskOptions = TaskOptions())
    on_lease_expiry === nothing && throw(ArgumentError(
        "External(…) needs `on_lease_expiry`: `:requeue` runs a run again when its consumer dies " *
        "mid-run (the job must be idempotent), `:fail` records it FAILED. There is no default, " *
        "because only the application knows whether its job may run twice"))
    return External(LeasePolicy(on_lease_expiry; max_attempts = Int(max_attempts)), max_pending, options)
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

# A declared queue: one buffer drained by up to `concurrency` processor tasks (#513).
#
# **`concurrency` is a bulkhead, not a throughput knob.** Every processor runs on `:default`, the
# pool that also runs every request handler, and Julia 1.12 has no preemption (#467), so a queue of
# CPU-bound jobs with `k` processors can hold at most `k` of those threads -- the rest stay free for
# handlers by construction. That is Sidekiq's per-queue concurrency and River's `MaxWorkers`.
#
# One exception, deliberately not closed here: a callback abandoned by `TaskOptions(timeout=…)` frees
# its processor but keeps its thread until it returns, so a queue of timing-out callbacks that never
# reach `checkpoint!` can hold more than `k`. Those count against `max_concurrent_runs` instead, and
# the queues hold their next item once they fill it (#324); `checkpoint!` is what makes the deadline
# actually stop such a callback.
#
# `k = 1` is the strict FIFO queue this type used to be (`SequentialQueue`). With `k > 1` items still
# START in FIFO order, since every processor `take!`s from the one channel, but they finish in
# whatever order they finish. Nothing else changes with `k`: each processor runs its item through
# the same `_execute_queued_task`, so the claim, the `run_id` fences, cancellation, deadlines and the
# teardown drain hold per item exactly as they do for one. A stale item and its successor can now
# execute side by side on two processors of one queue, which is the async path's ordinary case and
# is what `_claim_run!` takes `lock_tasks` for (#191, #198).
#
# There used to be an `exec_lock` held around each execution. With one processor it serialized
# nothing that the processor loop did not already serialize, and with `k` it would serialize the
# processors back into one, so it is gone.
mutable struct WorkerQueue
    channel::Channel{QueueItem}
    const concurrency::Int
    # The live processor tasks, at most `concurrency` of them, under `queue_lock`. A processor
    # removes itself in its `finally`, so `!isempty(processors)` is "this queue is running", and
    # `_start_queue_processor` tops the set back up to `concurrency` on the next submit.
    processors::Vector{Task}
    # The task ids the processors are executing right now, one entry per busy processor, under
    # `queue_lock`. A list, not a set: two processors can hold items for one key at once (a stale
    # item and its successor), and each removes only its own entry.
    current_tasks::Vector{String}
    # Set by `shutdown!` before it closes the channel: this queue is being torn down, so the
    # processor must record whatever it has already taken as abandoned rather than start it
    # ([#182](https://github.com/PingoLee/Nitro.jl/issues/182)).
    #
    # **On the QUEUE, not on the runtime**, and that placement is the whole design. A
    # runtime-level flag would have to be RESET for the documented shutdown-then-reuse case, and
    # the reset races a concurrent `submit_queued_task` -- clearing it mid-teardown re-opens
    # exactly the window this closes. `shutdown!` empties the queue registry, so a reused runtime
    # mints fresh `WorkerQueue`s that are not draining *by construction*, and the only reader
    # of a dead queue's flag is its own processor, which is precisely who should see it.
    #
    # `@atomic` because the writer is `shutdown!` and the reader is the processor task.
    @atomic draining::Bool
    # Slots handed out to submissions that have not yet been TAKEN by the processor (#324).
    # Reserved before the record is written and released at `take!`, so it bounds the buffer
    # exactly and `put!` can never block: a full queue refuses the submit instead of parking the
    # submitting request in `put!` with no timeout, which let one owner hang everyone else.
    # `capacity` is stored rather than read back off the `Channel`'s internals.
    capacity::Int
    @atomic reserved::Int
    # The items the processors have TAKEN but are holding back while abandoned queued callbacks
    # fill the runtime cap (#324), at most one per processor, under `queue_lock`. They are out of
    # the channel, so `shutdown!`'s collect step would miss them, and they would be abandoned only
    # after the teardown had returned -- PENDING forever on a persistent store if the process exits
    # first (the #182 orphan). So `shutdown!` collects them from here too; both abandons are the
    # same idempotent CAS.
    held::Vector{QueueItem}

    function WorkerQueue(size::Int=_DEFAULT_QUEUE_BUFFER; concurrency::Int=1)
        size >= 1 || throw(ArgumentError("WorkerQueue size must be at least 1, got $size"))
        concurrency >= 1 || throw(ArgumentError(
            "WorkerQueue concurrency must be at least 1, got $concurrency"))
        return new(Channel{QueueItem}(size), concurrency, Task[], String[], false, size, 0,
                   QueueItem[])
    end
end

mutable struct CleanupScheduler
    task::Task
    stop_signal::Channel{Nothing}
    # The one thing the loop parks on between ticks (#369): notified by the tick's `Timer` and by
    # `stop_cleanup_scheduler!`. Autoreset, so a notify that lands before the loop reaches its
    # `wait` is kept rather than lost -- that is what makes the stop race-free without polling.
    wake::Base.Event
end