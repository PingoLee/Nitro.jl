## Worker teardown drains in-flight runs instead of releasing them (#176)

- **Version**: 0.4.0
- **Nitro ref**: #176 (follow-up to #167); `src/Workers/runtime.jl`, `src/Workers/types.jl`,
  `src/Workers/execution.jl`, `src/Workers/queue.jl`, `src/Workers/api.jl`,
  `docs/src/tutorial/workers.md`, `.github/instructions/workers.instructions.md`,
  `test/workers_tests.jl`, `test/extensions/pormg_worker_tests.jl`
- **Recorded**: 2026-09-14
- **Severity**: **behaviour, and it is silent.** Nothing raises. Stopping a server that runs
  workers now takes up to five seconds longer, and a background callback that polls
  `cancel_requested` is asked to stop on the way out — so work that used to be abandoned
  mid-flight now finishes early, or finishes fully, depending on the callback.

### What changed

`shutdown!` used to release: it dropped every run handle and returned while the callbacks were
still executing. `recover_zombie_tasks!` decides liveness from exactly those handles, so a run that
survived a teardown/restart **in one process** looked dead — the next `start!(recover_zombies=true)`
marked it `FAILED`, and when the real callback finished, its run-fenced terminal write lost against
that record and the result was discarded.

It now drains, in the shape `terminate()` has always used for HTTP connections and that Go's
`http.Server.Shutdown(ctx)`, Sidekiq's `-t` and River's `Client.Stop` all share:

1. every in-flight run's `cancel_requested` token is set, **before** the wait, so a cooperative
   callback has the whole window to notice and return;
2. `shutdown!` waits up to `drain_timeout` seconds — default `WORKER_DRAIN_TIMEOUT_SECONDS`, five
   — and returns `true` if everything settled, `false` if anything was still running when it
   returned (an expired wait, or a `drain_timeout=0` that never waited);
3. a run that did not settle keeps its handle registered and logs a warning, so the zombie sweep
   no longer declares it dead. The handle is reclaimed when the callback actually returns.

`uninstall!`, `install!`'s displacement path, `start!`, `startup` and `worker_startup` all take
`drain_timeout` and pass it down. **`reset_runtime!` is the exception: it defaults to `0`**, because
a reset erases the live cache and the volatile records anyway, so waiting for an outcome it is about
to delete buys nothing.

Three consequences worth planning for:

- **Process exit takes longer.** `terminate()` runs lifecycle shutdown hooks *before* it drains
  HTTP connections, so the worker drain and `serve(shutdown_timeout = …)` are consecutive: worst
  case is now 5 s + 10 s with both defaults. Check that against your container's stop grace period.
- **A cooperative callback may now stop early on shutdown**, and records whatever it reached on
  its own: `COMPLETED` with the value it returned, `FAILED` if it threw, **or `CANCELLED` if the
  shutdown landed while the run was parked in its retry backoff**, which polls the same token. If
  you have alerting or reporting that reads `CANCELLED` as "a person cancelled this", a deploy can
  now produce that status on a retrying job. **#183, later in this same wave, is what makes that
  filterable**: a drained run records `"Cancelled by worker shutdown"` and only `cancel_task`
  produces `"Cancelled by user"`. Apply that entry too and alert on the message. The drain still
  writes no terminal state itself — that would race the run's own write — so a callback that needs
  something richer than a status still puts it in the value it returns.
- **Keeping the handle only helps a runtime that is reused.** A `serve → terminate → serve` cycle
  with `store=` builds a fresh `WorkerRuntime` whose handles start empty, so an abandoned run from
  the previous cycle is still swept. There, finishing the run inside the drain is the only thing
  that saves it.

### How to find the calls to migrate

```bash
# Anything that tears a worker runtime down, or bootstraps one that will.
grep -rn "worker_startup\|uninstall!\|reset_runtime!\|shutdown!" --include=*.jl .

# Callbacks that poll the token: these are the ones whose behaviour on shutdown changes.
grep -rn "cancel_requested" --include=*.jl .
```

An app that wants the old semantics passes `drain_timeout=0`, which skips both the token and the
wait and drops every handle — byte-for-byte the previous behaviour.

### Before → after

```julia
# BEFORE — teardown returned immediately; in-flight callbacks kept running unnoticed, and a
# restart in the same process marked them FAILED and discarded their results.
serve(middleware=[worker_startup(queues=["reports"])])

# AFTER (default) — teardown asks in-flight runs to stop and waits up to 5s for them.
serve(middleware=[worker_startup(queues=["reports"])])

# AFTER — tune the wait, or opt out of it entirely to restore the old exit timing.
serve(middleware=[worker_startup(queues=["reports"], drain_timeout=20)])
serve(middleware=[worker_startup(queues=["reports"], drain_timeout=0)])
```

```julia
# `shutdown!` now reports whether it finished, which it previously could not.
drained = shutdown!(runtime)              # true  — everything settled
drained = shutdown!(runtime; drain_timeout=0.5)   # false — the wait expired; handles kept
```
