## A cancellation now records its cause, and `cancel_requested` is no longer a field (#183)

- **Version**: 0.4.0
- **Nitro ref**: #183 (follow-up to #176); `src/Workers/types.jl`, `src/Workers/queue.jl`,
  `src/Workers/api.jl`, `src/Workers/execution.jl`, `src/Workers/runtime.jl`, `src/Workers.jl`,
  `docs/src/tutorial/workers.md`, `.github/instructions/workers.instructions.md`,
  `test/workers_tests.jl`
- **Recorded**: 2026-09-15
- **Severity**: **breaking for direct field reads, behaviour for everyone else.**
  `task_info.cancel_requested` no longer exists and raises immediately; the accessor
  `cancel_requested(task_info)` is unchanged. Separately, the text stored in a cancelled task's
  `error` field changes on **every** path — if you match on it, you must update the strings.

### What changed

Four things request a cancellation — `cancel_task`, an expired `TaskOptions(timeout=…)`, a re-run
displacing a still-executing predecessor, and (since #176) a teardown drain. The token recorded
only *that* one of them had fired, never *which*, and the stored message was worse than uninformative:

- `submit_task` passed `"Cancelled by user"`; `submit_sequential_task` took `_cancel_task!`'s
  `"Cancelled"` default. The same event recorded different text depending on which submit function
  the caller happened to use.
- And `"Cancelled by user"` was reachable **only when no user had cancelled anything**. A real
  `cancel_task` claims `CANCELLED` *before* setting the token, so the run's own terminal write
  loses its compare-and-set and stores nothing; a timeout is terminal `FAILED`; a supersede fails
  its `run_id` fence. The one cause that writes no record of its own is a drain — so the string
  naming a user was, in practice, the shutdown's.

Two changes fix it together:

1. **`TaskInfo`'s `@atomic cancel_requested::Bool` becomes `@atomic cancel_reason::Symbol`**, where
   `:none` means "not cancelled". One field rather than two, so a token that is set can never be
   missing its cause; two fields would have made correctness depend on every setter writing
   reason-before-flag. New accessor `cancel_reason(task_info)` returns `:none`, `:user`,
   `:timeout`, `:superseded` or `:shutdown` (exported as `CANCEL_REASONS`).
   **The first cause wins**: a job cancelled by a person a second before a deploy still reports
   `:user`.
2. **`_cancel_task!` renders the stored message from that reason** instead of taking one, so the
   two submit paths cannot diverge again. The strings are now:

   | Cause | Stored `error` |
   |---|---|
   | `:user` | `"Cancelled by user"` — and now *only* a person produces this |
   | `:shutdown` | `"Cancelled by worker shutdown"` — both submit paths |
   | `:superseded` | not stored on any current path — `replace_task!` mints a new `run_id`, so the displaced run's write always loses its fence. The reason reaches the *callback*, not the record |
   | `:timeout` | not stored — a deadline records `FAILED` with `"Timeout of Ns exceeded"`, unchanged |

`cancel_task`'s own durable write also moves from `"Cancelled"` to `"Cancelled by user"`, so a
user cancellation reads the same whichever writer got there first.

### How to find the calls to migrate

```bash
# 1. Direct field access — this is the breaking half. Raises immediately; there is no silent case.
grep -rn "\.cancel_requested" --include=*.jl .

# 2. Anything matching on the stored message. These keep working but now compare against
#    strings that no longer occur.
grep -rn '"Cancelled by user"\|"Cancelled"' --include=*.jl .

# 3. Alerting, dashboards and reports that read CANCELLED as "a person did this" — they can
#    now discriminate, and probably should.
grep -rn "CANCELLED" --include=*.jl .
```

### Before → after

```julia
# BEFORE — the field read, and no way to tell a deploy from a person.
if task_info.cancel_requested
    return "cancelled"
end

# AFTER — the accessor was always the documented form and is unchanged.
if cancel_requested(task_info)
    return "cancelled"
end

# AFTER — and the callback can now act on WHY it was asked to stop.
if cancel_requested(task_info)
    cancel_reason(task_info) === :shutdown && return checkpoint(done)  # we are coming back
    return "cancelled"
end
```

```julia
# BEFORE — matching the stored text, which named a user for a shutdown.
status[:error] == "Cancelled by user"      # true for a DRAIN, never for cancel_task

# AFTER — it means what it says, and a shutdown has its own string.
status[:error] == "Cancelled by user"              # a person cancelled it
status[:error] == "Cancelled by worker shutdown"   # a teardown stopped it
```
