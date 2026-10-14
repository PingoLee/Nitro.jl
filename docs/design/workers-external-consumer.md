# Workers: an opt-in out-of-process consumer

Design record for [#514](https://github.com/PingoLee/Nitro.jl/issues/514): running a Workers queue
in a **separate process**, for CPU, GC, memory and fault isolation, as an option and never the
default. **Status: proposal.** It needs the maintainer's sign-off before any code; §10 lists the
decisions that sign-off is for. Nothing here changes an app that does not opt in. It builds on
#513's queue concurrency, `submit_queued_task` and `checkpoint!`
([PR #523](https://github.com/PingoLee/Nitro.jl/pull/523)), and uses their names.

> **TL;DR.** [#513](https://github.com/PingoLee/Nitro.jl/issues/513) bounds CPU-bound jobs *inside*
> the web process (a queue's concurrency `k`, and `checkpoint!`). It cannot isolate garbage
> collection, memory or crashes; only a process boundary can. The proposal: a queue's *placement*
> becomes deployment configuration (`"heavy" => External()` in the web process), and a separate
> `Workers.consume!(app; queues = ["heavy" => 4])` process claims its runs from the shared store
> under a **lease**. That needs three things Nitro does not have yet, in this order: a
> claim/lease/requeue contract on the store (§3), **named jobs with serializable arguments** (§2),
> and the consumer itself (§5–§7). Delivery on an external queue becomes **at-least-once** (§4), which
> is the main semantic cost. A one-shot, process-per-run mode for rare heavy jobs falls out of the same
> pieces (§7).

## 1. What #513 leaves on the table

| failure in a job | in-process, bounded by #513 | external consumer |
|---|---|---|
| a Julia exception | caught; `FAILED`; server unaffected | the same, in the consumer |
| CPU saturation | handlers share the threads, at most `k` of them | **handlers unaffected** |
| GC pauses from heavy allocation | stop-the-world stops handlers too | **handlers unaffected** |
| `OutOfMemoryError`, segfault, a C library abort, `exit()` | **the server dies** | **only the consumer dies**; its lease expires and the run is re-claimed or failed (§4) |
| a heap that grows to a heavy run's peak and stays there | in the **web** process's RSS | in the consumer's, which can be recycled (§7) |

What it does **not** isolate: the store. A job that overloads the database, or holds locks there,
still reaches the web process through it, and the consumer adds claim and heartbeat traffic. Measure
store load as part of the work (§9).

Each consumer process pays Nitro's memory floor (about 450 MiB), which is why this can never be the
default.

## 2. Named jobs with serializable arguments

Today `submit_task` and `submit_queued_task` take a **closure**. A closure cannot cross a process
boundary, so an external queue needs a job that both processes can name and load from the app's own
module, plus arguments the store can persist.

**Proposal.** A job is registered by name on the app, with a typed argument struct, and submitted by
name:

```julia
struct FitArgs
    dataset_id::Int
    epochs::Int
end

register_job!(app, "fit_model", FitArgs) do task_info, args::FitArgs
    fit(args.dataset_id; epochs = args.epochs, on_batch = () -> checkpoint!(task_info))
end

submit_queued_task(app, "heavy", "fit-42", Job("fit_model", FitArgs(42, 10)), Owner(uid))
```

- **Arguments are JSON, bound to a declared type.** They are serialized with the store's existing
  JSON path (and its depth limit, #344) and parsed back with JSON.jl into the registered type, the
  same typed-binding tradition as `Json{T}`. A value that does not round-trip is refused **at submit
  time**, not when the consumer reads it.
- **Named jobs work in-process too**, on any queue. This is the property the design is after: once a
  job is named, moving its queue between in-process and external is configuration only, with no
  change to the job or the submit call. Closures stay supported in-process, for work that will never
  need isolation; the docs recommend the named form for anything that might.
- **An external queue refuses a closure at submit time**, with an error naming the queue and saying to
  register the job. It must never become a run nobody can execute.
- **The registry is per app**, not process-global, following #31: two `App`s in one process do not
  share job names. The consumer loads the same app module without `serve()`, so it builds the same
  registry.
- **A name the consumer does not know** (an old consumer during a rolling deploy) is recorded `FAILED`
  with an error naming the job. It is not re-queued, because re-queueing would loop until a new
  consumer arrives, which the supervisor, not the queue, is responsible for.

## 3. The store contract: claim, lease, renew, requeue

`AbstractWorkerStore` is data access only (#167), and that stays true: every addition below is an
atomic intent operation in the store, and everything that *runs* stays on a runtime.

**What already exists, and what it covers.** `try_transition!` is a `run_id`-fenced compare-and-set
in one SQL statement. Claiming a *known* row is therefore already atomic across processes. What is
missing is choosing *which* row, holding it for a bounded time, and taking it back.

| Method | Contract |
|---|---|
| `claim_next!(store, queue_name, consumer_id; lease_seconds)` | Atomically pick the oldest `PENDING` row of `queue_name`, move it to `RUNNING` with a **fresh** `run_id`, `claimed_by = consumer_id` and `lease_expires_at = now + lease`, and return it; `nothing` if there is none |
| `renew_leases!(store, consumer_id, run_ids, lease_seconds)` | Push `lease_expires_at` forward for the listed runs **fenced on `run_id`**; return the ones that matched. A run missing from the answer has lost its lease and must stop |
| `requeue_expired!(store, now; policy)` | For every `RUNNING` row whose lease expired: either back to `PENDING` with a fresh `run_id` and `attempt + 1`, or `FAILED`, per the queue's policy and its attempt bound |

- **PostgreSQL:** `claim_next!` is `UPDATE … WHERE id = (SELECT id … WHERE queue_name = $1 AND
  status = 'PENDING' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING …`, River's model.
  `SKIP LOCKED` is what lets several consumers claim concurrently without queueing on one row.
- **SQLite:** writers are serialized, so the same `UPDATE … RETURNING` without `SKIP LOCKED` is
  already exclusive. It is correct and slower, which is fine for SQLite's use.
- **The SQL lives only in `ext/NitroPormGExt.jl`** (workers §6). A backend that does not implement
  these methods does not support external queues, and says so at start (§5).
- **New columns:** `job_name`, `job_args`, `claimed_by`, `lease_expires_at`, `attempt`. They are
  added the way `run_id` was (#366): probe, then `ALTER`, never a destructive migration.
- **A fresh `run_id` per claim** is what fences a consumer that was presumed dead but was only
  partitioned. When its lease is taken back, every write it makes afterwards fails its `run_id` CAS,
  exactly the #108 defect class, already closed. `cancel_task` reads the record's current `run_id`
  durably before its own CAS, so it stays correct across re-claims.

**The existing zombie sweep must leave leased rows alone.** Today `recover_zombie_tasks!` marks
`RUNNING` rows with no handle *in this process* as `FAILED`. Run in the web process, it would fail
every run a consumer is executing. Liveness for a leased row is the lease, not a local handle, so the
sweep skips rows with a `claimed_by`, and `requeue_expired!` is the only thing that adjudicates them.
This is a correctness requirement of the first PR, not a later refinement.

## 4. Delivery semantics: at-least-once

A consumer that dies mid-run leaves a claim whose lease expires, and another consumer runs it again.
Jobs on an external queue must therefore be **idempotent**, and the docs must say so plainly, next to
the queue declaration and not only in a reference section. This is the price of isolation and the
main semantic difference from the in-process mode.

- **Re-queue or fail is a per-queue policy.** Re-queue is the right default for idempotent work;
  fail is right for a job whose side effects are not safe to repeat (send an email, charge a card).
  Proposed: `External(; on_lease_expiry = :requeue, max_attempts = 3)`, with `:fail` as the
  alternative. Past `max_attempts` a re-queued run is `FAILED` with an error saying so, which is the
  dead-letter state #19's vocabulary needs. A separate dead-letter table is not proposed.
- **Uniqueness is already the task id.** A `:user`- or `:global`-scoped key already deduplicates a
  submit onto a live run (#19), across processes, because the check is the store's.
- **Ordering:** an external queue's items start in submit order per claim, but a re-queued item goes
  back to its original position (`ORDER BY created_at`) and can overtake later items. An external
  queue with `k = 1` is therefore not a strict FIFO across a consumer crash, and the docs say so.

## 5. Placement is configuration, and impossible configurations fail at start

```julia
# web process: same submit call in both modes, once the job is named
worker_startup(app; store, queues = ["email", "compute" => 6, "heavy" => External()])

# consumer process: the same app module, without serve()
Workers.consume!(app; store, queues = ["heavy" => 4])     # 4 = this process's concurrency (#513's k)
```

`External()` sits where #513's `k` sits, so a queue is either in-process with a concurrency or
external. The consumer's `k` is its own, and two consumers with `k = 4` run eight.

Refused at `start!`/`worker_startup`/`consume!`, never later:

- `External()` on a store that cannot claim: `InMemoryWorkerStore` is invisible to every other
  process, so a run submitted there would never happen.
- `consume!` with no queues, or with a queue the app does not declare `External()`. The consumer
  reads the declaration from the same app module, so the two cannot disagree silently.
- An external queue with a closure submitted to it (at submit time, §2).

## 6. Heartbeat, cancellation and progress

- **The heartbeat is per consumer process, not per run.** One task renews every lease the process
  holds in one `renew_leases!` call per tick (at a third of the lease). A per-run heartbeat inside
  `checkpoint!` would let a job that never calls it lose its lease while healthy, which is the failure
  a heartbeat exists to prevent.
- **Run the heartbeat on the interactive thread**, and start consumers with one (`-t k,1`). A
  CPU-bound job holds a `:default` thread without yielding (#467), so a heartbeat on `:default` can
  be starved by the very jobs it reports on. This is the one place Nitro would put its own work on the
  interactive thread on purpose; it is a cheap periodic store write, not a handler.
- **Cancellation reaches the consumer through the store.** `cancel_task` already writes `CANCELLED`
  durably. The heartbeat learns of it (a renew for a cancelled run does not match) and sets that run's
  in-process token with a new reason, `:lease_lost`, which `checkpoint!` then throws on. No per-call
  store read is added to `checkpoint!`; its cost stays the #513 measurement.
- **Progress is persisted by the heartbeat.** `update_progress!` writes only the in-process object
  today, so a web reader would see no progress until the terminal write. The heartbeat writes each
  held run's current progress in the same statement as the renew.
- **Status, watchers and cancel** already go through the store, so the web side's task API is
  unchanged.

## 7. Lifecycle, recycling, and one-shot runs

- **`consume!` drains on SIGTERM like `serve`**, by the #427 shutdown rules: stop claiming, set every
  held run's token to `:shutdown`, wait up to the drain timeout, then exit. A run still going at exit
  keeps its lease until it expires, and is then re-queued or failed (§4). Ctrl-C follows the same task
  placement rules as everything else (`concurrency.instructions.md`).
- **Recycling.** A process's RSS rises to a heavy run's peak and tends to stay there. The established
  fix is to recycle: `consume!(…; max_runs = 500, max_rss_mb = 2048)` drains and exits past either
  bound, and the supervisor restarts it. It reuses the SIGTERM drain path, so it adds a reason to drain,
  not a new mechanism. The cost is the restart's compile time; a sysimage helps (`deployment.md`).
- **One-shot mode for rare heavy jobs.** A few very heavy jobs a day should not keep a 450 MiB
  process alive for 24 hours. That is `consume!(…; max_runs = 1, exit_when_idle = true)`: claim one,
  run it, exit. **What starts it is the open question**, with three candidates:

| launcher | for | against |
|---|---|---|
| an external scheduler: a systemd path or timer unit, a Kubernetes `Job`/`CronJob`, KEDA scaling a consumer from zero on queue depth | fully decoupled; the supervisor owns processes, which is this design's premise | infrastructure outside Nitro; only fits schedule- or depth-driven launches |
| the web process spawns a one-shot `julia` per enqueue | one deployment, no extra infrastructure | couples launch to the web process, the coupling §8 rejects for long-lived workers. Weaker here, since the child claims through the store and lives on its own lease, but the behaviour of a running child across a web restart must be defined |
| a long-running consumer with `max_runs = 1` under a restarting supervisor | simplest | the restarted process idles at the floor until the next run, which defeats the point |

**Proposal:** ship the external-scheduler route first and document it with a systemd and a KEDA
example, because it needs nothing from Nitro but `exit_when_idle`. A web-spawned launcher is a
separate, later decision, taken only if the maintainer wants a single-deployment story for this case.

## 8. Not this design

- **Workers spawned by the web process** (`Distributed`, Malt). It looks simpler, one command to
  deploy, but it ties the workers' lifecycle to the server's (if the server dies, they die),
  complicates code loading, and pulls toward the cluster model Nitro deliberately does not have.
  Separate services under one supervisor also **scale independently**: more consumers or a larger
  `k` for a backlog, more web capacity for traffic.
- **A message broker** (Redis streams, RabbitMQ). The task table already is the queue, and
  `SKIP LOCKED` makes it a correct one; River and Oban run production queues on exactly this. A
  Redis *store* (#9) is a second claim/lease backend, not a different design.

## 9. Plan, once signed off

Each step is its own PR, landable and useful alone:

1. **Store contract** (§3): the columns, `claim_next!`, `renew_leases!`, `requeue_expired!`, their
   `NitroPormGExt` implementations, the zombie sweep excluding leased rows, and conformance tests on
   SQLite plus the real-Postgres job (#407).
2. **Named jobs** (§2), in-process first, with no external queue yet. This is useful on its own and
   is what makes the switch later a configuration change.
3. **`External()` and `consume!`** (§5, §6), the start-time refusals, and an end-to-end test with two
   processes sharing a PormG store: a consumer killed mid-run, its lease expiring, the run re-claimed
   or failed per policy, and the web process unaffected throughout.
4. **Recycling and one-shot** (§7), with RSS measured before, during and after a heavy run on the
   Julia versions CI covers.
5. **Docs**: deployment (two services, one supervisor), idempotency, the fault-isolation table, and
   store-load numbers from step 3's test.

Additive throughout: an app that never uses `External()` or named jobs changes nothing, so none of it
needs an `upgrading/` entry. `consume!` is also the natural entry point for #8 (extracting
`NitroWorkers.jl`), so this design feeds that issue's extraction criteria.

## 10. Decisions this record asks the maintainer to make

1. **Named jobs:** `register_job!(app, name, ArgsType) do task_info, args … end` with JSON-bound typed
   arguments, available in-process too (§2). Or a different shape?
2. **Lease-expiry policy:** per-queue `:requeue` (default) or `:fail`, with `max_attempts` (§4).
3. **Heartbeat on the interactive thread** of the consumer, and consumers started with `-t k,1` (§6).
4. **A new cancellation reason `:lease_lost`** in `CANCEL_REASONS` (§6).
5. **One-shot launcher:** external scheduler first, web-spawned launcher deferred (§7).
6. **The zombie sweep skips leased rows** in the first PR (§3).
