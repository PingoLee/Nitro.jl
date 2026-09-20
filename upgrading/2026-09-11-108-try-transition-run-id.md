## `try_transition!` gains a required `run_id`; `nitro_task` gains a `run_id` column (#108)

- **Version**: Unreleased
- **Nitro ref**: #108 (builds on #88); `src/Workers/types.jl`, `src/Workers/registry.jl`,
  `src/Workers/queue.jl`, `src/Workers/api.jl`, `ext/NitroPormGExt.jl`,
  `docs/src/tutorial/workers.md`
- **Recorded**: 2026-09-11
- **Severity**: **breaking (custom `AbstractWorkerStore` implementations only)** — a correctness
  fix; part of the `0.1.x` pre-publish wave. Apps using the bundled stores need **no code change**:
  the `PormGWorkerStore` schema migration is applied automatically on boot.

### What changed

Re-running a *finished* task key replaces the record with a fresh `PENDING` one
(`_register_or_watch!` → `replace_task!`). The previous run's worker task can still be in flight —
parked in a `sleep`, blocked on IO, or simply mid-callback. When it finally finished, its terminal
write went through `try_transition!`, whose only precondition was `status in (PENDING, RUNNING)` —
which the **new** record satisfies. So a run that had nothing to do with the new submission stamped
`CANCELLED` or its own stale result onto it, and the resubmitted run's real result was discarded:

```
resubmit                          -> status = PENDING   (new record)
old run's terminal write arrives  -> status = CANCELLED (lands on the NEW run)
new run completes                 -> its own claim fails; result discarded
```

#88 made terminal writes **atomic**. It did not make them **addressed**: they named a task id, and
a task id outlives the run writing under it.

Every `TaskInfo` now carries a `run_id::UUID` minted in its constructor, and `try_transition!` takes
it as a **required** keyword and compares it in the same `WHERE` clause as the status. A write from
a run that no longer owns the record matches zero rows and — as with the status precondition —
**nothing is written**.

`run_id` follows exactly the write split `watchers` follows: **`replace_task!` writes it,
`set_task!` never does.** A store that carried it along on ordinary state saves would let whichever
run wrote last adopt the record's identity, defeating the mechanism entirely.

The runtime handle teardown in `_finish_task!` is fenced the same way. It used to
`deregister_active_task!` by id unconditionally, so a late-finishing previous run deleted its
*successor's* live handle — and `recover_zombie_tasks!` decides zombie-ness from exactly that
handle, so the next sweep marked a genuinely-running task `FAILED`.

**Why the keyword is required and not optional.** `run_id = nothing` is a legal value meaning "no
run precondition", but you have to write it. An optional keyword defaulting to `nothing` would
rebuild the shape #48 removed: the unfenced call becomes the *shorter* one, and a new terminal-write
call site that simply forgot it is indistinguishable in review from one that meant to skip the
fence.

### How to find the calls to migrate

```bash
# Custom stores. If this finds nothing, nothing below applies to you.
rg -n 'AbstractWorkerStore' --type julia

# Every try_transition! definition and call in your tree.
rg -n 'try_transition!' --type julia

# Anything constructing or persisting a TaskInfo by hand — a hand-rolled deserializer is the one
# that breaks SILENTLY rather than loudly. See the first operational note below.
rg -n 'TaskInfo\(' --type julia
```

```sql
-- Does your nitro_task table predate this change? (Informational: booting through
-- `pormg_nitro_worker` adds the column for you.)
SELECT * FROM nitro_task LIMIT 1;   -- no run_id column => yes
```

### Migrate your app

**1. The database — automatic, with a manual fallback.** `_ensure_task_table!` only issues
`CREATE TABLE IF NOT EXISTS`, so an existing table would never gain the column on its own. That is
the same limitation which made #88 reject a `watchers_version` column, and #108 is paying the cost
#88 declined. Because *every* read path goes through `_from_db_record`, an unmigrated table is
**unreadable**, not merely degraded — so the migration is applied on boot rather than left to the
operator. `pormg_nitro_worker` now also calls `_ensure_run_id_column!`, which issues the `ALTER` and
establishes idempotency by *proving* the column exists rather than by matching a duplicate-column
error string (the three dialects word it differently, and a `catch` broad enough to cover all three
would swallow real failures).

Pre-existing rows are backfilled with the **nil UUID**, which is exact: a row written before run ids
existed belongs to no live run, and `uuid4()` can never produce the nil UUID, so no running task can
accidentally adopt one.

If you provision the table yourself rather than through `pormg_nitro_worker`, run it by hand — one
statement, no dialect variants needed:

```sql
ALTER TABLE nitro_task
  ADD COLUMN run_id VARCHAR(36) NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000';
```

**2. A custom store.**

```julia
# ✗ before
function try_transition!(store::MyStore, id, from, to::TaskStatus;
                         error=nothing, completed_at=nothing,
                         result=UNSUPPLIED, progress=nothing)

# ✓ after — run_id is required (no default) and joins the compare half
function try_transition!(store::MyStore, id, from, to::TaskStatus;
                         run_id::Union{Nothing, UUID},
                         error=nothing, completed_at=nothing,
                         result=UNSUPPLIED, progress=nothing)
    # compare BOTH, in one atomic step:
    #   stored.status in from  &&  (run_id === nothing || stored.run_id == run_id)
end

# ✗ before — set_task! wrote run_id along with everything else
set_task!(store::MyStore, id, info)

# ✓ after — run_id follows watchers
set_task!(store::MyStore, id, info)      # state only; MUST NOT write run_id or watchers
replace_task!(store::MyStore, id, info)  # the whole record: run_id and watchers included
```

Operational notes:

- **Reading the column back is load-bearing, and getting it wrong fails silently.** A deserializer
  that rebuilds a `TaskInfo` from a row via the constructor gets a *freshly minted* `run_id` for
  free; if it does not then overwrite it from the row, every read invents a new run and **no worker
  can ever finish its own task**, because every fence compares against an id nothing holds. Assign
  it explicitly, and raise when the column is absent rather than keeping the invented one — which is
  what the bundled `_from_db_record` now does.
- An un-updated third-party store fails with a `MethodError` at the call site rather than silently
  degrading — the same property #88's three methods have, and for the same reason: the interface
  stubs in `src/Workers/registry.jl` carry no fallback method.
- A store that accepts `run_id` and ignores it is not a conforming store. It reintroduces #108 for
  its own backend, exactly as a store that reads the status and then saves reintroduces #88.
- `run_id` is a plain `uuid4()`, deliberately **not** `Crypto.secure_uuid4()`. It is an internal
  correlation value, never returned to a caller and never a capability; guessing one buys nothing,
  since forging a write also requires being inside the process that calls `try_transition!`.
