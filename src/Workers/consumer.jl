# ── The consumer process (#514) ──────────────────────────────────────────────────────────────
#
# `consume!` is the entry point of a process that runs an app's `External(…)` queues: it claims
# their runs from the shared store under a lease, runs them, and keeps the leases alive. The web
# process only records the submits. Design record: docs/design/workers-external-consumer.md §5–§7.
#
# Three kinds of task, and what each owns:
#
# * the CLAIM LOOP (`:default`, detached): claims while a queue has a free slot, and parks on
#   `wake` when there is nothing to claim. It is the only task that claims, so a slot count it
#   reads cannot be raised behind its back.
# * one RUN TASK per claimed run (`:default`, detached): binds the named job and runs the shared
#   attempt loop. Its outcome is a terminal write, or a hand-back (`release_claim!`) when the run
#   ended on `:shutdown` or `:lease_lost`, which are not the run's fault and leave it wanted.
# * the HEARTBEAT (`:interactive`): one `renew_leases!` per tick for every run the process holds,
#   then `requeue_expired!`. On the interactive thread because a CPU-bound job holds a `:default`
#   thread without yielding (#467), and a starved heartbeat turns a healthy run into a stolen one.
#   It is the one Nitro loop placed there on purpose (concurrency §3).
#
# Nothing here runs the unleased zombie sweep. Every row a web process runs in-process has no
# `claimed_by` and no handle in THIS process, so the sweep would fail the web's live jobs (§3).

# One run this process holds. `info` is the claimed run's own object: its cancel token is how the
# heartbeat and the drain reach the job, and its `progress` is what the heartbeat persists.
struct _HeldRun
    info::TaskInfo
    queue::String
end

mutable struct ConsumerHandle{S <: AbstractWorkerStore}
    const app::App
    # Used for its store and for the terminal writes it fences (`_finish_task!`); it is never
    # started, so it has no queue, no processor and no cleanup scheduler.
    const runtime::WorkerRuntime{S}
    const consumer_id::String
    const queues::Vector{Pair{String, Int}}       # name => this process's concurrency
    const placements::Dict{String, External}
    # Every external queue the app declares, not only the consumed ones: `requeue_expired!`
    # fails a leased row whose queue it has no policy for.
    const policies::Dict{String, LeasePolicy}
    const lease_seconds::Float64
    const poll_seconds::Float64
    const drain_timeout::Float64

    # Under `lock`. `held` is what the heartbeat renews and the drain cancels. `busy` is each
    # queue's occupied slots, and outlives a `held` entry when a deadline abandoned a callback:
    # the run is recorded and no longer renewed, but its callback still holds a thread
    # (`_RunHandoff`), so the slot stays taken until it returns.
    const lock::ReentrantLock
    const held::Dict{UUID, _HeldRun}
    const busy::Dict{String, Int}
    const poisoned::Set{String}
    @atomic held_count::Int          # `length(held)`, readable without the lock by the drain's wait

    const wake::Base.Event            # the claim loop's park: its timer, a freed slot, a stop
    const beat::Base.Event            # the heartbeat's park: its timer, the end of the drain, the last straggler
    const stop_requested::Base.Event  # what `consume!` waits on
    @atomic stopping::Bool            # no more claims
    # The drain clears it when it ends. The heartbeat then runs on until the last held run settles
    # (`_keeps_beating`), so a run a timed-out drain left going keeps its lease in a live process.
    @atomic beating::Bool
    @atomic drained::Bool             # the drain has begun; a second caller waits for it
    @atomic finished::Bool            # the drain has ended, however it ended
    claim_task::Union{Nothing, Task}
    heartbeat_task::Union{Nothing, Task}
    # Held for the consumer's lifetime on the Julia versions `_needs_wake_guard` names, closed by
    # the drain. See `_consumer_wake_guard`.
    const wake_guard::Union{Nothing, Timer}
end

const CONSUMER_DEFAULT_LEASE = Dates.Second(60)

# JuliaLang/julia#63882 (#586): on Julia 1.13.0-rc3 through 1.13.x, a task parked on a `Timer`
# does not wake while every `:default` thread runs a `yield()`ing loop, as long as its timer is the
# only live libuv handle. A consumer parks both its loops on one-shot `Timer`s, and its jobs are
# exactly those loops when they follow the "yield every few ms" advice. A consumer never calls
# `serve`, so it does not get `serve`'s guard (#604): it holds its own never-firing `Timer`, under
# the same gate, so lowering that gate when a fixed 1.13.x ships retires both.
_consumer_wake_guard() = (_WAKE_GUARD_FORCED[] || _needs_wake_guard()) ? Timer(typemax(Int32)) : nothing

# An interrupt, however a store wrapped it. PormG hands back a Ctrl-C that landed inside a query as
# a `DatabaseError` whose `cause` is the `InterruptException`, so a bare `isa` test would log the
# press as a failed tick and lose the stop request. Every catch below asks this instead.
_is_interrupt(e) = e isa InterruptException ||
    (hasproperty(e, :cause) && getproperty(e, :cause) isa InterruptException)

_positive_seconds(x::Real, what::String) = (isfinite(x) && x > 0) ? Float64(x) :
    throw(ArgumentError("`$what` must be a positive duration, got $x"))
_positive_seconds(p::Dates.Period, what::String) = _positive_seconds(Dates.toms(p) / 1000, what)

# Unique per process start: a restarted consumer must not renew the previous one's leases.
_default_consumer_id() = string(first(gethostname(), 128), ":", getpid(), ":", first(string(uuid4()), 8))

"""
    consume!(app::App; store, queues, lease = Second(60), consumer_id = <host:pid:random>,
             drain_timeout = WORKER_DRAIN_TIMEOUT_SECONDS, poll_interval = Second(1))

Run `app`'s `External(…)` queues in **this** process, until it is told to stop
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)). It is the consumer's entry point: the
same app code as the web process, the same setup function, and no `serve`.

```julia
# consumer.jl, started with `julia -t 4,1 --project consumer.jl`
using MyApp, Nitro, Nitro.Workers
app = MyApp.build_app()
MyApp.setup_workers!(app)                  # declare_queues! + register_job!, as the web process does
consume!(app; store = pormg_nitro_worker(), queues = ["heavy" => 4])
```

`queues` lists the queues this process runs, each with **this process's** concurrency: `"heavy"
=> 4` runs up to four of its runs at once here, and two consumers with `4` run eight. Each queue
must be declared `External(…)` on `app`.

What it does:

- **Claims** each queue's oldest runs from the shared store, under a **lease** of `lease`, while
  it has a free slot, and checks again every `poll_interval` when there is nothing to claim.
- **Runs** each one as its named job, with the queue's `External(…; options)`.
- **Keeps the leases alive** from a heartbeat on the interactive thread, every third of the lease,
  and persists each run's `update_progress!` with it. A healthy run whose heartbeat is late by
  more than the lease, for instance through a garbage-collection pause that long, can be taken
  back and run again: **the lease must exceed the worst pause your jobs cause**.
- **Use the LibPQ driver for a consumer.** The heartbeat's renewal stays on the interactive thread
  only with LibPQ. On SQLite and Postgres.jl, PormG runs the statement on a `:default` task
  ([PormG#1280](https://github.com/PingoLee/PormG.jl/issues/1280)), so CPU-bound jobs that fill every
  `:default` thread without yielding can still let healthy leases expire there, and their runs
  then run twice.
- **Adjudicates expired leases** by each queue's `on_lease_expiry`, once before the first claim and
  on every heartbeat, so a crashed consumer's runs are re-queued or failed.
- **Tells a job why it must stop.** A run whose lease is no longer this process's reads, at its
  next [`checkpoint!`](@ref), the reason from the store: `:user` for a `cancel_task`,
  `:lease_lost` when its lease was taken back and the run will happen again, `:superseded`
  otherwise. Cancellation reaches a consumer at the next heartbeat, not at once.

**Stopping.** A supervisor's `SIGTERM`, a `SIGINT` (Ctrl-C), or an interrupt in a REPL drains the
consumer: it stops claiming, sets `:shutdown` on every run it holds, keeps renewing their leases
for up to `drain_timeout` seconds, and returns. A run that ends in that window is **handed back**
to its queue, not cancelled, so the next consumer runs it again, even one that finished: its
result is discarded, because a job that saw the token and returned early looks the same as one
that completed. A run still going when `consume!` returns **in a process that lives on**, as in a
REPL, keeps being renewed until it returns, and is handed back then: it finishes under a live
lease, and no other consumer runs it at the same time. A run that never returns keeps its lease,
and the heartbeat, for as long as the process lives. A run still going when the process
exits keeps its lease until it expires, and is then re-queued or failed by its queue's policy. On
Windows a terminate is a hard kill that runs no hook, so there a stopped consumer's runs wait for
their leases to expire, as after a crash.

**Refused before anything starts** (`ArgumentError`): no `queues`; a queue `app` does not declare
`External(…)`; a store without the claim capability or one no other process can read
(`InMemoryWorkerStore`); and **a process with no interactive thread**: start it with
`julia -t k,1`, so the heartbeat has a thread a job cannot take.

A consumer never runs the zombie sweep: the web process's in-process runs look exactly like
zombies from here.
"""
function consume!(app::App; kwargs...)
    c = _start_consumer(app; kwargs...)
    # A supervisor's SIGTERM, and a SIGINT outside a REPL, end the process through `exit`, which
    # runs the `atexit` hooks but never returns to the wait below (probed on 1.12 and 1.13: a hook
    # can still spawn and wait on tasks on other threads). So the drain is registered here, at call
    # time, never in a module body. After a normal return it finds the drain done and returns.
    atexit(() -> _drain!(c))
    try
        wait(c.stop_requested)
    finally
        _drain!(c)
    end
    return nothing
end

function _start_consumer(app::App; store::AbstractWorkerStore, queues::AbstractVector,
                         lease::Union{Real, Dates.Period} = CONSUMER_DEFAULT_LEASE,
                         consumer_id::AbstractString = _default_consumer_id(),
                         drain_timeout::Real = WORKER_DRAIN_TIMEOUT_SECONDS,
                         poll_interval::Union{Real, Dates.Period} = Dates.Second(1),
                         require_interactive::Bool = true)
    isempty(queues) && throw(ArgumentError(
        "consume! needs at least one queue to run, like `queues = [\"heavy\" => 4]`"))
    specs = _queue_specs(queues)
    declared = Dict{String, External}(_app_external_queues(app))
    placements = Dict{String, External}()
    for (name, _) in specs
        placement = Base.get(declared, name, nothing)
        placement === nothing && throw(ArgumentError(
            "queue \"$name\" is not declared External(…) on this app. Call the setup function that " *
            "declares it, `declare_queues!(app, [\"$name\" => External(…)])`, before `consume!`: " *
            "the web process and the consumer must read their placements from one place"))
        placements[name] = placement
    end
    _check_external_store(store, Pair{String, External}[name => p for (name, p) in placements])
    if require_interactive && Threads.nthreads(:interactive) == 0
        throw(ArgumentError(
            "consume! needs an interactive thread for its lease heartbeat, which a CPU-bound job " *
            "would otherwise starve until healthy runs lose their leases: start the consumer " *
            "with `julia -t k,1`"))
    end
    drain_timeout >= 0 || throw(ArgumentError("`drain_timeout` must be >= 0, got $drain_timeout"))
    lease_seconds = _positive_seconds(lease, "lease")
    poll_seconds = _positive_seconds(poll_interval, "poll_interval")
    _check_consumer_id(consumer_id)

    c = ConsumerHandle(app, WorkerRuntime(store), String(consumer_id), specs, placements,
                       Dict{String, LeasePolicy}(name => p.policy for (name, p) in declared),
                       lease_seconds, poll_seconds, Float64(drain_timeout),
                       ReentrantLock(), Dict{UUID, _HeldRun}(), Dict{String, Int}(), Set{String}(), 0,
                       Base.Event(true), Base.Event(true), Base.Event(),
                       false, true, false, false, nothing, nothing, _consumer_wake_guard())

    # Every start has a stop on every path (#427): a claim loop that fails to start must not
    # leave the heartbeat it started renewing nothing for ever, nor the guard open.
    try
        # Before the first claim, so a consumer that finds nothing to do still adjudicates its
        # crashed predecessor's run (§3).
        _consumer_requeue!(c)

        pool = Threads.nthreads(:interactive) > 0 ? :interactive : :default
        c.heartbeat_task = errormonitor(_spawn_detached(() -> _heartbeat_loop(c); pool))
        c.claim_task = errormonitor(_spawn_detached(() -> _claim_loop(c)))
    catch
        @atomic c.beating = false
        notify(c.beat)
        c.wake_guard === nothing || close(c.wake_guard)
        rethrow()
    end
    @info "Nitro.Workers: consumer started" consumer_id = c.consumer_id queues = c.queues lease_seconds
    return c
end

# -- Claiming --

_request_stop!(c::ConsumerHandle) = (notify(c.stop_requested); nothing)

function _free_slot(c::ConsumerHandle, queue::String, k::Int)
    return lock(c.lock) do
        !(queue in c.poisoned) && Base.get(c.busy, queue, 0) < k
    end
end

function _release_slot!(c::ConsumerHandle, queue::String)
    lock(c.lock) do
        n = Base.get(c.busy, queue, 0)
        c.busy[queue] = max(n - 1, 0)
    end
    notify(c.wake)
    return nothing
end

function _claim_loop(c::ConsumerHandle)
    while !(@atomic c.stopping)
        # The `try` is inside the `while` (#169): one bad pass costs a poll interval, never the
        # loop. A dead claim loop under a live heartbeat would be a consumer that never claims
        # again and never exits, which a supervisor reads as healthy.
        try
            claimed = false
            for (queue, k) in c.queues
                (@atomic c.stopping) && break
                _free_slot(c, queue, k) || continue
                run = _claim_one(c, queue)
                run === nothing && continue
                claimed = true
                _start_run!(c, run, queue)
            end
            # Claimed something: look again at once, there may be more. Otherwise park until a
            # slot frees, the poll interval passes, or a stop.
            claimed && continue
            timer = Timer(_ -> notify(c.wake), c.poll_seconds)
            try
                (@atomic c.stopping) || wait(c.wake)
            finally
                close(timer)
            end
        catch e
            if _is_interrupt(e)
                @warn "Nitro.Workers: an interrupt (Ctrl-C) reached the consumer's claim loop; draining"
                _request_stop!(c)
                return nothing
            end
            @error "Nitro.Workers: a consumer's claim pass failed; retrying after the poll interval" exception = (e, catch_backtrace())
            # Parked like the normal path, so a drain cuts it short. Inside its own `try`: an
            # interrupt here must still become a stop request, not end the task.
            try
                timer = Timer(_ -> notify(c.wake), c.poll_seconds)
                try
                    (@atomic c.stopping) || wait(c.wake)
                finally
                    close(timer)
                end
            catch e2
                _is_interrupt(e2) || rethrow()
                _request_stop!(c)
                return nothing
            end
        end
    end
    return nothing
end

function _claim_one(c::ConsumerHandle, queue::String)
    try
        return claim_next!(c.runtime.store, queue, c.consumer_id; lease_seconds = c.lease_seconds)
    catch e
        _is_interrupt(e) && throw(InterruptException())
        if e isa ClaimPoisonedError
            # Stop, never retry (§11): the store fails at most one undecodable row per call, so a
            # retry loop would fail the whole backlog one row at a time. The other queues go on.
            lock(() -> push!(c.poisoned, queue), c.lock)
            @error "Nitro.Workers: this consumer stopped claiming from a queue: two of its head " *
                   "rows in one claim did not decode, so the cause is probably not the rows. " *
                   "Inspect them before restarting the consumer" queue consumer_id = c.consumer_id exception_type = e.exception_type
        else
            @error "Nitro.Workers: a claim failed; retrying on the next poll" queue exception = (e, catch_backtrace())
        end
        return nothing
    end
end

function _start_run!(c::ConsumerHandle, run::TaskInfo, queue::String)
    # Under the same lock the drain snapshots `held` with, and checking `stopping` there: a run
    # claimed while the drain began is either in the snapshot, or given straight back here.
    accepted = lock(c.lock) do
        (@atomic c.stopping) && return false
        c.held[run.run_id] = _HeldRun(run, queue)
        @atomic c.held_count = length(c.held)
        c.busy[queue] = Base.get(c.busy, queue, 0) + 1
        return true
    end
    accepted || return (_hand_back!(c, run, queue); nothing)
    errormonitor(_spawn_detached(() -> _run_claimed!(c, run, queue)))
    return nothing
end

# -- Running a claimed run --

# A run that ended because this process is stopping, or because its lease is gone, is still
# wanted: it goes back to its queue rather than to a terminal state (§7).
_gives_back(info::TaskInfo) = cancel_reason(info) in (:shutdown, :lease_lost)

function _hand_back!(c::ConsumerHandle, info::TaskInfo, queue::String)
    try
        # Outside `lock_tasks`, as every claim operation must be (workers §2).
        release_claim!(c.runtime.store, info.id, info.run_id; policy = c.placements[queue].policy)
    catch e
        _is_interrupt(e) && throw(InterruptException())
        @error "Nitro.Workers: a consumer could not hand a run back; its lease will expire instead" task_id = info.id exception = (e, catch_backtrace())
    end
    return info
end

function _run_claimed!(c::ConsumerHandle, run::TaskInfo, queue::String)
    placement = c.placements[queue]
    handoff = Ref(_RunHandoff(() -> _release_slot!(c, queue)))
    try
        if _gives_back(run)
            # The drain reached this run before its task started: give it back without running it.
            _hand_back!(c, run, queue)
        elseif run.job_name === nothing
            # Only a named job can be submitted to an external queue (#514), so a row without one
            # was written by something else. Recorded, never left to bounce between consumers.
            _fail_task!(c.runtime, run, "External run has no named job, so no consumer can run it")
        else
            callback = _job_run(c.app, something(run.job_name), something(run.job_args, "null"))
            _run_attempts!(c.runtime, run, callback, placement.options, handoff;
                on_complete = (info, result) -> _gives_back(info) ? _hand_back!(c, info, queue) :
                                                                    _complete_task!(c.runtime, info, result),
                on_cancel = info -> _gives_back(info) ? _hand_back!(c, info, queue) :
                                                        _cancel_task!(c.runtime, info))
        end
    catch e
        _is_interrupt(e) && throw(InterruptException())
        # A store write that threw. The lease is still this process's and will run out, and
        # `requeue_expired!` then decides the run by its queue's policy.
        @error "Nitro.Workers: a consumer run ended without a recorded outcome; its lease will expire" task_id = run.id exception = (e, catch_backtrace())
    finally
        emptied = lock(c.lock) do
            delete!(c.held, run.run_id)
            @atomic c.held_count = length(c.held)
            isempty(c.held)
        end
        # The last straggler of a drain that timed out: the heartbeat stops now, not a tick later.
        emptied && !(@atomic c.beating) && notify(c.beat)
        _handed_off(handoff[]) || _release_slot!(c, queue)
    end
    return nothing
end

# -- The heartbeat --

# Until the drain ends, and then until the last run it left going returns (#607). In a REPL the
# process outlives `consume!`, and so do those runs: unrenewed, their leases would expire, and
# another consumer would run them again while they still run here.
_keeps_beating(c::ConsumerHandle) = (@atomic c.beating) || (@atomic c.held_count) > 0

function _heartbeat_loop(c::ConsumerHandle)
    interrupted = false
    while _keeps_beating(c)
        try
            timer = Timer(_ -> notify(c.beat), c.lease_seconds / 3)
            try
                _keeps_beating(c) && wait(c.beat)
            finally
                close(timer)
            end
            _keeps_beating(c) || break
            _heartbeat_tick!(c)
        catch e
            if _is_interrupt(e)
                # Under `-t k,1` thread 1 is the interactive thread, so a REPL's Ctrl-C can land
                # here. It is a stop request: start the drain and keep renewing until it ends,
                # since the drain is what needs the leases alive (§6).
                interrupted || @warn "Nitro.Workers: an interrupt (Ctrl-C) reached the consumer's " *
                                     "lease heartbeat; draining. Runs that stop are handed back to their queues"
                interrupted = true
                _request_stop!(c)
                continue
            end
            @error "Nitro.Workers: a consumer heartbeat failed; retrying on the next one" exception = (e, catch_backtrace())
        end
    end
    # After a drain that timed out, this loop outlives the drain, so it closes the wake guard
    # itself: it is the last of the two loops the guard is for. Closing twice is harmless.
    c.wake_guard === nothing || close(c.wake_guard)
    return nothing
end

function _heartbeat_tick!(c::ConsumerHandle)
    store = c.runtime.store
    held = lock(() -> collect(values(c.held)), c.lock)
    # Each step on its own, as in the drain (#608): a failed renewal, or one run's failed lookup,
    # must not hold back the other runs' signals nor this tick's adjudication.
    if !isempty(held)
        renewals = LeaseRenewal[LeaseRenewal((h.info.id, h.info.run_id, Float64(@atomic h.info.progress)))
                                for h in held]
        # Renew first, adjudicate second: a heartbeat that was itself late must not take back its
        # own leases before it renews them.
        kept = try
            Set{UUID}(renew_leases!(store, c.consumer_id, renewals; lease_seconds = c.lease_seconds))
        catch e
            _is_interrupt(e) && throw(InterruptException())
            @error "Nitro.Workers: a consumer's lease renewal failed; retrying on the next heartbeat" runs = length(renewals) exception = (e, catch_backtrace())
            nothing
        end
        # A failed renewal says nothing about which runs were lost, so nothing is looked up.
        if kept !== nothing
            for h in held
                h.info.run_id in kept && continue
                try
                    reason = _lost_claim_reason(store, h.info)
                    reason === nothing || _request_cancel!(h.info, reason)
                catch e
                    _is_interrupt(e) && throw(InterruptException())
                    @error "Nitro.Workers: a consumer could not read why a run's renewal missed; retrying on the next heartbeat" task_id = h.info.id exception = (e, catch_backtrace())
                end
            end
        end
    end
    # Once the drain has ended, the heartbeat only keeps the runs it left going alive (#607): a
    # consumer that returned claims nothing and adjudicates nothing.
    (@atomic c.beating) && _consumer_requeue!(c)
    return nothing
end

# Why a run this process holds is no longer its own to run, read from the stored record (§6):
#
# | stored record                                   | reason        |
# |-------------------------------------------------|---------------|
# | this run, `CANCELLED`                           | the cancel's own reason (`:user` for `cancel_task`) |
# | another run, same `created_at` (re-queued, re-claimed) | `:lease_lost` |
# | another run, a new `created_at` (re-submitted)  | `:superseded` |
# | gone (released or pruned)                       | `:superseded` |
# | this run, another terminal state                | `:superseded` |
#
# `nothing` when the record still says this run is RUNNING: the renew missed for a reason that
# did not change the record, and the next tick renews it.
function _lost_claim_reason(store::AbstractWorkerStore, info::TaskInfo)
    rec = get_task_info(store, info.id)
    rec === nothing && return :superseded
    if rec.run_id == info.run_id
        rec.status == RUNNING && return nothing
        if rec.status == CANCELLED
            reason = _cancel_reason_from_error(rec.error)
            return reason === :none ? :superseded : reason
        end
        return :superseded
    end
    return rec.created_at == info.created_at ? :lease_lost : :superseded
end

function _consumer_requeue!(c::ConsumerHandle)
    try
        tally = requeue_expired!(c.runtime.store, current_time_utc(); policies = c.policies)
        if tally.requeued + tally.failed > 0
            @info "Nitro.Workers: expired leases adjudicated" consumer_id = c.consumer_id requeued = tally.requeued failed = tally.failed unknown_queue = tally.unknown_queue
        end
    catch e
        _is_interrupt(e) && throw(InterruptException())
        @error "Nitro.Workers: a consumer's lease adjudication failed; retrying on the next heartbeat" exception = (e, catch_backtrace())
    end
    return nothing
end

# -- Stopping --

# The drain (§7): stop claiming, set `:shutdown` on every held run, and wait up to `drain_timeout`
# for them. Runs that stop in the window hand themselves back (`_gives_back`). Runs still going
# when it ends keep the heartbeat renewing their leases until they return, and hand themselves back
# then (#607); a process that exits first takes them with it, and their leases expire. It runs
# once: a second caller -- the `atexit` hook after a normal return, or a stop while it runs --
# waits for the first. It never throws (#427): every failure is logged and the stop still completes.
function _drain!(c::ConsumerHandle)
    if !(@atomicreplace c.drained false => true).success
        # Bounded: if the first drain cannot finish -- a second signal landed on the very task
        # running it, so the `atexit` hook runs on top of it -- the process must still exit.
        try
            timedwait(() -> (@atomic c.finished), c.drain_timeout + 10; pollint = 0.05)
        catch
        end
        return nothing
    end
    try
        try
            @atomic c.stopping = true
            notify(c.wake)
            snapshot = lock(() -> collect(values(c.held)), c.lock)
            for h in snapshot
                _request_cancel!(h.info, :shutdown)
            end
            # The predicate reads an atomic, never the lock: it runs on a timer, and a run task
            # holds the lock to deregister itself, which is how it settles.
            timedwait(() -> (@atomic c.held_count) == 0, c.drain_timeout; pollint = 0.05)
            left = @atomic c.held_count
            if left > 0
                @warn "Nitro.Workers: the consumer's drain timed out with runs still going. The " *
                      "heartbeat keeps renewing their leases until they return; if the process " *
                      "exits first, the leases expire and their queues' policies decide" consumer_id = c.consumer_id runs = left
            end
        catch e
            if _is_interrupt(e)
                @warn "Nitro.Workers: a second interrupt reached the consumer's drain; stopping without waiting further"
            else
                @error "Nitro.Workers: the consumer's drain failed; stopping anyway" exception = (e, catch_backtrace())
            end
        end
    finally
        # Each step on its own, so none of them can keep the next from running.
        @atomic c.beating = false
        notify(c.beat)
        notify(c.wake)
        hb = c.heartbeat_task
        try
            # Not for a heartbeat that still renews runs the drain left going: it ends when they do.
            hb === nothing || timedwait(() -> istaskdone(hb) || (@atomic c.held_count) > 0, 5.0; pollint = 0.05)
            claim = c.claim_task
            claim === nothing || timedwait(() -> istaskdone(claim), 5.0; pollint = 0.05)
            @info "Nitro.Workers: consumer stopped" consumer_id = c.consumer_id runs_still_renewed = (@atomic c.held_count)
        catch e
            _is_interrupt(e) || @error "Nitro.Workers: the consumer's stop did not finish cleanly" exception = (e, catch_backtrace())
        end
        # Last, once both loops are done parking: they are what it guards. A heartbeat still
        # renewing closes it itself when it ends.
        (hb === nothing || istaskdone(hb)) && c.wake_guard !== nothing && close(c.wake_guard)
        @atomic c.finished = true
    end
    return nothing
end
