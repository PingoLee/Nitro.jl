## Worker read/manage APIs require an explicit `TaskAuthority` (#48)

- **Version**: 0.3.0
- **Nitro ref**: #48; `src/Workers/types.jl`, `src/Workers/api.jl`, `src/Workers/registry.jl`,
  `src/Workers.jl`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-09-06
- **Severity**: **breaking (every worker call site)** — security fix.

### What changed

`get_task_status`, `cancel_task` and `get_all_tasks` took `user_id` as an *optional* trailing
argument defaulting to `nothing`. Omitting it skipped the ownership check and returned or acted on
**every** task, including each task's full `:result`. So the bypass was the *shortest* call, and a
call site that had merely forgotten to scope was indistinguishable from one that meant not to. A
second, quieter bypass sat next to it: the guard was `user_id !== nothing && !isempty(user_id)`, so
an empty string — what you get from reading a missing JWT claim — also skipped the check while the
call site still *looked* scoped.

Authority is now a type, and it is required:

1. **`Owner(user_id)`** is a validated task identity. It rejects an empty id, one containing `::`,
   and one ending in `:` — the same rules `scoped_task_key` enforced, moved into the constructor so
   they hold by construction. `Owner("")` cannot exist, which removes the empty-string bypass
   rather than re-encoding it.
2. **`System()`** is the bypass, unchanged in power but now a value you have to name — greppable in
   review and in an audit.
3. **Omitting the authority is a `MethodError`**, not a bypass. A bare `String` is not an authority
   either, so a half-migrated call site fails loudly instead of silently widening.

`submit_task` and `submit_sequential_task` also take `Owner` instead of a `String`. That is what
closes a pre-existing hole: `scoped_task_key`'s `:global` branch returned *before* validating the
owner, so `submit_task("k", cb, "bad::uid"; scope=:global)` used to succeed and write an identity
into `watchers` that no later call could ever match.

Two consequences fall out:

- **Ownership is now derived from the task id, not read from `watchers`.** Under `:user` scope the
  id is `"<owner>::<key>"`, so the new `owner_of(task_id)` reads it back. An owner can no longer be
  evicted from their own task by a lost watcher entry or a full-row write from another process.
  `watchers` is now purely *additional* grants.
- **`:global` tasks are unaffected**: they have no owner half, so `watchers` remains their entire
  gate, including for the creator. Deriving ownership adds an authority source for `:user` ids and
  removes none for `:global` ones.

`get_task_status` and `get_all_tasks` also gained an `:owner` key. `set_queue_authorizer!` and
`set_watch_authorizer!` hook signatures are **unchanged** — they still receive plain `String` user
ids.

### How to find the calls to migrate

```bash
rg -n 'submit_task|submit_sequential_task|scoped_task_key' --type julia
rg -n 'get_task_status|cancel_task|get_all_tasks' --type julia
# The silent ones: an omitted or empty-string user id that used to mean "everything".
rg -n 'get_task_status\([^,)]+\)|cancel_task\([^,)]+\)|get_all_tasks\(\s*(nothing)?\s*\)' --type julia
```

### Migrate your app

```julia
# ✗ before — the short call was the unscoped one
task_id = submit_task("report_42", cb, user_id)
status  = get_task_status(task_id, user_id)
cancel_task(task_id, user_id)
mine    = get_all_tasks(nothing, user_id)
all     = get_all_tasks()                      # every task, every result
key     = scoped_task_key("report_42", user_id)

# ✓ after — the short call is the scoped one
task_id = submit_task("report_42", cb, Owner(user_id))
status  = get_task_status(task_id, Owner(user_id))
cancel_task(task_id, Owner(user_id))
mine    = get_all_tasks(Owner(user_id))
all     = get_all_tasks(System())              # same power, now named
key     = scoped_task_key("report_42", Owner(user_id))

# ✗ these no longer compile — that is the point
get_task_status(task_id)                       # MethodError
get_task_status(task_id, user_id_string)       # MethodError — a String is not an authority
get_all_tasks(RUNNING)                         # MethodError — a TaskStatus is not an authority

# Status filtering moved behind the authority, which now leads:
running = get_all_tasks(Owner(user_id), RUNNING)
```

Operational notes:

- **Audit every `System()` you write during the migration.** A mechanical `nothing` → `System()`
  translation reproduces the bug this entry exists to fix. `System()` is correct only where the
  caller genuinely has no user identity — an admin dashboard, a cleanup job, a startup sweep.
- If your app reads a user id out of a claim, `Owner` now rejects an empty one at the call site
  instead of silently escalating it to full access. Handle the missing-claim case explicitly.
- Stored task rows are unchanged; there is no data migration. Ownership is derived from ids that
  already have this shape.
- A custom `AbstractWorkerStore` must update its `get_all_tasks` method: the signature is now
  `get_all_tasks(store, authority; status=nothing, queue_name=nothing)`, replacing the positional
  `(store, status, user_id, queue_name)`.
