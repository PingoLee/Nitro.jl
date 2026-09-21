## Cancellation no longer interrupts the callback — poll `cancel_requested` instead (#127)

- **Version**: 0.4.0
- **Nitro ref**: #127 (unblocks #30; requires #142); `src/Workers/types.jl`,
  `src/Workers/api.jl`, `src/Workers/execution.jl`, `src/Workers/queue.jl`,
  `docs/src/tutorial/workers.md`
- **Recorded**: 2026-09-11
- **Severity**: **breaking (runtime behavior, and it breaks SILENTLY)** — part of the `0.1.x`
  pre-publish wave. Nothing throws and nothing is logged; long-running callbacks simply stop being
  stopped.

### What changed

`cancel_task` and the `TaskOptions(timeout=…)` monitor both used to do this:

```julia
schedule(sys_task, InterruptException(), error=true)
```

`schedule(t, exc; error=true)` sets `t.result`, sets `_isexception` and enqueues `t` — with **no
check that `t` is currently running**. That was survivable only because worker bodies were
`@async`, so the interrupter and its target were welded to the same thread and the target was
always parked or done when the interrupt landed. Interrupt a task genuinely executing on another
thread and it completes normally, overwrites `result` with its return value, leaves `_isexception`
set — and `jl_finish_task` aborts the **process**. Julia's own documentation says it: *"It is
incorrect to use `schedule` on an already started task."*

This is not a Julia quirk. Java deprecated `Thread.stop()` in 1.2 and eventually made it throw
unconditionally; .NET's `Thread.Abort` throws `PlatformNotSupportedException` on .NET Core. Both
were withdrawn for the same reason, and nothing re-adopted the model. Go (`context.Context`),
Sidekiq and River have always been cooperative. Celery and Oban can hard-kill only because they
have a process boundary to kill across — an OS process and a BEAM process respectively — which a
single-process framework does not.

Both injections are gone. Cancellation is now a **token** the callback polls:

```julia
submit_task("import", task_info -> begin
    for chunk in chunks
        cancel_requested(task_info) && return "cancelled"   # ← new, exported
        process(chunk)
        update_progress!(task_info, 100 * done / total)
    end
end, Owner("user-1"))
```

`cancel_task`'s observable contract is unchanged — it still records the terminal state atomically
and still returns `"Task cancelled"` — because the state was always claimed *before* the interrupt
was sent. What is gone is a best-effort nudge that was unreliable even under `@async`: a CPU-bound
callback also defeated the old timeout, because `timedwait` never got scheduled while the sticky
child hogged their shared thread.

**What this forces. Four shapes:**

1. **A callback that was implicitly cancellable now is not, silently.** Anything parked in a long
   `sleep`, a blocking `wait`, or IO used to be unwound by the injected exception without doing
   anything itself. It now runs to completion. **This is the dangerous one** — there is no error,
   no log, and no failing test; the job simply ignores cancellation from now on. The greps below
   are aimed at finding these.
2. **A `try`/`finally` runs only when the callback returns.** Releasing a file lock, killing a
   child process, closing a socket — all of that used to run as the interrupt unwound the
   callback. A callback that never polls never returns, so its `finally` never runs. The `ffmpeg`
   example in the worker tutorial was written that way and has been rewritten.
3. **`timeout` is advisory.** A timed-out callback keeps running and keeps a thread. Under #30
   that thread is one of `Threads.nthreads()` on the `:default` pool — **the same pool `serve`
   spawns every request into** — so `nthreads()` abandoned CPU-bound callbacks wedge the web
   server. Nitro logs a `@warn` naming the task at the moment it abandons it; that warning is now
   the only signal.
4. **`retry_on_failure` no longer retries a timeout.** It cannot: nothing stops the attempt that
   timed out, so `max_retries=3` would start four concurrent copies of one job against one
   `task_info` and one set of external side effects. A timeout is terminal `FAILED` on the first
   attempt, carrying the same `"Timeout of Ns exceeded"` message as before. Genuine failures still
   retry exactly as they did.

Two further notes:

- **`cancel_requested` is process-local.** With `PormGWorkerStore` across several processes, a
  cancel issued on another node writes the row and sets no token here. Cross-process callbacks
  must poll the durable record — `get_task_status(task_info.id, System())[:status] == "CANCELLED"`
  — sparingly, since it is a round-trip. That was already true of the previously documented
  `task_info.status` check; the token is a fast path, not a distributed one.
- **A callback that throws `InterruptException` is now `FAILED`, not `CANCELLED`.** Nothing
  injects one any more, so the only way one arrives is that your code raised it, and recording
  that as "Cancelled by user" was a lie about who stopped the job.

### How to find the calls to migrate

```bash
# 1. THE IMPORTANT ONE: long-running callbacks with no cancellation check. Every hit here is a
#    job that silently stopped being cancellable.
rg -n -A15 'submit_task\(|submit_sequential_task\(' --type julia | rg -n 'sleep|wait\(|read\(|download'
rg -n 'cancel_requested' --type julia          # ...and which of them now have a check

# 2. Callbacks that assumed they would be unwound — a `finally` that releases something.
rg -n -B2 -A8 'submit_task\(|submit_sequential_task\(' --type julia | rg -n 'finally|kill\(|close\(|unlock'

# 3. Anything that treated `timeout` as a hard stop, and the retry+timeout combination whose
#    behavior changed.
rg -n 'TaskOptions\(' --type julia | rg -n 'timeout|retry_on_failure'

# 4. Code matching on the old cancellation exception.
rg -n 'InterruptException' --type julia
```

### Before → after

```julia
# ✗ before — the `finally` ran because the interrupt unwound the callback
submit_task("convert", task_info -> begin
    p = run(pipeline(`ffmpeg -i in.mov out.mp4`); wait = false)
    try
        wait(p)                      # blocks forever now; nothing interrupts it
        return "converted"
    finally
        process_running(p) && (kill(p); wait(p))
    end
end, Owner("user-1"))

# ✓ after — poll the token, and the `finally` still does the reaping
submit_task("convert", task_info -> begin
    p = run(pipeline(`ffmpeg -i in.mov out.mp4`); wait = false)
    try
        while process_running(p)
            cancel_requested(task_info) && break
            sleep(0.2)               # the poll interval IS the cancellation latency
        end
        return process_running(p) ? "cancelled" : "converted"
    finally
        process_running(p) && (kill(p); wait(p))
    end
end, Owner("user-1"))
```

```julia
# ✗ before — a tight loop a timeout would eventually cut short
submit_task("crunch", () -> begin
    while more(); step(); end
end, Owner("u"); options = TaskOptions(timeout = 300))

# ✓ after — the deadline only works if the callback checks
submit_task("crunch", task_info -> begin
    while more()
        cancel_requested(task_info) && return "stopped"
        step()
    end
end, Owner("u"); options = TaskOptions(timeout = 300))
```

An app whose callbacks are short, or already poll the task status, needs no change beyond reading
the retry note.
