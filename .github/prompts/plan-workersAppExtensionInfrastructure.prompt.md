# Plan: Port Workers App from bi_server to Nitro.jl

Port the proven background task system from bi_server (`/home/pingo03/app/bi_server/src/Workers.jl`) into Nitro.jl while refactoring for **stateless core** — moving task/queue registry from global singletons to a composable store backend that can be replaced or extended.

## Scope: Capabilities to Port (from bi_server)

### Types and Enums
- `TaskStatus` enum: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED`, `CANCELLED`
- `TaskInfo` struct: Full lifecycle tracking (id, status, progress, result, error, timestamps, watchers, sys_task reference, queue_name)
- `TaskOptions` struct: Configuration for timeout, retry_on_failure, max_retries, priority
- `QueueItem` struct: Items for sequential queue execution
- `SequentialQueue` struct: Queue channel, running flag, current_task, exec_lock for atomicity

### Public API Functions
1. **Task Submission**
   - `submit_task(task_key, callback, user_id; options)` — Immediately spawn async task
   - `submit_sequential_task(queue_name, task_key, callback, user_id; options)` — Queue for sequential execution

2. **Task Management**
   - `get_task_status(task_id)` — Retrieve task details
   - `cancel_task(task_id)` — Cancel a task and interrupt execution
   - `is_task_running(task_key)` — Check if task is pending or running
   - `get_all_tasks(filter_status)` — List tasks with optional status filter

3. **Queue Management**
   - `get_queue_status(queue_name)` — Status of a specific sequential queue

4. **Maintenance**
   - `cleanup_old_tasks(days)` — Remove completed tasks older than N days
   - `start_cleanup_scheduler(interval_hours)` — Background cleanup task

### Internal Helpers
- `_execute_queued_task` — Execute a task from queue with retry logic + exponential backoff
- `_execute_task_async` — Manage async execution lifecycle for immediate tasks
- `timeout_call` — Execute function with timeout using Channels
- `format_error` — Extract real exception from TaskFailedException / CapturedException wrappers
- `_unwrap_exception`, `_unwrap_error` — Exception unwrapping helpers

## Phase 1: Port bi_server Implementation (v1 — Global State)

1. **Create `src/Workers.jl` entry point** — Minimal wrapper around implementation modules.
2. **Create `src/Workers/types.jl`** — All struct and enum definitions (TaskStatus, TaskInfo, TaskOptions, QueueItem, SequentialQueue).
3. **Create `src/Workers/registry.jl`** — Global `TASK_REGISTRY`, `TASK_LOCK`, `SEQUENTIAL_QUEUES`, `QUEUE_LOCK` (mimics bi_server).
4. **Create `src/Workers/execution.jl`** — All task execution logic (_execute_queued_task, _execute_task_async, timeout_call, error formatting).
5. **Create `src/Workers/queue.jl`** — Sequential queue processor with `_get_or_create_queue`, `_start_queue_processor`.
6. **Create `src/Workers/api.jl`** — Public API (submit_task, submit_sequential_task, get_task_status, cancel_task, etc.).
7. **Wire into `src/Nitro.jl`** — Include Workers.jl and expose as `Nitro.Workers` submodule.
8. **Write comprehensive tests** — Test queue order, retry, cancellation, timeout, duplicate submission, cleanup.

## Phase 2: Refactor for Stateless Core (Future)

This phase prepares the Workers system for use without global state, enabling:
- Pluggable storage backends (in-memory, Redis, database)
- Multiple independent task registries (e.g., one per ServerContext instance)
- Clean app extension pattern

> **Post-Phase-1 TODO**: After porting and testing the bi_server implementation, extract the store logic:
> - Create `AbstractWorkerStore` interface with methods like `register_task`, `get_task`, `update_task`, etc.
> - Provide `InMemoryWorkerStore` (default, wraps current global dict logic)
> - Refactor `registry.jl` to use a configurable store instead of hardcoded globals
> - Allow `ServerContext.app_context` to hold a `WorkerStore` reference
> - Document how to swap stores (for Redis/database backends in future)

## Threading Model (from bi_server, preserved)

- **Sequential queues**: `Threads.@spawn` loop runs on a separate thread, taking jobs from Channel one-at-a-time. ✅ *Correct* — doesn't block HTTP thread.
- **Immediate tasks**: Currently use `@async` (blocks on thread 1 if callback is synchronous). ⚠️ *Noted for BI server migration* — works but not ideal under heavy load.
- **Cancellation**: `schedule(task, InterruptException())` is best-effort; may not interrupt blocking I/O.

## File Structure

```
src/Workers/
  types.jl        ← TaskStatus, TaskInfo, TaskOptions, QueueItem, SequentialQueue
  registry.jl     ← Global TASK_REGISTRY, SEQUENTIAL_QUEUES, locks (v1 global state)
  execution.jl    ← _execute_queued_task, _execute_task_async, timeout_call, error formatting
  queue.jl        ← _get_or_create_queue, _start_queue_processor
  api.jl          ← Public API: submit_task, submit_sequential_task, get_task_status, cancel_task, etc.
src/Workers.jl    ← Module entry point, includes all submodules, exports public API
```

## Success Criteria (Phase 1)

1. ✅ All bi_server capabilities ported and tested
2. ✅ Full test coverage: queue order, retries, cancellation, timeout, deduplication, cleanup
3. ✅ Sequential queue uses `Threads.@spawn` (not `@async`)
4. ✅ Thread safety verified (no race conditions on TASK_REGISTRY, SEQUENTIAL_QUEUES)
5. ✅ Integration with Nitro's `serve()` and `serveparallel()` (workers don't interfere)
6. ✅ Cleanup scheduler runs correctly in background
7. ✅ BI server migration can use this module directly

## Future Work (Phase 2 + Beyond)

- Extract store logic to `AbstractWorkerStore` for pluggable backends
- Create `NitroWorkersRedisExt` for Redis-backed task registry
- Add structured logging and metrics (queue depth, execution times)
- Support task progress updates during long-running callbacks
- Add WebSocket support for real-time task status updates
