## Worker runs no longer inherit the submitter's dynamic scope (#209)

- **Version**: 0.4.0
- **Nitro ref**: #209; `src/Workers/execution.jl`, `src/Workers/api.jl`, `src/Workers/queue.jl`,
  `docs/src/tutorial/workers.md`, `test/workers_tests.jl`,
  `test/extensions/pormg_worker_tests.jl`
- **Recorded**: 2026-09-18
- **Severity**: **behaviour.** Nothing forces an edit unless your callbacks read a `ScopedValue`
  you set around the submit — those now read the value's *default* instead, silently. The logger
  is the one exception and is carried across deliberately, so `with_logger` still reaches worker
  output. The change it makes in the other direction is a repair: a task submitted inside a PormG
  transaction used to write on the submitter's connection, including after it went back to the pool.

### What changed

`Threads.@spawn` and `@async` inherit the spawning task's **dynamic scope**, so every
`ScopedValue` open at the submit site stayed open inside the worker run. PormG tracks transaction
state in exactly such a value (`PormG.Configuration._tx_context`), so a task submitted inside
`PormG.run_in_transaction(...)` resolved its *first* store write — the run-start CAS, before any
of your callback code — onto the **submitter's** transaction connection. Either that write landed
inside your transaction and was rolled back with it, or your block committed first and the run
kept writing on a connection already returned to the pool, racing whoever borrowed it next.

It was never store-specific: a callback that queries PormG had the identical use-after-release on
`InMemoryWorkerStore`, with no Nitro store write involved at all. So the fix is in the spawn, not
behind an extension seam. Three sites now build their `Task`, clear its scope and only then
schedule it — `_execute_task_async`, each sequential queue's processor, and the cleanup
scheduler. A queued item runs on its processor's task, so detaching the processor detaches every
item that queue will ever run.

**What this does not do.** `submit_task` writes the task record *synchronously, on your task*, so
that write is still governed by your transaction while the run it spawns reads on a different
connection. Submit from inside an open transaction on a PormG-backed store and the run cannot see
its own record yet, declines the claim, and does nothing; the record then commits and sits at
`PENDING`, where zombie recovery — which looks only at `RUNNING` — will never reach it. That is a
strictly better failure than writing on someone else's connection, but it is still a failure:
**submit after the block closes.**

### How to find the calls to migrate

```bash
rg -n 'ScopedValue' <app>/src
```

For each one, check whether anything reachable from a `submit_task` / `submit_sequential_task`
callback reads it. Then, for the transaction half:

```bash
rg -n 'run_in_transaction|with_tx_context' <app>/src
```

and check every `submit_task`, `submit_sequential_task`, `start!`, `startup` or `worker_startup`
reachable from inside one of those blocks.

### Migrate your app

A callback no longer sees your bindings — the logger excepted — so capture what it needs into the
closure:

```julia
const TENANT = ScopedValue("public")

# ✗ before — the run inherited the submitter's scope, so this read "acme"
with(TENANT => "acme") do
    submit_task("report", () -> render(TENANT[]), Owner(uid))
end

# ✓ after — the run sees TENANT's DEFAULT ("public"); pass the value explicitly
with(TENANT => "acme") do
    tenant = TENANT[]
    submit_task("report", () -> render(tenant), Owner(uid))
end
```

And submitting inside a transaction remains wrong, for the ordering reason above rather than the
corruption one:

```julia
# ✗ before and after — the run cannot see its own uncommitted record, so it never starts
PormG.run_in_transaction("db") do
    id = write_audit_row()
    submit_task("report_42", () -> render(id), Owner(uid))
end

# ✓ submit after the block closes, and pass the committed row's id
id = PormG.run_in_transaction("db") do
    write_audit_row()
end
submit_task("report_42", () -> render(id), Owner(uid))
```
