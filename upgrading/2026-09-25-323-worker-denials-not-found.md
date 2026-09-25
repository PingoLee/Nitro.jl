## Workers — a task you may not see reads as "not found", a denial is a `403`, and the store contract is no longer exported (#323)

- **Version**: Unreleased
- **Nitro ref**: [#323](https://github.com/PingoLee/Nitro.jl/issues/323) ;
  `src/Workers/api.jl`, `src/Workers.jl`, `src/utilities/misc.jl`
- **Recorded**: 2026-09-25
- **Severity**: **breaking.** A name the store contract used to export is now an
  `UndefVarError` unless you import it. `get_task_status` / `cancel_task` no longer raise
  `AuthorizationError`. A custom `AbstractWorkerStore` owes one more method.

### What changed

1. **`get_task_status` and `cancel_task` answer a task the caller may not see exactly as a missing
   one**: `Dict(:error => "Task not found", :status => "NOT_FOUND")`. They used to raise
   `AuthorizationError` for a foreign task and return that dict for a missing one. That difference
   let any authenticated user probe `"<victim>::<key>"` ids and learn who ran which job.
   `cancel_task`'s missing-task answer also gains `:status => "NOT_FOUND"`.
2. **An `AuthorizationError` that reaches Nitro's error handler is a `403`** with
   `{"message": "403: Forbidden"}`, logged at `@debug` without its message or a backtrace. It was a
   `500` with an `@error` and a full backtrace per request. The submit paths still raise it: the
   queue authorizer, joining or reusing someone else's `:global` key, and a refused `watchers=`
   grant.
3. **The store contract and the run and queue internals are no longer exported from
   `Nitro.Workers`:** `get_task_info`, `set_task!`, `replace_task!`, `add_watcher!`,
   `try_transition!`, `delete_task!`, `cleanup_tasks!`, `clear_records!`,
   `list_running_task_refs`, `RunningTaskRef`, `lock_tasks`, `get_active_task`,
   `get_active_task_info`, `register_run!`, `SequentialQueue`, `QueueItem`,
   `get_sequential_queues`, `get_queue_lock`. `get_task_info(runtime, id)` returned a whole record,
   `result` included, with no authority check. `add_watcher!(runtime, id, uid)` granted read and
   cancel with none. Both were listed as user-facing API.
4. **`AbstractWorkerStore` has a sixteenth required method,
   `try_delete_task!(store, task_id, from; run_id) -> Bool`**, a fenced conditional delete behind
   the new admin call `release_task!(task_id, System())`.

### How to find the calls to migrate

Code that relied on the exception from a read or a cancel:

```bash
rg -n --type julia 'AuthorizationError' .
rg -n --type julia '(get_task_status|cancel_task)\(' .
```

Every unqualified use of a name that is no longer exported:

```bash
rg -n --type julia -w 'get_task_info|set_task!|replace_task!|add_watcher!|try_transition!|delete_task!|cleanup_tasks!|clear_records!|list_running_task_refs|RunningTaskRef|lock_tasks|get_active_task|get_active_task_info|register_run!|SequentialQueue|QueueItem|get_sequential_queues|get_queue_lock' .
```

A custom backend: `@test isempty(missing_store_methods(MyStore))` now lists `:try_delete_task!`.

### Migrate your app

A status route. The `catch` branch never runs any more, and a foreign id now comes back as
`"NOT_FOUND"`, so make that a `404`:

```julia
# ✗ before
function task_status(req, id::String)
    try
        return Res.json(get_task_status(app, id, Owner(user_id(req))))
    catch e
        e isa AuthorizationError && return Res.json(Dict("error" => "forbidden"); status = 403)
        rethrow()
    end
end

# ✓ after
function task_status(req, id::String)
    status = get_task_status(app, id, Owner(user_id(req)))
    status[:status] == "NOT_FOUND" && return Res.json(Dict("error" => "unknown task"); status = 404)
    return Res.json(status)
end
```

Reading a record, or granting access after the fact:

```julia
# ✗ before
info = get_task_info(worker_runtime(app), task_id)          # no authority check
add_watcher!(worker_runtime(app), task_id, "backend-svc")   # post-hoc grant

# ✓ after — the authority-checked API, and the grant at submit time
info = get_task_status(app, task_id, Owner(uid))            # or System() for an admin view
submit_task(app, key, cb, Owner(uid); watchers = [Owner("backend-svc")])
```

A custom backend, or a test that drives the contract directly:

```julia
# ✓ import what you use, or qualify it
using Nitro.Workers: get_task_info, set_task!, try_transition!, lock_tasks

# ✓ and add the fenced delete: remove only while the status is in `from` and the record is
#   `run_id`'s, as one atomic step (the store's own compare-and-delete).
function Nitro.Workers.try_delete_task!(s::MyStore, id::String, from; run_id)
    # DELETE ... WHERE id = ? AND status IN (from...) AND run_id = ?  -> rows affected >= 1
end
```
