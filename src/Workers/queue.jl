function _get_or_create_queue(store::InMemoryWorkerStore, queue_name::String)
    lock(store.queue_lock) do
        return get!(store.sequential_queues, queue_name) do
            SequentialQueue()
        end
    end
end

function _mark_queue_current_task!(store::InMemoryWorkerStore, queue::SequentialQueue, task_id::Union{Nothing, String})
    lock(store.queue_lock) do
        queue.current_task = task_id
    end
    return queue
end

function _complete_task!(store::InMemoryWorkerStore, task_info::TaskInfo, result)
    lock(store.task_lock) do
        task_info.result = result
        task_info.status = COMPLETED
        task_info.completed_at = current_time_utc()
        task_info.progress = 100.0
        task_info.sys_task = nothing
    end
    return task_info
end

function _fail_task!(store::InMemoryWorkerStore, task_info::TaskInfo, message::String)
    lock(store.task_lock) do
        task_info.status = FAILED
        task_info.error = message
        task_info.completed_at = current_time_utc()
        task_info.sys_task = nothing
    end
    return task_info
end

function _cancel_task!(store::InMemoryWorkerStore, task_info::TaskInfo; message::String="Cancelled")
    lock(store.task_lock) do
        task_info.status = CANCELLED
        task_info.error = message
        task_info.completed_at = current_time_utc()
        task_info.sys_task = nothing
    end
    return task_info
end

function _execute_queued_task(store::InMemoryWorkerStore, item::QueueItem)
    task_info = lock(store.task_lock) do
        Base.get(store.task_registry, item.task_key, nothing)
    end

    if task_info === nothing
        return nothing
    end

    if task_info.status == CANCELLED
        return task_info
    end

    lock(store.task_lock) do
        task_info.status = RUNNING
        task_info.started_at = current_time_utc()
        task_info.sys_task = current_task()
    end

    max_attempts = item.options.retry_on_failure ? item.options.max_retries : 0
    for retry_count in 0:max_attempts
        try
            result = timeout_call(() -> _invoke_task_callback(item.callback, task_info); timeout=item.options.timeout)
            return _complete_task!(store, task_info, result)
        catch error
            unwrapped = _unwrap_exception(error)
            if unwrapped isa InterruptException || task_info.status == CANCELLED
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

function _start_queue_processor(store::InMemoryWorkerStore, queue_name::String)
    queue = _get_or_create_queue(store, queue_name)

    lock(store.queue_lock) do
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
                        finally
                            _mark_queue_current_task!(store, queue, nothing)
                        end
                    end
                end
            finally
                lock(store.queue_lock) do
                    queue.running = false
                    queue.current_task = nothing
                    queue.processor_task = nothing
                end
            end
        end
    end

    return queue
end