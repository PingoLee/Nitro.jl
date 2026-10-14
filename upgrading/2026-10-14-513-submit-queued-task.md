## Workers — `submit_sequential_task` is now `submit_queued_task`, and queue status reports `:current_tasks` (#513)

- **Version**: Unreleased
- **Nitro ref**: [#513](https://github.com/PingoLee/Nitro.jl/issues/513) ;
  `src/Workers/api.jl`, `src/Workers/queue.jl`, `src/Workers/types.jl`
- **Recorded**: 2026-10-14
- **Severity**: **breaking.** `submit_sequential_task` no longer exists (an `UndefVarError`), and
  `get_queue_status` no longer has a `:current_task` key.

### What changed

A declared queue now has a **concurrency**: `queues = ["email", "compute" => 6]` runs up to six
items of `"compute"` at once. A bare name still means one at a time, so an app that declares only
bare names keeps exactly the ordering it had. That is a bulkhead for CPU-bound work: a class of
heavy jobs can never take more than `k` threads, which keeps the rest for request handlers.

Once a queue can run more than one item, "sequential" is the wrong name for it, so the submit
function was renamed, with no alias. Its arguments and behavior are unchanged.

`get_queue_status` reported `:current_task`, the one id a queue was executing, or `nothing`. A
queue with `k > 1` executes up to `k` items at once, so the key is now `:current_tasks`, a
`Vector{String}` that is empty when the queue is idle. `:concurrency` reports `k`.

The unexported internals moved with it: `SequentialQueue` is `WorkerQueue`, and
`get_sequential_queues` is `get_worker_queues`.

### How to find the calls to migrate

```bash
grep -rnE 'submit_sequential_task|SequentialQueue|get_sequential_queues|:current_task\b' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before
submit_sequential_task(app, "reports", "monthly", build_report, Owner(uid))
status = get_queue_status(app, "reports", System())
busy = status[:current_task] !== nothing

# ✓ after
submit_queued_task(app, "reports", "monthly", build_report, Owner(uid))
status = get_queue_status(app, "reports", System())
busy = !isempty(status[:current_tasks])
```
