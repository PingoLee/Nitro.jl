## PormG session and worker stores — stored JSON nests at most 512 levels, and an overflow while reading it is no longer swallowed (#344)

- **Version**: Unreleased
- **Nitro ref**: [#344](https://github.com/PingoLee/Nitro.jl/issues/344) ; `ext/NitroPormGExt.jl`
- **Recorded**: 2026-09-25
- **Severity**: **behavior change.** It affects apps using `pormg_nitro_session` or
  `pormg_nitro_worker`. Storing a session payload or a task result nested deeper than 512 levels
  used to work and now throws. An interrupt, stack overflow or out-of-memory raised while
  reading one back now propagates instead of reading as "no session" or "does not decode".

### What changed

[#314](2026-09-24-314-json-nesting-depth-limit.md) capped the nesting of every JSON parse of
**request** data at 512 levels. The PormG stores' two parses of JSON they had stored themselves
were left out. Those are a session's `session_data`, and a task's `result` and `watchers`. Their
catches also rethrew only `InterruptException`, against the
[#254](2026-09-21-254-unrecoverable-errors-not-swallowed.md) policy every other read site
follows. So a stack overflow while reading a session silently became "no session" and logged the
visitor out. On a task it was relabelled a decode error. Either way the process kept serving,
possibly corrupted. The read happens on a request task (`SessionMiddleware`, or a handler
calling `get_task_status`), and on some Windows hosts an overflow there ends the process
(#301).

Both parses now go through the same 512-level bound. So that no value is stored which the
bound would then refuse to read, the **write** is checked too:

| Operation | Before | After |
|---|---|---|
| `set_session!` / `update_session!` / `SessionMiddleware` saving a payload nested past 512 levels | stored | `ArgumentError`, nothing written |
| A worker callback returning a value nested past 512 levels | stored as the result, `COMPLETED` | the completing write throws; the run retries or ends `FAILED` |
| `set_task!` / `replace_task!` with such a `result` | stored | `ArgumentError`, nothing written |
| Reading a session row stored past 512 levels by an older release | decoded | no session, with the payload-free "does not decode" warning |
| Reading a task row stored past 512 levels by an older release | decoded | `get_task_status` throws the value-free "does not decode" error, and a listing skips the row |
| `InterruptException` / `StackOverflowError` / `OutOfMemoryError` while reading a session | "no session", logged as a failed read | propagates: a `500` for an overflow or OOM through `SessionMiddleware`; an interrupt passes the error boundary, as everywhere else |
| … while reading a task (`get_task_status`, a listing) | "does not decode", or the row skipped | propagates |

Payloads at 512 levels or fewer are stored and read exactly as before. Real session data and
task results are a few levels deep; a recursive structure is the only way to get near the
limit. `MemoryStore` and `InMemoryWorkerStore` serialize nothing and have no limit, so a test
suite that runs on them will not show this.

A task whose result is refused goes through the same path as a callback that throws. With
`retry_on_failure` the callback **runs again** before the task is marked `FAILED`.

### How to find the calls to migrate

```bash
# 1. Whether the app uses the PormG stores at all. No hit, nothing to do.
rg -n 'pormg_nitro_session|pormg_nitro_worker' <app>/src

# 2. What goes into a session, and what callbacks return. Look for recursive values:
#    trees, nested comment threads, ASTs, a parsed document stored whole.
rg -n 'set_session!|storesession!|getsession\(' <app>/src
rg -n 'submit_task|submit_sequential_task' <app>/src

# 3. After deploying, rows written deeper by the old release show up as this warning,
#    once per read (the key and payload are never logged):
#      "PormGSessionStore: failed to read session: the stored session does not decode"
#      "PormGWorkerStore: skipping a task row that does not decode"
```

### Migrate your app

Store a recursive value flat, and rebuild it where it is used:

```julia
# ✗ before -- a tree kept in the session as nested children, any depth
session["tree"] = Dict("id" => 1, "children" => [Dict("id" => 2, "children" => [#= … =#])])

# ✓ after -- a flat list with parent links
session["tree"] = [Dict("id" => 1, "parent" => nothing), Dict("id" => 2, "parent" => 1) #= , … =#]
```

A worker callback returns the flat form the same way. An old row nested past the limit can only
be rewritten or deleted. A session row simply expires. A finished task row is pruned by
`cleanup_tasks!(store, retain_days)` once it ages out, or removed at once with
`delete_task!(store, task_id)`.
