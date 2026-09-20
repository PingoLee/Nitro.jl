## `AbstractWorkerStore` gains three atomic write methods; `set_task!` no longer writes watchers (#88)

- **Version**: 0.3.0
- **Nitro ref**: #88; `src/Workers/registry.jl`, `src/Workers/api.jl`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-09-06
- **Severity**: **breaking for custom `AbstractWorkerStore` implementations only.** Apps
  using `InMemoryWorkerStore` or `PormGWorkerStore` need no source edit.

### What changed

`PormGWorkerStore` stores `watchers` as a JSON array in one `TextField`, and every save
rewrote the whole row. `_register_or_watch!` and `cancel_task` guarded their
read-modify-write with `lock_tasks`, which for that store is a plain `ReentrantLock` held
in the struct — **process-local**. Two processes sharing one database each took their own
and neither saw the other, so the writes were last-write-wins.

The fix is not a better lock. `lock_tasks` promised mutual exclusion its weakest backend
cannot deliver, so the contended writes moved into the store as atomic *intent*
operations, which every backend can honour with its own storage:

- **`add_watcher!(store, task_id, user_id) -> Bool`** — idempotent, atomic. `PormGWorkerStore`
  implements it as a bounded-retry compare-and-set: the expected `watchers` document is part
  of the `WHERE` clause, so a racing append matches zero rows and the retry re-reads what the
  other writer left instead of overwriting it.
- **`try_transition!(store, task_id, from, to; error, completed_at, result, progress) -> Bool`**
  — moves a task between statuses only if it is still in `from`, with the precondition and
  the write in one statement. **Every** terminal transition now goes through it: `cancel_task`,
  and completion, failure and cancellation inside the worker. Whichever writer arrives first
  wins and the losers write nothing, so a task finishing concurrently — in this process or
  another one sharing the database — cannot overwrite a cancellation.
- **`reload_task(store, task_id)`** — reads the durable record, bypassing any in-process
  cache. Read paths consult it before *denying*, so a grant issued by another process is not
  refused merely because this process's cached record predates it.
- **`replace_task!(store, task_id, task_info)`** — writes a whole record, watchers included.

And the change that actually closes the issue: **`set_task!` no longer writes `watchers` at
all.** Two watcher appends racing each other was the visible symptom, but the dominant loss
path was an ordinary state transition — start, progress, finish — carrying a stale watcher
list along with it. Those happen far more often than appends. Grants are not volatile state,
so they no longer travel on the volatile-state write.

`InMemoryWorkerStore` honours the same contract even though it never had the bug, because a
rule enforced by only one backend is a store that silently behaves differently.

### How to find the calls to migrate

```bash
# Only custom stores are affected. If this finds nothing, there is nothing to do.
rg -n 'AbstractWorkerStore' --type julia
# Anything composing an atomic write out of the lock is now the wrong shape:
rg -n 'lock_tasks' --type julia
```

### Migrate your app

```julia
# ✗ before — a custom store needed these
set_task!(store::MyStore, id, info)   # wrote every field, watchers included

# ✓ after — three more methods, and set_task! narrows
set_task!(store::MyStore, id, info)      # state only; MUST NOT write watchers
replace_task!(store::MyStore, id, info)  # the whole record, watchers included
add_watcher!(store::MyStore, id, uid)    # atomic + idempotent; false if absent
try_transition!(store::MyStore, id, from, to; error=nothing, completed_at=nothing)

# ✗ do not build this on lock_tasks — it is process-local
lock_tasks(store) do
    info = get_task_info(store, id)
    push!(info.watchers, uid)
    set_task!(store, id, info)
end

# ✓ let the store make it atomic
add_watcher!(store, id, uid)
```

Operational notes:

- The store stubs have no fallback method, so a custom store missing any of the three
  fails with a `MethodError` at the call site rather than silently degrading.
- No schema change and no data migration: the compare-and-set works on the existing
  `watchers` text column. A `watchers_version` column was rejected because
  `_ensure_task_table!` only issues `CREATE TABLE IF NOT EXISTS`, so an existing database
  would never gain one.
- PormG's `with_advisory_lock` was also rejected: it is Postgres-only and degrades to a
  no-op with a warning on SQLite, which would give a silently different consistency
  posture per backend.
- **Nitro now owns the byte format of the `watchers` column.** It is a JSON array written by
  `JSON.json`, and its exact form is load-bearing twice: the compare-and-set matches the
  stored document, and user-scoped listing matches the JSON-quoted user id as a substring. A
  row reformatted by hand, by a migration, or by another language — `["alice", "bob"]` rather
  than `["alice","bob"]` — makes the next grant exhaust its retries and raise, and can make
  the row silently drop out of that user's task list. Change watchers only through the worker
  API.
- A custom store that also runs its own terminal transitions must route them through
  `try_transition!` rather than reading the status and then saving, or it reintroduces the
  race for its own backend.
- `try_transition!`'s `result` keyword defaults to the exported sentinel `UNSUPPLIED`,
  which is how a store tells "leave the stored result alone" apart from "the task completed
  with `nothing`". Compare with `===`, not `isnothing`.
- If your store's `filter`-style query builder **accumulates** predicates onto one object
  rather than returning a fresh one, a `get_all_tasks` implementation must build each leg
  of the owned/granted union from its own query. Sharing one base ANDs the legs together
  and silently drops every task the user only watches.
