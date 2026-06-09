abstract type AbstractWorkerStore end

# -- Storage and Registry interface functions (Abstract protocols) --
function get_task_info end
function set_task! end
function delete_task! end
function cleanup_tasks! end
function get_all_tasks end

# -- Active task / local runtime cache interface functions --
function get_active_task end
function register_active_task! end
function deregister_active_task! end
function get_active_task_info end
function register_active_task_info! end
function deregister_active_task_info! end

# -- Queue permission checks interface functions --
function get_queue_authorizer end
function set_queue_authorizer! end

# -- Queue management helper functions --
function get_sequential_queues end
function get_queue_lock end

# -- Cleanup and Locking helper functions --
function get_cleanup_scheduler end
function lock_tasks end

# ============================================================================
# InMemoryWorkerStore Implementation
# ============================================================================

mutable struct InMemoryWorkerStore <: AbstractWorkerStore
    task_registry::Dict{String, TaskInfo}
    task_lock::ReentrantLock
    sequential_queues::Dict{String, SequentialQueue}
    queue_lock::ReentrantLock
    cleanup_scheduler::Ref{Union{Nothing, CleanupScheduler}}
    active_tasks::Dict{String, Task}
    active_lock::ReentrantLock
    queue_authorizer::Ref{Any}

    function InMemoryWorkerStore()
        return new(
            Dict{String, TaskInfo}(),
            ReentrantLock(),
            Dict{String, SequentialQueue}(),
            ReentrantLock(),
            Ref{Union{Nothing, CleanupScheduler}}(nothing),
            Dict{String, Task}(),
            ReentrantLock(),
            Ref{Any}(nothing),
        )
    end
end

# -- Implement interface methods for InMemoryWorkerStore --

function get_task_info(store::InMemoryWorkerStore, task_id::String)
    lock(store.task_lock) do
        return get(store.task_registry, task_id, nothing)
    end
end

function set_task!(store::InMemoryWorkerStore, task_id::String, task_info::TaskInfo)
    lock(store.task_lock) do
        store.task_registry[task_id] = task_info
    end
    return task_info
end

function delete_task!(store::InMemoryWorkerStore, task_id::String)
    lock(store.task_lock) do
        delete!(store.task_registry, task_id)
    end
    return nothing
end

function cleanup_tasks!(store::InMemoryWorkerStore, retain_days::Int)
    cutoff = current_time_utc() - Dates.Day(retain_days)
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

function get_all_tasks(store::InMemoryWorkerStore, status::Union{Nothing, TaskStatus}=nothing, user_id::Union{Nothing, String}=nothing, queue_name::Union{Nothing, String}=nothing)
    lock(store.task_lock) do
        tasks = TaskInfo[]
        for task_info in values(store.task_registry)
            if status !== nothing && task_info.status != status
                continue
            end
            if user_id !== nothing && !isempty(user_id) && !(user_id in task_info.watchers)
                continue
            end
            if queue_name !== nothing && task_info.queue_name != queue_name
                continue
            end
            push!(tasks, task_info)
        end
        return tasks
    end
end

function get_active_task(store::InMemoryWorkerStore, task_id::String)
    lock(store.active_lock) do
        return get(store.active_tasks, task_id, nothing)
    end
end

function get_active_task_info(store::InMemoryWorkerStore, task_id::String)
    return get_task_info(store, task_id)
end

function register_active_task!(store::InMemoryWorkerStore, task_id::String, task::Task)
    lock(store.active_lock) do
        store.active_tasks[task_id] = task
    end
    lock(store.task_lock) do
        task_info = get(store.task_registry, task_id, nothing)
        if task_info !== nothing
            task_info.sys_task = task
        end
    end
    return task
end

function register_active_task_info!(store::InMemoryWorkerStore, task_id::String, task_info::TaskInfo)
    return set_task!(store, task_id, task_info)
end

function deregister_active_task!(store::InMemoryWorkerStore, task_id::String)
    lock(store.active_lock) do
        delete!(store.active_tasks, task_id)
    end
    lock(store.task_lock) do
        task_info = get(store.task_registry, task_id, nothing)
        if task_info !== nothing
            task_info.sys_task = nothing
        end
    end
    return nothing
end

function deregister_active_task_info!(store::InMemoryWorkerStore, task_id::String)
    return nothing
end

function get_queue_authorizer(store::InMemoryWorkerStore)
    return store.queue_authorizer[]
end

function set_queue_authorizer!(store::InMemoryWorkerStore, authorizer)
    store.queue_authorizer[] = authorizer
    return authorizer
end

function get_sequential_queues(store::InMemoryWorkerStore)
    return store.sequential_queues
end

function get_queue_lock(store::InMemoryWorkerStore)
    return store.queue_lock
end

function get_cleanup_scheduler(store::InMemoryWorkerStore)
    return store.cleanup_scheduler
end

function lock_tasks(callback::Function, store::InMemoryWorkerStore)
    return lock(store.task_lock) do
        callback()
    end
end

# -- Core extension management (ServerContext integration) --

const DEFAULT_STORE = Ref(InMemoryWorkerStore())

default_store() = DEFAULT_STORE[]

function worker_store(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY)
    return get_extension(ctx, key, nothing)
end

function install!(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY, store::AbstractWorkerStore=InMemoryWorkerStore())
    return set_extension!(ctx, key, store)
end

function uninstall!(ctx::ServerContext; key::Symbol=DEFAULT_EXTENSION_KEY)
    store = worker_store(ctx; key)
    if store isa AbstractWorkerStore
        shutdown!(store)
    end
    delete_extension!(ctx, key)
    return nothing
end

shutdown!(::AbstractWorkerStore) = nothing

function shutdown!(store::InMemoryWorkerStore)
    scheduler = store.cleanup_scheduler[]
    if !isnothing(scheduler)
        stop_cleanup_scheduler!(scheduler)
        store.cleanup_scheduler[] = nothing
    end

    lock(store.queue_lock) do
        for queue in values(store.sequential_queues)
            if isopen(queue.channel)
                close(queue.channel)
            end
            queue.running = false
            queue.current_task = nothing
            queue.processor_task = nothing
        end
    end

    lock(store.active_lock) do
        empty!(store.active_tasks)
    end

    return nothing
end

function reset_store!(store::AbstractWorkerStore=default_store())
    shutdown!(store)

    if store isa InMemoryWorkerStore
        lock(store.task_lock) do
            empty!(store.task_registry)
        end
        lock(store.queue_lock) do
            empty!(store.sequential_queues)
        end
        lock(store.active_lock) do
            empty!(store.active_tasks)
        end
    end

    return store
end
