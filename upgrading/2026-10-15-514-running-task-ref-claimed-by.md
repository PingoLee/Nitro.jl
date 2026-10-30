## `RunningTaskRef` gains `claimed_by`, and `nitro_task` gains four columns (#514)

- **Version**: 0.7.0
- **Nitro ref**: [#514](https://github.com/PingoLee/Nitro.jl/issues/514) ; `src/Workers/registry.jl`
- **Recorded**: 2026-10-15
- **Severity**: **breaking (custom worker stores, and a `PormGWorkerStore` built directly)** — a
  custom `AbstractWorkerStore` whose `list_running_task_refs` builds a three-field `RunningTaskRef`
  throws during zombie recovery, and a `PormGWorkerStore` constructed without `pormg_nitro_worker`
  over an older table cannot write tasks until its four new columns exist.

### What changed

`Nitro.Workers.RunningTaskRef` is the row the zombie sweep reads for each `RUNNING` task. It was
`@NamedTuple{id, run_id, started_at}` and is now
`@NamedTuple{id, run_id, started_at, claimed_by::Union{Nothing, String}}`.

The new field names the consumer process that holds a run under a lease, part of the store-side
claim capability for queues run by a separate consumer process. The sweep skips such a run,
because its liveness is its lease rather than a handle in any one process, and counts it as
`leased` in its completion log line. `nothing` means an ordinary run that some process is executing
itself, which is every run an app has today.

Only a store that implements the **optional** `list_running_task_refs` itself is affected. The
shipped `InMemoryWorkerStore` and `PormGWorkerStore` are updated. A store that leaves the method to
its default is unaffected. Building the ref with three values now throws
`ArgumentError: Wrong number of arguments to named tuple constructor`, so the boot-time sweep
logs its read failure and recovers nothing.

A store whose method returns plain named tuples without the field, rather than `RunningTaskRef`s,
keeps working: the sweep reads a missing `claimed_by` as `nothing`.

### `PormGWorkerStore` writes four new columns

Every task the PormG store creates or re-runs now writes four new `nitro_task` columns: `external`,
`attempt`, `claimed_by` and `lease_expires_at`. **`pormg_nitro_worker(...)` adds them on boot**,
with the probe-then-`ALTER` it already uses for `run_id`, and builds two indexes beside them. An app
that boots through it needs no edit. On a large PostgreSQL table, though, the boot that builds the
indexes blocks writes to the table while it runs.

An app that constructs `PormGWorkerStore(; model, db_key)` **directly**, over a table an older Nitro
created, gets no bootstrap: every submit then fails with a missing-column error from the database.
Add the columns once, by hand:

```sql
-- PostgreSQL
ALTER TABLE "nitro_task" ADD COLUMN "external" BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE "nitro_task" ADD COLUMN "attempt" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "nitro_task" ADD COLUMN "claimed_by" VARCHAR(255);
ALTER TABLE "nitro_task" ADD COLUMN "lease_expires_at" TIMESTAMPTZ;   -- DATETIME on SQLite
-- Optional, performance only: what the claim and lease-expiry queries read.
CREATE INDEX IF NOT EXISTS "nitro_task_claim_idx" ON "nitro_task" ("queue_name", "status", "external", "created_at");
CREATE INDEX IF NOT EXISTS "nitro_task_lease_idx" ON "nitro_task" ("status", "lease_expires_at");
```

Or call `pormg_nitro_worker(db_key = …)` once and keep the store it returns.

### How to find the calls to migrate

```bash
rg -n 'RunningTaskRef' <app>/src <app>/test        # constructions, comprehensions, push!es
rg -n 'list_running_task_refs' <app>/src          # a custom store's own method
rg -n 'PormGWorkerStore\(' <app>/src              # a PormG store built without pormg_nitro_worker
rg -n 'column .*(external|attempt|claimed_by|lease_expires_at)' <app's log>
```

### Migrate your app

```julia
# ✗ before
RunningTaskRef((task.id, task.run_id, task.started_at))

# ✓ after — by name, so a future field fails with an error that names it
RunningTaskRef((id = task.id, run_id = task.run_id, started_at = task.started_at,
                claimed_by = nothing))
```

Pass the stored claim instead of `nothing` if the store also implements the claim capability
(`Nitro.Workers.missing_claim_methods(MyStore)` is then empty).
