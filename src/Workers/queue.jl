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

function _execute_queued_task(runtime::WorkerRuntime, item::QueueItem)
    # The DURABLE read: a live-preferring one here would hand this run its predecessor's
    # `TaskInfo` when a terminal-but-still-executing key is re-run, and the fenced start below
    # would then fail forever (#167).
    task_info = get_task_info(runtime.store, item.task_key)

    if task_info === nothing
        return nothing
    end

    if task_info.status == CANCELLED
        return task_info
    end

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

    # Register the handles BEFORE claiming RUNNING, not after. `recover_zombie_tasks!`
    # decides a run is dead from exactly `status == RUNNING && isnothing(get_active_task(id))`
    # and does not hold anything that excludes this function, so a store that reads RUNNING
    # before the handle exists is a window in which a sweep marks a genuinely-live run FAILED
    # -- and the run's real result is then discarded by its own losing CAS. The old
    # unconditional `set_task!` wrote the store LAST and so never opened that window;
    # claiming the start (#142) reversed the order, and this restores it. Registering while
    # the record is still PENDING is harmless: that sweep only looks at RUNNING.
    # ONE atomic publish, not two writes: `_deregister_run!` fences on `run_id` read off the
    # info, so a handle visible without its info is invisible to the fence -- and a predecessor
    # finishing in that window deletes the SUCCESSOR's handle (#167). See `register_run!`.
    register_run!(runtime, task_info.id, task_info, current_task())

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
        if !try_transition!(runtime.store, task_info.id, (PENDING,), RUNNING;
                            run_id=task_info.run_id, started_at=started)
            # Cancelled, or this run no longer owns the record. The `finally` hands the
            # handles back -- fenced, so we cannot tear down a successor's (#108).
            return task_info
        end

        task_info.status = RUNNING
        task_info.started_at = started

        max_attempts = item.options.retry_on_failure ? item.options.max_retries : 0
        for retry_count in 0:max_attempts
            try
                result = timeout_call(item.callback, task_info; timeout=item.options.timeout)
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
                if unwrapped isa TaskTimeoutError
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
        queue.processor_task = Threads.@spawn begin
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
