---
description: Workers module — persistent stores, user_id/watchers, queue authorizers, zombie recovery
applyTo: "src/Workers/**/*.jl,ext/NitroPormGExt.jl,test/**/*worker*.jl,test/extensions/**/*.jl"
---

# Nitro.jl Workers Module

This rule applies when changing the Workers queue, `NitroPormGExt` worker storage, or worker tests.

## 1. Context & Architecture

The worker system supports both volatile in-memory queues and persistent database stores with access control.

### Two objects: the store and the runtime

Split in [#167](https://github.com/PingoLee/Nitro.jl/issues/167). One question decides which one a
change belongs to: **the store answers *"what does the record say?"*; the runtime answers *"what is
this process doing right now?"***.

- **`AbstractWorkerStore`** (`src/Workers/registry.jl`): data access plus policy hooks, 15 required
  methods. It owns **nothing that runs** — no queue, no scheduler, no `Task` handle — which is what
  makes the #29 leak unrepresentable rather than merely fixed.
- **`WorkerRuntime`** (`src/Workers/runtime.jl`): the sequential queues and their processor tasks,
  the cleanup scheduler, and `active_tasks` / `active_task_infos`. `shutdown!` takes one. It is
  parametric on the store type so `rt.store` stays concrete.
- **One store may back several runtimes.** Two `App`s over one `PormGWorkerStore` get their own
  queues and scheduler, and `uninstall!` on one cannot stop the other's processors. Policy stays on
  the store, so they correctly share one security posture.
- **`InMemoryWorkerStore`**: Volatile, thread-safe store in `src/Workers/registry.jl`. Its records
  *are* the objects callbacks hold, so it is the one backend that implements `clear_records!`.
- **`PormGWorkerStore`**: Persistent store in `ext/NitroPormGExt.jl`.
- **Volatile execution handles**: running `Task` objects and the live `TaskInfo` cache live on the
  **runtime**, in `active_tasks` / `active_task_infos`. Entries are keyed by task id but describe one
  **run** — only the run that registered one may tear it down (see §6).
- **Queue authorization hooks**: Optional `queue_authorizer(queue_name, user_id)::Bool`, consulted on
  **both** submit paths — `submit_task` has no sequential queue, so it passes `DEFAULT_QUEUE_NAME`.
- **Watch authorization hooks**: Optional `watch_authorizer(task_key, watchers, user_id)::Bool`,
  consulted only when a caller submits a key that already exists and that they do not already watch.
- **Watchers**: Task submissions register the submitting `user_id` as a watcher. Read/manage APIs validate watcher access when `user_id` is supplied. Watcher membership is the *only* gate on reading a
  result and cancelling, so it is never granted implicitly — see §2.

## 2. Task API

**Every task API takes a required `TaskAuthority`.** `Owner("user_123")` is a validated identity;
`System()` is the explicit, unscoped bypass. There is no arity that omits it — a call that forgets
to scope is a `MethodError`, not a silent bypass
([#48](https://github.com/PingoLee/Nitro.jl/issues/48)). Never re-introduce an optional or
defaulted authority argument, and never let a `String` stand in for one: `user_id=nothing` **and**
`user_id=""` were both full bypasses, and the empty-string case was reachable by reading a missing
claim into an empty string.

**The submit call returns the id, and it is not the `task_key` you passed.** Task ids double as
deduplication keys, so `scope` decides who can collide with whom
([#19](https://github.com/PingoLee/Nitro.jl/issues/19)).

```julia
# scope=:user (the default) — id is "user_123::report_42"; no cross-user collision is possible
task_id = submit_task("report_42", () -> work(), Owner("user_123"))
task = get_task_status(task_id, Owner("user_123"))
cancel_task(task_id, Owner("user_123"))
user_tasks = get_all_tasks(Owner("user_123"))

# Rebuild the id when the return value was not kept
task_id == scoped_task_key("report_42", Owner("user_123"))

# scope=:global — verbatim key, system-wide dedup. A caller who is not already a watcher is
# refused (AuthorizationError) whether the task is live or finished, unless a watch authorizer
# allows it. Finished counts: replacing the record would discard the owner's result.
shared = submit_task("warm-cache", () -> work(), Owner("user_123"); scope=:global)

# The bypass, only when the app intentionally allows it — and greppable because it is named:
public_status = get_task_status(task_id, System())
```

**Grant a second identity at submit time, never after.** `submit_task(...; watchers=[Owner("svc")])`
is the supported way to let a different identity poll or cancel a task
([#96](https://github.com/PingoLee/Nitro.jl/issues/96)) — the owner is already resolved and
authorized there, so no second authorization question arises. Do not add a public post-hoc
`add_watcher!(task_id, ...)`: that would be a second route into the watcher list, which is the
surface [#19](https://github.com/PingoLee/Nitro.jl/issues/19) closed. The store-level
`add_watcher!` performs no authorization and is not that API. A grantee gets read, list **and**
cancel, because `cancel_task` gates on the same list.

**Authority comes from the id; `watchers` only adds to it.** `owner_of(id)` reads the owner half
back out of a `:user` id, so ownership is derived and unclobberable — a lost watcher append or a
full-row write from another process cannot evict an owner from their own task. A `:global` id has
no owner half, so for those `watchers` remains the entire gate, including for the creator. Keep
that asymmetry: it is what makes deriving ownership purely additive.

Never hand-build a scoped id by string concatenation. `Owner` rejects a `user_id` that is empty,
contains `::`, **or ends in `:`**, and `scoped_task_key` rejects a `:global` `task_key` that
contains `::`. Those rules together are what make `(user, key) → id` injective, keep the two
scopes' id spaces disjoint, and make `owner_of` a total inverse; drop any one and two distinct
pairs collide.

### Reporting progress — never assign the field

`TaskInfo.progress` is declared `@atomic`. Plain assignment from a callback throws
`ConcurrencyViolationError`:

```julia
# ✗ throws — violates the @atomic field
task_info.progress = 50

# ✓ the only supported write
update_progress!(task_info, 50)     # 0–100 scale, returns the task
```

The workers tutorial used to show the assignment form
([#54](https://github.com/PingoLee/Nitro.jl/issues/54)); it was corrected alongside the #19 fix. Do
not copy the assignment form from anywhere it survives, and fix it where you find it.

### The rest of the exported surface

`Workers` exports considerably more than the four functions above. The ones worth knowing before
you add anything:

| API | Purpose |
|-----|---------|
| `submit_sequential_task`, `SequentialQueue` | Ordered, one-at-a-time execution within a queue |
| `scoped_task_key`, `DEFAULT_QUEUE_NAME` | Resolve a `(task_key, user_id, scope)` to its stored id; the queue name `submit_task` authorizes against |
| `get_queue_status` | Queue-wide introspection — **admin only**, takes `System()`; an `Owner` is a `MethodError` |
| `update_progress!` | The only safe write to `TaskInfo.progress` |
| `cleanup_old_tasks`, `start_cleanup_scheduler`, `stop_cleanup_scheduler!` | Retention |
| `shutdown!`, `reset_runtime!` | Teardown — takes a `WorkerRuntime`, never a store. Both take `drain_timeout`; `shutdown!` defaults to `WORKER_DRAIN_TIMEOUT_SECONDS`, `reset_runtime!` to `0` |
| `WorkerRuntime`, `default_runtime`, `worker_runtime`, `install!`, `uninstall!`, `worker_store`, `default_store` | Lifecycle and resolution. An App-first call on an App with no runtime throws `WorkerUnavailableError` (a 503) and never falls back to `default_runtime()`, which carries none of the app's policy; `worker_startup(app; …)` installs when it is *built*, ahead of the listener; the bare `worker_startup()` runs `default_runtime()` and refuses `store=`/`runtime=` ([#322](https://github.com/PingoLee/Nitro.jl/issues/322)) |

**`runtime=` is the public keyword; `store=` only selects a backend.** Every read and submit call
takes `runtime::WorkerRuntime=default_runtime()`, or resolves one from an `App` first argument.
`store=` survives on exactly four entry points — `install!`, `start!`, `startup`, `worker_startup`
— because that is where a backend is *chosen*. A `store=` on a submission call would be a lie: a
store cannot run anything.

**A new backend implements no teardown method at all.** `shutdown!` is a concrete method on
`WorkerRuntime`, so there is no fallback to forget — which is what closes
[#29](https://github.com/PingoLee/Nitro.jl/issues/29) as a *class* rather than an instance. Two
optional store methods exist, and neither is a `WORKER_STORE_INTERFACE` row, so `missing_store_methods`
never lists them:

- `clear_records!`: volatile backends only. `reset_runtime!` calls it, and the default must stay a
  no-op so a reset can never delete durable rows.
- `list_running_task_refs`: the zombie-recovery scan
  ([#236](https://github.com/PingoLee/Nitro.jl/issues/236)). The default derives it from
  `get_all_tasks`, which is correct but deserializes every `RUNNING` record in full. A serializing
  backend implements it as a projection of `id`, `run_id` and `started_at`. It must **rethrow** a
  read failure: an empty result means "nothing to recover", so a swallowed error would pass for a
  clean sweep.

**`get_all_tasks` rethrows a failed read too, paged or not; it skips an undecodable row alone**
([#267](https://github.com/PingoLee/Nitro.jl/issues/267)). The unpaged PormG listing used to
swallow every error into `TaskInfo[]`, so one bad `result` blob emptied the admin and user
listings. A row that does not decode is now dropped by itself, before the authority gate. Schema
drift (no `run_id` column) is not a bad row, and it still throws. JSON.jl quotes the stored text
around a parse failure, so its message carries part of a `result` or a session payload. Two
guarantees keep that text out of logs, and both stay:
- **At the source**, `_parse_stored_json` replaces the parse error with a value-free one, thrown
  *after* the `catch` so the original is not on the exception stack. That is what protects the
  rethrow path, because a request handler's error logger prints a message in full.
- **At each warning**, the listing, `get_task_info` and the session decode log the exception type
  and task id, never the message.

**`get_task_info(store, id)` is the DURABLE read.** A store must not cache live objects. Serving a
running callback's own object to a reader is `get_task_info(runtime, id)`, and the split is
load-bearing: run-start reads durably, because a live-preferring read there hands a re-run its
predecessor's `TaskInfo` and the `run_id` fence then strands it at `PENDING` forever. That was a
real `PormGWorkerStore` defect (#167). The rule: **a call about to *claim* a run reads the store; a
call that is *reporting* reads the runtime.**

## 3. Database Persistence

Configure PormG, then bootstrap the store:

```julia
# db_key defaults to "db"; "workers" below is an explicit override, not the default.
persistent_store = pormg_nitro_worker(db_key="workers")
app = App(mod = @__MODULE__)
serve(app; middleware=[worker_startup(app; queues=["reports"], store=persistent_store, recover_zombies=true)])
```

## 4. Queue And Watch Authorization

Two independent store hooks. Both are `Ref{Any}` slots invoked through `Base.invokelatest`; a
`nothing` authorizer disables the queue check and **denies** every cross-user watch.

```julia
# Gates submission. Runs on both submit paths — submit_task passes DEFAULT_QUEUE_NAME
# ("default"), so an allowlist authorizer must permit it or submit_task is closed to everyone.
function my_queue_authorizer(queue_name::String, user_id::String)::Bool
    queue_name == "maintenance" && return user_id == "admin-user"
    return true
end
set_queue_authorizer!(persistent_store, my_queue_authorizer)

# Gates joining or reusing an existing key the caller does not already watch.
# `watchers` is a copy. The hook runs under the store's task lock, which also
# serializes set_task!, cancel_task, and zombie recovery — so make it a pure
# in-memory predicate. No DB queries, and never `fetch` a spawned task that
# touches the same store: the child cannot take a ReentrantLock its parent
# holds, so that deadlocks.
set_watch_authorizer!(persistent_store, function(task_key, watchers, user_id)
    return ORG_OF[first(watchers)] == ORG_OF[user_id]
end)
```

The hook is store-wide, not per-scope: it fires on *any* collision with an existing key.
In practice the id rules above make that unreachable for `:user` ids — a foreign caller
cannot produce one — so it governs `:global` keys and app-written records only. Re-running
a finished key replaces the record, so its watcher list resets to the submitter and
previously-authorized sharers must be re-approved.

A new backend must implement `get_watch_authorizer` / `set_watch_authorizer!` alongside the queue
pair — see §6.

## 5. Zombie Task Recovery

On startup, `RUNNING` tasks without a live in-memory `Task` are marked `FAILED` when `recover_zombies=true`.

Since [#176](https://github.com/PingoLee/Nitro.jl/issues/176) that criterion is correct rather than
conditionally correct: a teardown no longer manufactures zombies out of runs that are still
executing. The window is narrower, not gone — run handles are per-runtime, so a restart that builds
a **new** `WorkerRuntime` over the same store still sweeps the previous one's abandoned runs. That
is also what keeps a genuine process crash recoverable.

**The sweep is bounded, and paged listings are keyset in SQL**
([#236](https://github.com/PingoLee/Nitro.jl/issues/236),
[#237](https://github.com/PingoLee/Nitro.jl/issues/237)). It reads `list_running_task_refs`, a
three-column projection, never the listing, and walks it `ZOMBIE_SWEEP_BATCH` records at a time
under one `lock_tasks`.

Paging is keyset on the id (`id > after ORDER BY id LIMIT n`), never offset: the sweep moves every
row it adjudicates out of `RUNNING`, so an offset page would skip rows.

A database backend pages **in SQL and never re-sorts in Julia**. `ORDER BY` and `>` share the
column's collation, which on a non-C PostgreSQL collation is not Julia's codepoint order. That is
why the paged `Owner` listing is one `Qor` query and not the unpaged path's two legs merged in
Julia.

A paged method returns fewer than `limit` only when nothing is left. A row it skips, whether
through the authority gate, an undecodable blob, or an unparseable `run_id`, is made up from past
the cursor.

**A `RUNNING` row whose `run_id` does not parse is skipped forever, by decision**
([#267](https://github.com/PingoLee/Nitro.jl/issues/267)). It gets an ids-only warning on every
boot, and retention never retires it. Only a hand edit or an app-side write produces one, since
pre-#108 rows are backfilled with the nil UUID, which parses. Do not "fix" it with an unfenced
(`run_id = nothing`) FAILED write. `lock_tasks` is process-local, so if another process has
already failed the row and the key was re-run, the stale unfenced write fails the live successor,
which is the #108 defect. The operator repairs the row.

**`zombie_min_age` bounds OLD claims in, never recent ones**
([#239](https://github.com/PingoLee/Nitro.jl/issues/239)). It is a keyword on `start!` / `startup`
/ `recover_zombie_tasks!`, `nothing` by default. The sweep then adjudicates only records whose
`started_at` is older than `now - zombie_min_age`; a NULL `started_at` is always eligible. The
opposite bound ("only recent claims") would strand every old record `RUNNING` forever, and retention
never retires those, since it needs a `completed_at`.

The filter runs **in Julia over the projected `started_at`**, not in SQL, so a row it excludes is
still seen and counted. Do not "optimize" it into the query without keeping that count.

**With a bound, the retention tick re-runs the sweep; without one, it never does**
([#266](https://github.com/PingoLee/Nitro.jl/issues/266)). `start!` passes `zombie_min_age` to
`start_cleanup_scheduler` when `recover_zombies` is on, and every tick then runs the bounded
sweep **before** retention, each in its own `try`, so a throw costs one sweep one tick. That is
what picks up the claims the boot sweep counted `too_recent`, within `zombie_min_age +
cleanup_interval_hours`. It needs `cleanup_enabled`, because there is no separate interval or
second janitor.

Do not make the tick's sweep unconditional. Liveness is process-local, so an unbounded sweep on a
timer marks another process's live runs `FAILED` on every tick, and a single process gains nothing
from it, since its boot sweep already took everything. It is safe in the running runtime because
`_claim_run!` publishes a run's handle before its RUNNING claim, so this runtime's own runs are
always `spared_live`.

**The boot sweep's completion line is unconditional**
([#238](https://github.com/PingoLee/Nitro.jl/issues/238)). `"Nitro.Workers: scanning for zombie
tasks"` goes out before `lock_tasks`, and `"… zombie recovery complete"` goes out after, with
`recovered = 0` included. On a read failure, an `@error` carrying the same counts replaces it. The
sweep runs after the banner and before the first request, which is the window where silence cost an
incident, so never make that line conditional. Counts only, never a `result` or `error` payload.

The **periodic** re-sweep (#266) is the one exception, and it follows the retention tick's rule
instead: `@info` only when `recovered > 0`, `@debug` otherwise, and `@error` on failure. An
unconditional pair on a caller-supplied interval is noise. `_recover_zombie_tasks!`'s `periodic`
flag changes only the logging: the log levels, plus a write failure being logged once and then
absorbed rather than rethrown. The tick carries on either way, so a rethrow would only log it
twice. Keep the flag out of every adjudication, so the two sweeps cannot drift apart in what they
decide.

## 6. Developer Rules

> **Strict core isolation**: Never import `PormG` or run DB queries in `src/Workers`. Database logic belongs in `ext/NitroPormGExt.jl`.

- **`lock_tasks` is process-local, so never build a read-modify-write on it.** For a
  database-backed store it is a plain `ReentrantLock` in the struct: two processes sharing one
  database each take their own and neither sees the other
  ([#88](https://github.com/PingoLee/Nitro.jl/issues/88)). A write that must not lose a concurrent
  update belongs in the store as a single atomic *intent* operation — `add_watcher!` (a
  compare-and-set on the stored document) and `try_transition!` (a conditional status change) are
  the pattern. Composing `get_task_info` + mutate + `set_task!` under the lock is exactly the bug.
- **`set_task!` writes state; `replace_task!` writes the whole record.** `set_task!` must never
  write `watchers` **or `run_id`** — neither is volatile state, and carrying them on every
  transition is how grants got clobbered. `replace_task!` has exactly one caller: re-running a
  finished key, which by design resets the watcher list and publishes the new run's identity.
- **A terminal write is addressed to a RUN, not to a task id.** A task id outlives the run writing
  under it: re-running a finished key builds a fresh record while the previous run may still be in
  flight, and a status-only precondition cannot tell the two apart
  ([#108](https://github.com/PingoLee/Nitro.jl/issues/108)). `try_transition!` therefore takes a
  **required** `run_id` — `nothing` is the named opt-out, never a default — and so does the runtime
  handle teardown: only the run that owns the runtime's `active_tasks[id]` may deregister it,
  because `recover_zombie_tasks!` reads liveness from exactly that entry. One `TaskInfo` object is
  one run; a re-run is a new object, never a mutated one.
  - **A write that fences on a run it just re-read is not fenced.** `_abandon_queued_item!` (#182)
    writes a terminal state for a task that never started, and re-reading the record to get a
    `run_id` would agree with whatever currently owns the key — precisely the successor the fence
    exists to spare. So `QueueItem` carries the `run_id` `_register_or_watch!` minted for it. The
    rule generalises: a fence value must come from *before* the window it guards, never from
    inside it.
- **`shutdown!` drains, within a bound, and releases only what settled**
  ([#176](https://github.com/PingoLee/Nitro.jl/issues/176)). It sets every in-flight run's
  cancellation token **first**, waits up to `drain_timeout` seconds, then deletes the handles of
  runs that finished — **fenced on `run_id`**, because that window is seconds wide and a re-run can
  publish a successor inside it; an id-keyed delete there is the #108/#167 defect through a wider
  door. A run that outlives the wait **keeps its handle**, which is what stops
  `recover_zombie_tasks!` declaring a live run dead; `_finish_task!` reclaims it when the callback
  returns. The sweep touches `active_tasks` only — `active_task_infos` stays populated, or a run
  outliving a teardown would be uncancellable.
  - **A teardown stops the queues FETCHING before it drains the runs**
    ([#182](https://github.com/PingoLee/Nitro.jl/issues/182)). Closing a channel only stops
    submissions; the processor kept working through the buffer, so a teardown started runs that
    were never in the snapshot — no token, no wait, `RUNNING` rows nothing awaited. `shutdown!` now
    sets `queue.draining`, closes, **collects the buffer**, and records every collected item
    `CANCELLED` / `"Cancelled by worker shutdown"`. Three rules hold it together:
    - **`draining` lives on the `SequentialQueue`, never on the `WorkerRuntime`.** A runtime-level
      flag would need resetting for the documented shutdown-then-reuse case, and the reset races a
      concurrent submit. `shutdown!` empties the registry, so a reused runtime mints queues that
      are not draining *by construction*.
    - **Set `draining` → close → collect, in that order.** `put!` on a closed channel throws, so
      collecting after the close is airtight; collecting first leaves a window for a submit.
    - **The abandon write happens OUTSIDE `queue_lock`.** It is a store write, and the processor
      takes the store lock (`_finish_task!`) and then `queue_lock` (its `finally`) — holding
      `queue_lock` across a store write is that pair inverted. One `lock_tasks` for the batch.

    It is **unconditional, including at `drain_timeout = 0`**: that keyword means *do not wait*,
    and abandoning a backlog costs no wait. It is the one respect in which `0` is no longer
    byte-for-byte pre-#176. The return value is unaffected — it still means *did every in-flight
    run settle*, and abandoned items are terminal before it returns.
  - **In `_run_settled`, the info clause is what terminates every production wait; `istaskdone` is
    a backstop.** A real run clears both caches through `_deregister_run!` *before* its task
    completes, so for anything `register_run!` published, clause 2 always fires first — on the
    async path as much as the sequential one. On the sequential path it is also *necessary*, since
    the registered handle is the shared queue processor and `istaskdone` on that is false until the
    whole backlog has drained; narrowing the predicate to `istaskdone` alone stalls every
    sequential teardown for the full window. `istaskdone` decides only for a handle whose info
    nothing will ever remove — the test-only `register_active_task!` + `register_active_task_info!`
    pair, where clause 2 is permanently false — and it is what gates the delete in
    `_release_settled_handles!`.
  - **`reset_runtime!` defaults to `drain_timeout = 0`**, unlike every other teardown entry point.
    A reset erases the live cache and the volatile records, so waiting for an outcome it is about
    to delete buys nothing — and it keeps `resetstate()` and every test `finally` off the drain
    path.
  - **The drain's budget is not the call's.** `stop_cleanup_scheduler!` waits without a deadline
    and runs first, and a closed sequential queue keeps executing its buffered backlog, starting
    runs that were never in the snapshot. Say so rather than implying `drain_timeout` bounds
    teardown.
  - **Hold no lock across the wait.** `active_lock` deadlocks against `_deregister_run!`, which is
    how a run settles; `queue_lock` is re-acquired by the processor's own `finally`. The predicate
    runs in a `Timer` callback, so it must stay cheap, total, and store-free.
- Add abstract stubs in `src/Workers/registry.jl` — **for data and policy only.** Anything that
  runs, schedules, or holds a `Task` belongs on `WorkerRuntime`, where there is one implementation
  and no way for a backend to get it wrong.
- Implement in `InMemoryWorkerStore` **and** `PormGWorkerStore` — a hook implemented in only one of
  them is a store that silently behaves differently, which for the authorizer pair means a silently
  different security posture. Assert cross-backend parity in a shared test body rather than by
  inspection: #166's cancellation regression came from two backends whose live-object handling
  looked equivalent and was not.
- **Nothing may inject an exception into a worker task.** `schedule(t, exc; error=true)` does
  not check whether `t` is running, and injecting into a task executing on another thread aborts
  the process in `jl_finish_task` — which is what blocked worker bodies from moving to
  `Threads.@spawn` ([#127](https://github.com/PingoLee/Nitro.jl/issues/127),
  [#30](https://github.com/PingoLee/Nitro.jl/issues/30)). Cancellation is a **token** the callback
  polls (`cancel_requested`). Four things set it — `cancel_task` (`:user`), an expired
  `TaskOptions(timeout=…)` (`:timeout`), `_register_or_watch!` displacing a still-executing
  predecessor on a re-run (`:superseded`), and a teardown drain (`:shutdown`, the `shutdown!`
  bullet above, #176) — and since
  [#183](https://github.com/PingoLee/Nitro.jl/issues/183) the token **carries which**. Never
  reintroduce the injection, and do not add a public setter for the token: `cancel_task` is the
  authorized path, and a second route into it would bypass both the authorization check and the
  status CAS — those four are not that route, because none of them takes a caller-supplied
  identity. The token is process-local and never reset — a re-run gets a fresh `TaskInfo`.
  - **The reason IS the token — `@atomic cancel_reason::Symbol`, `:none` for "not cancelled".**
    Not a second field beside a `Bool`, because two atomics need every setter to write
    reason-before-flag or a reader sees a set token with no cause, and a convention across four
    sites plus every future one is not a shape a test can hold. `cancel_requested(t)` is exactly
    `cancel_reason(t) !== :none`.
  - **`_request_cancel!` is the only writer, it is private, and the FIRST cause wins.** It is a
    CAS off `:none`, not an assignment: a drain fires on every in-flight run at once, so
    last-write-wins would make a shutdown the likeliest final writer and would overwrite a
    person's cancel. Keep it unexported — a public setter for the reason would be exactly the
    second route into the token the bullet above forbids.
  - **`_cancel_task!` renders the stored message from the reason and takes no `message`.** That
    parameter is what let `api.jl` and `queue.jl` record different text for one event; deleting it
    is why they cannot diverge again. Add a new cause to `CANCEL_REASONS` and `_cancel_message`
    together, never a new string at a call site.
- **A drain writes no terminal state of its own, but it still decides one.** `cancel_task` claims
  `CANCELLED` before setting the token and an expired deadline throws; a drain claims nothing,
  because a terminal write there would race the run's own — the #88/#108 failure mode. What the run
  then records is its own doing: `COMPLETED` with whatever it returns, `FAILED` if it throws with
  no retry left, **or `CANCELLED` if the token lands while it is parked in the retry backoff**,
  which polls the same token. Reaching a terminal state there is right — better than a job
  restarting mid-teardown — and since #183 the record says so: the drain sets `:shutdown`, so that
  run stores `"Cancelled by worker shutdown"` on **both** submit paths. Do not "fix" the race by
  pre-claiming a status from the drain; the provenance rides on the token, which is what #183 did.
  - Before #183 this stored `"Cancelled by user"` on the async path and `"Cancelled"` on the
    sequential one — and the string naming a user was reachable *only* from a shutdown, since
    every other cause either claims the record first or loses the `run_id` fence, leaving the
    run's own write to lose its CAS. Worth remembering when reading pre-#183 records: there, a
    `CANCELLED` task whose error says "by user" was almost certainly a deploy.
- **A timeout bounds the wait, not the work, and is never retried.** Nothing stops the attempt
  that timed out, so retrying it runs a second copy of the callback beside the first against one
  `task_info`. `TaskTimeoutError` is terminal on the first attempt.
- **Never serialize running `Task` objects** to the database.
