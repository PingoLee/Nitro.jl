abstract type AbstractWorkerStore end

mutable struct InMemoryWorkerStore <: AbstractWorkerStore
    task_registry::Dict{String, TaskInfo}
    task_lock::ReentrantLock
    sequential_queues::Dict{String, SequentialQueue}
    queue_lock::ReentrantLock
    cleanup_scheduler::Ref{Union{Nothing, CleanupScheduler}}

    function InMemoryWorkerStore()
        return new(
            Dict{String, TaskInfo}(),
            ReentrantLock(),
            Dict{String, SequentialQueue}(),
            ReentrantLock(),
            Ref{Union{Nothing, CleanupScheduler}}(nothing),
        )
    end
end

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
    end

    return store
end