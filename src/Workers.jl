module Workers

using Dates
using UUIDs: UUID, uuid4
using Base: @kwdef
import Base.Threads: ReentrantLock, lock

using ..Core: App, LifecycleMiddleware
using ..Core.AppContext: set_extension!, get_extension, delete_extension!
using ..Core: AuthorizationError, StoreInterfaceError, WorkerUnavailableError, WorkerCapacityError
using ..Core.Errors: implements_contract_method, store_contract_error
# The per-attempt catch in the two executors treats these as terminal (#367); see the site
# table in `is_unrecoverable`'s docstring.
using ..Core.Errors: is_unrecoverable

const DEFAULT_EXTENSION_KEY = :workers

include("Workers/types.jl")
include("Workers/registry.jl")
include("Workers/runtime.jl")
include("Workers/execution.jl")
include("Workers/queue.jl")
include("Workers/api.jl")

export TaskStatus, PENDING, RUNNING, COMPLETED, FAILED, CANCELLED,
    TaskInfo, TaskOptions, CleanupScheduler,
    AbstractWorkerStore, InMemoryWorkerStore, missing_store_methods,
    # The live half: the runtime and its lifecycle (#167)
    WorkerRuntime, default_runtime, worker_runtime, reset_runtime!, shutdown!,
    get_cleanup_scheduler,
    install!, uninstall!, worker_store, default_store,
    start!, startup, recover_zombie_tasks!,
    submit_task, submit_sequential_task, get_task_status, cancel_task, release_task!,
    update_progress!, cancel_requested, cancel_reason, CANCEL_REASONS, TaskTimeoutError,
    get_all_tasks, cleanup_old_tasks,
    start_cleanup_scheduler, stop_cleanup_scheduler!, get_queue_status,
    format_error, MAX_STORED_ERROR_CHARS, WORKER_DRAIN_TIMEOUT_SECONDS, ZOMBIE_SWEEP_BATCH,
    scoped_task_key, owner_of, DEFAULT_QUEUE_NAME,
    TaskAuthority, Owner, System, UNSUPPLIED,
    # The application-facing policy hooks. The rest of the store contract is NOT exported (#323).
    get_queue_authorizer, set_queue_authorizer!,
    get_error_redactor, set_error_redactor!,
    get_watch_authorizer, set_watch_authorizer!

# NOT exported, and reached qualified (`Nitro.Workers.get_task_info`) or imported by name:
#
# * The store's data-access contract -- `get_task_info`, `set_task!`, `replace_task!`,
#   `add_watcher!`, `try_transition!`, `delete_task!`, `try_delete_task!`, `cleanup_tasks!`,
#   `clear_records!`, `list_running_task_refs`, `RunningTaskRef`, `lock_tasks` -- and the live-run
#   internals `get_active_task`, `get_active_task_info`, `register_run!`. A backend implements them
#   and Nitro calls them; an application has no business calling them. They were exported and
#   documented as user-facing API, which made the unsafe call the shorter one again (#323):
#   `get_task_info(rt, id)` hands out a full record, `result` included, with no authority check, and
#   `add_watcher!(rt, id, uid)` grants read + cancel with none -- exactly the post-hoc grant #96 said
#   must not exist, and the unchecked-read shape #48 removed from the task API.
# * The queue internals `SequentialQueue`, `QueueItem`, `get_sequential_queues`, `get_queue_lock`:
#   anything that enqueues without going through `submit_sequential_task` bypasses its authorizer.
# * `register_active_task!` / `register_active_task_info!` and their deregistrars. They have no
#   production callers, and writing one dict without the other is exactly the state
#   `register_run!` exists to make unbuildable (#167). Reach them qualified, from tests.

end
