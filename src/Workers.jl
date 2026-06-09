module Workers

using Dates
using Base: @kwdef
import Base.Threads: ReentrantLock, lock

using ..Core: ServerContext, LifecycleMiddleware
using ..Core.AppContext: set_extension!, get_extension, delete_extension!
using ..Core: AuthorizationError

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
    start!, startup, recover_zombie_tasks!,
    submit_task, submit_sequential_task, get_task_status, cancel_task,
    update_progress!, is_task_running, get_all_tasks, cleanup_old_tasks,
    start_cleanup_scheduler, stop_cleanup_scheduler!, get_queue_status,
    format_error, reset_store!, shutdown!,
    # Abstract store interface
    get_task_info, set_task!, delete_task!, cleanup_tasks!,
    get_active_task, register_active_task!, deregister_active_task!,
    get_active_task_info, register_active_task_info!, deregister_active_task_info!,
    get_queue_authorizer, set_queue_authorizer!,
    get_sequential_queues, get_queue_lock, get_cleanup_scheduler, lock_tasks

end
