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

function _complete_task!(store::AbstractWorkerStore, task_info::TaskInfo, result)
    return lock_tasks(store) do
        current = get_task_info(store, task_info.id)
        if current !== nothing && current.status == CANCELLED
            deregister_active_task!(store, task_info.id)
            deregister_active_task_info!(store, task_info.id)
            return current
        end
        task_info.result = result
        task_info.completed_at = current_time_utc()
        @atomic task_info.progress = 100.0
        task_info.sys_task = nothing
        task_info.status = COMPLETED
        deregister_active_task!(store, task_info.id)
        deregister_active_task_info!(store, task_info.id)
        set_task!(store, task_info.id, task_info)
        return task_info
    end
end

function _fail_task!(store::AbstractWorkerStore, task_info::TaskInfo, message::String)
    return lock_tasks(store) do
        task_info.error = message
        task_info.completed_at = current_time_utc()
        task_info.sys_task = nothing
        task_info.status = FAILED
        deregister_active_task!(store, task_info.id)
        deregister_active_task_info!(store, task_info.id)
        set_task!(store, task_info.id, task_info)
        return task_info
    end
end

function _cancel_task!(store::AbstractWorkerStore, task_info::TaskInfo; message::String="Cancelled")
    return lock_tasks(store) do
        task_info.error = message
        task_info.completed_at = current_time_utc()
        task_info.sys_task = nothing
        task_info.status = CANCELLED
        deregister_active_task!(store, task_info.id)
        deregister_active_task_info!(store, task_info.id)
        set_task!(store, task_info.id, task_info)
        return task_info
    end
end

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
