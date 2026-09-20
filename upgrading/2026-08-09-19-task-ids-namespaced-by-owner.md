## Worker task ids are namespaced by owner, and `submit_task` is authorized (#19)

- **Version**: 0.2.0
- **Nitro ref**: #19; `src/Workers/`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-08-09
- **Severity**: **breaking (return value + submit authorization)** — security fix.

### What changed

A task key used to be both the deduplication identity **and** the access capability. Resubmitting a
key that was already `RUNNING` or `PENDING` added the caller to the task's watcher list, and watcher
membership is the only gate on `get_task_status` (which returns `:result`) and `cancel_task`. Any
authenticated user who could guess a key derived from a non-secret resource id — `export_$report_id`
— read another user's task result and cancelled their job. Resubmitting a *finished* foreign key was
worse still: it replaced the record, destroying the owner's result and dropping them from the
watcher list. `submit_task` also ran no authorizer at all, unlike `submit_sequential_task`.

Three changes:

1. **`submit_task` and `submit_sequential_task` take `scope::Symbol = :user` and return the id the
   task is stored under.** Under `:user` that id is `"<user_id>::<task_key>"`, so two users
   submitting the same key get two independent tasks and neither can name the other's.
   `scope=:global` keeps the old verbatim key for genuinely shared work.
2. **A caller who is not already a watcher of an existing key is refused** with `AuthorizationError`,
   whether the task is live or finished. Opt back in with the new
   `set_watch_authorizer!(store, (task_key, watchers, user_id) -> Bool)`. Under `:user` scope this
   cannot fire between two ordinary callers.
3. **`submit_task` now runs the store's queue authorizer** under `DEFAULT_QUEUE_NAME` (`"default"`),
   following the default-queue convention. An allowlist authorizer must permit that name.

Two supporting changes fall out of those:

- **`submit_task` can now throw `AuthorizationError`**, which it never could before — from the
  queue authorizer and from the cross-user gate. Nitro does not map that exception to a status
  code, so a handler that submits without a `try`/`catch` turns a denial into a 500.
- **`PormGWorkerStore.get_task_info` rethrows read failures** instead of logging and returning
  `nothing`, matching `set_task!`. It had to: `nothing` meant "no such task", so one swallowed
  connection error would have skipped the gate above and let a caller take over an existing task.
  A failing read now surfaces instead of masquerading as an absent row.

  This reaches the read APIs too. Where a database failure used to be reported as
  `get_task_status → Dict(:status => "NOT_FOUND")`, `cancel_task → Dict(:error => "Task not
  found")`, and `is_task_running → false`, the exception now propagates. The old answers were
  wrong — a client could not tell "your task was cleaned up" from "the database is down" — but a
  polling route that silently degraded will now return 500 during an outage. Handle it if that
  matters to you. The sequential-queue processor is unaffected: it drops the failing item, logs,
  and keeps draining.

### How to find the calls to migrate

```bash
# 1. Every submission: the return value is now the id to keep.
rg -n 'submit_task|submit_sequential_task' --type julia

# 2. Reads and cancels given a literal or reconstructed key rather than the returned id.
rg -n 'get_task_status|cancel_task|is_task_running' --type julia

# 3. Queue authorizers that allowlist rather than denylist — these now close submit_task.
rg -n 'set_queue_authorizer!' --type julia
```

### Migrate your app

```julia
# ✗ before — the key you passed was the key you polled
submit_task("export_$(report_id)", cb, user_id)
status = get_task_status("export_$(report_id)", user_id)
cancel_task("export_$(report_id)", user_id)

# ✓ after — keep what the submit returned
task_id = submit_task("export_$(report_id)", cb, user_id)
status  = get_task_status(task_id, user_id)
cancel_task(task_id, user_id)

# ✓ after — or rebuild it, when the value was not kept (e.g. a separate status route)
task_id = scoped_task_key("export_$(report_id)", user_id)

# ✗ before — an allowlist authorizer that never saw submit_task
set_queue_authorizer!(store, (q, uid) -> q in queues_for(uid))

# ✓ after — it does now, under DEFAULT_QUEUE_NAME
set_queue_authorizer!(store, (q, uid) -> q == DEFAULT_QUEUE_NAME || q in queues_for(uid))

# ✓ after — deliberately shared work, gated explicitly. Keep the hook a pure in-memory
# predicate: it runs under the store's task lock.
set_watch_authorizer!(store, (task_key, watchers, uid) -> ORG_OF[first(watchers)] == ORG_OF[uid])
submit_task("warm-price-cache", cb, user_id; scope=:global)

# ✓ after — a denial is an exception, not a return value
try
    task_id = submit_task(key, cb, user_id)
catch err
    err isa AuthorizationError || rethrow()
    return Res.status(403, Res.json(Dict("error" => "forbidden")))
end
```

Operational notes:

- **In-flight rows are not migrated.** Tasks already persisted under the old unscoped ids stay
  readable only by their old id, and a resubmission now writes a new namespaced row. Drain the queue
  before upgrading, or delete the stale `nitro_task` rows.
- **`nitro_task.id` widened from `VARCHAR(100)` to `VARCHAR(255)`** to fit both halves.
  `_ensure_task_table!` only issues `CREATE TABLE IF NOT EXISTS`, so an existing Postgres or MySQL
  database keeps its old width and needs a one-time
  `ALTER TABLE nitro_task ALTER COLUMN id TYPE VARCHAR(255);`. SQLite ignores `VARCHAR` lengths and
  needs nothing.
- **`user_id` values are now constrained under `:user` scope**: they may not contain `::` and may
  not end in `:`, or `scoped_task_key` raises `ArgumentError`. Both rules keep the owner half of an
  id unambiguous. A colon elsewhere (`"google:12345"`) is still fine. Likewise a `:global`
  `task_key` may not contain `::`.
- **A scoped id contains `::`, which is not a legal Windows filename character.** If you used the
  value returned by `submit_task` as a path component — a staged upload, a cache file — derive that
  path from the `task_key` you passed in instead, or sanitize the id.
