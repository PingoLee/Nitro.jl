## Starting a task is a claimed transition; `try_transition!` gains `started_at` (#142)

- **Version**: 0.4.0
- **Nitro ref**: #142 (builds on #108; prerequisite for #127); `src/Workers/api.jl`,
  `src/Workers/queue.jl`, `src/Workers/registry.jl`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-09-11
- **Severity**: **breaking (custom `AbstractWorkerStore` implementations only)** — a correctness
  fix; part of the `0.1.x` pre-publish wave. Apps using the bundled stores need **no code change**.

### What changed

A worker body used to announce itself with an unconditional write:

```julia
task_info.status = RUNNING
task_info.started_at = current_time_utc()
set_task!(store, task_key, task_info)     # no precondition
```

`set_task!` has no precondition, so a `cancel_task` that had *already* claimed
`PENDING → CANCELLED` was overwritten a moment later. The callback then ran, and
`_complete_task!`'s own compare-and-set succeeded from `RUNNING` — reporting `COMPLETED` for a task
whose caller had been told `"Task cancelled"`. Nothing threw and nothing was logged.

Locking does not help: the two writes are strictly sequential, and `cancel_task` holding the task
lock for its whole body changes nothing about what happens after it releases.

The start is now claimed, exactly like every terminal transition since #88:

```julia
started = current_time_utc()
if !try_transition!(store, task_key, (PENDING,), RUNNING;
                    run_id = task_info.run_id, started_at = started)
    return task_info          # cancelled, or this run no longer owns the record
end
```

`try_transition!` therefore takes a new `started_at` keyword, so the timestamp is written by the
same statement that claims the status rather than by a follow-up save. There is no `set_task!`
after it — the compare-and-set *is* the write.

**On how reachable this was.** In the unqueued path it was masked rather than absent: `cancel_task`
also interrupted the worker task, and a task that had not started yet never ran its body at all.
The sequential path had no such cover — its queue processor is already `Threads.@spawn`ed, so a
cancel can land between that path's `get_task_info` and its start write. Removing the interrupt
(#127) uncovers the unqueued path too, which is why this fix lands **before** it. Had the two
shipped in the other order, #127 would have introduced a silent cancellation loss.

### How to find the calls to migrate

```bash
# Custom stores. If this finds nothing, nothing below applies to you.
rg -n 'AbstractWorkerStore' --type julia
rg -n 'try_transition!' --type julia

# A store that writes `started_at` only from set_task! now has a column the claimed start
# transition also needs to be able to write.
rg -n 'started_at' --type julia
```

### Before → after

```julia
# ✗ before — #108's signature
function try_transition!(store::MyStore, id, from, to::TaskStatus;
                         run_id::Union{Nothing, UUID},
                         error=nothing, completed_at=nothing,
                         result=UNSUPPLIED, progress=nothing)

# ✓ after — `started_at` joins the optional column set, alongside `completed_at`
function try_transition!(store::MyStore, id, from, to::TaskStatus;
                         run_id::Union{Nothing, UUID},
                         error=nothing, completed_at=nothing,
                         started_at=nothing,
                         result=UNSUPPLIED, progress=nothing)
```

Nothing else moves: `started_at` is written only when supplied, the same rule `completed_at`,
`result` and `progress` already follow. An app that only *uses* the bundled stores sees one
behavior change and no API change — a cancellation issued before a task starts now sticks, where
before it could be silently undone.
