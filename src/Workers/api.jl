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

"""
    recover_zombie_tasks!(; store::AbstractWorkerStore=default_store())

Sweeps the active store and transitions any tasks in `RUNNING` state that do 
not have an active local thread executing them into a `FAILED` state.
"""
function recover_zombie_tasks!(; store::AbstractWorkerStore=default_store())
    return lock_tasks(store) do
        running_tasks = get_all_tasks(store, RUNNING)
        count = 0
        for task in running_tasks
            if isnothing(get_active_task(store, task.id))
                task.status = FAILED
                task.completed_at = Dates.now(Dates.UTC)
                task.error = "Worker process terminated unexpectedly mid-execution."
                set_task!(store, task.id, task)
                count += 1
            end
        end
        return count
    end
end

function recover_zombie_tasks!(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return recover_zombie_tasks!(; store=_resolve_store(ctx; key, store))
end

function start!(ctx::ServerContext;
    queues::AbstractVector{<:AbstractString}=String[],
    cleanup_enabled::Bool=true,
    cleanup_interval_hours::Real=24,
    cleanup_retain_days::Int=7,
    recover_zombies::Bool=true,
    key::Symbol=DEFAULT_EXTENSION_KEY,
    store::Union{Nothing, AbstractWorkerStore}=nothing,
)
    resolved_store = _install_or_resolve_store!(ctx; key, store)

    if recover_zombies
        recover_zombie_tasks!(; store=resolved_store)
    end

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
    recover_zombies::Bool=true,
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
            recover_zombies=recover_zombies,
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

function _register_or_watch!(store::AbstractWorkerStore, task_key::String, user_id::String; queue_name::Union{Nothing, String}=nothing)
    return lock_tasks(store) do
        should_start = false
        task_info = get_task_info(store, task_key)
        if task_info !== nothing
            if task_info.status in (RUNNING, PENDING)
                if !(user_id in task_info.watchers)
                    push!(task_info.watchers, user_id)
                    set_task!(store, task_key, task_info)
                end
                return false
            end
        end

        task_info = TaskInfo(task_key; queue_name)
        push!(task_info.watchers, user_id)
        set_task!(store, task_key, task_info)
        return true
    end
end

function _execute_task_async(store::AbstractWorkerStore, task_key::String, callback::Function, options::TaskOptions)
    task = @async begin
        task_info = get_task_info(store, task_key)

        if task_info === nothing
            return nothing
        end

        task_info.status = RUNNING
        task_info.started_at = current_time_utc()
        task_info.sys_task = current_task()
        register_active_task!(store, task_key, current_task())
        set_task!(store, task_key, task_info)

        max_attempts = options.retry_on_failure ? options.max_retries : 0
        for retry_count in 0:max_attempts
            try
                result = timeout_call(() -> _invoke_task_callback(callback, task_info); timeout=options.timeout)
                return _complete_task!(store, task_info, result)
            catch error
                unwrapped = _unwrap_exception(error)
                latest_info = get_task_info(store, task_key)
                if unwrapped isa InterruptException || (latest_info !== nothing && latest_info.status == CANCELLED)
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

    register_active_task!(store, task_key, task)
    return task
end

function submit_task(task_key::AbstractString, callback::Function, user_id::AbstractString; options::TaskOptions=TaskOptions(), store::AbstractWorkerStore=default_store())
    key = String(task_key)
    uid = String(user_id)
    should_start = _register_or_watch!(store, key, uid)
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
    queue_id = String(queue_name)
    uid = String(user_id)

    # Queue Authorization
    authorizer = get_queue_authorizer(store)
    if authorizer !== nothing
        if !Base.invokelatest(authorizer, queue_id, uid)
            throw(AuthorizationError("User '$uid' is not authorized to submit tasks to queue '$queue_id'"))
        end
    end

    key = String(task_key)
    should_start = _register_or_watch!(store, key, uid; queue_name=queue_id)
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

function get_task_status(task_id::AbstractString, user_id::Union{Nothing, AbstractString}=nothing; store::AbstractWorkerStore=default_store())
    task_info = get_task_info(store, String(task_id))
    if task_info === nothing
        return Dict{Symbol, Any}(:error => "Task not found", :status => "NOT_FOUND")
    end

    if user_id !== nothing && !isempty(user_id)
        uid = String(user_id)
        if !(uid in task_info.watchers)
            throw(AuthorizationError("User '$uid' is not authorized to view task '$(task_info.id)'"))
        end
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

function get_task_status(ctx::ServerContext, task_id::AbstractString, user_id::Union{Nothing, AbstractString}=nothing; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return get_task_status(task_id, user_id; store=_resolve_store(ctx; key, store))
end

function cancel_task(task_id::AbstractString, user_id::Union{Nothing, AbstractString}=nothing; store::AbstractWorkerStore=default_store())
    return lock_tasks(store) do
        task_info = get_task_info(store, String(task_id))
        if task_info === nothing
            return Dict{Symbol, Any}(:error => "Task not found")
        end

        if user_id !== nothing && !isempty(user_id)
            uid = String(user_id)
            if !(uid in task_info.watchers)
                throw(AuthorizationError("User '$uid' is not authorized to cancel task '$(task_info.id)'"))
            end
        end

        if task_info.status in (COMPLETED, FAILED, CANCELLED)
            return Dict{Symbol, Any}(:error => "Task already finished with status $(task_info.status)")
        end

        sys_task = get_active_task(store, task_info.id)
        if sys_task !== nothing && !istaskdone(sys_task)
            try
                schedule(sys_task, InterruptException(), error=true)
            catch
            end
        end

        task_info.error = "Cancelled"
        task_info.completed_at = current_time_utc()
        task_info.status = CANCELLED
        set_task!(store, task_info.id, task_info)
        deregister_active_task!(store, task_info.id)

        return Dict{Symbol, Any}(:status => "Task cancelled")
    end
end

function cancel_task(ctx::ServerContext, task_id::AbstractString, user_id::Union{Nothing, AbstractString}=nothing; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return cancel_task(task_id, user_id; store=_resolve_store(ctx; key, store))
end

function is_task_running(task_key::AbstractString; store::AbstractWorkerStore=default_store())
    task_info = get_task_info(store, String(task_key))
    return task_info !== nothing && task_info.status in (PENDING, RUNNING)
end

function is_task_running(ctx::ServerContext, task_key::AbstractString; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return is_task_running(task_key; store=_resolve_store(ctx; key, store))
end

function get_all_tasks(filter_status::Union{Nothing, TaskStatus}=nothing, user_id::Union{Nothing, String}=nothing; store::AbstractWorkerStore=default_store())
    task_infos = get_all_tasks(store, filter_status, user_id)
    tasks = Vector{Dict{Symbol, Any}}()
    for task_info in task_infos
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
    sort!(tasks, by=task -> task[:created_at])
    return tasks
end

function get_all_tasks(ctx::ServerContext, filter_status::Union{Nothing, TaskStatus}=nothing, user_id::Union{Nothing, String}=nothing; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return get_all_tasks(filter_status, user_id; store=_resolve_store(ctx; key, store))
end

function cleanup_old_tasks(days::Int=7; store::AbstractWorkerStore=default_store())
    return cleanup_tasks!(store, days)
end

function cleanup_old_tasks(ctx::ServerContext, days::Int=7; key::Symbol=DEFAULT_EXTENSION_KEY, store::Union{Nothing, AbstractWorkerStore}=nothing)
    return cleanup_old_tasks(days; store=_resolve_store(ctx; key, store))
end

function get_queue_status(queue_name::AbstractString; store::AbstractWorkerStore=default_store())
    qlock = get_queue_lock(store)
    queues = get_sequential_queues(store)

    lock(qlock) do
        queue = Base.get(queues, String(queue_name), nothing)
        if queue === nothing
            return Dict{Symbol, Any}(:error => "Queue not found")
        end

        pending_tasks = [task.id for task in get_all_tasks(store, PENDING, nothing, String(queue_name))]
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
    scheduler_ref = get_cleanup_scheduler(store)
    existing = scheduler_ref[]
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
    scheduler_ref[] = scheduler
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
    scheduler_ref = get_cleanup_scheduler(store)
    scheduler = scheduler_ref[]
    if !isnothing(scheduler)
        stop_cleanup_scheduler!(scheduler)
        scheduler_ref[] = nothing
    end
    return nothing
end