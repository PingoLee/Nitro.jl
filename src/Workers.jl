module Workers

using Dates
using Base: @kwdef
import Base.Threads: ReentrantLock, lock

using ..Core: ServerContext, LifecycleMiddleware
using ..Core.AppContext: set_extension!, get_extension, delete_extension!

const DEFAULT_EXTENSION_KEY = :workers

include("Workers/types.jl")
include("Workers/registry.jl")
include("Workers/execution.jl")
include("Workers/queue.jl")
include("Workers/api.jl")

export TaskStatus, PENDING, RUNNING, COMPLETED, FAILED, CANCELLED,
    TaskInfo, TaskOptions, QueueItem, SequentialQueue, CleanupScheduler,
    AbstractWorkerStore, InMemoryWorkerStore,
    install!, uninstall!, worker_store, default_store,
    start!, startup,
    submit_task, submit_sequential_task, get_task_status, cancel_task,
    is_task_running, get_all_tasks, cleanup_old_tasks,
    start_cleanup_scheduler, stop_cleanup_scheduler!, get_queue_status,
    format_error, reset_store!, shutdown!

end