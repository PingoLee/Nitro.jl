# Workers: an opt-in out-of-process consumer

Design record for [#514](https://github.com/PingoLee/Nitro.jl/issues/514): running a Workers queue
in a **separate process**, for CPU, GC, memory and fault isolation, as an option and never the
default. **Status: decided.** §10 records the maintainer's decisions (2026-10-14); implementation
follows the plan in §9, one PR per step. **Step 1 (the store contract) is implemented**; §11
records where it departs from §3. **Step 2 (named jobs, in-process) is implemented**; §12 records
where it departs from §2. **Step 3 lands in two parts**: 3a, the web side of `External(…)`, is
implemented, and §13 records where it departs from §5; 3b, `consume!`, is implemented, and §14
records where it departs from §6–§7, with the measurements. Nothing here changes an app that does not
opt in. It builds
on #513's queue concurrency, `submit_queued_task` and `checkpoint!`
([PR #523](https://github.com/PingoLee/Nitro.jl/pull/523)), and uses their names.

> **TL;DR.** [#513](https://github.com/PingoLee/Nitro.jl/issues/513) bounds CPU-bound jobs *inside*
> the web process (a queue's concurrency `k`, and `checkpoint!`). It cannot isolate garbage
> collection, memory or crashes; only a process boundary can. The design: a queue's *placement*
> becomes configuration (`"heavy" => External(on_lease_expiry = :requeue)`), and a separate
> `Workers.consume!(app; queues = ["heavy" => 4])` process claims its runs from the shared store
> under a **lease**. That needs three things Nitro does not have yet, in this order: a
> claim/lease/requeue contract on the store (§3), **named jobs with serializable arguments** (§2),
> and the consumer itself (§5–§7). Delivery on an external queue becomes **at-least-once** (§4),
> which is the main semantic cost, so every external queue must say explicitly what a lost lease
> does. A one-shot, process-per-run mode for rare heavy jobs falls out of the same pieces (§7).

## 1. What #513 leaves on the table

| failure in a job | in-process, bounded by #513 | external consumer |
|---|---|---|
| a Julia exception | caught; `FAILED`; server unaffected | the same, in the consumer |
| CPU saturation | handlers share the threads, at most `k` of them | **handlers unaffected** |
| GC pauses from heavy allocation | stop-the-world stops handlers too | **handlers unaffected** |
| `OutOfMemoryError`, segfault, a C library abort, `exit()` | **the server dies** | **only the consumer dies**; its lease expires and the run is re-claimed or failed (§4) |
| a heap that grows to a heavy run's peak and stays there | in the **web** process's RSS | in the consumer's, which can be recycled (§7) |

The CPU row is what [#512](https://github.com/PingoLee/Nitro.jl/pull/512) measured: an unbounded
64-job burst put `/health` at a p99 of about 4 seconds, in every thread layout. #513's bound brings
that to about 10 ms ([PR #523](https://github.com/PingoLee/Nitro.jl/pull/523)), but only for the
CPU; the next three rows need a process boundary.

What it does **not** isolate: the store. A job that overloads the database, or holds locks there,
still reaches the web process through it, and the consumer adds claim and heartbeat traffic. Measure
store load as part of the work (§9).

Each consumer process pays Nitro's memory floor (about 450 MiB), which is why this can never be the
default.

## 2. Named jobs with serializable arguments

Today `submit_task` and `submit_queued_task` take a **closure**. A closure cannot cross a process
boundary, so an external queue needs a job that both processes can name and load from the app's own
code, plus arguments the store can persist.

A job is registered by name on the app, with a typed argument struct, and submitted by name:

```julia
@kwdef struct FitArgs
    dataset_id::Int
    epochs::Int = 10
end

function setup_workers!(app)            # called by BOTH processes, see §5
    declare_queues!(app, ["email", "heavy" => External(on_lease_expiry = :requeue)])
    register_job!(app, "fit_model", FitArgs) do task_info, args::FitArgs
        fit(args.dataset_id; epochs = args.epochs, on_batch = () -> checkpoint!(task_info))
    end
end

submit_queued_task(app, "heavy", "fit-42", Job("fit_model", FitArgs(dataset_id = 42)), Owner(uid))
```

- **Arguments are JSON, bound to a declared type.** They are serialized with the store's existing
  JSON path (and its depth limit, #344) and parsed back with JSON.jl into the registered type, the
  same typed-binding tradition as `Json{T}`. A value that does not round-trip is refused **at submit
  time**, not when the consumer reads it.
- **Argument types evolve additively only.** During a rolling deploy, a job queued by the old version
  of the app is run by the new one, so the new type must still bind the old JSON: add fields with
  defaults (`@kwdef`, as above), and never rename, remove or retype one. The docs state this rule
  next to `register_job!`.
- **Arguments that do not bind are recorded `FAILED`, never re-queued.** The error names the job and
  the argument type, so the operator can see which deploy broke the contract. Re-queueing would only
  fail again on every consumer running the same code.
- **Named jobs work in-process too**, on any queue. This is the property the design is after: once a
  job is named, moving its queue between in-process and external is configuration only (subject to
  the switch procedure in §5), with no change to the job or the submit call. Closures stay supported
  in-process, for work that will never need isolation; the docs recommend the named form for
  anything that might.
- **An external queue refuses a closure at submit time**, with an error naming the queue and saying to
  register the job. It must never become a run nobody can execute.
- **The registry is per app**, not process-global, following #31: two `App`s in one process do not
  share job names. **Registration is a call the app makes at startup, never a module-body side
  effect**: `register_job!` writes app state, so the "no runtime side effects in module bodies" rule
  applies to it as to everything else. Both processes call the same setup function (§5).
- **A name the consumer does not know** (an old consumer during a rolling deploy) is recorded `FAILED`
  with an error naming the job. It is not re-queued, for the same reason as an argument that does not
  bind: re-queueing would loop until a new consumer arrives, which the supervisor, not the queue, is
  responsible for.

## 3. The store contract: claim, lease, renew, requeue

`AbstractWorkerStore` is data access only (#167), and that stays true: every addition below is an
atomic intent operation in the store, and everything that *runs* stays on a runtime.

**What already exists, and what it covers.** `try_transition!` is a `run_id`-fenced compare-and-set
in one SQL statement: its `WHERE` holds both the `run_id` and the `from` statuses, so a stale run's
terminal write after a re-claim or a requeue (each under a fresh `run_id`) changes nothing. Claiming
a *known* row is therefore already atomic across processes. What is missing is choosing *which* row,
holding it for a bounded time, and taking it back.

| Method | Contract |
|---|---|
| `claim_next!(store, queue_name, consumer_id; lease_seconds)` | Atomically pick the oldest `PENDING` row of `queue_name` **that was submitted as external** (`external = true`), move it to `RUNNING` with a **fresh** `run_id`, `claimed_by = consumer_id`, `lease_expires_at = now + lease` and `attempt + 1`, and return it; `nothing` if there is none |
| `renew_leases!(store, consumer_id, runs, lease_seconds)` | `runs` is `(run_id, progress)` pairs. Push `lease_expires_at` forward and write `progress` for each, **fenced on `run_id` and on `status = RUNNING`**; return the run ids that matched. A run missing from the answer is no longer this consumer's to run (§6 says how it finds out why) |
| `release_claim!(store, task_id, run_id)` | Hand a claim back: `RUNNING` → `PENDING` with a fresh `run_id` and `claimed_by` cleared, fenced on `run_id`. `attempt` is **not** charged back, so a run a consumer gives up on voluntarily still counts toward `max_attempts` |
| `requeue_expired!(store, now; policies)` | For every `RUNNING` row whose lease expired: back to `PENDING` with a fresh `run_id` and `claimed_by` cleared, or `FAILED`, per its queue's policy and attempt bound. A row whose queue has **no** known policy (the queue is no longer declared anywhere) is `FAILED` with an error saying so: fail-closed, never stranded |

- **PostgreSQL:** `claim_next!` is `UPDATE … WHERE id = (SELECT id … WHERE queue_name = $1 AND
  external AND status = 'PENDING' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING …`,
  River's model. `SKIP LOCKED` is what lets several consumers claim concurrently without queueing on
  one row.
- **SQLite:** writers are serialized, so the same `UPDATE … RETURNING` without `SKIP LOCKED` is
  already exclusive. It is correct and slower, which is fine for SQLite's use.
- **`requeue_expired!` is conditional per row, not "one statement per policy".** It needs a fresh
  `run_id` per row (SQLite has no UUID generator, so the store mints them in Julia) and two outcomes
  under `:requeue` (below the attempt bound, and at it). It runs as a transaction over the expired
  rows, and each row's write repeats the expiry in its `WHERE` (`status = 'RUNNING' AND
  lease_expires_at < now AND run_id = <read>`). A consumer renewing at the same moment then either
  renews first, and the requeue skips the row, or loses its fence, and the requeue wins. Never both,
  under PostgreSQL's re-check of a statement's own `WHERE` after a lock wait (the property #379 relies
  on). Renew deliberately does **not** fence on `lease_expires_at >= now`: a late renew of a lease
  nobody has taken yet is harmless, and is exactly what a GC pause produces (§6).
- **The SQL lives only in `ext/NitroPormGExt.jl`** (workers §6). A backend that does not implement
  these methods does not support external queues, and says so at start (§5).
- **New columns:** `external`, `job_name`, `job_args`, `claimed_by`, `lease_expires_at`, `attempt`,
  and `cancel_reason`, which `cancel_task` writes in the same statement as `CANCELLED` so a consumer
  can read back *why* (§6). They are added the way `run_id` was (#366): probe, then `ALTER`, never a
  destructive migration.
- **`run_id` gets new writers, so its invariant changes.** Today the store contract says `run_id` is
  written only by `replace_task!` (`registry.jl`, `types.jl`). `claim_next!`, `release_claim!` and
  `requeue_expired!` now mint one too, each as part of the same fenced statement. The first PR updates
  that invariant where it is stated.
- **A fresh `run_id` per claim** is what fences a consumer that was presumed dead but was only
  partitioned. When its lease is taken back, every write it makes afterwards fails its `run_id` CAS,
  exactly the #108 defect class, already closed.
- **`cancel_task` must retry across a claim.** Today it reads the record, then CASes on the `run_id`
  it read. A cancel that reads a `PENDING` row and loses its CAS to `claim_next!` (which minted a new
  `run_id`) reports *"Task was re-submitted; the run you asked to cancel has already ended"*, which is
  wrong, and the cancel is lost. The fix: when the CAS fails and the record still has the **same
  `created_at`**, the key was claimed, re-claimed or re-queued rather than replaced, so re-read and
  retry. A re-submit mints a new `created_at` (`replace_task!`), and that case keeps today's answer.
  Because ownership of the key has not changed, the #108 authorization concern does not apply to the
  retry.

**Who runs `requeue_expired!`.** Every consumer, on each heartbeat tick **and once before its first
claim**, so a one-shot consumer that finds nothing to do still adjudicates its crashed predecessor's
row. And the web process's retention tick, as the fallback for a queue whose last consumer is gone.
The tick adjudicates only the queues its own runtime declares external (`on_unknown_queue = :skip`,
decided on #603 and recorded in §13); a consumer keeps the fail-closed rule. That tick is coarse (it needs `cleanup_enabled`, and defaults to 24 hours), so the docs say a
deployment relying on it should shorten `cleanup_interval_hours`. It is a store CAS, so it is safe
from any process and idempotent across all of them.

**The zombie sweep and leased rows, in both directions.** `recover_zombie_tasks!` marks `RUNNING`
rows with no handle *in this process* as `FAILED`, and `start!` runs it unbounded by default
(`recover_zombies = true`, `zombie_min_age = nothing`).
- **In the web process**, it would fail every run a consumer is executing. Liveness for a leased row
  is the lease, not a local handle, so the sweep skips rows with a `claimed_by`, and
  `requeue_expired!` is the only thing that adjudicates them.
- **In a consumer**, it would fail every *in-process* run the web is executing: those rows have no
  `claimed_by` and no handle in the consumer. So `consume!` never runs the unleased sweep. It is
  forced off, not a keyword, because every external deployment is multi-process by construction, and
  one-shot mode would otherwise fail the web's live jobs on every launch.

Both halves are a hard requirement (§9): the web half of the **first** PR, the consumer half of the
PR that adds `consume!`.

## 4. Delivery semantics: at-least-once

A consumer that dies mid-run leaves a claim whose lease expires, and another consumer runs it again.
Jobs on an external queue must therefore be **idempotent**, and the docs must say so plainly, next to
the queue declaration and not only in a reference section. This is the price of isolation and the
main semantic difference from the in-process mode.

- **What a lost lease does has no default; every external queue declares it.** `External()` takes
  `on_lease_expiry = :requeue` or `on_lease_expiry = :fail`, and omitting it is an `ArgumentError` at
  `start!`/`worker_startup`/`consume!`. The right answer depends on whether the job is idempotent,
  which only the app knows, and a default of `:requeue` would let an email or a charge repeat
  silently. It is the fail-closed posture #515 took for denial responses, and the one #519 asks of
  guard results.
- **`:requeue`** puts the run back to `PENDING` under a fresh `run_id`, until it has been claimed
  `max_attempts` times (default `3`). Past that, the run is `FAILED` with an error saying so, which is
  the dead-letter state #19's vocabulary needs. A separate dead-letter table is not proposed.
  **`:fail`** records `FAILED` on the first expiry, and `max_attempts` does not apply.
- **A run handed back on purpose is not an expiry.** A drain or a lost lease returns the claim with
  `release_claim!` (§7), whatever the policy: nothing failed, and a `:fail` queue would otherwise lose
  every run in flight at each deploy. `attempt` is still charged, so a job that keeps being handed
  back still reaches its bound.
- **Uniqueness is already the task id.** A `:user`- or `:global`-scoped key already deduplicates a
  submit onto a live run (#19), across processes, because the check is the store's.
- **Ordering:** an external queue's items start in submit order per claim, but a re-queued item goes
  back to its original position (`ORDER BY created_at`) and can overtake later items. An external
  queue with `k = 1` is therefore not a strict FIFO across a consumer crash, and the docs say so.

## 5. Placement is configuration, and impossible configurations fail at start

**Both processes run the same setup function.** The queue declarations and the job registrations
live in an app function (`setup_workers!` in §2) that the web process calls before `serve` and the
consumer calls before `consume!`. Today `worker_startup(app; queues)` declares queues inside the
`serve` middleware, which a consumer never builds; so for external queues the declaration moves to
`declare_queues!`, and `worker_startup` / `consume!` read the app's declarations rather than taking
their own. That is what makes *"the two processes cannot disagree"* true rather than hoped for.

```julia
# web process
setup_workers!(app)
serve(app; middleware = [worker_startup(app; store)])

# consumer process, started with `julia -t 4,2` (§14, #636): the same app code, without serve()
setup_workers!(app)
Workers.consume!(app; store, queues = ["heavy" => 4])    # 4 = this process's concurrency (#513's k)
```

- **Placement and concurrency are different settings.** The declaration says *where* a queue runs
  (`"compute" => 6` in-process, or `External(…)`). A consumer's `k` says *how many of its runs this
  process executes*; it is a `consume!` argument, not a re-declaration, so #523's rule that a name is
  declared once with one setting is untouched. Two consumers with `k = 4` run eight.
- **The web process mints no processors for an external queue**, and an external name is never
  "undeclared": `allow_undeclared_queues` does not apply to it.
- **Rows record their placement.** A submit to an external queue writes `external = true`, and
  `claim_next!` claims only those, so a consumer can never take a row the web queued in-process under
  the same name (and holds in a channel).
- **Switching a queue's placement is a deploy step, not only a config edit.** In-process → external:
  the switch is a restart, and the old web process's teardown **cancels** the runs still buffered in
  its channel (`"Cancelled by worker shutdown"`), as every teardown does; runs already executing get
  the drain timeout. They never become external rows, so drain the queue first if they matter. New
  submits go external. (Corrected in §13: this bullet first said the buffered rows stay and run.)
  External → in-process: stop the consumers once the queue is empty. Rows still `PENDING` with
  `external = true` are reported by the web's `start!` (`@warn` with the count) and stay claimable by
  any consumer still running. The docs give both procedures.
- **Admission is bounded through the store.** An external submit has no local channel and no local
  run to release a reservation, so #523's `:queue` slot and the runtime's owner counter do not apply.
  In their place, `External(…; max_pending = 100)` refuses a submit (`WorkerCapacityError(:queue, …)`,
  a `503`) when the store counts that many `PENDING` external rows for the queue, and
  `max_runs_per_owner` is counted in the store for external queues. Both are counts read before an
  insert, so under concurrent submits they are approximate by a few rows. The docs say so: they bound
  the backlog against runaway callers (the #324 class); they are not exact quotas. A consumer applies
  no owner limit at claim time: the submit side already bounded the owner, and a claim-time limit
  would let one owner's backlog stall the queue for everyone behind it.

Refused at `start!`/`worker_startup`/`consume!`, never later:

- `External()` with no `on_lease_expiry` (§4).
- `External()` on a store that cannot claim: `InMemoryWorkerStore` is invisible to every other
  process, so a run submitted there would never happen.
- `consume!` with no queues, or with a queue the app does not declare `External(…)`.
- `consume!` in a process with no interactive thread (§6).
- An external queue with a closure submitted to it (at submit time, §2).

## 6. Heartbeat, cancellation and progress

- **The heartbeat is per consumer process, not per run.** One task renews every lease the process
  holds in one `renew_leases!` call per tick, at a third of the lease. A per-run heartbeat inside
  `checkpoint!` would let a job that never calls it lose its lease while healthy, which is the failure
  a heartbeat exists to prevent.
- **The heartbeat runs on the interactive thread.** A CPU-bound job holds a `:default` thread without
  yielding (#467), so a heartbeat on `:default` can be starved by the very jobs it reports on. This
  is the one place Nitro puts its own work on the interactive thread on purpose; it is a cheap
  periodic store write, not a handler. **`consume!` refuses to start** (`ArgumentError`) when
  `Threads.nthreads(:interactive) == 0`, and the error says to start the consumer with `-t k,1`.
  This is an exception to `concurrency.instructions.md` §3 (background tasks spawn on `:default`),
  and the PR that adds it amends that rule file with the maintainer's agreement.
  *Superseded by §14 ([#636](https://github.com/PingoLee/Nitro.jl/issues/636)): the refusal is
  now below two interactive threads (`-t k,2`), and the heartbeat is pinned off thread 1.*
- **Under `-t k,1`, thread 1 is the interactive thread**, so a SIGINT can land in the heartbeat
  (`deployment.md` says thread 1 runs none of Nitro's loops; that changes for a consumer). The
  heartbeat treats an `InterruptException` as a stop request: it starts the drain (§7) and keeps
  renewing until the drain ends, with one `@warn`, never a crash. *Under §14's `-t k,2` layout,
  thread 1 runs only the main task parked in `consume!`, so a SIGINT lands there and drains.*
- **The lease must outlast the worst stop-the-world GC pause.** A collection stops the interactive
  thread too, so a pause longer than the lease's unrenewed remainder lets `requeue_expired!` take a
  healthy run. The lease is configurable, `consume!(…; lease = Second(60))` by default, and the
  docs state that rule next to it, with the heartbeat lateness measured in §9 as the evidence for the
  default.
- **When a renew does not match, the heartbeat reads why.** A run missing from `renew_leases!`'s
  answer is no longer this consumer's, and job code must be able to tell *"I was cancelled"* (clean up
  and stop) from *"I lost my lease"* (stop, and assume the run will happen again). So the heartbeat
  reads the stored record and sets that run's in-process token by what it finds:

  | stored record | reason set on the run's token | what the job should do |
  |---|---|---|
  | `CANCELLED` | **the cancel's own reason**, e.g. `:user`, read from `cancel_reason` | clean up and stop |
  | another `run_id`, **same** `created_at` (re-queued, or re-claimed) | `:lease_lost` | stop, and assume the run will happen again |
  | another `run_id`, **new** `created_at` (the key was re-submitted) | `:superseded` | stop; a new run owns the key |
  | gone (released or pruned) | `:superseded` | stop; nothing of this run is wanted any more |
  | another terminal status under another `run_id` | `:superseded` | stop |

  `:lease_lost` joins `CANCEL_REASONS` and is never used for a cancel a person asked for. A cancel
  followed within one tick by a re-submit or a `release_task!` reads as `:superseded`, not `:user`;
  both mean "stop, this run is not wanted", which is what the job needs to know. `checkpoint!` throws
  on any of them, exactly as it does in-process; no per-call store read is added to it, so its cost
  stays #513's measurement.
- **Progress is persisted by the heartbeat**, in the renew statement (`renew_leases!` takes it).
  `update_progress!` writes only the in-process object today, so without this a web reader would see
  no progress until the terminal write.
- **Status, watchers and cancel** already go through the store, so the web side's task API is
  unchanged, apart from `cancel_task`'s retry (§3).

## 7. Lifecycle, recycling, and one-shot runs

**A consumer gives work back; it does not cancel it.** In-process, a drain sets `:shutdown` and a run
that unwinds on it is recorded `CANCELLED` (PR #523). A consumer must not do that: the run is still
wanted, and the next consumer should run it. So on a consumer, a run that ends on `:shutdown` or
`:lease_lost` (whether through `checkpoint!` or a callback that polls `cancel_requested` and returns)
hands its claim back with `release_claim!` instead of recording a terminal state, and its return value
is discarded. A `:lease_lost` run's `release_claim!` simply loses its fence, since the claim is
already gone. Only a cancel a person or a deadline asked for is terminal.

- **Stopping.** Nitro has no SIGTERM handler today; `serve` drains on Ctrl-C and on `terminate`. The
  PR that adds `consume!` decides how a supervisor's stop request reaches it (an explicit handler, or
  `SIGINT` delivered as `InterruptException`) and tests it. Either way the stop runs the drain: stop
  claiming, set every held run's token to `:shutdown`, keep the heartbeat renewing until the drain
  ends, wait up to the drain timeout, then exit. Runs that unwound were handed back; a run still going
  at exit keeps its lease until it expires, and is then adjudicated by its queue's policy (§4). The
  drain follows `concurrency.instructions.md` §3–§4: every start has a stop on every path (#427), and
  shutdown code never throws.
- **Recycling is not a drain.** A process's RSS rises to a heavy run's peak and stays there until a
  full collection runs, which an idle consumer, allocating little, may not trigger for a long time
  (measured in §15), and the established
  fix is to recycle: `consume!(…; max_runs = 500, max_rss_mb = 2048)`. Past
  either bound it **stops claiming and waits for the runs it holds to finish**, with no cancellation
  token and no timeout, then exits, and the supervisor restarts it. Reusing the drain here would set
  `:shutdown` on healthy runs and abandon them after the drain timeout, every time. The cost is the
  restart's compile time; a sysimage helps (`deployment.md`).
- **One-shot mode for rare heavy jobs.** A few very heavy jobs a day should not keep a 450 MiB
  process alive for 24 hours. That is `consume!(…; max_runs = 1, exit_when_idle = true)`: run
  `requeue_expired!`, claim one, run it to completion (`max_runs` is a recycle, so it waits), and
  exit. `exit_when_idle` means *nothing claimable **and** nothing held*, so it never exits under a
  running job.

**The launcher is an external scheduler** (decided, §10). Heavy jobs in this case run on a fixed
schedule, which a scheduler already expresses. The documented examples are a **systemd timer** unit
and a **Kubernetes `CronJob`**, each starting the one-shot consumer shortly after the job's submit
time; a note covers **KEDA** for scaling a consumer from zero on queue depth, where a cluster runs
it. That needs nothing from Nitro but `exit_when_idle`, and keeps the supervisor owning processes,
which is this design's premise.

| launcher | for | against |
|---|---|---|
| **an external scheduler** (decided): a systemd timer, a Kubernetes `CronJob`; KEDA as an option | fully decoupled; the supervisor owns processes | infrastructure outside Nitro; fits schedule- or depth-driven launches only |
| the web process spawns a one-shot `julia` per enqueue | one deployment, no extra infrastructure | couples launch to the web process, the coupling §8 rejects for long-lived workers. **Deferred**: it needs a defined restart story and a bound on live children, and becomes a separate decision only if a user-triggered heavy job needs it |
| a long-running consumer with `max_runs = 1` under a restarting supervisor | simplest | the restarted process idles at the floor until the next run, which defeats the point |

## 8. Not this design

- **Workers spawned by the web process** (`Distributed`, Malt). It looks simpler, one command to
  deploy, but it ties the workers' lifecycle to the server's (if the server dies, they die),
  complicates code loading, and pulls toward the cluster model Nitro deliberately does not have.
  Separate services under one supervisor also **scale independently**: more consumers or a larger
  `k` for a backlog, more web capacity for traffic.
- **A message broker** (Redis streams, RabbitMQ). The task table already is the queue, and
  `SKIP LOCKED` makes it a correct one; River and Oban run production queues on exactly this. A
  Redis *store* (#9) is a second claim/lease backend, not a different design.

## 9. Plan

Each step is its own PR, landable and useful alone:

1. **Store contract** (§3): the columns, `claim_next!`, `renew_leases!`, `release_claim!`,
   `requeue_expired!` (with its fail-closed rule for unknown queues), their `NitroPormGExt`
   implementations, the updated `run_id` invariant, `cancel_task`'s retry across a claim, and
   conformance tests on SQLite plus the real-Postgres job (#407). **Hard requirement of this PR: the
   web's zombie sweep skips leased rows.** Without it, the first consumer PR marks its own runs
   `FAILED`.
2. **Named jobs** (§2), in-process first, with no external queue yet: `declare_queues!`, the
   registry, typed binding, the additive-evolution rule, and a test that a job queued under an older
   argument type still binds after a field with a default is added. This is useful on its own and is
   what makes the switch later a configuration change.
3. **`External(…)` and `consume!`** (§5–§7): placement on the row, store-counted admission, the
   start-time refusals, the heartbeat and its reason mapping, hand-back on drain, the stop mechanism,
   and the `concurrency.instructions.md` amendment. **Hard requirement of this PR: `consume!` never
   runs the unleased zombie sweep.** An end-to-end test with two processes sharing a PormG store
   covers: a consumer killed mid-run, its lease expiring, the run re-claimed or failed per its
   declared policy; a drained consumer handing a `checkpoint!`ing run back rather than cancelling it;
   a user cancel reaching the consumer as `:user` and a stolen lease as `:lease_lost`; a consumer
   starting while the web runs in-process jobs, which must stay untouched; and the web process
   unaffected throughout. **Measure the heartbeat's lateness under a heavily allocating job**, which is
   the evidence for the default lease (§6).
4. **Recycling and one-shot** (§7), with RSS measured before, during and after a heavy run on the
   Julia versions CI covers, and the systemd timer and `CronJob` examples run once against it.
5. **Docs**: deployment (two services, one supervisor, the shared setup function, the placement
   switch procedure), idempotency and the `on_lease_expiry` choice, the fault-isolation table, and
   store-load numbers from step 3's test.

Additive throughout: an app that never uses `External(…)` or named jobs changes nothing, so none of
it needs an `upgrading/` entry. `consume!` is also the natural entry point for #8 (extracting
`NitroWorkers.jl`), so this design feeds that issue's extraction criteria.

## 10. Decisions (recorded 2026-10-14)

1. **Named jobs: accepted.** `register_job!(app, name, ArgsType) do task_info, args … end` with
   JSON-bound typed arguments, available in-process too. Argument types evolve additively only;
   arguments that do not bind are `FAILED` with an error naming the job and the type, never
   re-queued (§2).
2. **Lease-expiry policy: no default.** `External()` must declare `on_lease_expiry = :requeue | :fail`,
   and omitting it is an `ArgumentError` at `start!`, because the choice depends on idempotency and a
   default would let a side effect repeat silently. `max_attempts` stays, default `3` under
   `:requeue` (§4, §5).
3. **Heartbeat on the interactive thread: accepted**, with `consume!` refusing to start without one,
   and a configurable lease that must exceed the worst stop-the-world GC pause, measured in §9 (§6).
4. **`:lease_lost`: accepted, and never used for a user cancel.** A run whose renew fails takes the
   stored cancel's own reason when the record is `CANCELLED`, and `:lease_lost` only when the same
   submission was re-queued or re-claimed (§6).
5. **One-shot launcher: external scheduler first** (a systemd timer and a Kubernetes `CronJob`
   documented, KEDA as an optional note). The web-spawned launcher is deferred (§7).
6. **The zombie sweep skips leased rows: accepted**, as a hard requirement of the first
   implementation PR (§3, §9).

## 11. Implementation notes: step 1, the store contract (2026-10-15)

Step 1 shipped the four claim operations on both stores, the zombie sweep's skip of leased rows,
and `cancel_task`'s retry across a claim. Where it departs from §3, it is because the code showed
a simpler or safer shape, and each change was agreed with the maintainer before it landed:

- **No `cancel_reason` column.** A `CANCELLED` record's `error` is rendered only by
  `_cancel_message(reason)` (the error redactor reaches only `FAILED` text), so the reason inverts
  exactly from the stored text: `_cancel_reason_from_error`. A column would have needed a new
  keyword on `try_transition!`, a required store method, and would have broken every custom store.
  §6's heartbeat reads the reason through that function.
- **The claim operations are an optional capability**, `CLAIM_STORE_INTERFACE`, checked by
  `missing_claim_methods`, not rows of the required contract. Existing custom stores keep
  conforming. Both shipped stores implement them, behind one conformance body. Refusing
  `InMemoryWorkerStore` for `External(…)` (§5) is a separate check that step 3 adds: it is about
  whether other processes can see the store, not about a missing method.
- **`claim_next!` is an ORM read plus a fenced `UPDATE`, in one transaction**, not one
  `UPDATE … RETURNING`. On PostgreSQL the read is `SELECT … FOR UPDATE SKIP LOCKED`
  (`select_for_update(skip_locked = true)`), so the concurrency is the same as River's. Reading a
  raw `RETURNING` row needs `Tables`, which Nitro does not depend on; PormG avoids `RETURNING` on
  SQLite; and the test mock cannot see a raw statement. The claiming write is fenced on the
  `run_id` it read, so a lost race moves on to the next row. A head row that does not decode is
  failed out of the way rather than blocking the queue, but only one per call: a second one means
  the cause is not the rows (a decode regression, say), and failing the whole backlog would be
  irreversible, so the claim throws instead.
- **`renew_leases!` takes `(id, run_id, progress)`**, not `(run_id, progress)`: `run_id` is not
  indexed, so a run is addressed by its primary key and fenced on its run. It also fences on
  `claimed_by`.
- **`requeue_expired!` runs no wrapping transaction.** Each outcome is its own statement, fenced on
  the run it read and on the lease still being expired. A transaction would hold every
  adjudicated row's lock, and on SQLite the database's write lock, until the sweep ended, blocking
  the renewals it races with. It returns `(requeued, failed, unknown_queue, lost_race)`, and a
  requeue also clears `started_at` and resets progress.
- **`cancel_task`'s retry is gated on `external` as well as `created_at`.** `created_at` has
  millisecond resolution, so it alone could mistake a fast re-submit for a claim. Only an external
  submission has runs that are not submissions, so for every record an app writes today the answer
  is exactly the pre-#514 one. Each round restarts from `_visible_record` and re-authorizes; the
  loop is bounded at eight rounds.
- **`job_name` and `job_args` are not added yet.** Nothing writes or reads them before step 2,
  which owns their type and binding. Adding a column is one `_ensure_column!` call.
- **`RunningTaskRef` gained `claimed_by`**, which is how the sweep sees a leased row. That is the
  one change a custom store may have to make, and `upgrading/` records it.

**Checked against real drivers** (PostgreSQL 16 and SQLite, by hand: CI has no PostgreSQL, #407).
- Three consumer processes released at one barrier drained 200 external rows with no duplicate
  and no decoy touched.
- On PostgreSQL the claim skipped a row another transaction held, at once, where the same read
  without `SKIP LOCKED` waited.
- A requeue whose write waited on an uncommitted renew lost its re-checked fence once the renew
  committed.
- On SQLite the same drain was **correct but not fair**: one process took all 200 rows, because
  the write-lock holder re-acquires at once while the others back off in SQLite's busy handler.
  Step 5's docs should say that several consumers on one SQLite file serialize, and that one of
  them may do all the work.

**Left to step 3, which the store cannot enforce.** §4 says a run handed back on purpose "still
reaches its bound", because `attempt` is charged. The store keeps the count, but only
`requeue_expired!` compares it with `max_attempts`; neither `claim_next!` nor `release_claim!`
knows the queue's policy. The consumer must therefore record a run `FAILED` once it reaches the
bound rather than releasing it again, or `release_claim!` must learn the bound. Step 3 also owns:
- wiring `requeue_expired!` into the consumer's heartbeat and the web process's retention tick,
  which needs `External(…)`'s policies. It throws on a read or decode failure, so the caller owns
  the per-tick `try`, the `InterruptException` rule, and the `_janitor` discipline (#190, #266);
- a consumer must **stop and alert, not retry**, when `claim_next!` refuses a second undecodable
  head row: the one-row limit is per call, so a retry loop would still fail the whole backlog, one
  row per call. Today the refusal is a plain `ErrorException`; step 3 should give it a distinct
  exception type so the consumer can match on type, not on message text;
- `created_at` and `queue_name` are submission identity now (`cancel_task`'s retry and the claim
  order read them), but `set_task!` still writes both. Nothing calls `set_task!` in production
  today; a consumer that does must not, or `set_task!` should stop writing them;
- the rule that every web process runs step 1 or later before any consumer starts. An older web
  process's zombie sweep would fail leased rows, and its `replace_task!` would not reset the claim
  columns.

## 12. Implementation notes: step 2, named jobs (2026-10-16)

Step 2 shipped `register_job!`, `Job`, the run-side bind, `JobError`, and the `job_name` and
`job_args` columns, for in-process queues only. Where it departs from §2 and §9, it is because the
code showed a simpler or safer shape, and each change was agreed with the maintainer before it
landed:

- **`declare_queues!` is deferred to step 3.** §9 lists it in step 2, but its purpose is to carry
  `External(…)` placements, which do not exist yet. Shipped alone, it would only be a second way
  to declare in-process queues beside `worker_startup(app; queues)`, with a merge rule to define and
  nothing to use it for. Step 3 adds it together with `External(…)`.
- **An unknown name is refused at submit, not only recorded `FAILED`.** The submitting process
  registers every job it submits (§5: both processes run one setup function), so a name it does
  not know is a typo, and an `ArgumentError` at the call site beats a `FAILED` row. The run-side
  half of §2 is still built: a run resolves its name when it starts, and a name the running
  process does not know is a terminal `JobError`. That is the old-consumer case, and it is tested
  by running a stored `(job_name, job_args)` pair (`_job_run`) against an `App` that lacks the
  name.
- **"Round-trip" means serializes, then binds back to the registered type.** The submit check
  writes the arguments through `_json_for_storage`, the store's JSON path with its #344 depth
  bounds (moved from the PormG extension to `src/utilities/bodyparsers.jl` so Workers shares it),
  and binds the text with `stored_json_bind`, which is the `Json{T}` binder without the request
  field cap. Job arguments are stored data, so both sides parse them with `max_fields = 0`, as
  every stored read does. Under the cap, a job submitted from a handler under a raised
  `serve(max_fields = …)` passed its submit check and then failed its run, which binds outside
  any request at 1000. The check does not compare the bound value with the original: `==` on a
  mutable field, or a `Dict`'s iteration order, would refuse sound values. A lossy-but-bindable value is therefore accepted. The refusal names the type and never
  the value.
- **The registry lives in the App's extension slot (`:workers_jobs`), not on the
  `WorkerRuntime`.** Registration happens before `worker_startup` installs a runtime, and
  `uninstall!` drops the runtime's slot on every `terminate`, while registrations must survive a
  re-serve. The registry is created on first use under the extension lock.
- **Only the App-first submit forms take a `Job`.** A runtime has no registry, so
  `submit_task(key, Job(…), owner; runtime)` is an `ArgumentError` pointing at the App form.
- **The job is encoded after the queue authorizer and the declared-queue check**, not before them.
  A caller the authorizer refuses gets the same `AuthorizationError` as for a closure, and learns
  nothing about the job. The encoding costs nothing until the submit is allowed. It still runs
  before the record is written, so a refused job writes and reserves nothing.
- **`register_job!` refuses more than a duplicate name:** a name longer than 255 characters (the
  PormG column is `VARCHAR(255)`, so PostgreSQL would refuse it at every submit), a type that is
  not a concrete struct, a
  type holding a `Symbol` (Nitro's read style never binds one, #306, so the job could never run),
  and a handler with no `(task_info, args)` method. A re-registration of the same name is refused
  even when it is identical, like a re-declared queue concurrency: one rule, no comparison of
  closures.
- **`JobError` is terminal in both executors**, in the same arm as `TaskTimeoutError` and the
  `is_unrecoverable` three, so `TaskOptions(retry_on_failure = true)` does not retry it. Its
  message names the job and the type and never renders the parse error, which quotes its input.
- **In-process runs bind the queue item's copy, not the row.** The arguments are encoded once at
  submit, and the `NamedJobRun` the item carries holds that text, the same text the row records.
  Re-reading the row would be the fence-from-inside-the-window mistake workers §6 forbids. A
  consumer will build the same `NamedJobRun` from a claimed row, so both placements go through
  one bind.
- **`job_name` and `job_args` are submission identity**, like `external`. `replace_task!` writes
  them, the claim operations carry them (`_successor_run`), and `set_task!` never writes them.
  `get_task_status` does not expose them, because the arguments are application data. On the
  PormG store they are `VARCHAR(255)` and `TEXT`, added on boot with one `_ensure_column!` each.
- **No `upgrading/` entry.** Every change is additive: new exported names, new optional `TaskInfo`
  constructor keywords, and nullable columns. A custom store that does not persist the two fields
  still runs named jobs in-process.

**Left to step 3:**
- an external queue's refusal of a closure at submit (§2);
- building a `NamedJobRun` from a claimed row (`_job_run` is the seam);
- `declare_queues!`;
- the distinct exception type for `claim_next!`'s second undecodable head (§11).

## 13. Implementation notes: step 3a, placement on the web side (2026-10-16)

Step 3 is split in two PRs, agreed with the maintainer: 3a is everything the **web process** does
with an external queue, and 3b is `consume!` (the claim loop, the heartbeat, hand-back and the stop
path) with the two-process test. 3a shipped `External(…)`, `declare_queues!`, external rows,
store-counted admission, the start-time refusals, `requeue_expired!` on the retention tick,
`release_claim!`'s policy, and `ClaimPoisonedError`. Where it departs from §2–§5:

- **`External(…; options = TaskOptions(…))`.** A claimed row carries no `TaskOptions`: the
  `QueueItem` that holds them in-process never crosses to another process, and §3 adds no column
  for them. An external queue's timeout and retry settings are therefore queue configuration, read
  by both processes from the shared declaration, and a submit to an external queue that passes its
  own `options` is an `ArgumentError` pointing at the declaration.
- **`External()` refuses a missing `on_lease_expiry` when it is built**, not first at `start!`:
  earlier than §4 asks, and the same refusal.
- **Declarations live on the App** (extension slot `:workers_queues`), like the job registry, so
  they survive `terminate` and a consumer, which installs no runtime, reads the same ones.
  `worker_startup(app; queues)` and `start!(app; queues)` keep their keyword and merge it with the
  app's declarations under the one-name-one-setting rule. An `External(…)` passed through that
  keyword, or to `WorkerRuntime(store; queues)`, is refused with a pointer to `declare_queues!`, so
  placement has one source. `declare_queues!` on an app with a runtime installed applies to it at
  once.
- **"A store no other process can read" is a trait**, `_visible_across_processes(store)`: `false`
  for `InMemoryWorkerStore`, `true` by default. §11 had kept it separate from the claim capability,
  since `InMemoryWorkerStore` implements every claim method.
- **Admission adds one store read to the claim capability**, `count_external_runs(store, statuses;
  queue_name, submitter)`. `max_pending` counts the queue's `PENDING` external rows;
  `max_runs_per_owner` counts the live external rows the identity **submitted** plus its live runs
  in this process, so one quota covers both placements for an external submit. The submitter is the
  record's first watcher, which needs no new column. Two shapes were rejected in review: the owner
  half of the id, because a `:global` id has none, so `scope = :global` was a way past the quota;
  and "any watcher", because a submit may grant any identity, so one user could fill another's
  quota with grants. An in-process submit still counts only this
  process's runs, which keeps its path free of store reads. The checks run inside
  `_register_or_watch!`, where a run is about to be minted, so joining a live key is never refused
  by them. The count is a plain read, so it is the one claim-capability method called under
  `lock_tasks`.
- **`release_claim!(…; policy)` enforces the attempt bound in the store**, as proposed on #514
  (2026-10-15): at the bound under `:requeue` the run is `FAILED`, under `:fail` a hand-back is
  never failed, because nothing expired. Its error has its own wording ("Handed back … not
  re-queued"), not `_lease_expiry_error`'s "Lease expired", since nothing did; the bound itself is
  one condition. On PormG the write reads the row's attempt under the same fence it then writes
  with, which is sound because every writer of `attempt` also changes `run_id`.
- **`get_queue_status` answers an external queue from the store** (`:external => true`, the pending
  ids and the running count) rather than "Queue not found".
- **Declarations made while a runtime starts are not lost.** `start!` and `startup` merge the
  app's declarations again, under their lock, after the install, so a `declare_queues!` racing the
  start either lands in that merge or finds the runtime installed. Under `allow_undeclared_queues`,
  an undeclared first submit racing an `External(…)` declaration of the same name is refused where
  the queue would be minted, under `queue_lock`, so one name never runs in both places.
- **The web tick adjudicates only its own external queues** (decided by the maintainer on #603,
  2026-10-17). As first written, the web process adjudicated with its runtime's policies and §3's
  fail-closed rule, so an expired lease on an external queue it does not declare was `FAILED` as
  `unknown_queue`. Two apps sharing one store with different external queues, or an old web
  process during a rolling deploy that adds a queue, would then fail the other's crashed
  `:requeue` runs. `requeue_expired!` now takes `on_unknown_queue = :fail | :skip`: the web tick
  passes `:skip`, so it reads only its own queues' rows, and the others are left to the consumers
  that declare them. Consumers keep `:fail`, the default, so a queue no process declares any more
  is still failed closed by the next consumer of the app, never stranded. The cost is that a
  queue with no consumer *and* no web declaration stays `RUNNING` until one exists.
- **`max_pending` defaults to 100** (maintainer, #603), an in-process queue's buffer size, as §5
  first proposed; the first cut had shipped no default. `max_pending = nothing` removes the bound.
- **§5's switch procedure was wrong and is corrected there** (maintainer, #603): switching a queue
  from in-process to external is a restart, and the old web process's teardown cancels the runs
  still buffered in its channel, as every teardown does. They do not stay and run; the tutorial
  already said so.
- **Under `:requeue`, every hand-back counts toward `max_attempts`.** `claim_next!` increments
  `attempt` whatever ended the previous claim, so a run handed back at each deploy drain is
  recorded `FAILED` once it has been claimed `max_attempts` times. The tutorial says so.
- **`set_task!` still writes `created_at` and `queue_name`** (§11). The consumer in 3b writes
  terminal states through `try_transition!`, never `set_task!`, so the item stays open rather than
  changing a shared write path here.

No `upgrading/` entry: `release_claim!`'s new required keyword is on an optional store method that
no release has shipped yet (step 1 is still `Unreleased`), and everything else is additive.

## 14. Implementation notes: step 3b, the consumer (2026-10-16)

Step 3b shipped `consume!` (`src/Workers/consumer.jl`): the claim loop, the lease heartbeat, the
reason mapping, hand-back on drain and on a lost lease, and the stop path. It also shipped the
`concurrency.instructions.md` amendment (the heartbeat's place on `:interactive`) and the
two-process test, which adds SQLite.jl as a test dependency. Where it departs from §6–§7:

- **The stop mechanism is `atexit`, plus the interrupt.** §7 left it open.
  - Probed on Julia 1.12.7 and 1.13.2 with a script parked in `wait`:
    - a `SIGTERM`, and a `SIGINT` outside a REPL, both end the process through `exit`;
    - `exit` runs the `atexit` hooks, and the main task's wait never returns;
    - a hook can still spawn tasks on other threads, and wait on them.
  - So `consume!` registers one `atexit` drain when it is called (never in a module body), and its
    own `finally` drains on a REPL interrupt. The drain runs once, and a second caller waits for it.
  - A supervisor needs nothing special: systemd's and Kubernetes' default `SIGTERM` drains.
  - The probe ran on Linux; macOS CI is the evidence there. On Windows a terminate is a hard kill
    that runs no hook, so a stopped consumer's runs wait for their leases, as after a crash.
  - **The hook runs on top of whatever thread 1 was doing, so thread 1 runs nothing of the
    consumer's** ([#636](https://github.com/PingoLee/Nitro.jl/issues/636)).
    - On `SIGTERM`, Julia's signal thread interrupts thread 1 mid-instruction and runs `exit` in
      the interrupted task's context: `jl_exit_thread0` → `jl_exit_thread0_cb` →
      `jl_atexit_hook` (`src/signals-unix.c`). That task never resumes. This includes a task
      parked in `sleep` or `wait`, which stays thread 1's current task while the thread looks for
      work. Julia's source calls a stuck exit there "unavoidable due to its async nature". The
      answer to it is a second signal, which `raise`s at once.
    - This section first assumed that a heartbeat hijacked this way cost only renewals. Under
      `-t k,1` the interactive thread **is** thread 1, and the hook also inherits what the
      heartbeat holds:
      - **mid-compile:** the drain never started, and the process hung until killed;
      - **inside PormG's SQLite write transaction:** the hand-back waited for the lock until
        `drain_timeout`, and the run was left claimed.
    - So `consume!` requires **`-t k,2`** and pins the heartbeat, and the start-up adjudication, to
      the last interactive thread (`_spawn_pinned`, `jl_set_task_tid`). Thread 1 hosts only the
      parked main task.
    - The heartbeat parks on a plain `Timer`, never a `Timer(cb)`. That callback's task inherits
      the heartbeat's stickiness and sticks to whichever thread first schedules it, which can be
      thread 1.
    - `test/workers_thread1_hijack_tests.jl` shows the mechanism with no consumer at all. A task
      holding a lock across a `sleep` releases it to an `atexit` hook when pinned to thread 2, and
      never does on thread 1.
    - **What is left:** a `SIGTERM` during `consume!`'s own start-up, before the main task parks,
      lands on code that is still compiling, and can hang until the supervisor's kill. Nothing is
      claimed yet, so no run waits on it.
  - A second signal during the drain is bounded: the second drain caller waits at most
    `drain_timeout + 10` seconds.
  - A run that finishes during the drain is handed back too, and so runs again. A consumer cannot
    tell a job that completed from one that saw `:shutdown` and returned early, and recording the
    second as done would lose work (§7). A run the drain reaches before its task starts is handed
    back without running.
  - **A drain that times out in a live process keeps renewing** (maintainer, #607). In a REPL,
    `consume!` returns and the process lives on, so do the runs still going. With the heartbeat
    stopped, their leases expired, and another consumer re-ran them while they still ran here:
    the fence kept the stale copy's writes out, not its side effects. So the heartbeat now runs
    until the last of them returns, renewing them and nothing else: no claim, no `requeue_expired!`.
    They finish under a live lease and hand themselves back. A run that never returns keeps its
    lease for the life of the process. A process that exits is unchanged.
- **The heartbeat renews first and adjudicates second, against a clock read before the renewal.**
  A heartbeat that was itself late does not take back its own leases before renewing them. Reading
  the clock first is the half that order alone did not give
  ([#623](https://github.com/PingoLee/Nitro.jl/issues/623)):
  - a renewal stamps its leases from the time it was called;
  - a slow one returns after the lease it wrote has run out. In the two-process test, a first call
    compiling under CPU load took 2.4 s against a 2 s lease;
  - an adjudication that read the clock again then found the consumer's own runs expired, and
    re-queued or failed them while they were still running.

  Against a reading taken before the renewal, a lease that tick renewed, or a run claimed since,
  cannot be expired yet. Other consumers' expired leases are adjudicated at most one tick later.
  The renewal keeps its own reading, so its lease is as long as it can be. What a renewal slower
  than the lease still risks is **another** process's adjudicator, which can find that lease
  already expired when it is written: the case the rule "the lease must exceed the worst pause"
  covers, and a reason a lease far above the heartbeat's period is the default.
- **A claim in flight bounds that clock too** ([#666](https://github.com/PingoLee/Nitro.jl/issues/666)).
  "A run claimed since cannot be expired yet" held only for a claim that returned at once:
  - `claim_next!` stamps the lease from the time it was called, and its row is `RUNNING` under that
    lease before the claim returns. The first claim of a fresh process compiles its whole path;
  - until the run is in `held`, no heartbeat snapshot has it, so a tick that read its clock past
    that lease took the run back from the very process still claiming it. On a `:fail` queue that
    failed a healthy run. Its two-process signature: the first claim (s1) gone before any tick
    renewed it, `held` one short from the first tick on, no log of either;
  - so the claim loop publishes a clock (`claim_clock`) before it calls the store, then reads the
    clock it stamps the lease from and hands that to the store, so the published one is never
    later. `_start_run!` clears it under the lock it registers the run with; a run given back keeps
    it until the hand-back is done. The tick reads, in order, its own clock, `claim_clock` and its
    snapshot. A run missing from the snapshot was then either in flight at the second read, or its
    claim was published after it, which stamps a lease that cannot be expired at the tick's clock.
    A claim in flight bounds the adjudication to `claim_clock + lease` (less a millisecond), so it
    defers other processes' expired leases only while a claim has outlasted its own lease.

  The issue first suspected #653's heartbeat pin. An in-process store whose claim returns 1.6 s
  after stamping a 1 s lease reproduced the take-back, with no pin and no load, so the
  pinned-against-unpinned latency measurement was not run. The new claim record then caught it
  on the real driver, in an unloaded local run of the two-process test (1.13.2, SQLite): s1's
  first claim took 2.74 s against its 2 s lease, and returned 0.74 s after the lease it had written
  ran out. What a claim slower than the lease still risks is, again, another process's
  adjudicator. Since #666 the child logs, at `@debug`, each claim with its `claim_s` and stamped
  expiry, each renewal that comes after the lease it extends (`late_s`), each held run found no
  longer the consumer's own, with its reason, and each run's end. The e2e test prints every record
  naming a failing scenario's runs from the start of the log, and their marker files.
- **One attempt loop.** `_run_attempts!` (`src/Workers/queue.jl`) is now the loop of the queued
  executor, the async one and the consumer, which differ only in `on_complete` / `on_cancel`. The
  two executors used to carry identical copies. A third copy for the consumer is what this avoided.
- **A consumer's policies are every external queue the app declares**, not only the consumed ones,
  because `requeue_expired!` fails a leased row whose queue it has no policy for. The consumer
  keeps that fail-closed default (`on_unknown_queue = :fail`); only the web tick skips, as decided
  on #603 (§13).
- **An interrupt is recognised however the store wrapped it** (`_is_interrupt`). PormG hands back
  a Ctrl-C that landed inside a query as a `DatabaseError` whose `cause` is the interrupt, and a
  bare `isa` test would log it as a failed heartbeat and lose the stop (found in review).
- **A `ClaimPoisonedError` stops that queue only.** The consumer logs one `@error`, keeps running
  its other queues, and does not exit. Exiting would make a restarting supervisor fail one more
  row per restart, which is the backlog-eating loop the error exists to prevent.
- **Progress** goes to the store with each renewal (`renew_leases!` carries it), as §6 asked. The
  two-process test reads it back from the database.
- **Timeouts are still the queue's**, from `External(…; options)` (§13). A timed-out callback keeps
  its consumer slot until it returns, as in-process (`_RunHandoff`), but stops being renewed once
  its run is recorded.
- **A consumer holds #604's wake guard** (maintainer, #605). On Julia 1.13.0-rc3 through 1.13.x, a
  task parked on a `Timer` does not wake while every `:default` thread runs a `yield()`ing loop,
  as long as its timer is the only live libuv handle in the process
  ([#586](https://github.com/PingoLee/Nitro.jl/issues/586),
  [JuliaLang/julia#63882](https://github.com/JuliaLang/julia/issues/63882)). Both consumer loops
  park on one-shot `Timer`s, and jobs that follow the "`yield()` every few ms" advice are exactly
  those loops; the claim loop's timer is re-armed only from `:default`. Whether a waiter on
  `:interactive` is affected at all was not tested (#586's repro parked on `:default`), so this is
  a cheap precaution, not a measured fix. A consumer never calls `serve`, so it holds its own
  never-firing `Timer(typemax(Int32))` for its lifetime, under the same `_needs_wake_guard()` gate,
  and the drain closes it once both loops are done. One gate means one place to lower when a fixed
  1.13.x ships.
- **Every hand-back costs an attempt** (maintainer, #605). Claiming increments `attempt`, and a
  hand-back keeps it (§4, #603), including the hand-back of a run that completed during the drain
  and of one the drain reached before it started. Under `:requeue` with the default
  `max_attempts = 3`, a long run that lives through three rolling deploys is recorded `FAILED`
  ("Handed back … after 3 attempt(s)") without having failed. The tutorial says so.

**Measured: heartbeat lateness under a heavily allocating job** (`bench/consumer/heartbeat_lateness.jl`;
`-t 4,1`; three jobs that allocate small objects into a ring that keeps a live heap, plus
short-lived garbage; lease 3 s, so a tick every 1 s; 60 s per run):

| Julia | live heap per job | GC pause total / max | renewal gap p50 / p99 / max |
|---|---|---|---|
| 1.12.7 | 256 MiB | 41 s / 0.89 s | 1.20 / 1.55 / 1.55 s |
| 1.12.7 | 1 GiB | 42 s / **11.6 s** | 1.00 / 12.5 / **12.5 s** |
| 1.13.2 | 1 GiB | 43 s / **18.3 s** | 1.27 / 19.3 / **19.3 s** |

- **The worst gap is the worst GC pause plus about one tick**, as §6 predicted. A stop-the-world
  collection stops the interactive thread with everything else.
- A 3 s lease would have lost these healthy runs. The **60 s default** holds the worst measured
  pause, 18 s on 1.13, about three times over.
- A job that keeps several GiB of small live objects can pause longer still. The docs therefore
  state the rule ("the lease must exceed the longest pause your jobs cause") instead of a number.

**Measured: the interactive thread is what keeps a CPU-bound job from starving the heartbeat.**
Four jobs spinning without allocating or yielding, one per `:default` thread:

- **At `-t 4,1`** the heartbeat was at most **17 ms** late.
- **At `-t 4,0`** the heartbeat had no thread to run on: the four jobs held all four, thread 1
  included. It never renewed, and the run had to be killed at 600 s.

That is the evidence for refusing to start without an interactive thread.

**Measured: the interactive thread keeps the heartbeat on time, not the renewal's statement**
(maintainer, #605). The runs above use an in-memory store. Through PormG, a renewal is a database
statement, and where it runs depends on the driver. At the PormG commit Nitro pins (`6f558894`),
SQLite sends every statement to one global worker task started with `Threads.@spawn`, and
Postgres.jl's `backend_execute_async` is a `Threads.@spawn`: both on `:default`. LibPQ's
`async_execute` runs its task with `@async`, on the calling thread, so there the renewal stays on
the interactive thread; that was read in LibPQ's source and not measured. The bench's
`store = sqlite` runs the same consumer over `pormg_nitro_worker()` on a temporary SQLite file.
Spin mode, `-t 4,1`, Julia 1.12.7, lease 3 s (a tick every 1 s), 60 s per run:

| store | spinning jobs | renewals | first renewal | max gap | gaps longer than the lease |
|---|---|---|---|---|---|
| in-memory (the control) | 4 | 59 | 1.17 s | 1.002 s | 0 |
| PormG, SQLite | 4 | **1** | **60.47 s** | — | **1: the whole run** |
| PormG, SQLite | 3 | 60 | 1.18 s | 1.025 s | 0 |

- **With every `:default` thread spinning, nothing renewed for the whole minute.** The heartbeat
  woke on time and then waited for a `:default` thread for its statement; the one renewal landed
  only after the drain had stopped the jobs. Every lease was expired from about 3 s on, so another
  consumer, or the web's retention tick, would have taken back four healthy runs, which then run
  twice.
- **One free `:default` thread is enough**: with three jobs on four threads the SQLite store
  renewed as punctually as the in-memory one.
- **So the guarantee holds with LibPQ only.** The docs recommend LibPQ for consumers, and on SQLite
  or Postgres.jl they say to run fewer jobs than `nthreads(:default)` or to have jobs `yield()`.
  Postgres.jl was not measured; its code path is the same `:default` spawn. The real fix is on the
  PormG side, a driver that runs the statement on the caller's pool, tracked on
  [PormG#1280](https://github.com/PingoLee/PormG.jl/issues/1280).

**Checked against real drivers.** The two-process test (`test/workers_consumer_e2e_tests.jl`)
covers each of these:

- a consumer `SIGKILL`ed mid-run, and its leases re-queued (`:requeue`) or failed (`:fail`) after
  they expired;
- the next consumer running the re-queued run;
- a `SIGTERM` drain handing a `checkpoint!`ing run back;
- a user cancel reaching the job as `:user`, and a lease taken back reaching it as `:lease_lost`;
- the web's in-process run left alone throughout;
- progress persisted;
- the submitter count matching `_`, `%` and `\` in user ids literally.

It runs on SQLite in CI, and was run by hand against PostgreSQL 16, through
`NITRO_E2E_POSTGRES=<libpq conninfo>` and an environment with LibPQ: green on both. Store load
was not measured beyond that; step 5's docs should not quote a number for it yet.

## 15. Implementation notes: step 4, recycling and one-shot (2026-10-19)

Step 4 shipped `consume!(…; max_runs, max_rss_mb, exit_when_idle)` and `consume!`'s return value.
Where it departs from §7, or settles what §7 left open, each choice was agreed with the maintainer:

- **A recycle is its own path, not a flavour of the drain.**
  - Reaching a bound sets `stopping`, so no more claims, and records the bound. No `:shutdown`
    token is set, there is no timeout, and the heartbeat goes on renewing.
  - When the last held run settles, the consumer requests its own stop. `consume!`'s `finally`
    then drains, and that drain finds nothing held. Settled means what `exit_when_idle` means:
    nothing held **and** no slot still taken by a callback a deadline abandoned. That callback is
    recorded `FAILED` and no longer held, but it runs on a thread until it returns, and a recycle
    that exited under it would end the process on top of it, which is the drain's behaviour the
    recycle exists not to have.
  - A stop request during the wait drains what is left, as any stop does.
  - Only a recycle that ran to its end sets the exit reason, so a stop that cut one short returns
    `:stopped`.
- **`consume!` returns why it ended**: `:max_runs`, `:max_rss`, `:idle` or `:stopped`. It used to
  return `nothing`. It has never been released, so this is additive.
- **`max_runs` counts the runs `_start_run!` accepted**, after they are held, so the recycle it
  begins waits for the run that reached it. A run claimed while a recycle begins is handed back,
  exactly as one claimed while a drain begins.
- **`max_rss_mb` compares against `Sys.maxrss()`, the peak** (maintainer). That is Celery's
  `max_memory_per_child` precedent (`ru_maxrss`), and it is portable. Current RSS would need code
  per OS.
  - The peak never goes down. The docstring and the tutorial say so, and the bench below shows the
    consequence: a process whose heap a collection has returned still recycles.
  - The bound is checked when a run settles and before each claim pass.
  - A bound the process is already past at `consume!` is an `ArgumentError`. Otherwise every start
    would end before its first run, and a restarting supervisor would loop.
  - The tests move the reading with `_RSS_OVERRIDE_MB` instead of allocating past the shared test
    process's own peak.
- **`exit_when_idle` is checked by the claim loop**, after a pass in which every queue answered
  "nothing to claim", with nothing held and no slot still taken by a callback a deadline abandoned.
  That loop is the only one that starts runs, so the condition cannot change under it. The
  conditions came out of review:
  - **A claim that throws is not an empty queue.** Otherwise a one-shot that met a store blip at
    its start would exit 0 and leave the run for the next scheduled start.
  - **The idle exit also waits for one successful `requeue_expired!`**, so a crashed
    predecessor's run whose lease has expired is back in its queue first.
  - **A poisoned queue is out of the rotation** and does not keep the consumer from being idle.

**Measured: what a consumer keeps after a heavy run** (`bench/consumer/rss_recycle.jl`, `-t 2,1`,
one run holding 1 GiB of small objects for 5 s, then returning):

| Julia | floor | run returned | 5 s idle | after `GC.gc(true)` | after `malloc_trim(0)` | `Sys.maxrss()` at the end |
|---|---|---|---|---|---|---|
| 1.12.7 | 473 MiB | 2159 | 2160 | **537** | 534 | 2159 |
| 1.13.2 | 406 MiB | 2103 | 2104 | **476** | 476 | 2104 |

- **An idle process keeps the peak.** It allocates too little for a collection to come within the
  5 s measured, and nothing says one comes soon after.
- **A full collection gives back about 96% of the run's growth on both versions.** `malloc_trim`
  adds nothing measurable. §7's "tends to stay there" holds only for the idle case. Heaps with
  live data interleaved with garbage will return less; this bench frees everything at once.
- **So recycling is the guaranteed measure, and an explicit `GC.gc(true)` after a heavy job is
  the cheap one.** The tutorial says both.
- **Against the peak, `max_rss_mb` recycles a process that has already shrunk back.** That is the
  documented price of a portable, monotone signal. If it turns out to recycle too often, the
  alternative is current RSS read per OS.

**Checked once against a real scheduler.**
- The tutorial's `Type=oneshot` service and `.timer` ran as user units, with the timer firing
  every minute, over a SQLite store holding two pending runs. Each firing was its own process, and
  each exited 0:
  - the first two each claimed one run, completed it and returned `:max_runs`;
  - the third found nothing and returned `:idle`, 0.5 s after the consumer started;
  - both rows ended `COMPLETED` at attempt 1, each claimed by a different one-shot process;
  - each firing spent about 11 s loading the app before it claimed. That is the per-run cost §7
    accepts for heavy, rare jobs, and a sysimage lowers it.
- The Kubernetes `CronJob` is written but was **not** run: no cluster was available.
