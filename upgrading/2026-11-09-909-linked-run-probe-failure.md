## A linked run whose request check fails now ends on its own outcome, not `RUNNING`

- **Version**: Unreleased
- **Nitro ref**: #909 (follow-up to #662 and #906); `src/Workers/types.jl` (`_settled_cause`),
  `src/Workers/queue.jl` (`_run_attempts!`, `_backoff_wait`, `_cancel_task!`, the dequeue check)
- **Recorded**: 2026-11-09
- **Severity**: **behavior change** — no API changes. It matters only for a run linked to a
  request (`submit_task(…; parent = cancel_token(req))` or `submit_queued_task(…; parent)`) whose
  request's disconnect check fails with a socket error other than the client leaving.

### What changed

A run linked to its request reads the request's cause, and that read can ask the kernel whether
the client is still there. When that check itself fails (a socket error that does not mean the
client left), the failure used to be handled in one of two ways, depending on where it happened:

- **Inside your callback** (your own `cancel_requested(task_info)` or `checkpoint!`): the attempt
  fails, and is recorded and retried like any other failure. **Unchanged.**
- **In the executor's own checks between attempts** (the retry backoff, the check after it, the
  test for a `TaskCancelledError`, and the message of a cancel another process recorded): the
  failure escaped the executor.
  - **Before:** the record stayed `RUNNING`, with no live run behind it, until a zombie sweep
    marked it `FAILED`. On a queue, the processor also logged
    `Worker queue item aborted outside task execution`.
  - **Now:** the failed check counts as "no cause", as it already did at a queued item's dequeue
    (#906). The run goes on and ends on its own outcome: `COMPLETED` when a retry succeeds,
    `FAILED` with the callback's error when every attempt fails, `CANCELLED` when it was cancelled.

An `InterruptException`, `StackOverflowError` or `OutOfMemoryError` raised by the check is still
rethrown.

### How to find the calls to migrate

You are affected only if something reads a linked run's final status and relied on such a run
ending `RUNNING`, then `FAILED` by the zombie sweep:

```bash
grep -rn "parent *= *cancel_token" src/ bin/ *.jl
grep -rn "recover_zombie_tasks!\|zombie" src/ bin/ *.jl
```

Nothing to migrate otherwise.

### Migrate your app

```julia
# ✗ before: a linked run whose disconnect check failed between attempts never finished on
# its own; a periodic sweep turned it into FAILED, with no error from the callback
status = get_task_status(id, Owner(uid))[:status]   # "RUNNING", then "FAILED" after a sweep

# ✓ after: it finishes on its own outcome, like an unlinked run
status = get_task_status(id, Owner(uid))[:status]   # "COMPLETED", or "FAILED" with the callback's error
```
