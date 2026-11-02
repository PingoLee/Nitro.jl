## `LifecycleMiddleware` — `on_startup` hooks run on a default-pool task outside a REPL, not on the task that called `serve`

- **Version**: Unreleased
- **Nitro ref**: #824, #829 ; `src/core/lifecycle.jl` (`_startup_broadcast`, `_startup_off_thread1`),
  `src/types.jl` (the `LifecycleMiddleware` docstring, *Which task runs `on_startup`*)
- **Recorded**: 2026-11-02
- **Severity**: behavior change. Hook order and the interrupt contract are unchanged, and most apps
  need no edit. A hook that relies on the task or the thread that called `serve` does.

### What changed

`serve` used to run every `on_startup` hook on the task that called it. In the default layout
(`julia -t N`, so thread 1 is the interactive thread) that task runs on thread 1. A `SIGTERM` runs
the `atexit` hooks on thread 1, on top of whatever thread 1 is running, and that frame never
resumes. A start-up hook that was compiling there, such as the Workers boot sweep, therefore hung
the exit until the supervisor sent `SIGKILL` (#824).

Now, **outside a REPL and when thread 1 is the interactive thread**
(`!isinteractive() && Threads.threadpool(1) === :interactive`), `serve` runs the start-up broadcast
on one `Threads.@spawn :default` task and waits for it. In a REPL, and when every thread is a
default one (`--threads=1`, `--threads=N,0`), nothing changes. The hooks still run one after
another, route-owned first, in the same order, and a hook's interrupt is handed back as before.

What a hook can no longer rely on, when the new path applies:

- **The caller's task-local storage.** The hook runs on another task, so `task_local_storage(key)`
  set by the code that calls `serve` is not there.
- **Thread 1.** An `@async` the hook starts, or a `Timer(cb)`, stays on the default-pool thread the
  hook runs on. Code that assumed it would sit on thread 1 (or read `Threads.threadid() == 1`)
  no longer holds.
- **A lock the caller holds.** If the code that calls `serve` holds a lock across the call and a
  hook takes the same lock, the hook now waits on another task's lock, and start-up deadlocks. A
  `ReentrantLock` does not help, since it is reentrant per task.
- **Ctrl-C under `Base.exit_on_sigint(false)`.** In a script that sets it, a Ctrl-C during
  start-up now waits for the hooks to return instead of interrupting one that hangs. No code edit
  follows from this one; know it when a start-up hook can hang.

### How to find the calls to migrate

```
grep -rnE 'on_startup' --include=*.jl .
```

For each hook it finds, read the hook's body, and what it calls, for
`task_local_storage`, `@async`, `Timer(`, `threadid()`, and a lock that the code calling `serve`
also holds around that call:

```
grep -rnE 'task_local_storage|@async|Timer\(|threadid\(\)|lock\(' --include=*.jl src/
```

### Migrate your app

```julia
# ✗ before: the hook read state from the task that called `serve`
task_local_storage(:tenant, "acme")
warmup = Nitro.LifecycleMiddleware(middleware = identity,
    on_startup = () -> warm_cache(task_local_storage(:tenant)))
serve(app; middleware = [warmup])

# ✓ after: hand the hook what it needs through its closure
tenant = "acme"
warmup = Nitro.LifecycleMiddleware(middleware = identity,
    on_startup = () -> warm_cache(tenant))
serve(app; middleware = [warmup])
```

```julia
# ✗ before: the caller holds BOOT_LOCK across `serve`, and the hook takes it -> deadlock
lock(BOOT_LOCK) do
    serve(app; middleware = [warmup])   # warmup's on_startup calls lock(BOOT_LOCK)
end

# ✓ after: release it before `serve`, or let only the hook take it
lock(BOOT_LOCK) do
    prepare_boot()
end
serve(app; middleware = [warmup])
```
