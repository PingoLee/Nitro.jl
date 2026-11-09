## Workers — a failed completion write no longer re-runs the callback

- **Version**: Unreleased
- **Nitro ref**: #918; `src/Workers/queue.jl` (`_run_attempts!`, `_record_outcome!`,
  `_record_unstored_outcome!`), `src/Workers/consumer.jl`
- **Recorded**: 2026-11-09
- **Severity**: **behavior change** — no API changes. It matters only when the store throws while
  writing the outcome of a callback that **returned**: a transient database failure on that write,
  or a result the store cannot serialize (with `PormGWorkerStore`, a result nested deeper than 512
  levels).

### What changed

A run's completing write used to sit inside the attempt's own `try`, so a store that threw there
read as the callback failing. Now the attempt covers the callback alone. A callback that returned
is never run again by the retry loop.

| path | before | now |
|---|---|---|
| `submit_task` / `submit_queued_task` with `retry_on_failure = true` | the callback ran again, up to `max_retries + 1` times, then `FAILED` with the store's error text (or `COMPLETED`, if a later write succeeded) | the callback runs **once**; the task is `FAILED` with `"The callback returned, but its outcome could not be stored (<ExceptionType>)"` |
| the same, `retry_on_failure = false` | `FAILED` with the store's error text | `FAILED` with the message above |
| the failure write throws too | the exception escaped the executor: an unhandled task failure, or the queue's "aborted outside task execution" log | logged, and the task is left `RUNNING`; the zombie sweep (`recover_zombie_tasks!`) marks it `FAILED` |
| a consumer's run of an `External(…)` queue | the job ran again under the queue's `options`, then the consumer recorded `FAILED` itself | the job runs **once**; the row is left to its lease, and `requeue_expired!` decides by the queue's `on_lease_expiry` |

The message names the exception's type only, never its text, which can quote stored values. The
full exception is in the `@error` log line.

### How to find the calls to migrate

You are affected only if you relied on a re-run to get a result stored:

```bash
grep -rn "retry_on_failure" src/ bin/ *.jl
```

Then check whether anything reads a `FAILED` task's `error` to decide what to do.

### Migrate your app

```julia
# ✗ before: a result the store refused was retried, re-running the callback's side effects
submit_task(app, "report", () -> build_report(), owner;
            options = TaskOptions(retry_on_failure = true))

# ✓ after: the callback runs once. If its outcome could not be stored, the task is FAILED with a
# message that says so, and re-submitting is the caller's decision.
status = get_task_status(app, task_id, owner)
if status[:status] == "FAILED" && startswith(something(status[:error], ""),
                                            "The callback returned, but its outcome could not be stored")
    # the work happened; only its result was lost
end
```
