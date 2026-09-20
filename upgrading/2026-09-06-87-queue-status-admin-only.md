## `is_task_running` is removed; `get_queue_status` is admin-only (#87)

- **Version**: 0.3.0
- **Nitro ref**: #87; `src/Workers/api.jl`, `src/Workers.jl`
- **Recorded**: 2026-09-06
- **Severity**: **breaking (one removal, one signature)** — security fix. Builds on #48.

### What changed

Two worker introspection APIs took no `user_id` at all, so unlike the read/manage trio in
#48 there was not even a bypass to *omit* — there was no scoped form to reach for, while
the surrounding API shape suggested the worker layer was user-scoped.

**`is_task_running` is removed outright.** Any caller who could name an id learned whether
it was live — an existence oracle over the whole task table, with no authorization
anywhere in it. It had no tests and no documentation, so nothing pinned the behaviour;
hardening it would have meant designing and testing a function no one used. Its docstring
already admitted it "performs no authorization at all".

**`get_queue_status` now takes `System()` and only `System()`.** Its `:pending_tasks` and
`:current_task` enumerate every pending id on a queue regardless of owner — and since #19
those ids carry their owner in the `"<owner>::<key>"` prefix, so the enumeration discloses
*who* has work queued, not merely that work exists.

Accepting an `Owner` and filtering the id list was the tempting fix and is the wrong one:
queue depth, `:running` and `:current_task` are facts about a queue rather than about any
one user, so the result would look user-scoped while still reporting another tenant's
queue depth. Queue-wide introspection is an admin surface in every comparable framework —
Sidekiq Web, Oban Web, Flower, Hangfire's dashboard — and is treated as one here. Passing
an `Owner` is a `MethodError`.

### How to find the calls to migrate

```bash
rg -n 'is_task_running' --type julia
rg -n 'get_queue_status' --type julia
```

### Migrate your app

```julia
# ✗ before
if is_task_running(task_id)
    ...
end
queue = get_queue_status("reports")

# ✓ after — the same question, with authorization applied.
# NOTE `:status` is a String, not the TaskStatus enum.
if get_task_status(task_id, Owner(user_id))[:status] in ("PENDING", "RUNNING")
    ...
end
queue = get_queue_status("reports", System())

# ✗ no longer compiles — there is no user-scoped queue view
get_queue_status("reports", Owner(user_id))

# ✓ for "show a user their own pending work", read it scoped instead
mine_pending = get_all_tasks(Owner(user_id), PENDING)
```

Operational notes:

- **Move `get_queue_status` off any user-facing route.** Put it behind the authorization
  you would put in front of a Sidekiq or Hangfire dashboard: all-or-nothing, admin only.
  If it currently sits behind a broad auth guard on a status endpoint, that endpoint is
  disclosing other tenants' queued job ids today.
- There is no deprecation shim for `is_task_running`; a stale call is an `UndefVarError`.
