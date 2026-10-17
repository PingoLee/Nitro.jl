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
  HTTP.jl does not hold its interactive thread, and its lease heartbeat runs there instead (§3).
  `consume!` refuses to start without an interactive thread (`julia -t k,1`). Under `-t k,1`
  thread 1 is that thread, so a REPL Ctrl-C can land in the heartbeat or in the task blocked in
  `consume!`; both treat it as a stop request and drain. Outside a REPL, a SIGINT or a
  supervisor's SIGTERM exits through `atexit`, where `consume!` registers its drain: probed on
  1.12 and 1.13, an `atexit` hook still runs, and can still spawn and wait on tasks on other
  threads, before the process exits.

## 3. Background tasks

- **Spawn with `_spawn_detached`** (`src/Workers/execution.jl`): non-sticky, on `:default`,
  detached from the caller's scope. **Never `@async`.** A sticky task parked on thread 1 is where
  a REPL's Ctrl-C lands (#369).
  - **One exception: a consumer's lease heartbeat runs on `:interactive`**
    (`_spawn_detached(…; pool = :interactive)`, `src/Workers/consumer.jl`, #514). A CPU-bound job
    holds a `:default` thread without yielding (#467), so a heartbeat there can be starved by the
    very runs it renews, and a starved heartbeat turns a healthy run into a stolen one. It is
    allowed there because it is one cheap store write per tick in a process that serves nothing,
    so it competes with no connection task. Nothing else goes on `:interactive`; a new caller
    needs the same argument and an entry here.
- **A periodic loop goes through `_janitor`/`_janitor_loop`** (`src/middleware/janitor.jl`). It
  keeps the `try` inside the `while` (#169), uses a stop token per activation (#190), and ends
  with one `@warn` on an interrupt (#369). The Workers retention scheduler is a hand-rolled
  loop, and its reasoning is next to `_cleanup_scheduler_loop`. A consumer's claim loop and
  heartbeat are the other two (#514). They are waited on by the consumer's drain, and an
  interrupt there is a request to drain, not a reason to stop the loop: the heartbeat must keep
  renewing until the drain ends.
- **A long idle wait parks; it does not poll.** A task that idles between ticks or until stopped
  parks once on a `Base.Event`, woken by a `Timer` and by the stop path (#369, #371). A short
  `timedwait` with a deadline is fine for a bounded wait during shutdown or a drain.
- **Every start has a stop on every path**, including a failed start, and never overwrites the
  only handle to a running task (#427).

## 4. Exceptions and cancellation

- **Never throw into a task that may be running** (`schedule(t, exc; error = true)`): it aborts
  the process when `t` is on another thread (#127). The one exception proves the task is parked,
  under the lock its waker takes: `_cancel_revision_wait` (`ext/NitroReviseExt.jl`).
- **Stopping is cooperative.** The stopper sets a flag or token and the task checks it: Workers'
  `cancel_requested`/`cancel_reason`, and #466 for requests.
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
    1.48 s late without it, 10-23 ms with it. **Still exposed:** yielding loops while no server is
    up. When a fixed 1.13.x ships, lower the gate's upper bound; once Nitro's floor passes the
    last affected release, delete the guard and this bullet, and change the documents below
    with it.
  - **The bench masks it unless told not to:** `bench/socket/server.jl` parks on a `Timer` by
    default, which is itself a guard; `wake.sh` runs it with `PARK=event`.
- The measurements and the user-facing rule live in `docs/src/tutorial/deployment.md` (*Handlers
  that compute*) and `docs/src/tutorial/workers.md` (*CPU-Bound Jobs*); the `nitro-usage` skill
  carries the same rule for application code. Change all of them together, or none.

## 6. Julia 1.14: changes to plan for

- Ctrl-C arrives as `Base.CancellationRequest`, not `InterruptException`. `Task.queue` no longer
  names a parked task's wait queue, which `_cancel_revision_wait` relies on. Both are #459.
- `Base.CancellationTokenSource`, `cancel!` and `@cancel_check` arrive. Design new cancellation
  so it can be backed by them (#466). Their per-task cost is JuliaLang/julia#63416 (#468).
