## `pormg_nitro_session` / `pormg_nitro_worker` create their table through PormG's `ensure_table!`, and refuse inside an open transaction on that connection

- **Version**: Unreleased
- **Nitro ref**: #791 (item 2) ; `ext/NitroPormGExt.jl` (`_ensure_session_table!`, `_ensure_task_table!`, `_upgrade_session_table!`, `_upgrade_task_table!`), `src/exts.jl` (the two factories' docstrings)
- **Recorded**: 2026-11-08
- **Severity**: behavior change. An app that builds its stores in `main()` outside any transaction,
  as the generated boot and `docs/src/tutorial/bigger_applications.md` do, needs no edit. Neither
  does an existing database: a table an older Nitro created gets the same DDL as before.

### What changed

A factory that finds its table missing now creates it through `PormG.Migrations.ensure_table!(model,
db_key; force = true)` (PormG 0.9, `force` since PormG #1677), instead of issuing `CREATE TABLE IF NOT
EXISTS` and `CREATE INDEX IF NOT EXISTS` through raw `fetch`. The DDL is the model's own, the two
claim indexes of `nitro_task` included (declared as `Index` meta under their fixed names), run in one
transaction. On PostgreSQL it runs under PormG's migration advisory lock, so two instances booting
together create the table once.

`force = true` keeps the old outcome on a `change_db: false` connection, which is PormG's production
posture and what `register_connection` builds. The two tables are Nitro's infrastructure, kept out of
the application's migrations, so `change_db` does not govern them, and the factories create them
whatever it says, as they always did.

A table that already exists is left alone by `ensure_table!`, which never alters one. The factory
then runs the statements an older table needs, as before: the column probes and `ALTER`s (`run_id`,
#108; the claim and named-job columns, #514; `created_at`, #362), then every index under the name it
has always had, `IF NOT EXISTS`. The one-column index names are unchanged on a new table too: PormG
derives `<table>_<column>_idx` for a `db_index` column (PormG #1341), which is the name Nitro gave
them by hand.

| call | before | now |
|---|---|---|
| a factory on a key with no table, `change_db: false` | table created | table created (unchanged) |
| a factory on a key whose table an older Nitro created | probes, `ALTER`s where a column is missing, `CREATE INDEX IF NOT EXISTS` | the same statements, after `ensure_table!`'s existence check (see the boot waits below) |
| two instances booting together on an empty PostgreSQL database | both ran `CREATE TABLE IF NOT EXISTS` | one creates the table under the migration lock; the other finds it |
| a factory called **inside an open transaction on its connection** (`run_in_transaction(key) do … end`, `atomic`) | the DDL ran inside the caller's transaction | **raises PormG's `TransactionError`** before any statement runs |

The last row is the edit an app may owe. Build the store before the transaction, or outside it.

Two waits a boot can now meet, neither of which needs an edit:

- **SQLite, every boot.** `ensure_table!` checks for the table inside a write transaction
  (`BEGIN IMMEDIATE`), so a boot waits behind another process's open write transaction on the same
  file, up to the connection's busy timeout, and fails with `OperationalError` (`database is
  locked`) past it. The old boot took no write lock on an existing table. It matters only when
  another process, a separate `consume!` consumer say, holds a long write transaction while an
  instance starts.
- **PostgreSQL, a missing table only.** Creating it waits on PormG's migration advisory lock, the
  one `migrate` holds, so a first boot that coincides with a `migrate` run waits for it, and fails
  with `OperationalError` past PormG's lock timeout. A table that exists is found without the
  lock.

### How to find the calls to migrate

```
grep -rnE 'pormg_nitro_(session|worker)\(' --include=*.jl .
```

For each hit, check that it does not run inside a `run_in_transaction` / `atomic` block on the same
key, directly or through a function that block calls.

### Migrate your app

```julia
# ✗ before: the store is built inside a transaction on its own connection
PormG.run_in_transaction("db") do
    seed_reference_rows!()
    global WORKERS = worker_startup(app; queues = ["reports"], store = pormg_nitro_worker(db_key = "db"))
end

# ✓ after: build the store first, then open the transaction
store = pormg_nitro_worker(db_key = "db")
PormG.run_in_transaction("db") do
    seed_reference_rows!()
end
workers = worker_startup(app; queues = ["reports"], store)
```
