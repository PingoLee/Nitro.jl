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
        claimed = try_transition!(store, task_info.id, (PENDING, RUNNING), to;
                                  error, completed_at=finished_at, result, progress)

        # Whether or not we won, this process is done running it.
        deregister_active_task!(store, task_info.id)
        deregister_active_task_info!(store, task_info.id)
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

    task_info.status = RUNNING
    task_info.started_at = current_time_utc()
    task_info.sys_task = current_task()
    register_active_task!(store, task_info.id, current_task())
    register_active_task_info!(store, task_info.id, task_info)
    set_task!(store, task_info.id, task_info)

    max_attempts = item.options.retry_on_failure ? item.options.max_retries : 0
    for retry_count in 0:max_attempts
        try
            result = timeout_call(() -> _invoke_task_callback(item.callback, task_info); timeout=item.options.timeout)
            return _complete_task!(store, task_info, result)
        catch error
            unwrapped = _unwrap_exception(error)
            latest_info = get_task_info(store, task_info.id)
            if unwrapped isa InterruptException || (latest_info !== nothing && latest_info.status == CANCELLED)
                return _cancel_task!(store, task_info)
            end

            if retry_count == max_attempts
                return _fail_task!(store, task_info, format_error(unwrapped))
            end

            sleep(2 ^ (retry_count + 1))
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
