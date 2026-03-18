function _resolve_store(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    if !isnothing(store)
        return store
    end

    ctx_store = worker_store(ctx; key)
    return isnothing(ctx_store) ? default_store() : ctx_store
end

function _install_or_resolve_store!(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    if isnothing(store)
        existing_store = worker_store(ctx; key)
        return isnothing(existing_store) ? install!(ctx; key) : existing_store
    end

    install!(ctx; key, store)
    return store
end

function start!(ctx::ServerContext;
    queues::AbstractVector{<:AbstractString}=String[],
    cleanup_enabled::Bool=true,
    cleanup_interval_hours::Real=24,
    cleanup_retain_days::Int=7,
    key::Symbol=DEFAULT_EXTENSION_KEY,
    store::Union{Nothing, AbstractWorkerStore}=nothing,
)
    resolved_store = _install_or_resolve_store!(ctx; key, store)
    resolved_store isa InMemoryWorkerStore || throw(MethodError(start!, (ctx, resolved_store)))

    for queue_name in queues
        _start_queue_processor(resolved_store, String(queue_name))
    end

    if cleanup_enabled
        start_cleanup_scheduler(; interval_hours=cleanup_interval_hours, retain_days=cleanup_retain_days, store=resolved_store)
    else
        stop_cleanup_scheduler!(resolved_store)
    end

    return resolved_store
end

function startup(ctx::ServerContext;
    queues::AbstractVector{<:AbstractString}=String[],
    cleanup_enabled::Bool=true,
    cleanup_interval_hours::Real=24,
    cleanup_retain_days::Int=7,
    key::Symbol=DEFAULT_EXTENSION_KEY,
    store::Union{Nothing, AbstractWorkerStore}=nothing,
)
    queue_names = String.(collect(queues))

    passthrough = function(handle::Function)
        return function(req)
            return handle(req)
        end
    end

    on_startup = () -> begin
        start!(ctx;
            queues=queue_names,
            cleanup_enabled=cleanup_enabled,
            cleanup_interval_hours=cleanup_interval_hours,
            cleanup_retain_days=cleanup_retain_days,
            key=key,
            store=store,
        )
        return nothing
    end

    on_shutdown = () -> begin
        uninstall!(ctx; key)
        return nothing
    end

    return LifecycleMiddleware(; middleware=passthrough, on_startup, on_shutdown)
end

function _register_or_watch!(store::InMemoryWorkerStore, task_key::String, user_id::String; queue_name::Union{Nothing, String}=nothing)
    should_start = false

    lock(store.task_lock) do
        if haskey(store.task_registry, task_key)
            task_info = store.task_registry[task_key]
            if task_info.status in (RUNNING, PENDING)
                if !(user_id in task_info.watchers)
                    push!(task_info.watchers, user_id)
                end
                return false
            end
        end

        task_info = TaskInfo(task_key; queue_name)
        push!(task_info.watchers, user_id)
        store.task_registry[task_key] = task_info
        should_start = true
    end

    return should_start
end

function _execute_task_async(store::InMemoryWorkerStore, task_key::String, callback::Function, options::TaskOptions)
    task = @async begin
        task_info = lock(store.task_lock) do
            Base.get(store.task_registry, task_key, nothing)
        end

        if task_info === nothing
            return nothing
        end

        lock(store.task_lock) do
            task_info.status = RUNNING
            task_info.started_at = current_time_utc()
            task_info.sys_task = current_task()
        end

        max_attempts = options.retry_on_failure ? options.max_retries : 0
        for retry_count in 0:max_attempts
            try
                result = timeout_call(() -> _invoke_task_callback(callback, task_info); timeout=options.timeout)
                return _complete_task!(store, task_info, result)
            catch error
                unwrapped = _unwrap_exception(error)
                if unwrapped isa InterruptException || task_info.status == CANCELLED
                    return _cancel_task!(store, task_info; message="Cancelled by user")
                end

                if retry_count == max_attempts
                    return _fail_task!(store, task_info, format_error(unwrapped))
                end

                sleep(2 ^ (retry_count + 1))
            end
        end

        return task_info
    end

    lock(store.task_lock) do
        if haskey(store.task_registry, task_key)
            store.task_registry[task_key].sys_task = task
        end
    end

    return task
end

function submit_task(task_key::AbstractString, callback::Function, user_id::AbstractString; options::TaskOptions=TaskOptions(), store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(submit_task, (task_key, callback, user_id, store)))

    key = String(task_key)
    should_start = _register_or_watch!(store, key, String(user_id))
    if should_start
        _execute_task_async(store, key, callback, options)
    end
    return key
end

function submit_task(ctx::ServerContext, task_key::AbstractString, callback::Function, user_id::AbstractString; options::TaskOptions=TaskOptions(), key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    resolved_store = _resolve_store(ctx; key, store)
    return submit_task(task_key, callback, user_id; options, store=resolved_store)
end

function submit_sequential_task(queue_name::AbstractString, task_key::AbstractString, callback::Function, user_id::AbstractString; options::TaskOptions=TaskOptions(), store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(submit_sequential_task, (queue_name, task_key, callback, user_id, store)))

    queue_id = String(queue_name)
    key = String(task_key)
    should_start = _register_or_watch!(store, key, String(user_id); queue_name=queue_id)
    if should_start
        _start_queue_processor(store, queue_id)
        queue = _get_or_create_queue(store, queue_id)
        put!(queue.channel, QueueItem(key, callback, options))
    end
    return key
end

function submit_sequential_task(ctx::ServerContext, queue_name::AbstractString, task_key::AbstractString, callback::Function, user_id::AbstractString; options::TaskOptions=TaskOptions(), key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    resolved_store = _resolve_store(ctx; key, store)
    return submit_sequential_task(queue_name, task_key, callback, user_id; options, store=resolved_store)
end

function get_task_status(task_id::AbstractString; store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(get_task_status, (task_id, store)))

    lock(store.task_lock) do
        task_info = Base.get(store.task_registry, String(task_id), nothing)
        if task_info === nothing
            return Dict{Symbol, Any}(:error => "Task not found", :status => "NOT_FOUND")
        end

        return Dict{Symbol, Any}(
            :id => task_info.id,
            :status => string(task_info.status),
            :progress => task_info.progress,
            :result => task_info.result,
            :error => task_info.error,
            :created_at => task_info.created_at,
            :started_at => task_info.started_at,
            :completed_at => task_info.completed_at,
            :watcher_count => length(task_info.watchers),
            :queue_name => task_info.queue_name,
        )
    end
end

function get_task_status(ctx::ServerContext, task_id::AbstractString; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return get_task_status(task_id; store=_resolve_store(ctx; key, store))
end

function cancel_task(task_id::AbstractString; store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(cancel_task, (task_id, store)))

    lock(store.task_lock) do
        task_info = Base.get(store.task_registry, String(task_id), nothing)
        if task_info === nothing
            return Dict{Symbol, Any}(:error => "Task not found")
        end

        if task_info.status in (COMPLETED, FAILED, CANCELLED)
            return Dict{Symbol, Any}(:error => "Task already finished with status $(task_info.status)")
        end

        if task_info.sys_task !== nothing && !istaskdone(task_info.sys_task)
            try
                schedule(task_info.sys_task, InterruptException(), error=true)
            catch
            end
        end

        task_info.status = CANCELLED
        task_info.error = "Cancelled"
        task_info.completed_at = current_time_utc()
        return Dict{Symbol, Any}(:status => "Task cancelled")
    end
end

function cancel_task(ctx::ServerContext, task_id::AbstractString; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return cancel_task(task_id; store=_resolve_store(ctx; key, store))
end

function is_task_running(task_key::AbstractString; store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(is_task_running, (task_key, store)))

    lock(store.task_lock) do
        task_info = Base.get(store.task_registry, String(task_key), nothing)
        return task_info !== nothing && task_info.status in (PENDING, RUNNING)
    end
end

function is_task_running(ctx::ServerContext, task_key::AbstractString; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return is_task_running(task_key; store=_resolve_store(ctx; key, store))
end

function get_all_tasks(filter_status::Union{Nothing, TaskStatus}=nothing; store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(get_all_tasks, (filter_status, store)))

    lock(store.task_lock) do
        tasks = Vector{Dict{Symbol, Any}}()
        for task_info in values(store.task_registry)
            if filter_status === nothing || task_info.status == filter_status
                push!(tasks, Dict{Symbol, Any}(
                    :id => task_info.id,
                    :status => string(task_info.status),
                    :progress => task_info.progress,
                    :watcher_count => length(task_info.watchers),
                    :created_at => task_info.created_at,
                    :started_at => task_info.started_at,
                    :queue_name => task_info.queue_name,
                ))
            end
        end
        sort!(tasks, by=task -> task[:created_at])
        return tasks
    end
end

function get_all_tasks(ctx::ServerContext, filter_status::Union{Nothing, TaskStatus}=nothing; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return get_all_tasks(filter_status; store=_resolve_store(ctx; key, store))
end

function cleanup_old_tasks(days::Int=7; store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(cleanup_old_tasks, (days, store)))

    cutoff = current_time_utc() - Day(days)
    removed = String[]

    lock(store.task_lock) do
        for (task_id, task_info) in store.task_registry
            if task_info.completed_at !== nothing && task_info.completed_at < cutoff && task_info.status in (COMPLETED, FAILED, CANCELLED)
                push!(removed, task_id)
            end
        end

        for task_id in removed
            delete!(store.task_registry, task_id)
        end
    end

    return length(removed)
end

function cleanup_old_tasks(ctx::ServerContext, days::Int=7; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return cleanup_old_tasks(days; store=_resolve_store(ctx; key, store))
end

function get_queue_status(queue_name::AbstractString; store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(get_queue_status, (queue_name, store)))

    lock(store.queue_lock) do
        queue = Base.get(store.sequential_queues, String(queue_name), nothing)
        if queue === nothing
            return Dict{Symbol, Any}(:error => "Queue not found")
        end

        pending_tasks = lock(store.task_lock) do
            [task.id for task in values(store.task_registry) if task.queue_name == String(queue_name) && task.status == PENDING]
        end

        processing = queue.current_task !== nothing
        return Dict{Symbol, Any}(
            :queue_name => String(queue_name),
            :running => queue.running,
            :current_task => queue.current_task,
            :pending_count => Base.n_avail(queue.channel),
            :pending_tasks => pending_tasks,
            :status_text => processing ? "Processing" : (isempty(pending_tasks) ? "Idle" : "Queued"),
            :total_load => length(pending_tasks) + (processing ? 1 : 0),
        )
    end
end

function get_queue_status(ctx::ServerContext, queue_name::AbstractString; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return get_queue_status(queue_name; store=_resolve_store(ctx; key, store))
end

function start_cleanup_scheduler(; interval_hours::Real=24, retain_days::Int=7, store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(start_cleanup_scheduler, (store,)))

    existing = store.cleanup_scheduler[]
    if !isnothing(existing) && !istaskdone(existing.task)
        return existing
    end

    stop_signal = Channel{Nothing}(1)
    interval_seconds = max(interval_hours * 3600, 0.01)
    task = @async begin
        while true
            wait_result = timedwait(() -> isready(stop_signal), interval_seconds)
            if wait_result == :ok
                break
            end
            cleanup_old_tasks(retain_days; store=store)
        end
    end

    scheduler = CleanupScheduler(task, stop_signal)
    store.cleanup_scheduler[] = scheduler
    return scheduler
end

function start_cleanup_scheduler(ctx::ServerContext; interval_hours::Real=24, retain_days::Int=7, key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return start_cleanup_scheduler(; interval_hours, retain_days, store=_resolve_store(ctx; key, store))
end

function stop_cleanup_scheduler!(scheduler::CleanupScheduler)
    if isopen(scheduler.stop_signal) && !isready(scheduler.stop_signal)
        put!(scheduler.stop_signal, nothing)
    end
    wait(scheduler.task)
    return nothing
end

function stop_cleanup_scheduler!(store::AbstractWorkerStore=default_store())
    store isa InMemoryWorkerStore || throw(MethodError(stop_cleanup_scheduler!, (store,)))

    scheduler = store.cleanup_scheduler[]
    if !isnothing(scheduler)
        stop_cleanup_scheduler!(scheduler)
        store.cleanup_scheduler[] = nothing
    end
    return nothing
end