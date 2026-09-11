function _get_or_create_queue(store::AbstractWorkerStore, queue_name::String)
    lock(get_queue_lock(store)) do
        return get!(get_sequential_queues(store), queue_name) do
            SequentialQueue()
        end
    end
end

function _mark_queue_current_task!(store::AbstractWorkerStore, queue::SequentialQueue, task_id::Union{Nothing, String})
    lock(get_queue_lock(store)) do
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
# `get_active_task_info` is the right probe on both backends. `InMemoryWorkerStore` aliases it to
# `get_task_info`, so it returns the registry record — whichever run currently owns the key.
# `PormGWorkerStore` returns its process-local `active_task_infos` entry, and `nothing` there
# means no local run, where both deregisters are already no-ops.
function _deregister_run!(store::AbstractWorkerStore, task_info::TaskInfo)
    live = get_active_task_info(store, task_info.id)
    if live === nothing || live.run_id == task_info.run_id
        deregister_active_task!(store, task_info.id)
        deregister_active_task_info!(store, task_info.id)
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
function _finish_task!(store::AbstractWorkerStore, task_info::TaskInfo, to::TaskStatus;
                       error::Union{Nothing, String}=nothing,
                       result=UNSUPPLIED,
                       progress::Union{Nothing, Real}=nothing)
    finished_at = current_time_utc()
    return lock_tasks(store) do
        # `run_id` is what makes this write ADDRESSED rather than merely atomic: #88 made
        # terminal transitions compare-and-set, but they still named only a task id, and a task
        # id outlives the run writing under it (#108).
        claimed = try_transition!(store, task_info.id, (PENDING, RUNNING), to;
                                  run_id=task_info.run_id,
                                  error, completed_at=finished_at, result, progress)

        # Whether or not we won, THIS RUN is done — and only this run's handles may go.
        _deregister_run!(store, task_info)
        task_info.sys_task = nothing

        if !claimed
            # Someone else reached a terminal state first — a cancellation, here or in
            # another process. Their record stands; report it rather than ours.
            latest = reload_task(store, task_info.id)
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

_complete_task!(store::AbstractWorkerStore, task_info::TaskInfo, result) =
    _finish_task!(store, task_info, COMPLETED; result, progress=100.0)

# Carry the progress the task had reached. A serializing store writes only the columns it
# is given, so omitting it would reset a failed job's "got to 47% and died" to zero there
# while the in-memory store kept it — a store-parity gap and a diagnostic loss.
_fail_task!(store::AbstractWorkerStore, task_info::TaskInfo, message::String) =
    _finish_task!(store, task_info, FAILED; error=message, progress=task_info.progress)

_cancel_task!(store::AbstractWorkerStore, task_info::TaskInfo; message::String="Cancelled") =
    _finish_task!(store, task_info, CANCELLED; error=message, progress=task_info.progress)

function _execute_queued_task(store::AbstractWorkerStore, item::QueueItem)
    task_info = get_task_info(store, item.task_key)

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
    task_info.sys_task = current_task()
    register_active_task!(store, task_info.id, current_task())
    register_active_task_info!(store, task_info.id, task_info)

    if !try_transition!(store, task_info.id, (PENDING,), RUNNING;
                        run_id=task_info.run_id, started_at=started)
        # Cancelled, or this run no longer owns the record. Hand back the handles we just
        # took -- fenced, so we cannot tear down a successor's (#108).
        _deregister_run!(store, task_info)
        task_info.sys_task = nothing
        return task_info
    end

    task_info.status = RUNNING
    task_info.started_at = started

    max_attempts = item.options.retry_on_failure ? item.options.max_retries : 0
    for retry_count in 0:max_attempts
        try
            result = timeout_call(item.callback, task_info; timeout=item.options.timeout)
            return _complete_task!(store, task_info, result)
        catch error
            unwrapped = _unwrap_exception(error)

            # NOT dead code, however redundant it looks. `_fail_task!` below would lose
            # its CAS against an already-CANCELLED record anyway -- but without this
            # branch a cancelled task with `retry_on_failure` falls through to the
            # backoff `sleep` and RE-RUNS. This is what short-circuits the retry loop.
            #
            # `unwrapped isa InterruptException` used to be an arm of this test, back when
            # cancellation was delivered by injecting one. Nothing injects any more, so
            # the only way one arrives is that the callback itself threw it -- recording
            # that as "Cancelled by user" would be a lie about who stopped the job (#127).
            latest_info = get_task_info(store, task_info.id)
            if latest_info !== nothing && latest_info.status == CANCELLED
                return _cancel_task!(store, task_info)
            end

            # A timeout is terminal on the first attempt. Retrying it cannot help and can
            # harm: nothing stops the attempt that timed out, so `max_retries = 3` would
            # put four copies of the callback on the thread pool at once, sharing one
            # `task_info` and one set of external side effects (#127). The token is not
            # reset between attempts either, so a retry would start pre-cancelled.
            if unwrapped isa TaskTimeoutError
                return _fail_task!(store, task_info, format_error(unwrapped))
            end

            if retry_count == max_attempts
                return _fail_task!(store, task_info, format_error(unwrapped))
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
                return _cancel_task!(store, task_info)
            end
            resumed = get_task_info(store, task_info.id)
            if resumed !== nothing && resumed.status == CANCELLED
                return _cancel_task!(store, task_info)
            end
        end
    end

    return task_info
end

function _start_queue_processor(store::AbstractWorkerStore, queue_name::String)
    queue = _get_or_create_queue(store, queue_name)
    qlock = get_queue_lock(store)

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
                        _mark_queue_current_task!(store, queue, item.task_key)
                        try
                            _execute_queued_task(store, item)
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
                            _mark_queue_current_task!(store, queue, nothing)
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
