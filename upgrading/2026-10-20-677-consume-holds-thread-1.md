## `consume!` holds thread 1 outside the scheduler, so tasks tied to thread 1 wait for it (#677)

- **Version**: Unreleased
- **Nitro ref**: [#677](https://github.com/PingoLee/Nitro.jl/issues/677) ; `src/Workers/consumer.jl`
- **Recorded**: 2026-10-20
- **Severity**: behavior change, in a consumer process outside Windows only. Nothing changes in a
  web process, or on Windows.

### What changed

A supervisor's `SIGTERM` runs the consumer's drain on thread 1, at whatever instruction thread 1 is
on. `consume!` used to wait for a stop with its main task parked in Julia's scheduler. Sometimes a
signal landed while that scheduler step was running a libuv timer callback, and then the drain
deadlocked on a lock its own interrupted frame held: the consumer logged that its drain began and
never exited, and its runs were left claimed until their leases expired.

Outside Windows, `consume!` now waits with thread 1 asleep outside the scheduler. It first moves libuv's event loop,
which only thread 1 ran, to an extra thread of its own (`Base.Experimental.make_io_thread`), for the
rest of the process. A stop request, a `SIGTERM` or a Ctrl-C still reaches it as before. What
changed is that **thread 1 runs no task while `consume!` waits**. A task tied to thread 1 waits until `consume!` returns. Those are the tasks started from the
consumer script's top level, before `consume!`, with:

- `@async`;
- `Timer(callback, …)` and `Timer(…) do t … end`: created from a sticky task such as the main task,
  the callback runs on a task tied to that thread;
- `Task(…)` + `schedule`, which is `@async` spelled out.

Tasks started with `Threads.@spawn`, a `Timer(callback, …; spawn = true)`, Nitro's own loops, and the
jobs the consumer runs are not affected. A package that starts an `@async` task or a `Timer`
callback in its `__init__` ties it to thread 1 as well, and the grep below cannot find that.

### How to find the calls to migrate

In the consumer's entry script, and in any setup function it calls before `consume!`:

```bash
grep -rn -E '@async|Timer\([^)]*->|Timer\(\s*[a-z_]+\s*,|Timer\(.*\)\s*do\b|\bTask\(' --include=*.jl .
```

A hit needs a change only when it runs on the consumer's main task before `consume!`, and the task
it starts must keep running while the consumer runs. A `Timer(delay, interval)` with no callback
matches too, and needs no change.

### Migrate your app

```julia
# ✗ before -- tied to thread 1, so it no longer runs while consume! waits
@async while true
    report_metrics()
    sleep(30)
end
consume!(app; store, queues = ["heavy" => 4])

# ✓ after -- spawned onto the default pool
Threads.@spawn while true
    report_metrics()
    sleep(30)
end
consume!(app; store, queues = ["heavy" => 4])

# ✗ before -- a Timer callback created by the main task is tied to thread 1
Timer(_ -> report_metrics(), 0; interval = 30)

# ✓ after -- the callback task may run on any thread
Timer(_ -> report_metrics(), 0; interval = 30, spawn = true)
```
