module Workers

using Dates
using UUIDs: UUID, uuid4
using Base: @kwdef
import Base.Threads: ReentrantLock, lock

using ..Core: App, LifecycleMiddleware
using ..Core.AppContext: set_extension!, get_extension, delete_extension!
using ..Core: AuthorizationError, StoreInterfaceError
using ..Core.Errors: implements_contract_method, store_contract_error

const DEFAULT_EXTENSION_KEY = :workers

include("Workers/types.jl")
include("Workers/registry.jl")
include("Workers/runtime.jl")
include("Workers/execution.jl")
include("Workers/queue.jl")
include("Workers/api.jl")

export TaskStatus, PENDING, RUNNING, COMPLETED, FAILED, CANCELLED,
    TaskInfo, TaskOptions, QueueItem, SequentialQueue, CleanupScheduler,
    AbstractWorkerStore, InMemoryWorkerStore, missing_store_methods,
    # The live half: queues, scheduler, run handles (#167)
    WorkerRuntime, default_runtime, worker_runtime, reset_runtime!, shutdown!,
    get_sequential_queues, get_queue_lock, get_cleanup_scheduler,
    get_active_task, get_active_task_info, register_run!,
    # NOT exported: `register_active_task!` / `register_active_task_info!` and their
    # deregistrars. They have no production callers, and writing one dict without the other is
    # exactly the state `register_run!` exists to make unbuildable -- an exported API whose
    # documented correct use is "never use this alone" is the same shape as the `shutdown!` a
    # backend could forget, which is what #167 removed. Reach them qualified, from tests.
    install!, uninstall!, worker_store, default_store,
    start!, startup, recover_zombie_tasks!,
    submit_task, submit_sequential_task, get_task_status, cancel_task,
    update_progress!, cancel_requested, TaskTimeoutError,
    get_all_tasks, cleanup_old_tasks,
    start_cleanup_scheduler, stop_cleanup_scheduler!, get_queue_status,
    format_error, MAX_STORED_ERROR_CHARS, WORKER_DRAIN_TIMEOUT_SECONDS,
    scoped_task_key, owner_of, DEFAULT_QUEUE_NAME,
    TaskAuthority, Owner, System, UNSUPPLIED,
    # Abstract store interface
    get_task_info, set_task!, replace_task!, add_watcher!, try_transition!,
    delete_task!, cleanup_tasks!, clear_records!,
    get_queue_authorizer, set_queue_authorizer!,
    get_error_redactor, set_error_redactor!,
    get_watch_authorizer, set_watch_authorizer!,
    lock_tasks

end
