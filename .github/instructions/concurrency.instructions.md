---
description: Nitro.jl task model — where code runs, background tasks, interrupts, cancellation, CPU-bound handlers
---

# Nitro.jl Concurrency & Task Model

Read this before you spawn, park or stop a task, write a background loop, catch an interrupt, or
add work to HTTP.jl's connection task. This file indexes the rules. The reasoning behind each one
lives in the code comment it names, and that comment is canonical.

## 1. The model

- **Julia tasks are cooperative.** A task gives up its thread only at `wait`, `yield`, `sleep` or
  I/O. Julia 1.12 has no preemption, so a loop that computes without any of those holds its
  thread until it finishes. Go preempts; #469 measured the difference (Go without preemption
  stalls another goroutine for the whole loop).
- **Tasks are heavier than goroutines.** Each one reserves an 8 MiB stack (`JL_STACK_SIZE`). Measure
  before you change how many tasks a request costs (#468).

## 2. Where code runs

- **HTTP.jl 2.x runs the accept loop and every connection task on `:interactive`**, and
  `julia -t N` gives that pool one thread. `parallel_stream_handler`'s per-request
  `Threads.@spawn` moves handlers onto `:default`. That is a 2.2× win (#448), so keep it. The
  reasoning sits at its #39 comment in `src/core/transport.jl`.
- **With no interactive thread (`-t N,0`) the connection tasks run on `:default`**, spread over
  every thread. The spawn is still a win there: skipping it measured 4–9% slower (#492), so keep
  it in every layout. It is unconditional, and `serve` has no keyword to skip it (#525): do not
  add one, and do not make the spawn depend on the thread layout. Thread 1 is then a
  default thread, so a REPL Ctrl-C can land in a handler or a background loop: everything that
  "never gets a press under the default layout" (#369) can get one at `N,0`, as under `-t 1`.
- **The interactive thread protects accepting and reading heads, not handlers.** A handler runs on
  `:default` in every layout, so a CPU-bound handler or Workers job delays other requests just as
  much at `N,1` as at `N,0` (#491). Do not cite the interactive pool as protection from
  CPU-bound handlers or jobs.
- **The interactive thread is the scarcest resource in the process.** Add nothing to the
  connection task before the spawn. Since HTTP.jl 2.9, Nitro does no work there: the
  header-deadline clear it used to run (#316) moved into HTTP.jl (JuliaWeb/HTTP.jl#1382).
  The response is written on the request task: `stream_handler` calls `closewrite` itself
  (#453). See #462 for HTTP.jl's own share of that thread.
- **A consumer process (`Workers.consume!`, #514) is the other layout.** It serves nothing, so
  HTTP.jl does not hold an interactive thread, and its lease heartbeat runs on one instead (§3).
  `consume!` refuses to start with fewer than two (`julia -t k,2`), because **thread 1 must stay
  idle** (#636).
  - Outside a REPL, a SIGINT or a supervisor's SIGTERM exits through `atexit`, where `consume!`
    registers its drain. Probed on 1.12 and 1.13: an `atexit` hook still runs, and can still
    spawn and wait on tasks on other threads, before the process exits.
  - But Julia runs that exit **on thread 1, on top of the task it interrupted** (`jl_exit_thread0`),
    and that task never resumes, even one parked in `sleep`. Whatever it holds, the drain never
    gets. A heartbeat there was caught mid-compile (the drain never started) and inside a store's
    write transaction (the hand-backs timed out).
  - So the heartbeat is pinned to the last interactive thread, and thread 1 hosts only the main
    task waiting in `consume!`. Outside Windows, that wait holds thread 1 outside the scheduler
    (§3, #677): thread 1 runs no task until `consume!` returns, and libuv's loop runs on a thread
    of its own. A REPL Ctrl-C still lands there as an `InterruptException`, and the main task
    treats it as a stop request and drains.
  - What that leaves open: after a normal stop (a recycle, `exit_when_idle`), the drain runs on
    thread 1 inside the scheduler, so a SIGTERM during that drain can still land where #677's did.
  - Any new consumer-side work stays off thread 1, for the same reason.

## 3. Background tasks

- **Spawn with `_spawn_detached`** (`src/Workers/execution.jl`): non-sticky, on `:default`,
  detached from the caller's scope. **Never `@async`.** A sticky task parked on thread 1 is where
  a REPL's Ctrl-C lands (#369). In a consumer it is worse: a task stuck to thread 1 does not run
  at all while `consume!` waits (#677).
  - **One exception: a consumer's lease heartbeat runs on `:interactive`, pinned**
    (`_spawn_pinned`, `src/Workers/execution.jl`; `src/Workers/consumer.jl`, #514, #636).
    - It is on `:interactive` because a CPU-bound job holds a `:default` thread without yielding
      (#467). A heartbeat there can be starved by the very runs it renews, and a starved
      heartbeat turns a healthy run into a stolen one. It is allowed there because it is one
      cheap store write per tick in a process that serves nothing, so it competes with no
      connection task.
    - It is **sticky to the last interactive thread**, never thread 1, because a SIGTERM's exit
      runs on top of whatever thread 1 is doing (§2). This is the one sticky task Nitro starts,
      and it is the opposite of the #369 hazard: pinned *off* thread 1.
    - It parks on a plain `Timer`, never a `Timer(cb)`: that callback task inherits the
      stickiness and lands on whichever thread first schedules it.
    - Without the `-t k,2` layout, which only tests and benches can request, it falls back to
      `_spawn_detached(…; pool = :interactive)`.
    - Nothing else goes on `:interactive`; a new caller needs the same argument and an entry here.
- **A periodic loop goes through `_janitor`/`_janitor_loop`** (`src/middleware/janitor.jl`). It
  keeps the `try` inside the `while` (#169), uses a stop token per activation (#190), and ends
  with one `@warn` on an interrupt (#369). The Workers retention scheduler is a hand-rolled
  loop, and its reasoning is next to `_cleanup_scheduler_loop`. A consumer's claim loop and
  heartbeat are the other two (#514). They are waited on by the consumer's drain, and an
  interrupt there is a request to drain, not a reason to stop the loop: the heartbeat must keep
  renewing until the drain ends. It may outlive the drain, but only to renew. A drain that times
  out returns, and the heartbeat goes on renewing the runs it left going until the last one
  returns. Meanwhile it claims nothing and adjudicates nothing. In a REPL the process outlives
  `consume!`, and an unrenewed lease there would let another consumer run the same job at the
  same time (#607).
- **A long idle wait parks; it does not poll.** A task that idles between ticks or until stopped
  parks once on a `Base.Event`, woken by a `Timer` and by the stop path (#369, #371). A short
  `timedwait` with a deadline is fine for a bounded wait during shutdown or a drain.
  - **One exception: `consume!`'s main task on thread 1 polls, outside the scheduler**
    (`_park_until_stop!`, `src/Workers/consumer.jl`, #677). A park leaves thread 1 inside the
    scheduler, which is exactly where a SIGTERM's exit hung the drain: inside a libuv timer
    callback it holds the loop's lock and that `Timer`'s lock, and inside the scheduler's sleep it
    can block in `pthread_cond_wait`. So the main task sleeps in a GC-safe `usleep` and reads a
    flag, and libuv's loop first moves to a thread of its own (`Base.Experimental.make_io_thread`).
    Without that move, parking thread 1 stops every timer in the process.
  - Nothing else polls. A new caller needs the same argument and an entry here.
- **Every start has a stop on every path**, including a failed start, and never overwrites the
  only handle to a running task (#427).

## 4. Exceptions and cancellation

- **Never throw into a task that may be running** (`schedule(t, exc; error = true)`): it aborts
  the process when `t` is on another thread (#127). The one exception proves the task is parked,
  under the lock its waker takes: `_cancel_revision_wait` (`ext/NitroReviseExt.jl`).
- **Stopping is cooperative.** The stopper sets a flag or token and the task checks it. One
  generic pair serves both kinds of task: `cancel_requested`/`cancel_reason` on a Workers
  `TaskInfo`, and on an `HTTP.Request` (#466), where it reads `:client_disconnected` or
  `:shutdown`.
  - **Request side:** `terminate` sets a per-run flag before its hooks; each pipeline captures
    its run's flag in `RequestScope`. A disconnect is a lazy, throttled, non-blocking
    `MSG_PEEK` probe on the **caller's** task (`_peer_gone`, `src/core/transport.jl`), never
    work on the connection task (§2).
  - **A new cause** (a deadline, a token a spawned task or job can hold, #661, #662) extends that
    pair rather than adding a second vocabulary.
- **The catch policy is canonical in `src/errors.jl`**, in `is_unrecoverable` and its site
  table: which catches rethrow `StackOverflowError`, `OutOfMemoryError` and `InterruptException`,
  which stay narrow on purpose, and why the worker executors record `FAILED` instead of
  rethrowing. Add every new catch site to that table.
- **Shutdown code never throws.** `close` and `terminate` run after the listener is down (#427).

## 5. Handlers that compute

- **Nothing can preempt or stop a CPU-bound handler.** Julia 1.12 has no preemption: a handler
  that computes without waiting holds its `:default` thread until it returns, and
  `Threads.nthreads(:default)` of them stall every other request until one finishes. Measured in
  #467 (PR #584): with 8 default threads, 8 handlers each computing 200 ms took a minimal route
  from about 100k requests per second to 1.5k, with a p99 of 192 ms, the handlers' own run time.
  The knee is the default thread count; below it the other requests barely notice (4 of 8 cost
  4%). Waiting on I/O, a lock or a `sleep` is not computing: those handlers give the thread back.
- **The threshold is the application's latency budget, not a fixed number of milliseconds.** Past
  the knee, a cheap request's p99 becomes the computing handler's run time, so the longest a
  handler may compute is the delay the application accepts for every other request. For an API
  answering in milliseconds, that is a few milliseconds of computation. Do not add a long-handler
  warning to `serve` for it (declined in #467): the threshold is per application, and the
  `AccessLog` middleware already records each request's `duration_ms`.
  - **Against Go, as a data point, not a threshold (#590):** at the knee, a handler computing
    about 1 ms per call costs throughput but no stall (p99 3.7 ms, Go's too). The plain loop stops
    matching Go between 11 and 33 ms per call: Go preempts the long calls, so its p99 levels off
    near 18 ms, and Nitro's becomes the call time. A loop yielding every 2 ms kept pace with Go
    past it, in a run not interleaved with Go's. Do not turn the 11–33 ms into a rule: it is
    where Go stops being better, not what an application's budget allows.
- **Past it, the work leaves the handler for a bounded queue and the handler answers `202`.**
  `submit_queued_task` to a queue whose concurrency leaves default threads free
  (`queues = ["compute" => max(N - 2, 1)]`), returning the task id. Not a bare `submit_task`: an
  unbounded submit runs on the same default threads and stalls them the same way (#512, #513).
  A full queue refuses the submit with `WorkerCapacityError`, which Nitro answers `503`; that is
  the backpressure, not a bug.
- **Or `yield()` every 1-2 ms** in a loop that has to stay in the handler. It bounds the wait
  (a p99 of 10.5 ms at the knee in #467's run, against 192 ms) but not the throughput loss, so it
  is the fallback, not the rule.
- **On Julia 1.13.0 through 1.13.2, `yield()` does not wake a parked task when nothing else
  keeps a libuv timer alive (#586).** In the repro, every default thread runs a loop that yields
  every 1 ms, and a task in `sleep(0.001)` does not run again until the loops end (1.5 s), against
  a few ms on 1.12.7 and on 1.14-DEV. It begins at 1.13.0-rc3, with the scheduler backports in
  JuliaLang/julia#62665, and is reported as JuliaLang/julia#63882. **Any second live `Timer`
  removes it, even one that never fires.**
  - **Not affected:** the bounded queue, and new requests (#467's `cpu_yield` row did not move on
    1.13.2). **Exposed:** a process with no other live timer.
  - **`serve()` holds the guard itself (#598).** On the versions `_needs_wake_guard`
    (`src/context.jl`) names, `startserver` keeps one never-firing `Timer` in
    `Service.wake_guard`, and `close(::Service)` releases it once nothing serves. Measured with
    `bench/socket/wake.sh` on 1.13.2: a parked handler in a `serve()` with no other timer woke
    1.48 s late without it, 10-23 ms with it. **`consume!` holds its own** (#514), since a
    consumer never calls `serve`: one never-firing `Timer` in `ConsumerHandle.wake_guard` under the
    same gate. The drain closes it, or the heartbeat does, if it outlives a drain that timed out
    (#607). **Still exposed:** yielding loops while neither a server nor a
    consumer is up. When a fixed 1.13.x ships, lower the gate's upper bound; once Nitro's floor passes the
    last affected release, delete the guard and this bullet, and change the documents below
    with it.
  - **The bench masks it unless told not to:** `bench/socket/server.jl` parks on a `Timer` by
    default, which is itself a guard; `wake.sh` runs it with `PARK=event`.
- **A Nitro primitive that can run more than about 1 ms on a request thread reaches a safepoint on
  a budget**: every N KiB or N items, at a natural boundary in its own loop. This covers
  framework code, not the application's (the bullets above). Below the knee, what a large body
  costs every other request is the collector: a collection stops every thread and then waits for the one still in
  a call with no safepoint. Measured in #588 with four in flight on 8 threads: a 100 MiB
  whole-file read made each collection wait 43 ms, and a 64 MiB multipart parse 20 ms; the
  minimal route's p99 went from 3 ms to 51–75 ms.
  - **A `GC.safepoint()` is enough; a `yield()` is optional.** Past the knee a yield bounds p99
    but adds no throughput (#467's `/cpu_yield`), and it costs a scheduler round trip per budget.
    Code that allocates as it goes already reaches safepoints: the JSON parses waited 0.4–3.5 ms
    per collection.
  - **A file goes through the streamed path.** `Res.file(req, path)` streams over
    `Constants.FILE_STREAM_THRESHOLD` (8 MiB), like the mounts. A streamed body's socket writes
    give the thread up whenever the client is slower than the server.
  - **Instances:** `multipart()` copies each part in 1 MiB chunks with a safepoint between them
    (`_read_part`, `src/utilities/bodyparsers.jl`). HTTP.jl's boundary scan before it has none
    (about 33 ms at 64 MiB), which only an upstream change or a cap on `max_body_bytes` bounds.
  - **Check one with a time-to-safepoint probe, not a timing:** one thread runs the call in a
    loop while another forces `GC.gc(false)`, and read the `Base.gc_num()`
    `total_time_to_safepoint` delta per collection. An idle thread reads about 0.03 ms.
- The measurements and the user-facing rule live in `docs/src/tutorial/deployment.md` (*Handlers
  that compute*, and the paragraphs on Nitro's own primitives after it) and
  `docs/src/tutorial/workers.md` (*CPU-Bound Jobs*); the `nitro-usage` skill carries the same rule
  for application code. Change all of them together, or none.

## 6. Julia 1.14: changes to plan for

- Ctrl-C arrives as `Base.CancellationRequest`, not `InterruptException`. `Task.queue` no longer
  names a parked task's wait queue, which `_cancel_revision_wait` relies on. Both are #459.
- `Base.CancellationTokenSource`, `cancel!` and `@cancel_check` arrive. #466 shaped the request
  token so it can be backed by them: a `Bool` predicate plus a reason, and no Nitro token type to
  migrate. Backing it is #663, which needs a push-style disconnect watcher #466 deliberately
  avoided. Their per-task cost is JuliaLang/julia#63416 (#468).
