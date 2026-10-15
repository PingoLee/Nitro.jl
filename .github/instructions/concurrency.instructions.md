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

## 3. Background tasks

- **Spawn with `_spawn_detached`** (`src/Workers/execution.jl`): non-sticky, on `:default`,
  detached from the caller's scope. **Never `@async`.** A sticky task parked on thread 1 is where
  a REPL's Ctrl-C lands (#369).
- **A periodic loop goes through `_janitor`/`_janitor_loop`** (`src/middleware/janitor.jl`). It
  keeps the `try` inside the `while` (#169), uses a stop token per activation (#190), and ends
  with one `@warn` on an interrupt (#369). The Workers retention scheduler is the one
  hand-rolled loop; its reasoning is next to `_cleanup_scheduler_loop`.
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

- Nothing can preempt or stop a CPU-bound handler. `Threads.nthreads(:default)` of them stall
  every other request until they finish. Long computation belongs in a Worker (`submit_task`) or
  must reach a yield point regularly. The threshold to document is #467's measurement.

## 6. Julia 1.14: changes to plan for

- Ctrl-C arrives as `Base.CancellationRequest`, not `InterruptException`. `Task.queue` no longer
  names a parked task's wait queue, which `_cancel_revision_wait` relies on. Both are #459.
- `Base.CancellationTokenSource`, `cancel!` and `@cancel_check` arrive. Design new cancellation
  so it can be backed by them (#466). Their per-task cost is JuliaLang/julia#63416 (#468).
