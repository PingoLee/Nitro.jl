## A teardown abandons a sequential queue's backlog instead of executing it (#182)

- **Version**: 0.4.0
- **Nitro ref**: #182 (follow-up to #176; builds on #183); `src/Workers/runtime.jl`,
  `src/Workers/queue.jl`, `src/Workers/types.jl`, `src/Workers/api.jl`,
  `docs/src/tutorial/workers.md`, `.github/instructions/workers.instructions.md`,
  `test/workers_tests.jl`
- **Recorded**: 2026-09-15
- **Severity**: **behaviour, and it changes what a shutdown does to queued work.** Nothing raises.
  Tasks that a teardown used to run on the way out are now recorded `CANCELLED` and never run. If
  you relied on a stop draining the backlog, you must resubmit.

### What changed

`shutdown!` closed each sequential queue's channel, which stops new *submissions* — it never
stopped the **processor**, which kept `take!`-ing whatever was already buffered (`Channel(100)` by
default). So a teardown could *start* runs that:

- were never in the drain's snapshot, so they got no cancellation token and no wait;
- registered themselves in the `active_tasks` of a runtime being torn down;
- wrote `RUNNING` records that nothing in this process was waiting on.

A teardown now stops fetching first — the shape Sidekiq's quiet-then-`-t` and Go River's
`Client.Stop` both use. Every task still queued when `shutdown!` is called is recorded
**`CANCELLED`** with error **`"Cancelled by worker shutdown"`** — the same string a run parked in
its retry backoff gets (#183), so one teardown produces one vocabulary.

`CANCELLED` rather than silence, because silence is not free: an abandoned record sits at `PENDING`
and `recover_zombie_tasks!` only sweeps `RUNNING`, so nothing would ever reap it. `CANCELLED`
rather than `FAILED`, because nothing failed and `FAILED` is what the zombie sweep writes.

**`submit_sequential_task` now records the task it failed to enqueue.** Closing a queue's channel
raises in every submitter already blocked on it (the buffer is `Channel(100)`), and that call had
already written a `PENDING` record — the same orphan, arriving through the one door closing the
channel leaves open. The caller still gets the `InvalidStateException` it always got, but the
record is now `CANCELLED` / `"Cancelled by worker shutdown"` instead of `PENDING`. If you catch
that exception and then poll `get_task_status`, you will see `CANCELLED` where you used to see
`PENDING`; treat it as "not accepted, resubmit", which is what `PENDING`-forever meant in practice.

**This narrows #176's `drain_timeout=0` claim.** That entry said `0` restores the pre-#176
behaviour byte-for-byte. It still does for in-flight runs — no token, no wait, every handle
dropped — but the backlog is abandoned regardless, because `0` means *do not wait* and abandoning a
backlog costs no wait. There is no setting that restores "execute the backlog during teardown".

Internal, but visible if you reach past the public API: `QueueItem` gains a `run_id` field and
`_register_or_watch!` returns `Union{Nothing, UUID}` instead of `Bool`. The abandon write is a
terminal write, and workers §6 requires those to be addressed to a *run*, not a task id — a queued
item can outlive the run that queued it, and cancelling by key would cancel a successor.

### How to find the calls to migrate

```bash
# Every sequential submission — these are the tasks whose teardown behaviour changed.
grep -rn "submit_sequential_task" --include=*.jl .

# Anything that stops a runtime, i.e. decides when that backlog gets discarded.
grep -rn "worker_startup\|uninstall!\|reset_runtime!\|shutdown!" --include=*.jl .

# If you construct QueueItem or call _register_or_watch! directly (neither is public API).
grep -rn "QueueItem(\|_register_or_watch!" --include=*.jl .
```

### Before → after

```julia
# BEFORE — on server stop, anything still queued on "reports" ran anyway, unsupervised:
# no cancellation token, nothing waiting for it, RUNNING rows nobody reaped.
serve(middleware=[worker_startup(queues=["reports"])])

# AFTER (same call) — those tasks are recorded CANCELLED / "Cancelled by worker shutdown"
# and never start. Nothing to change unless you depended on them running.
serve(middleware=[worker_startup(queues=["reports"])])
```

```julia
# If queued work must survive a restart, resubmit it on startup. The abandoned records are
# terminal, so re-submitting under the same key builds a fresh run rather than joining a ghost.
for job in pending_jobs_from_your_own_table()
    submit_sequential_task("reports", job.key, () -> run_report(job), Owner(job.user_id))
end
```
