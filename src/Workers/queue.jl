function _get_or_create_queue(runtime::WorkerRuntime, queue_name::String)
    lock(get_queue_lock(runtime)) do
        return get!(get_sequential_queues(runtime), queue_name) do
            SequentialQueue()
        end
    end
end

function _mark_queue_current_task!(runtime::WorkerRuntime, queue::SequentialQueue, task_id::Union{Nothing, String})
    lock(get_queue_lock(runtime)) do
        queue.current_task = task_id
    end
    return queue
end

# `active_tasks` and `active_task_infos` are keyed by task id, but what they describe is a
# RUN. A previous run that finishes late must not delete the handles of the run that replaced
# it: `recover_zombie_tasks!` decides zombie-ness from exactly `isnothing(get_active_task(...))`
# (`api.jl`), so an unfenced teardown makes a live successor look dead and the next sweep marks
# it FAILED — a worse outcome than the stale write `run_id` was added to stop (#108).
#
# `get_active_task_info` is now one mechanism rather than a per-backend one: the runtime publishes
# the object the executing run itself registered, so the probe answers with whichever run currently
# owns the key. It used to be an alias for the in-memory registry and a private PormG cache, which
# looked equivalent and was not (#167).
#
# **Probe and delete in ONE critical section.** Three separate `active_lock` acquisitions let a
# successor register between the probe and the deletes, so the predecessor deleted handles it had
# just been told it did not own.
#
# The `live === nothing` branch is safe because of [`register_run!`](@ref), not because of any
# ordering convention: a handle and its info are published together, so that branch cannot find a
# handle to delete. There is deliberately no "register the info first" rule to remember — the
# window is not observable from outside the runtime, so a convention could not be tested and the
# next refactor would silently reintroduce it.
#
# The `live.run_id == task_info.run_id` branch is honest for a second reason from the same
# function: `register_run!` refuses to publish over a foreign run (#198), and `_claim_run!` only
# calls it under the lock every supersede holds. So an info naming this run was put there by this
# run — never by a stale predecessor that overwrote a live successor a moment ago, which is the
# case where this match would have deleted handles belonging to someone else.
function _deregister_run!(runtime::WorkerRuntime, task_info::TaskInfo)
    lock(runtime.active_lock) do
        live = Base.get(runtime.active_task_infos, task_info.id, nothing)
        if live === nothing || live.run_id == task_info.run_id
            delete!(runtime.active_tasks, task_info.id)
            delete!(runtime.active_task_infos, task_info.id)
        end
    end
    return nothing
end

# Every terminal transition goes through the store's compare-and-set, so whichever writer
# gets there first wins and the losers write nothing.
#
# Reading the status and then deciding does NOT work across processes, and reading it via
# `get_task_info` does not work even in principle: for a database-backed store that serves
# the live in-memory object of the very task being finished, so the "was I cancelled?"
# guard would be inspecting this process's own copy and could never observe a cancellation
# recorded elsewhere (#88).
function _finish_task!(runtime::WorkerRuntime, task_info::TaskInfo, to::TaskStatus;
                       error::Union{Nothing, String}=nothing,
                       result=UNSUPPLIED,
                       progress::Union{Nothing, Real}=nothing)
    finished_at = current_time_utc()
    return lock_tasks(runtime) do
        # `run_id` is what makes this write ADDRESSED rather than merely atomic: #88 made
        # terminal transitions compare-and-set, but they still named only a task id, and a task
        # id outlives the run writing under it (#108).
        claimed = try_transition!(runtime.store, task_info.id, (PENDING, RUNNING), to;
                                  run_id=task_info.run_id,
                                  error, completed_at=finished_at, result, progress)

        # Whether or not we won, THIS RUN is done — and only this run's handles may go.
        _deregister_run!(runtime, task_info)

        if !claimed
            # Someone else reached a terminal state first — a cancellation, here or in
            # another process. Their record stands; report it rather than ours.
            latest = get_task_info(runtime.store, task_info.id)
            return latest === nothing ? task_info : latest
        end

        # Mirror onto the caller's object so an in-process reader holding it agrees with
        # what was just written.
        error === nothing || (task_info.error = error)
        result === UNSUPPLIED || (task_info.result = result)
        progress === nothing || (@atomic task_info.progress = Float64(progress))
        task_info.completed_at = finished_at
        task_info.status = to
        return task_info
    end
end

# Claim the start of a run: read the record durably, verify it still belongs to the run the caller
# carries, and publish the run's handles -- as ONE critical section under the store lock. Returns
# the run's `TaskInfo` when the handles were published and `nothing` when this run must not start.
# The contract callers rely on: `try`/`finally _deregister_run!` is entered if and only if
# `register_run!` succeeded.
#
# Three decisions, each of which was a defect once:
#
# **The DURABLE read** (`get_task_info(runtime.store, ·)`, never the live-preferring one). A run
# start is a CLAIMING call. Re-running a key whose record is terminal while its previous run is
# still executing is reachable -- cancellation is cooperative -- and a live-preferring read there
# hands the new run its PREDECESSOR's `TaskInfo`; its start CAS then fails its own `run_id` fence
# and the task sits `PENDING` forever (#167). That rule decides WHICH RECORD to read. It is silent
# about WHOSE RUN the reader is.
#
# **The identity check, fenced on the CARRIED `run_id`** (#191). Reading durably does not
# authenticate the reader: a queued item can outlive its run (`cancel_task` makes the record
# terminal while the item is still buffered, a re-submit replaces it with a fresh run), and a
# stale item that read the SUCCESSOR's record ran the superseded callback against it -- storing
# its value as the successor's result while the successor's own item lost its `(PENDING,)` claim.
# The identity therefore comes in from `_register_or_watch!`, which minted it, and is compared
# BEFORE the publish: `register_run!` makes `task_info` the oracle for every fence this run
# performs afterwards (`_deregister_run!`, `_finish_task!`, `_cancel_task!`, `_snapshot_runs`,
# `_run_settled`), so a run that registers a record it does not own has ADOPTED the successor's
# identity for all of them.
#
# It drops no work: `_register_or_watch!` mints a `run_id` only on its `replace_task!` branch and
# each such call yields at most one item or one spawn, so run -> item is 1:1 and a mismatch proves
# a successor exists whose own submit will run it -- or, if its `put!` lost a teardown race, will
# record it terminal instead, or failing both is logged as an orphan (#182 territory).
#
# **Everything under `lock_tasks`** (#198). The check and the publish used to be two steps with
# no lock between them, and a supersede landing in that gap -- `cancel_task` plus a re-submit,
# which need only `lock_tasks`, free by then -- let a run that had just verified its ownership
# publish over the LIVE SUCCESSOR's entries. Its `finally` then deleted them on a fence that now
# matched, leaving a genuinely-running job with no handle: `recover_zombie_tasks!` reads exactly
# that as death and writes FAILED over it, and `cancel_task` can no longer reach its live object.
# The window was nanoseconds and the safety argument was an ordering coincidence.
#
# Every supersede holds `lock_tasks` (`_register_or_watch!`), and the eviction that makes the
# successor own the slot -- `replace_task!(runtime, ·)` -- happens under it. So a run that reads
# and verifies its ownership under the same lock finds the slot empty or its own BY CONSTRUCTION;
# no supersede can interleave. This is the process-local half of what workers §6 says about that
# lock: it cannot make a read-then-durable-write atomic across processes, which is why the run's
# durable write (`try_transition!`, below in each caller) stays a `run_id`-fenced CAS outside
# this section. What it CAN do is serialise this process's run-handle caches against this
# process's supersede path -- and those caches have no other writer. The lock order it adds,
# `lock_tasks` -> `active_lock`, is the one `_finish_task!` -> `_deregister_run!` already uses.
#
# `register_run!` being a compare-and-set as well is the guard on that argument: under this lock a
# refusal is unreachable in production, so a hit means out-of-band state (the test-only
# registrars) or a refactor that moved the read back outside the lock. That is why it is a
# `@warn` where the identity failure is a `@debug` -- the second is a normal race outcome, the
# first is an invariant that has stopped holding.
#
# **The `PENDING` pre-check.** The only status a record can hold under this run's `run_id` before
# the run starts, other than `PENDING`, is `CANCELLED` -- a `cancel_task` or an abandoned queue
# item (#182) that claimed it first. Declining here rather than at the start CAS means a cancelled
# run never publishes handles at all. The sequential path always checked this; the async path used
# to register, lose its CAS, and deregister, which was correct but published for nothing.
#
# `nothing` on every decline, never the record: handing the caller the SUCCESSOR's record under
# this run's name is the same "a value escapes under the wrong run's identity" error #191 fixed.
# No caller reads the return except to test it against `nothing`.
function _claim_run!(runtime::WorkerRuntime, task_key::String, run_id::UUID)
    return lock_tasks(runtime) do
        task_info = get_task_info(runtime.store, task_key)
        task_info === nothing && return nothing

        if task_info.run_id != run_id
            @debug "Run superseded before it started; not running it" task_key run_id record_run=task_info.run_id
            return nothing
        end

        task_info.status == PENDING || return nothing

        if !register_run!(runtime, task_key, task_info, current_task())
            @warn "Nitro: run-handle slot for a task is held by a foreign run at claim time; " *
                  "declining the run. This is unreachable through the public API -- something " *
                  "registered a live TaskInfo outside `_claim_run!`." task_key run_id
            return nothing
        end

        return task_info
    end
end

_complete_task!(runtime::WorkerRuntime, task_info::TaskInfo, result) =
    _finish_task!(runtime, task_info, COMPLETED; result, progress=100.0)

# Carry the progress the task had reached. A serializing store writes only the columns it
# is given, so omitting it would reset a failed job's "got to 47% and died" to zero there
# while the in-memory store kept it — a store-parity gap and a diagnostic loss.
_fail_task!(runtime::WorkerRuntime, task_info::TaskInfo, message::String) =
    _finish_task!(runtime, task_info, FAILED; error=message, progress=task_info.progress)

# The message is RENDERED from the run's own token, never passed in. Until #183 this took a
# `message::String="Cancelled"`, and the two execution paths disagreed about it: `api.jl` passed
# `"Cancelled by user"` at all three of its call sites while `queue.jl` took the default. Same
# event, two strings, decided by which submit function the caller happened to use.
#
# Worse, the string that named a user was the one no user could produce. A real `cancel_task`
# claims CANCELLED *before* setting the token, so the run's own write here loses its CAS and
# stores nothing; likewise a timeout (terminal FAILED) and a supersede (fails the `run_id` fence).
# The one cause that writes nothing of its own is a teardown drain -- so `"Cancelled by user"` was
# reachable only when no user had cancelled anything. Reading the reason off the task removes the
# parameter that made the two paths differ, rather than asking both to remember one string.
_cancel_task!(runtime::WorkerRuntime, task_info::TaskInfo) =
    _finish_task!(runtime, task_info, CANCELLED;
                  error=_cancel_message(cancel_reason(task_info)), progress=task_info.progress)

# Record a queued task that a teardown will never run (#182).
#
# Closing a queue's channel stops new SUBMISSIONS; it does not stop the processor, which keeps
# `take!`-ing whatever is already buffered until the channel raises. So before this, a teardown
# could START runs that were never in the drain's snapshot: no cancellation token, no wait, and a
# `RUNNING` record published into a runtime that was being torn down. Discarding the backlog
# silently is not the alternative -- those records strand at `PENDING`, and `recover_zombie_tasks!`
# only ever looks at `RUNNING`, so nothing would reap them. Sidekiq and River both stop FETCHING
# first and then settle what is left; this is the settling half.
#
# CANCELLED rather than FAILED: nothing failed, and `FAILED` is what the zombie sweep writes, so
# reusing it would merge two causes under one status again -- the defect #183 just removed. The run
# never started, so there is no handle, no `register_run!`, and no token to set.
#
# **Fenced on the ITEM's `run_id`, and a CAS from `PENDING` only.** This is a terminal write, so
# workers §6 addresses it to a RUN, never to a task id. Re-reading the record and fencing on what
# comes back would be no fence at all -- it would agree with whatever currently owns the key, which
# is exactly the successor this must not cancel. A queued item can outlive its run: `cancel_task`
# makes the record terminal while the item is still buffered, a re-submit then replaces it with a
# fresh run, and that successor may be about to start on the async path where no queue item is
# abandoning anything.
#
# `item.run_id` is what `_register_or_watch!` minted for this item, so no read can drift from it.
# The CAS also makes this idempotent, which it must be: `shutdown!` drains the buffer itself AND
# the processor checks `draining` for anything it had already taken, so one item can reach here
# twice and the second call writes nothing.
function _abandon_queued_item!(runtime::WorkerRuntime, item::QueueItem)
    return try_transition!(runtime.store, item.task_key, (PENDING,), CANCELLED;
                           run_id=item.run_id,
                           error=_cancel_message(:shutdown),
                           completed_at=current_time_utc())
end

function _execute_queued_task(runtime::WorkerRuntime, item::QueueItem)
    # The durable read, the #191 identity check against the ITEM's carried `run_id`, and the
    # handle publish, as one critical section under the store lock -- see `_claim_run!` for why
    # each of those is the way it is. `nothing` means this run must not start: the record is
    # gone, it belongs to a successor, or it was cancelled before it was dequeued.
    #
    # Every way out of this function gives back the run's capacity reservation (#324), exactly
    # once -- `_release_run!` is idempotent by `run_id` -- except a timed-out callback, which keeps
    # it until it actually returns (`_RunHandoff`, `execution.jl`).
    task_info = try
        _claim_run!(runtime, item.task_key, item.run_id)
    catch
        _release_run!(runtime, item.run_id)
        rethrow()
    end
    task_info === nothing && (_release_run!(runtime, item.run_id); return nothing)
    # A sequential callback abandoned by its deadline also counts against the RUNTIME cap until
    # it returns: the processor moves on to the next item, so without this each queue could add
    # one still-running callback per timeout, with nothing bounding them.
    handoff = _RunHandoff(() -> _release_run!(runtime, item.run_id),
                          () -> _count_abandoned!(runtime, item.run_id))

    # From here `task_info` is a snapshot of THIS run's record -- on `InMemoryWorkerStore` the
    # very object the registry holds, on `PormGWorkerStore` a fresh deserialization of its row.
    # A snapshot, not the record: `progress` and `watchers` can move on before the claim below.
    # Progress is harmless -- the run overwrites it itself. A concurrent grant lands on this
    # object through `add_watcher!`'s mirror, now that the handles are already published; before
    # the claim was atomic there was a window in which it wrote to nothing. Authorization
    # survives either way, because `_visible_record` re-reads the durable record whenever the
    # cached one denies.

    # Starting is a CLAIMED transition, not an unconditional write. `set_task!` has no
    # precondition, so a `cancel_task` that already claimed PENDING -> CANCELLED was simply
    # overwritten here a moment later; the callback then ran and `_complete_task!`'s own CAS
    # succeeded from RUNNING, reporting COMPLETED for a task whose caller had been told
    # "Task cancelled". Silent, and not fixable by locking -- the two writes are strictly
    # sequential (#142). The CAS *is* the write, so there is no `set_task!` after it.
    #
    # In the ASYNC path this was masked, not absent: `cancel_task` also interrupted the worker
    # task, and a task that had not started yet never ran its body at all. The sequential path
    # had no such cover -- its processor is already `Threads.@spawn`ed, and a cancel can land
    # between its `get_task_info` and its start write. Removing the interrupt (#127) uncovers
    # the async path too, which is why this lands FIRST.
    started = current_time_utc()

    # The handles are already published -- `_claim_run!` did it BEFORE this claim of RUNNING,
    # not after. `recover_zombie_tasks!` decides a run is dead from exactly
    # `status == RUNNING && isnothing(get_active_task(id))` and does not hold anything that
    # excludes this function, so a store that reads RUNNING before the handle exists is a window
    # in which a sweep marks a genuinely-live run FAILED -- and the run's real result is then
    # discarded by its own losing CAS. The old unconditional `set_task!` wrote the store LAST and
    # so never opened that window; claiming the start (#142) reversed the order, and publishing
    # first restores it. Registering while the record is still PENDING is harmless: that sweep
    # only looks at RUNNING.
    #
    # `try`/`finally`, so this run's handles are released on EVERY exit -- including the two
    # that no terminal write covers: a store exception escaping the claim below (the processor
    # logs it and drops the item, `_start_queue_processor`), and the `0:max_attempts` loop
    # falling through when `retry_on_failure=true` with a negative `max_retries`, which
    # `TaskOptions` does not reject. Both leaked a registration nothing ever removed.
    # `shutdown!` used to sweep those up by accident with `empty!(active_tasks)`; now that it
    # drains and deliberately KEEPS live handles, a leaked one can never settle -- so every
    # later teardown on this runtime would burn its whole `drain_timeout` and then warn about a
    # run that ended long ago (#176).
    #
    # `_deregister_run!` is fenced on `run_id` and idempotent, so this is a no-op on every path
    # `_finish_task!` already covered.
    try
        # Fenced on the ITEM's identity, never on the record's. `_claim_run!` already proved
        # the two are equal, so this is the same VALUE -- but not the same provenance, and
        # provenance is the rule: workers §6 asks that a fence value come from before the window
        # it guards, and `item.run_id` visibly does while `task_info.run_id` requires the reader
        # to first reconstruct the claim's invariant. It is also what survives a refactor that
        # moves or weakens that check.
        if !try_transition!(runtime.store, task_info.id, (PENDING,), RUNNING;
                            run_id=item.run_id, started_at=started)
            # Cancelled, or the record moved on between the claim and this CAS -- a cross-process
            # cancel, or a supersede that landed after the claim released the lock. (A stale or
            # already-cancelled item never reaches here -- the claim declined it.) The `finally`
            # hands the handles back -- fenced, so we cannot tear down a successor's (#108).
            return task_info
        end

        task_info.status = RUNNING
        task_info.started_at = started

        max_attempts = item.options.retry_on_failure ? item.options.max_retries : 0
        for retry_count in 0:max_attempts
            try
                handoff = _RunHandoff(handoff)           # a fresh one per attempt
                result = timeout_call(item.callback, task_info; timeout=item.options.timeout, handoff)
                return _complete_task!(runtime, task_info, result)
            catch error
                unwrapped = _unwrap_exception(error)

                # NOT dead code, however redundant it looks. `_fail_task!` below would lose
                # its CAS against an already-CANCELLED record anyway -- but without this
                # branch a cancelled task with `retry_on_failure` falls through to the
                # backoff `sleep` and RE-RUNS. This is what short-circuits the retry loop.
                #
                # `unwrapped isa InterruptException` used to be an arm of this test, back when
                # cancellation was delivered by injecting one. Nothing injects any more, so
                # the only way one arrives is that the callback itself threw it -- and nothing
                # set a cancel reason for it, so recording it as a cancellation would be a lie
                # about who stopped the job (#127).
                latest_info = get_task_info(runtime, task_info.id)
                if latest_info !== nothing && latest_info.status == CANCELLED
                    return _cancel_task!(runtime, task_info)
                end

                # A timeout is terminal on the first attempt. Retrying it cannot help and can
                # harm: nothing stops the attempt that timed out, so `max_retries = 3` would
                # put four copies of the callback on the thread pool at once, sharing one
                # `task_info` and one set of external side effects (#127). The token is not
                # reset between attempts either, so a retry would start pre-cancelled.
                #
                # So are the three `is_unrecoverable` exceptions (#367), recorded FAILED and
                # never rethrown -- see that function's site table (src/errors.jl). A rethrow
                # here would reach the processor's catch-all below, which logs and DROPS the item,
                # leaving its record RUNNING until a zombie sweep.
                if unwrapped isa TaskTimeoutError || is_unrecoverable(unwrapped)
                    return _fail_task!(runtime, task_info, _store_error_text(runtime.store, unwrapped))
                end

                if retry_count == max_attempts
                    return _fail_task!(runtime, task_info, _store_error_text(runtime.store, unwrapped))
                end

                # Cancellation-aware backoff. The catch above checks CANCELLED before sleeping and
                # never after, and the interrupt that used to abort this sleep is gone (#127) -- so a
                # cancel landing inside a 2/4/8s window re-invoked the user callback on a task that was
                # already cancelled. Polling the token instead of sleeping blind also cuts cancellation
                # latency during a backoff from seconds to milliseconds.
                deadline = time() + 2.0 ^ (retry_count + 1)
                while time() < deadline && !cancel_requested(task_info)
                    sleep(0.05)
                end

                # The token is process-local, so a cancel issued on another node sets nothing here. One
                # durable read per ATTEMPT (not per poll) covers that without a round-trip every 50ms.
                if cancel_requested(task_info)
                    return _cancel_task!(runtime, task_info)
                end
                resumed = get_task_info(runtime.store, task_info.id)
                if resumed !== nothing && resumed.status == CANCELLED
                    return _cancel_task!(runtime, task_info)
                end
            end
        end

        return task_info
    finally
        _deregister_run!(runtime, task_info)
        _handed_off(handoff) || _release_run!(runtime, item.run_id)
    end
end

function _start_queue_processor(runtime::WorkerRuntime, queue_name::String)
    queue = _get_or_create_queue(runtime, queue_name)
    qlock = get_queue_lock(runtime)

    lock(qlock) do
        if queue.running && !isnothing(queue.processor_task) && !istaskdone(queue.processor_task)
            return queue
        end
        queue.running = true
        # `_spawn_detached`, not `Threads.@spawn` (#209). This one matters more than the async
        # path, not less: the processor is spawned by whoever submits FIRST into an unstarted
        # queue (`submit_sequential_task` -> `_start_queue_processor`), and it then runs for the
        # life of the process. Inheriting that caller's scope would pin every item this queue
        # ever executes -- including ones submitted hours later, by anyone -- to a transaction
        # connection that was returned to the pool long ago.
        queue.processor_task = _spawn_detached() do
            try
                while true
                    item = try
                        take!(queue.channel)
                    catch error
                        if error isa InvalidStateException
                            break
                        end
                        rethrow(error)
                    end
                    # The item has left the buffer, so its slot is free for the next submit
                    # (#324). Its OWNER's reservation lasts until the run ends.
                    _release_queue_slot!(queue)

                    # While the runtime is at its cap, hold this item rather than start it
                    # (#324). Abandoned sequential callbacks count toward the cap, so this is what
                    # stops a queue of timing-out callbacks from piling up threads one per
                    # deadline. It pauses the QUEUE, never a submitter: new submits still fail fast
                    # once the buffer fills. A teardown ends the pause, and the item is then
                    # abandoned below like any other.
                    while _runtime_saturated(runtime) && !(@atomic queue.draining)
                        sleep(0.05)
                    end

                    # BEFORE `_mark_queue_current_task!` and before `_execute_queued_task`'s
                    # `_claim_run!`, so once `draining` is visible no further run starts,
                    # publishes a handle into the runtime being torn down, and claims RUNNING with
                    # nothing waiting on it (#182). A processor that read `false` a moment before
                    # `shutdown!` set it can still register after `_snapshot_runs` -- the window is
                    # narrowed, not closed, exactly as workers §5 says of the zombie sweep.
                    #
                    # `shutdown!` drains the buffer itself, so what this actually catches is the
                    # narrow case that loop cannot reach: an item this processor had ALREADY taken
                    # when the teardown began. `_abandon_queued_item!` is idempotent, so the two
                    # abandoners cannot fight over one item.
                    if (@atomic queue.draining)
                        try
                            _abandon_queued_item!(runtime, item)
                        catch error
                            @error "Worker queue item abandoned but not recorded during teardown" exception=(error, catch_backtrace()) queue_name=queue_name task_key=item.task_key
                        end
                        _release_run!(runtime, item.run_id)    # after the `catch`: never skipped
                        continue
                    end

                    lock(queue.exec_lock) do
                        _mark_queue_current_task!(runtime, queue, item.task_key)
                        try
                            _execute_queued_task(runtime, item)
                        catch error
                            # One bad item must never take the processor down. This
                            # loop is the only thing draining the queue and nothing
                            # restarts it until the next submission, so an escaping
                            # exception strands every item behind it. Callback
                            # failures are already converted to FAILED inside
                            # _execute_queued_task; reaching here means the *store*
                            # threw — a failed metadata read, say. Log it, drop the
                            # item, keep draining.
                            @error "Worker queue item aborted outside task execution" exception=(error, catch_backtrace()) queue_name=queue_name task_key=item.task_key
                        finally
                            _mark_queue_current_task!(runtime, queue, nothing)
                        end
                    end
                end
            finally
                lock(qlock) do
                    queue.running = false
                    queue.current_task = nothing
                    queue.processor_task = nothing
                end
            end
        end
    end

    return queue
end
