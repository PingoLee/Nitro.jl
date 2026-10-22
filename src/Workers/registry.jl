"""
    AbstractWorkerStore

The storage contract behind Nitro's worker queue. Two backends ship — [`InMemoryWorkerStore`](@ref)
and `PormGWorkerStore` (in `NitroPormGExt`) — and an application may add its own.

Every method below is **required**. Each has a fallback defined on this abstract type that raises
`StoreInterfaceError` naming the missing method, so an incomplete backend fails with a message
saying what to implement rather than a bare `MethodError` from deep inside task execution.
[`missing_store_methods`](@ref) lists what a type still owes and is the intended conformance check
for a backend's own test suite:

```julia
using Nitro.Workers    # the contract names are not re-exported from `Nitro`
@test isempty(missing_store_methods(MyWorkerStore))
```

# Durable task records

| Method | Contract |
|---|---|
| `get_task_info(store, task_id::String)` | The **durable** record: `TaskInfo` or `nothing`, see *Live objects* |
| `set_task!(store, task_id::String, task_info::TaskInfo)` | Write volatile state; must never write `watchers`, `run_id`, the claim fields, or `job_name`/`job_args` |
| `replace_task!(store, task_id::String, task_info::TaskInfo)` | Write the whole record, `watchers`, `run_id`, the claim fields and `job_name`/`job_args` included |
| `add_watcher!(store, task_id::String, user_id::String)` | Atomic compare-and-set append, returns `Bool` |
| `try_transition!(store, task_id::String, from, to::TaskStatus; run_id, …)` | Atomic conditional status change, returns `Bool` |
| `delete_task!(store, task_id::String)` | Remove one record |
| `try_delete_task!(store, task_id::String, from; run_id)` | Atomic conditional removal, returns `Bool` |
| `cleanup_tasks!(store, retain_days::Int)` | Prune finished records, returns how many went |
| `get_all_tasks(store, authority::TaskAuthority; status, queue_name, after, limit)` | `Vector{TaskInfo}`; see *Paging* |

## Paging

`after::Union{Nothing,String}` and `limit::Union{Nothing,Int}` page the listing by keyset on the
id ([#237](https://github.com/PingoLee/Nitro.jl/issues/237)): ids strictly greater than `after`,
**in id order**, at most `limit`. Paging is applied **after** the authority gate, so a page holds
fewer than `limit` records only when nothing is left. Neither keyword set means the whole listing,
in any order, exactly as before.

A database backend pages **in SQL** and must not re-sort in Julia. Its `ORDER BY id` and its
`id > after` use the column's collation, which is not Julia's codepoint order on, say, an
`en_US` PostgreSQL database. A Julia-side merge would then disagree with the next page's
cursor and skip rows.

The paging keywords are opt-in for a backend too. [`WorkerRuntime`](@ref) forwards them only when
the caller set one, so a store written before them keeps serving every unpaged call.

**A failed read must throw, paged or not** ([#267](https://github.com/PingoLee/Nitro.jl/issues/267)).
A caller reads an empty listing as "no tasks" and a short page as the end, so a store that
swallows a read error into an empty result reports a false fact. A serializing backend **may**
skip one record it cannot decode, so a single bad row does not cost the whole listing. It then
logs the task id and the exception *type* only: a parse error's message quotes the stored text,
which is a task's `result`. A skipped record counts like one the authority gate dropped, so a
page is still short only when nothing is left.

# Application hooks

Each is a plain slot the application writes and the framework reads through `Base.invokelatest`.

| Method | Contract |
|---|---|
| `get_queue_authorizer(store)` / `set_queue_authorizer!(store, f)` | `f(queue_name::String, user_id::String)::Bool`, or `nothing` |
| `get_watch_authorizer(store)` / `set_watch_authorizer!(store, f)` | `f(task_key, watchers, user_id)::Bool`, or `nothing` |
| `get_error_redactor(store)` / `set_error_redactor!(store, f)` | `f(exception, rendered)::String`, or `nothing` |

# Locking

| Method | Contract |
|---|---|
| [`task_locks`](@ref)`(store)` | The store's own [`TaskLocks`](@ref), constructed once with it and returned on every call |

A store does not implement any locking itself: it holds one `TaskLocks` and hands it out. Nitro
takes it for each section that orders an in-process writer of one task id
([#711](https://github.com/PingoLee/Nitro.jl/issues/711)), so the lock is the **store's** —
two runtimes over one store contend on it — while two sections on different ids do not contend.

# What a store is NOT asked for

Nothing here runs, schedules, or holds a handle to a live `Task`. The declared queues and their
processor tasks, the cleanup scheduler, and the process-local run handles belong to
[`WorkerRuntime`](@ref) ([#167](https://github.com/PingoLee/Nitro.jl/issues/167)) — so a backend
cannot leak them by forgetting a teardown method, which is what
[#29](https://github.com/PingoLee/Nitro.jl/issues/29) was. There is no `shutdown!` to implement.

Two optional methods exist, and neither is in the table above because each has a working default:

- `clear_records!(store)`, which [`reset_runtime!`](@ref) calls. The default is a no-op. Only a
  volatile backend should implement it — for a durable one the registry is rows that outlive the
  process, so the no-op default is the safe direction.
- [`list_running_task_refs`](@ref)`(store)`, the zombie-recovery scan. The default derives it from
  `get_all_tasks`, which is correct but deserializes every `RUNNING` record in full; a serializing
  backend should implement it as a projection
  ([#236](https://github.com/PingoLee/Nitro.jl/issues/236)).

# Claims (an optional capability)

What a queue run by a **separate consumer process** needs from the store
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)): picking a submission, holding it for a
bounded time, and taking it back. A store that does not implement these is still a conforming
store; it just cannot back an external queue. [`missing_claim_methods`](@ref) lists what a type
still owes for this capability, and `missing_store_methods` does not include them.

| Method | Contract |
|---|---|
| [`claim_next!`](@ref)`(store, queue_name, consumer_id; lease_seconds, now)` | Atomically claim the oldest external `PENDING` submission of a queue as a new run, or `nothing` |
| [`renew_leases!`](@ref)`(store, consumer_id, runs; lease_seconds, now)` | Extend the leases a consumer holds, returns the run ids that are still its own |
| [`release_claim!`](@ref)`(store, task_id, run_id; policy, now)` | Hand a claim back to `PENDING` as a new run, or record it `FAILED` at its queue's attempt bound, returns `Bool` |
| [`requeue_expired!`](@ref)`(store, now; policies, on_unknown_queue)` | Adjudicate every expired lease by its queue's [`LeasePolicy`](@ref), failing or skipping one on a queue `policies` does not name, returns counts |
| [`count_external_runs`](@ref)`(store, statuses; queue_name, submitter)` | Count external submissions, for the submit-time bounds of an external queue |

The first four are each one atomic intent operation in the store, like `try_transition!`: a
database backend expresses it in fenced statements, never as a read-modify-write under
`lock_tasks`, which is process-local. **Never call them under `lock_tasks`**: a database
transaction can take a lock of its own, and an order that differs from the request path's is a
deadlock. `count_external_runs` is the exception: it is a plain read, like `get_task_info`, and the
submit path calls it under `lock_tasks`, where it decides to mint a run.

# Obligations that are not methods

- **Live objects.** `get_task_info` is the **durable** read and is free to reconstruct a fresh
  object every time; a store must *not* cache live ones. Serving a running callback's own object
  to a reader is [`WorkerRuntime`](@ref)'s job, and doing it here instead breaks run-start, which
  needs the durable record to fence its own transition (#167).

  `InMemoryWorkerStore` is not an exception: its records simply *are* the objects callbacks hold,
  because it stores whatever it is handed.
- **`run_id` round-trips, but `try_transition!` never writes it.** It is a precondition, not state.
  A fresh one is published only by `replace_task!` (a new submission) and by the claim operations
  (a new run of the same submission), each in the same atomic step as the write it identifies.
  See [`TaskInfo`](@ref).
- **`watchers` is populated on every read path.** Authorization reads it off whatever
  `get_task_info` returns, so a store that omits it silently denies everyone.
- **`TaskLocks` is process-local.** For a database-backed store it guards this process only, so
  never build a read-modify-write on it; express such a write as a single atomic store operation.

# `TaskInfo.error` is application-controlled free text

A failed task's `error` is rendered from the exception the **application's** callback threw. If that
callback interpolates user data into an exception message, that data reaches this store. Nitro
bounds the text and offers a redaction hook — see `set_error_redactor!` — but the store is where it
lands, so a backend that persists it is persisting attacker-influenceable input.
"""
abstract type AbstractWorkerStore end

# -- Storage and Registry interface functions (Abstract protocols) --
function get_task_info end

"""
    set_task!(store, task_id::String, task_info::TaskInfo)

Persist a task's **volatile runtime state**: status, progress, result, error, timestamps.

**It must not write `watchers` or `run_id`.** Neither is volatile state, and a store that
carries them along on every state transition loses them: `PormGWorkerStore` rewrote the whole row
on each save, so a task completing in one process clobbered a watcher another process had
appended since that process last read the row
([#88](https://github.com/PingoLee/Nitro.jl/issues/88)). State transitions are far more
frequent than watcher appends, so this was the dominant way a grant went missing.

`run_id` is excluded for a second, sharper reason: it is the precondition
[`try_transition!`](@ref) fences terminal writes with, so a `set_task!` that carried it would let a
re-run's identity be overwritten by whichever run wrote last — defeating the mechanism entirely
([#108](https://github.com/PingoLee/Nitro.jl/issues/108)).

The claim fields — `claimed_by`, `lease_expires_at`, `attempt` — are excluded for the same reason
as `run_id`: they describe the current claim, which only the claim operations may change, and a
state save carrying a stale copy would hand a run back its predecessor's lease. `external` is
identity of the submission and is never rewritten either.

Use [`add_watcher!`](@ref) to add a grant and [`replace_task!`](@ref) to write a whole
record, watchers and run id included.

The return value is **unspecified** — a store may return the caller's object or the record
it holds. Do not rely on it, and do not rely on it being the same across backends.
"""
function set_task! end

"""
    replace_task!(store, task_id::String, task_info::TaskInfo)

Write a task record **in full, `watchers`, `run_id`, `external` and the claim fields included**,
replacing whatever is stored.

The counterpart to [`set_task!`](@ref), and the only sanctioned way to reset a watcher
list — or to publish a new **submission's** identity. There is exactly one caller: re-running a
*finished* task key, which by documented design replaces the record and resets its watchers to the
resubmitter. The new submission's `TaskInfo` has never been claimed, so writing its claim fields
resets them too: a key re-run after an external run does not inherit that run's `attempt` count.

A new run of the **same** submission is published by the claim operations instead (see
[`claim_next!`](@ref)), which keep `created_at`, the watchers and the attempt count.

A store that cannot distinguish this from `set_task!` has not implemented `set_task!`
correctly — the whole point of the split is that ordinary saves leave grants alone.
"""
function replace_task! end

"""
    add_watcher!(store, task_id::String, user_id::String) -> Bool

Grant `user_id` watch access to `task_id`. Returns `true`, or `false` when no such task
exists. Idempotent.

**This is an atomic intent operation, and implementing it as read + `push!` + `set_task!`
defeats its purpose.** `_register_or_watch!` used to compose it exactly that way under
`lock_tasks`, which for a database-backed store is a *process-local* `ReentrantLock`: two
processes sharing one database each took their own and neither saw the other, so the
read-modify-write was last-write-wins and an append could vanish
([#88](https://github.com/PingoLee/Nitro.jl/issues/88)). A backend must make this a single
atomic step against its own storage — a compare-and-set, a conditional update, or a lock
the storage engine itself honours.

Performs **no** authorization. The authorized public path for granting access is the
`watchers=` keyword on `submit_task` / `submit_queued_task`.
"""
function add_watcher! end

"""
    try_transition!(store, task_id::String, from, to::TaskStatus;
                    run_id, error=nothing, completed_at=nothing) -> Bool

Move `task_id` from any status in `from` to `to`, atomically. Returns `true` if this call
made the transition, `false` if the task was absent, had already left `from`, or belongs to a
run other than `run_id` — in which case **nothing was written**.

The compare-and-set counterpart to `set_task!` for the one write where losing the race
matters: cancellation. `cancel_task` used to read the status, decide, and then save the
whole record under `lock_tasks`; against a shared database that lock does not span
processes, so a task completing in one process could overwrite a cancellation another
process had just recorded ([#88](https://github.com/PingoLee/Nitro.jl/issues/88)).

`from` is any iterable of `TaskStatus`. Like `set_task!`, this must not write `watchers` or
`run_id` — it *compares* the latter, it never sets it.

It is not only for terminal states. **Starting** a task is a claimed transition too
(`(PENDING,) → RUNNING`, carrying `started_at`), because an unconditional start write can land
*after* a cancellation that already claimed the record and silently undo it
([#142](https://github.com/PingoLee/Nitro.jl/issues/142)).

A start claim is therefore fenced on the same terms as a terminal one, and the `run_id` it passes
must name the run the caller **intends to start** — never the one it just read back. Reading the
record and fencing on what comes back is not a fence at all: it agrees with whoever currently owns
the key, which is exactly the successor the caller must be distinguished from
([#191](https://github.com/PingoLee/Nitro.jl/issues/191)).

# `run_id` — the precondition names a run, not just a status

A task id outlives the run writing under it. Re-running a finished key replaces the record with a
fresh `PENDING` one ([`replace_task!`](@ref)) while the previous run's worker task may still be in
flight; its terminal write then satisfies `status in (PENDING, RUNNING)` against a record it never
ran, and stamps its stale result onto the new run
([#108](https://github.com/PingoLee/Nitro.jl/issues/108)).

`run_id` is therefore **required, with no default**. Passing `nothing` is legal and means "no run
precondition — write whichever run owns the record", but you have to write it. A default would
rebuild the shape [#48](https://github.com/PingoLee/Nitro.jl/issues/48) removed: the unfenced call
would be the *shorter* one, and a new terminal-write call site that merely forgot the keyword would
be indistinguishable in review from one that meant to skip the fence.

A store that accepts `run_id` and ignores it is **not a conforming store** — it reintroduces #108
for its own backend, exactly as a store that reads the status and then saves reintroduces #88. An
un-updated third-party store fails loudly instead — but by a different route than you might expect,
so it is worth stating exactly.

A stale store whose `try_transition!` still takes the *other* keywords wins dispatch normally and
rejects `run_id` itself, with Julia's "does not support all of the given keyword arguments". A
stale store whose method has **no keyword parameters at all** is invisible to keyword dispatch —
Julia only considers methods that accept keywords — so the call reaches the contract fallback
instead. `store_contract_error` recognizes that the store did implement the method and raises a
`MethodError` carrying the positional arguments rather than mislabelling the backend as
unimplemented. Both routes throw; neither silently accepts a call that would reintroduce #108.

The second route's message is the one to be careful with. It cannot name `run_id`, because a
`MethodError` built from positional arguments has no keywords to report — and Julia appends *"This
error has been manually thrown, explicitly, so the method may exist but be intentionally marked as
unimplemented"* to any hand-built `MethodError`, which reads as a flat contradiction of the
situation: the method does exist, and the problem is a keyword it cannot accept. If you are
diagnosing one of these, check for a missing `run_id` parameter before believing that sentence.
"""
function try_transition! end

function delete_task! end

"""
    try_delete_task!(store, task_id::String, from; run_id) -> Bool

Remove `task_id` only while its status is in `from` and its record belongs to `run_id`, as one
atomic step. Returns `true` if this call removed it, and `false`, having removed **nothing**, if
the task was absent, had left `from`, or belongs to another run.

It is the delete counterpart of [`try_transition!`](@ref), and it exists for the same reason:
`lock_tasks` is process-local, so reading a record, checking it, and then calling
`delete_task!` is a read-modify-write that another process can interleave. Between the
check and the delete, another node can re-run the key, and an unfenced delete then removes the
successor's fresh `PENDING` record, whose run never starts. Its one caller is
[`release_task!`](@ref) ([#323](https://github.com/PingoLee/Nitro.jl/issues/323)).

`run_id` is **required, with no default**, on the terms `try_transition!` sets out: `nothing` is
the named opt-out, never the shorter call.
"""
function try_delete_task! end

function cleanup_tasks! end
function get_all_tasks end

"""
    RunningTaskRef

What zombie recovery needs to know about one `RUNNING` record, and nothing more: its `id`, the
`run_id` a fenced [`try_transition!`](@ref) is addressed to, the `started_at` its run claimed
it at (`nothing` when the record carries none), and the `claimed_by` of a run a consumer process
holds under a lease (`nothing` for a run some process is executing as its own).

`claimed_by` was added by [#514](https://github.com/PingoLee/Nitro.jl/issues/514): a leased run's
liveness is its lease, not a handle in any process, so the sweep must leave it alone. Build a ref
by name, `RunningTaskRef((id = …, run_id = …, started_at = …, claimed_by = …))`; the sweep still
accepts a ref without the field, as an unleased run.
"""
const RunningTaskRef = @NamedTuple{id::String, run_id::UUID, started_at::Union{Nothing, DateTime},
                                   claimed_by::Union{Nothing, String}}

_running_ref(task::TaskInfo) = RunningTaskRef((task.id, task.run_id, task.started_at, task.claimed_by))

# -- Keyset paging (#237) --
#
# `after` is a cursor on the task id and `limit` a page size, and a page means
# `id > after ORDER BY id LIMIT limit`. Keyset, never offset: an offset counts rows, and the
# rows a scan is working through change underneath it -- zombie recovery moves every row it
# adjudicates out of `RUNNING`, so an offset page would skip a row per transition. A cursor on the
# primary key is unaffected by rows leaving the result set behind it.

# Validates, and answers "is this a paged call?".
function _check_page(after::Union{Nothing, AbstractString}, limit::Union{Nothing, Integer})
    limit === nothing || limit >= 1 || throw(ArgumentError("`limit` must be at least 1, got $limit"))
    return after !== nothing || limit !== nothing
end

# A page of records already in hand: what a database does with `id > after ORDER BY id LIMIT n`.
# Only for stores whose records ARE in hand. A database store must page in SQL, and must not
# re-sort in Julia either -- its `ORDER BY` and its `>` share the column's collation, which on a
# non-C PostgreSQL collation is not Julia's codepoint order.
function _keyset_page(items::AbstractVector, after, limit)
    page = sort!(filter(x -> after === nothing || x.id > after, items); by = x -> x.id)
    limit === nothing || length(page) <= limit || resize!(page, limit)
    return page
end

"""
    list_running_task_refs(store; after=nothing, limit=nothing) -> Vector{RunningTaskRef}

The `RUNNING` records, as [`RunningTaskRef`](@ref)s: the scan behind
[`recover_zombie_tasks!`](@ref), which walks it a page at a time.

**Optional.** The default below derives the refs from `get_all_tasks(store, System();
status=RUNNING)`, so a backend that does not implement this still recovers its zombies. It just
pays for the listing API to do it, and the listing materializes every record in full.
Recovery asks a three-column question, and a serializing store answering it through the listing
deserializes each row's `result` and `watchers` only to throw them away
([#236](https://github.com/PingoLee/Nitro.jl/issues/236)). A backend that serializes should
implement this as a projection of those three columns.

# Paging

`after` / `limit` page by keyset on the id, like the store's `get_all_tasks`: ids strictly
greater than `after`, in id order, at most `limit` of them. An implementation returns **fewer
than `limit` only when nothing is left** — a row it has to skip must be made up from past the
cursor, or the caller reads a short page as the end
([#237](https://github.com/PingoLee/Nitro.jl/issues/237)).

The default honours `after` and ignores `limit`: it has already read the whole listing, so it
returns everything past the cursor in one page instead of re-reading the listing for each page.
A caller must therefore accept a page longer than `limit`. Recovery does.

It is a **recovery scan, not a listing**: it takes no `TaskAuthority` and hands out no record
contents, only the identity a fenced transition needs. Do not build a user-facing surface on it.
"""
function list_running_task_refs(store::AbstractWorkerStore; after::Union{Nothing, String}=nothing,
                                 limit::Union{Nothing, Int}=nothing)
    paged = _check_page(after, limit)
    refs = RunningTaskRef[_running_ref(task) for task in get_all_tasks(store, System(); status=RUNNING)]
    # Sorted on EVERY paged call, the first one included. The listing comes back in whatever
    # order the store keeps (a `Dict`'s, for most), and a caller's cursor is the last id of this
    # page. Unsorted, that cursor is arbitrary, so the next page `id > cursor` hands back rows the
    # caller has ALREADY adjudicated and that are still `RUNNING` (spared as live, too recent, or
    # lost the race), which the sweep would then count twice.
    return paged ? _keyset_page(refs, after, nothing) : refs
end

# -- Claims: the optional capability behind an out-of-process consumer (#514) --

"""
    claim_next!(store, queue_name::String, consumer_id::String;
                lease_seconds::Real, now::DateTime = current_time_utc()) -> Union{TaskInfo, Nothing}

Claim the oldest `PENDING` submission of `queue_name` that was queued as **external**, for the
consumer `consumer_id`, as one atomic step. Returns the claimed record, or `nothing` when there is
nothing to claim. Part of the optional claim capability — see [`AbstractWorkerStore`](@ref).

The claim is a **new run of the same submission**: the record moves to `RUNNING` under a fresh
`run_id` (see [`TaskInfo`](@ref)), with `claimed_by = consumer_id`, `lease_expires_at = now +
lease_seconds`, `attempt + 1` and `started_at = now`. `created_at` and the watchers are kept.
Whatever the previous run of it was, its writes now fail their `run_id` fence.

- **Only external rows.** A row the web process queued for itself under the same queue name sits
  in that process's channel and is never claimed here.
- **Oldest first**, by `created_at` and then `id`, so a burst submitted within one clock tick
  still leaves in one order. A requeued run keeps its `created_at`, so it goes back to its original
  position.
- **Concurrent consumers never claim one row twice.** A database backend skips a row another
  claimer holds rather than waiting on it (`FOR UPDATE SKIP LOCKED` on PostgreSQL), and fences
  the claiming write on the `run_id` it read, so a lost race moves on to the next row.
- **`nothing` means empty**, never "lost a race": a one-shot consumer exits on it. A backend that
  cannot settle a claim after repeated races throws instead.
- **A head row that cannot be read is failed out of the way, one per call.** A serializing store
  that cannot decode the oldest row records it `FAILED`, so one bad row does not block the queue.
  If a second head in the same call fails to decode, it throws instead and writes nothing more:
  the cause is then probably not the rows, and failing a whole backlog cannot be undone. A
  consumer must therefore **stop, not retry**, on that error. Retrying would fail one more row per
  call.

Never call it under `lock_tasks`.
"""
function claim_next! end

"""
    LeaseRenewal

One run whose lease [`renew_leases!`](@ref) extends: the task `id`, the `run_id` the consumer
holds, and the `progress` to persist with it.

The task id is part of it because `run_id` is not indexed: a store addresses the row by its primary
key and fences on the run.
"""
const LeaseRenewal = @NamedTuple{id::String, run_id::UUID, progress::Float64}

"""
    renew_leases!(store, consumer_id::String, runs::AbstractVector{LeaseRenewal};
                  lease_seconds::Real, now::DateTime = current_time_utc()) -> Vector{UUID}

Extend every lease in `runs` to `now + lease_seconds`, and persist each run's `progress`, as one
fenced write per run. Returns the run ids that matched. Part of the optional claim capability.

Each write is fenced on the run (`id`, `run_id`), on `status = RUNNING`, and on `claimed_by =
consumer_id`. A run missing from the answer is **no longer this consumer's to run** — cancelled,
taken back by [`requeue_expired!`](@ref), or the key re-submitted — and the consumer reads the
record to learn which.

It deliberately does **not** fence on the lease still being in the future. A late renew of a lease
nobody has taken back yet is harmless, and it is exactly what a long garbage-collection pause
produces. Taking a lease back is `requeue_expired!`'s decision, fenced on the expiry; the two
writes cannot both win.
"""
function renew_leases! end

"""
    release_claim!(store, task_id::String, run_id::UUID; policy::LeasePolicy,
                   now::DateTime = current_time_utc()) -> Bool

Hand a claim back: the run `run_id` of `task_id` goes from `RUNNING` to `PENDING` as a new run of
the same submission, with a fresh `run_id`, `claimed_by`, `lease_expires_at` and `started_at`
cleared, and progress reset. Returns whether it wrote anything. Part of the optional claim
capability.

Fenced on `run_id`, on `status = RUNNING`, and on the submission being external, so a run whose
claim is already gone — cancelled, requeued, re-claimed — changes nothing, and neither does a run
a process executes as its own, which nothing would ever pick up again from `PENDING`.

`attempt` is **not** given back. A run a consumer hands back on purpose (it is draining) still
counts as an attempt, so a job that keeps being handed back still reaches its queue's bound, and
**the store enforces that bound**, from `policy`, the queue's [`LeasePolicy`](@ref):

| `policy` | Outcome |
|---|---|
| `:requeue`, `attempt < max_attempts` | back to `PENDING`, as above |
| `:requeue`, `attempt >= max_attempts` | `FAILED`, with an error naming the attempts |
| `:fail` | back to `PENDING`: nothing expired, so the policy for a lost lease does not apply |

Both outcomes are one write fenced on the run, so the attempt count it reads is the current one:
every writer of `attempt` also changes `run_id`. Leaving the bound to the consumer would make it
hold only for a well-behaved one.
"""
function release_claim! end

"""
    count_external_runs(store, statuses::AbstractVector{TaskStatus};
                        queue_name::Union{Nothing, String} = nothing,
                        submitter::Union{Nothing, String} = nothing) -> Int

How many **external** submissions are in one of `statuses`, optionally only those of `queue_name`,
and only those **submitted by** the user id `submitter`. Part of the optional claim capability.

The submitter is the record's **first** watcher: a submit writes the submitter, then its grants, and
a later grant or join only appends. Not the owner half of the id ([`owner_of`](@ref)), because a
`:global` id has none, so a count by id would let one identity past its quota with `scope =
:global`. And not "any watcher", because a submit may grant any identity, so counting grants would
let one user exhaust another's quota. This is the identity the in-process quota counts too.

The web process reads it to bound an external queue at submit time
([`External`](@ref)`(; max_pending)`, and `max_runs_per_owner`), because an external run reserves
nothing in the process that submitted it. It is a plain read, so a count followed by an insert is
approximate under concurrent submits.
"""
function count_external_runs end

"""
    requeue_expired!(store, now::DateTime; policies::AbstractDict{String, LeasePolicy},
                     on_unknown_queue::Symbol = :fail)
        -> @NamedTuple{requeued::Int, failed::Int, unknown_queue::Int, lost_race::Int}

Adjudicate every `RUNNING` run whose lease expired before `now`, by its queue's
[`LeasePolicy`](@ref). Part of the optional claim capability.

| The run's queue | Outcome |
|---|---|
| not in `policies`, `on_unknown_queue = :fail` | `FAILED`, counted in `unknown_queue`: **fail-closed**, never stranded |
| not in `policies`, `on_unknown_queue = :skip` | not read, and left `RUNNING` for a process that declares the queue |
| `:fail` | `FAILED` |
| `:requeue`, `attempt < max_attempts` | back to `PENDING` as a new run (fresh `run_id`, claim and `started_at` cleared, progress reset, `created_at` kept) |
| `:requeue`, `attempt >= max_attempts` | `FAILED`, with an error naming the attempts |

`failed` counts every run recorded `FAILED`; `unknown_queue` is how many of those had no policy.

A consumer passes `:fail`, the default: it holds the app's whole set of external queues, so an
expired run on a queue none of them names belongs to a queue no longer declared anywhere. The web
process's retention tick passes `:skip`: it adjudicates only the queues its own runtime declares,
so two apps sharing one store, or an old web process in a rolling deploy that adds a queue, never
fail each other's runs.

Only leased runs are looked at: a `RUNNING` row with no lease belongs to a process running it as
its own, and is the zombie sweep's to judge. Each outcome is one write fenced on the run it read
**and** on the lease still being expired, so a consumer renewing at the same moment either renews
first and is spared (counted in `lost_race`), or loses its fence. It is safe to run from any
number of processes at once, and idempotent.

`now` is the caller's clock, compared with a lease written by the claiming process's clock: clock
skew between the two shortens or lengthens the effective lease by the skew.
"""
function requeue_expired! end

# The duration a lease is extended by, validated once for every backend.
function _lease_period(lease_seconds::Real)
    # At least one millisecond, the resolution it is stored at: a smaller lease would round to
    # zero and be born expired.
    (isfinite(lease_seconds) && lease_seconds >= 0.001) || throw(ArgumentError(
        "`lease_seconds` must be a finite number of seconds, at least 0.001, got $lease_seconds"))
    return Dates.Millisecond(round(Int, 1000 * lease_seconds))
end

# A queue a claim can name. Empty is refused: `PormGWorkerStore` stores "no queue" as an empty
# string, so an empty name there would claim the external rows that have no queue at all, which
# no other backend does.
function _check_claim_queue(queue_name::AbstractString)
    isempty(queue_name) && throw(ArgumentError("`queue_name` must not be empty"))
    return queue_name
end

# What may name a consumer: it is stored in a VARCHAR(255) column and compared byte for byte.
function _check_consumer_id(consumer_id::AbstractString)
    isempty(consumer_id) && throw(ArgumentError("`consumer_id` must not be empty"))
    ncodeunits(consumer_id) <= 255 || throw(ArgumentError(
        "`consumer_id` must be at most 255 bytes, got $(ncodeunits(consumer_id))"))
    '\0' in consumer_id && throw(ArgumentError("`consumer_id` must not contain a NUL"))
    return consumer_id
end

# The stored error of a run `requeue_expired!` fails, `nothing` when it requeues it instead. One
# renderer for both backends, so the two cannot word an outcome differently.
function _lease_expiry_error(queue::Union{Nothing, String}, policy::Union{Nothing, LeasePolicy},
                             attempt::Int)
    q = queue === nothing ? "(none)" : "'$queue'"
    policy === nothing && return "Lease expired on queue $q, which no process declares as " *
                                 "external; failing closed"
    policy.on_expiry === :fail && return "Lease expired on queue $q (on_lease_expiry = :fail)"
    attempt >= policy.max_attempts && return "Lease expired on queue $q after $attempt " *
        "attempt(s) (max_attempts = $(policy.max_attempts)); not re-queued"
    return nothing
end

# The stored error of a run `release_claim!` fails because it reached its queue's attempt bound,
# `nothing` when it goes back to `PENDING` instead. Its own wording, not `_lease_expiry_error`'s:
# nothing expired. One renderer for both backends, so the two cannot word it differently.
function _release_bound_error(queue::Union{Nothing, String}, policy::LeasePolicy, attempt::Int)
    (policy.on_expiry === :requeue && attempt >= policy.max_attempts) || return nothing
    q = queue === nothing ? "(none)" : "'$queue'"
    return "Handed back on queue $q after $attempt attempt(s) (max_attempts = " *
           "$(policy.max_attempts)); not re-queued"
end

_lease_policy(policies::AbstractDict, queue::Union{Nothing, String}) =
    queue === nothing ? nothing : get(policies, queue, nothing)

# `requeue_expired!`'s `on_unknown_queue`, validated once for every backend.
function _check_on_unknown_queue(on_unknown_queue::Symbol)
    on_unknown_queue in (:fail, :skip) || throw(ArgumentError(
        "`on_unknown_queue` must be :fail or :skip, got $(repr(on_unknown_queue))"))
    return on_unknown_queue
end

const _ExpiryTally = @NamedTuple{requeued::Int, failed::Int, unknown_queue::Int, lost_race::Int}

function get_queue_authorizer end
function set_queue_authorizer! end

# -- Cross-user task-key permission checks interface functions --
function get_watch_authorizer end

"""
    set_watch_authorizer!(store, authorizer)

Install the hook that decides whether a user may join or reuse a task key someone
else already owns, and return it.

    authorizer(task_key::String, watchers::Vector{String}, user_id::String)::Bool

Watcher membership is the only thing gating `get_task_status` and `cancel_task`, so
adding a watcher hands out the owner's read and cancel rights. Submitting a key that
already exists and that the caller does not already watch is therefore refused with
`AuthorizationError` unless this hook returns `true`. That covers both the live task
(joining it) and the finished one (replacing it, which discards the owner's result).

`watchers` is a copy, so mutating it has no effect.

**The hook runs while the task key's lock is held** — one stripe of the store's
[`TaskLocks`](@ref), which every submit, run start, finish, cancel and zombie verdict on that
key takes, and which a fixed share of the *other* keys hash to as well. Blocking in the hook
stalls all of them, so make it a pure in-memory predicate over data the app already has.
Do not query a database from it, never call the worker API from it (`submit_task`,
`cancel_task`, … on another key would take that key's lock, and two such hooks deadlock each
other, so a call that takes another key's lock throws `ConcurrencyViolationError` instead), and never
`fetch` a spawned task that touches the same store: the child cannot take a
`ReentrantLock` its parent holds, and any key it touches may hash to that stripe, so that
deadlocks.

**Re-running a finished key resets its watcher list to the submitter.** An authorized
reuse therefore drops the previous watchers, who must be re-authorized to rejoin. Hand out
long-lived ids for a shared task only if the app is prepared for that.

With `:user`-scoped keys (the default) this cannot trigger between two ordinary
callers, because their ids never collide. Set it when an app deliberately uses
`scope=:global` to share one expensive task across users.

```julia
# Resolve the sharing rule from data already in memory, not from a query.
set_watch_authorizer!(store, function(task_key, watchers, user_id)
    return ORG_OF[first(watchers)] == ORG_OF[user_id]
end)
```
"""
function set_watch_authorizer! end

# -- Stored-error redaction --

function get_error_redactor end

"""
    set_error_redactor!(store, redactor)

Install the hook that rewrites a failed task's error text before it is stored, and return it.

    redactor(exception, rendered::String)::String

A task's stored `error` is rendered from the exception the **application's** callback threw, and
exceptions quote their input. A callback that parses user-submitted data hands its parser's
`ArgumentError` the offending bytes, and those bytes land in the store — for `PormGWorkerStore`,
in a `TEXT` column, kept until the retention sweep removes the row
([#140](https://github.com/PingoLee/Nitro.jl/issues/140)).

Nitro cannot know which parts of an app's exception messages are sensitive, so it bounds the
text (see `MAX_STORED_ERROR_CHARS`) and offers this hook for the rest. `nothing`, the default,
means no redaction.

`rendered` is the **full** text, before truncation, so a redactor sees what it is deciding about
rather than a prefix. The cap is applied to whatever it returns, so a redactor cannot exceed it.

```julia
# Keep the exception type, drop everything it quoted.
set_error_redactor!(store, (exc, rendered) -> string(nameof(typeof(exc))))

# Or redact selectively, leaving ordinary failures diagnosable.
set_error_redactor!(store, function(exc, rendered)
    exc isa MyApp.UserDataError ? "UserDataError (details withheld)" : rendered
end)
```

The hook runs on the failure path of a task that has already failed, so a redactor that throws
must not lose the failure as well: Nitro catches it, logs that it threw **without the text it
was handed**, and stores the exception type alone.

Like the authorizer hooks, this is invoked through `Base.invokelatest`, so a redactor defined
after the worker started is still seen.
"""
function set_error_redactor! end

# -- Locking --

"""
    TaskLocks()

The process-local locks Nitro takes around a worker store's sections, owned by the store
([#711](https://github.com/PingoLee/Nitro.jl/issues/711)). A backend constructs one with itself
and returns it from [`task_locks`](@ref); it never takes them itself.

```julia
struct MyWorkerStore <: AbstractWorkerStore
    # … the backend's own fields
    locks::TaskLocks
end
Nitro.Workers.task_locks(store::MyWorkerStore) = store.locks
```

What they order is **in-process, per task id**: one in-process writer of a record's `run_id` at
a time, a run's live handle registered against the record it was claimed from, and no zombie
verdict between a claim and its handle. Those are per-id facts, so the locks are a fixed set of
`ReentrantLock` stripes picked by the id's hash: two sections on the same id serialize, and two
on different ids serialize only when the ids share a stripe (one chance in 64 per pair). A
store-wide lock here capped one process at one database round trip at a time, whatever its
connection pool.

One more lock covers what is not per id: an external queue's submit-time bounds count every
record of the queue, and a count followed by a write must not interleave with another submit's
in this process. It is taken inside a stripe, never the other way round.

A section is about one id: never a second id inside it, and never `queue_lock` inside either.
The first is enforced — [`lock_tasks`](@ref) on another id inside a section throws
`ConcurrencyViolationError` ([#717](https://github.com/PingoLee/Nitro.jl/issues/717)), because
two such calls on two threads deadlock each other, and whether they do depends on the ids' hash.
That is why an application hook that runs under a stripe — the watch authorizer — must not call
back into the worker API.
None of this spans processes; cross-process correctness is the store's atomic operations'.
"""
struct TaskLocks
    stripes::Vector{ReentrantLock}
    admission::ReentrantLock

    function TaskLocks(stripes::Vector{ReentrantLock}, admission::ReentrantLock)
        # A stripe is a mask of the hash, which spreads evenly only over a power of two.
        ispow2(length(stripes)) ||
            throw(ArgumentError("`TaskLocks` needs a power-of-two number of stripes, got $(length(stripes))"))
        return new(stripes, admission)
    end
end

# A power of two, so a stripe is a mask of the hash. With 64, two of 4 concurrent keys share a
# stripe 9% of the time, of 8 37%, of 16 87% -- which costs throughput only: those two serialize,
# as every key did before #711. 256 stripes measured no faster at 16 and 32 clients on SQLite or
# PostgreSQL, where the database, not the stripe, is the ceiling (#717).
const TASK_LOCK_STRIPES = 64

TaskLocks() = TaskLocks([ReentrantLock() for _ in 1:TASK_LOCK_STRIPES], ReentrantLock())

_stripe_index(locks::TaskLocks, task_id::String) =
    Int(hash(task_id) & UInt(length(locks.stripes) - 1)) + 1
_stripe(locks::TaskLocks, task_id::String) = locks.stripes[_stripe_index(locks, task_id)]

"""
    task_locks(store) -> TaskLocks

The store's [`TaskLocks`](@ref): the same object on every call, constructed with the store.
Required by [`AbstractWorkerStore`](@ref); a backend implements it as a field read.
"""
function task_locks end

"""
    lock_tasks(callback, store, task_id::String)

Run `callback()` holding `task_id`'s stripe of `store`'s [`TaskLocks`](@ref). Implemented once
here for every store; a backend provides [`task_locks`](@ref), not this.

A section is about one task id. Inside one, `lock_tasks` on the same id re-enters; on any other
id it throws `ConcurrencyViolationError` before taking anything
([#717](https://github.com/PingoLee/Nitro.jl/issues/717)), even when the two ids share a stripe.
"""
function lock_tasks(callback::Function, store::AbstractWorkerStore, task_id::String)
    tls = task_local_storage()
    held = get(tls, _HELD_TASK_ID, nothing)::Union{Nothing, String}
    held === nothing || held == task_id || _throw_second_task_id(held, task_id)
    stripe = _stripe(task_locks(store), task_id)
    lock(stripe)
    try
        # Re-entry: the outermost section owns the marker.
        held === nothing || return callback()
        tls[_HELD_TASK_ID] = task_id
        try
            return callback()
        finally
            # Overwritten, never deleted: a delete and re-insert per section churns the task's
            # `IdDict` into rehashing, which cost every section ~150 ns and an allocation.
            tls[_HELD_TASK_ID] = nothing
        end
    finally
        unlock(stripe)
    end
end

# The id whose section the current task is inside, or `nothing`. Task-local, not a
# `ScopedValue`: it marks the task that holds the lock, and a child spawned inside the section
# does not hold it (#717).
const _HELD_TASK_ID = :nitro_workers_lock_tasks_held

# Refused on the id, not the stripe: two ids on one stripe would re-enter today, but whether they
# share one depends on their hash and on `TASK_LOCK_STRIPES`, so the same app code would pass or
# deadlock by chance. On the id, it fails on its first call.
@noinline function _throw_second_task_id(held::String, task_id::String)
    throw(ConcurrencyViolationError(
        "`lock_tasks` for task \"$task_id\" inside the section of task \"$held\": a section is " *
        "about one task id, and two sections on two ids from two threads can deadlock each other. " *
        "The usual caller is a watch authorizer (`set_watch_authorizer!`) that calls the worker " *
        "API (`submit_task`, `cancel_task`, `release_task!`, ...); it runs under the submitted " *
        "key's section, so resolve what it needs before installing it."))
end

# The external-submit admission lock: taken inside a key's stripe, around a bound's count and the
# write it admits. See `TaskLocks`.
_lock_admission(callback::Function, store::AbstractWorkerStore) =
    lock(callback, task_locks(store).admission)

# ============================================================================
# The contract, as data
# ============================================================================

"""
    WORKER_STORE_INTERFACE

The [`AbstractWorkerStore`](@ref) contract as data: one row per required method, holding the
function and its **documented** positional argument types, with `AbstractWorkerStore` standing in
the store slot.

Two consumers read it and must not drift apart — the fallback methods generated directly below, and
[`missing_store_methods`](@ref). Adding a method to the contract means adding a row here; nothing
else.

The types here document the contract and fix each method's **arity** and store position; the
generated fallbacks widen every non-store parameter to `Any`. That widening is not laziness. A
fallback pinned to these exact types is *ambiguous* with a backend that types one of its own
parameters more loosely — `(::MyStore, ::AbstractString)` against a contract that says `::String`,
which is how Nitro's own public API is written — and Julia may then resolve the call to the
fallback rather than to the store's method. The imprecision that widening costs is bought back at
runtime by `store_contract_error`, which tells a missing backend method apart from a caller who
passed the wrong argument.
"""
const WORKER_STORE_INTERFACE = (
    # -- Durable task records --
    (get_task_info,                 (AbstractWorkerStore, String)),
    (set_task!,                     (AbstractWorkerStore, String, TaskInfo)),
    (replace_task!,                 (AbstractWorkerStore, String, TaskInfo)),
    (add_watcher!,                  (AbstractWorkerStore, String, String)),
    (try_transition!,               (AbstractWorkerStore, String, Any, TaskStatus)),
    (delete_task!,                  (AbstractWorkerStore, String)),
    (try_delete_task!,              (AbstractWorkerStore, String, Any)),
    (cleanup_tasks!,                (AbstractWorkerStore, Int)),
    (get_all_tasks,                 (AbstractWorkerStore, TaskAuthority)),
    # -- Authorization hooks --
    (get_queue_authorizer,          (AbstractWorkerStore,)),
    (set_queue_authorizer!,         (AbstractWorkerStore, Any)),
    (get_watch_authorizer,          (AbstractWorkerStore,)),
    (set_watch_authorizer!,         (AbstractWorkerStore, Any)),
    (get_error_redactor,            (AbstractWorkerStore,)),
    (set_error_redactor!,           (AbstractWorkerStore, Any)),
    # -- Process-local ordering of a task id's sections (#711) --
    (task_locks,                    (AbstractWorkerStore,)),
)

"""
    CLAIM_STORE_INTERFACE

The optional claim capability of an [`AbstractWorkerStore`](@ref), as data, in the same shape as
`WORKER_STORE_INTERFACE` ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)). Its
rows get the same generated fallbacks, so calling one on a store that lacks it raises
`StoreInterfaceError` naming the method. [`missing_claim_methods`](@ref) reads it;
`missing_store_methods` does not, which is what keeps the capability optional.
"""
const CLAIM_STORE_INTERFACE = (
    (claim_next!,                   (AbstractWorkerStore, String, String)),
    (renew_leases!,                 (AbstractWorkerStore, String, Any)),
    (release_claim!,                (AbstractWorkerStore, String, UUID)),
    (requeue_expired!,              (AbstractWorkerStore, DateTime)),
    (count_external_runs,           (AbstractWorkerStore, Any)),
)

_store_arg_index(argtypes) = something(findfirst(T -> T === AbstractWorkerStore, argtypes))

# Generate one fallback per row: the store slot typed at the abstract type, every other parameter
# widened to `Any` so a backend's own method is strictly more specific in every slot and can never
# be ambiguous with this one. See `store_contract_error` for why the width is required and how the
# precision is recovered.
#
# `kwargs...` is accepted and ignored on purpose. It never swallows a keyword mistake: a store that
# defines the method at all is more specific on the positional arguments, so it is the one that
# gets to reject the keyword.
for (f, argtypes) in (WORKER_STORE_INTERFACE..., CLAIM_STORE_INTERFACE...)
    local idx = _store_arg_index(argtypes)
    local names = [Symbol("a", i) for i in eachindex(argtypes)]
    local params = [i == idx ? Expr(:(::), names[i], AbstractWorkerStore) : names[i]
                    for i in eachindex(argtypes)]
    @eval @noinline function $(nameof(f))($(params...); kwargs...)
        store_contract_error($f, AbstractWorkerStore, $idx, $(names...))
    end
end

"""
    missing_store_methods(S::Type{<:AbstractWorkerStore}) -> Vector{Symbol}

The [`AbstractWorkerStore`](@ref) methods `S` has not implemented, in contract order. Empty means
`S` is conforming.

This is the conformance check a backend runs in its own test suite. It uses no test framework on
purpose, so it ships with the package and costs a third-party store nothing to call:

```julia
@test isempty(missing_store_methods(MyWorkerStore))
```

A name appears here when `S` contributed no method of its own for it. It answers about a *type*, so
it runs at load time, in a test, or in a REPL, without constructing a store.

It asks about presence, not signature compatibility — see `implements_contract_method` for why
checking the exact call signature is the less useful question.
"""
missing_store_methods(S::Type{<:AbstractWorkerStore}) = _missing_methods(S, WORKER_STORE_INTERFACE)

"""
    missing_claim_methods(S::Type{<:AbstractWorkerStore}) -> Vector{Symbol}

The methods of the optional claim capability ([`CLAIM_STORE_INTERFACE`](@ref)) that `S` has not
implemented. Empty means `S` can back a queue run by a separate consumer process
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)).

The counterpart of [`missing_store_methods`](@ref), which does not list these: a store without
them is conforming, it just cannot claim.

```julia
@test isempty(missing_claim_methods(MyWorkerStore))   # only if MyWorkerStore should claim
```
"""
missing_claim_methods(S::Type{<:AbstractWorkerStore}) = _missing_methods(S, CLAIM_STORE_INTERFACE)

# Whether a store implements the whole claim capability. Not exported: the consumer process asks it.
supports_claims(S::Type{<:AbstractWorkerStore}) = isempty(missing_claim_methods(S))
supports_claims(store::AbstractWorkerStore) = supports_claims(typeof(store))

# Whether a process other than this one can read what `store` holds. An external queue needs it:
# its runs are claimed by a consumer process, so a store that only this process can see would
# record a submit no consumer could ever claim. `true` unless a backend says otherwise: a store
# that implements the claim capability is assumed to be shared, and the one volatile backend
# opts out below.
_visible_across_processes(::AbstractWorkerStore) = true

# Whether `authority` may be served `task_id`'s durable record, asked BEFORE that record is read
# (#565). `false` means the full read would be refused or would find nothing; `true` means "read it
# and decide on the record". A pre-filter, never the gate: `_visible_record` re-checks the record it
# reads, because the run can change between the two reads and a re-run resets the watcher list.
# `true` unless a backend can do better. One whose full read decodes the stored `result` answers it
# from a projection of the watcher list instead, so a caller who may not see the task never pays
# for that decode, and a foreign id costs what a missing one does.
_may_read_durable(::AbstractWorkerStore, ::TaskAuthority, ::String) = true

function _missing_methods(S::Type{<:AbstractWorkerStore}, interface)
    names = Symbol[]
    for (f, argtypes) in interface
        idx = _store_arg_index(argtypes)
        if !implements_contract_method(f, S, AbstractWorkerStore, idx)
            push!(names, nameof(f))
        end
    end
    return names
end

# ============================================================================
# InMemoryWorkerStore Implementation
# ============================================================================

"""
    InMemoryWorkerStore()

The volatile backend: task records in a `Dict`, nothing durable, nothing persisted.

Records are the live objects — `set_task!` stores whatever object it is handed — so a running
callback's `update_progress!` is visible to a reader here without any live-object cache. That is
also why this is the one backend that implements [`clear_records!`](@ref): its registry is
process state, so discarding it on [`reset_runtime!`](@ref) is a reset rather than a destructive
delete.

It owns no queues, no scheduler and no run handles; those belong to [`WorkerRuntime`](@ref) (#167).
"""
mutable struct InMemoryWorkerStore <: AbstractWorkerStore
    task_registry::Dict{String, TaskInfo}
    # Guards `task_registry` alone, around each operation's own reads and writes: a leaf, taken
    # under a task's stripe and never across a callback. The ordering of a task's sections is
    # `locks`' job (#711); before that one lock did both.
    registry_lock::ReentrantLock
    locks::TaskLocks
    queue_authorizer::Ref{Any}
    watch_authorizer::Ref{Any}
    error_redactor::Ref{Any}

    function InMemoryWorkerStore()
        return new(
            Dict{String, TaskInfo}(),
            ReentrantLock(),
            TaskLocks(),
            Ref{Any}(nothing),
            Ref{Any}(nothing),
            Ref{Any}(nothing),
        )
    end
end

# -- Implement interface methods for InMemoryWorkerStore --

function get_task_info(store::InMemoryWorkerStore, task_id::String)
    lock(store.registry_lock) do
        return get(store.task_registry, task_id, nothing)
    end
end

function set_task!(store::InMemoryWorkerStore, task_id::String, task_info::TaskInfo)
    lock(store.registry_lock) do
        existing = Base.get(store.task_registry, task_id, nothing)
        # Callers almost always save the very object they read, so there is nothing to
        # reconcile and the record simply stands.
        if existing === nothing || existing === task_info
            store.task_registry[task_id] = task_info
            return task_info
        end

        # A different object: copy the volatile state across and keep the *stored*
        # record's watchers, run_id, cancel_reason (and its `cancel_waker`, #568) AND the claim
        # fields (`external`, `claimed_by`, `lease_expires_at`, `attempt`, #514) and the named-job
        # identity (`job_name`, `job_args`, #514) — precisely what the serializing
        # store achieves by omitting those columns. The list below is otherwise "copy every
        # field", so those absences ARE the rule.
        #
        # `run_id` is the value `try_transition!` fences on, so copying it off a caller's
        # object would let a stale run adopt the current run's identity (#108).
        # `cancel_reason` is worse: a stale object still carrying `:none` would ERASE a
        # cancel already requested, which is the #88 watcher clobber with the sign flipped
        # (#127). (It was `cancel_requested::Bool` until #183; the field carries the cause
        # now, and the exclusion rule is unchanged.) The caller's object is left untouched,
        # so both backends agree on that too; a rule honoured by only one of them is a store
        # that silently behaves differently, which for this pair means a different security
        # posture.
        existing.status = task_info.status
        @atomic existing.progress = task_info.progress
        existing.result = task_info.result
        existing.error = task_info.error
        existing.created_at = task_info.created_at
        existing.started_at = task_info.started_at
        existing.completed_at = task_info.completed_at
        existing.queue_name = task_info.queue_name
        return existing
    end
end

function replace_task!(store::InMemoryWorkerStore, task_id::String, task_info::TaskInfo)
    lock(store.registry_lock) do
        store.task_registry[task_id] = task_info
    end
    return task_info
end

function add_watcher!(store::InMemoryWorkerStore, task_id::String, user_id::String)
    lock(store.registry_lock) do
        task_info = Base.get(store.task_registry, task_id, nothing)
        task_info === nothing && return false
        # Mutating the registered object *is* the store write — no round-trip, and so
        # no window between the mutation and its publication.
        #
        # Copy-on-write, never `push!` (#323, #324). Readers check `watchers` WITHOUT this lock --
        # `get_task_status` on the live object, and the listing, which scans a snapshot outside
        # it -- and a `push!` can reallocate the very vector one of them is iterating. Swapping in
        # a new vector leaves any reader holding the old one with a complete, if stale, list.
        user_id in task_info.watchers || (task_info.watchers = vcat(task_info.watchers, user_id))
        return true
    end
end

function try_transition!(store::InMemoryWorkerStore, task_id::String, from, to::TaskStatus;
                         run_id::Union{Nothing, UUID},
                         error::Union{Nothing, String}=nothing,
                         completed_at::Union{Nothing, DateTime}=nothing,
                         started_at::Union{Nothing, DateTime}=nothing,
                         result=UNSUPPLIED,
                         progress::Union{Nothing, Real}=nothing)
    lock(store.registry_lock) do
        task_info = Base.get(store.task_registry, task_id, nothing)
        task_info === nothing && return false
        task_info.status in from || return false
        # The run fence. `nothing` is the named opt-out, never a default (#108).
        run_id === nothing || task_info.run_id == run_id || return false

        error === nothing || (task_info.error = error)
        completed_at === nothing || (task_info.completed_at = completed_at)
        started_at === nothing || (task_info.started_at = started_at)
        result === UNSUPPLIED || (task_info.result = result)
        progress === nothing || (@atomic task_info.progress = Float64(progress))
        task_info.status = to        # last, so no reader sees the new status early
        return true
    end
end

function delete_task!(store::InMemoryWorkerStore, task_id::String)
    lock(store.registry_lock) do
        delete!(store.task_registry, task_id)
    end
    return nothing
end

function try_delete_task!(store::InMemoryWorkerStore, task_id::String, from;
                          run_id::Union{Nothing, UUID})
    lock(store.registry_lock) do
        task_info = Base.get(store.task_registry, task_id, nothing)
        task_info === nothing && return false
        task_info.status in from || return false
        run_id === nothing || task_info.run_id == run_id || return false
        delete!(store.task_registry, task_id)
        return true
    end
end

function cleanup_tasks!(store::InMemoryWorkerStore, retain_days::Int)
    cutoff = current_time_utc() - Dates.Day(retain_days)
    removed = String[]

    lock(store.registry_lock) do
        for (task_id, task_info) in store.task_registry
            if task_info.completed_at !== nothing && task_info.completed_at < cutoff && task_info.status in (COMPLETED, FAILED, CANCELLED)
                push!(removed, task_id)
            end
        end

        for task_id in removed
            delete!(store.task_registry, task_id)
        end
    end

    return length(removed)
end

function get_all_tasks(store::InMemoryWorkerStore, authority::TaskAuthority;
                       status::Union{Nothing, TaskStatus}=nothing, queue_name::Union{Nothing, String}=nothing,
                       after::Union{Nothing, String}=nothing, limit::Union{Nothing, Int}=nothing)
    paged = _check_page(after, limit)
    tasks = _in_memory_listing(store, authority, status, queue_name)
    # Paged AFTER the authority gate, so a page is `limit` rows the caller may see, never
    # fewer because the gate thinned it.
    return paged ? _keyset_page(tasks, after, limit) : tasks
end

function _in_memory_listing(store::InMemoryWorkerStore, authority::TaskAuthority, status, queue_name)
    # Snapshot under the lock, filter OUTSIDE it (#324). The scan used to run while holding
    # the store's one lock -- which every submit, claim, finish and cancel then needed -- so one owner
    # listing a 200k-record registry stalled the whole worker subsystem for its duration. Copying the
    # values is a pointer copy; the per-record work below then contends with nothing.
    #
    # Reading a record outside the lock is the same thing `get_task_status` already does with a
    # live object: `status` is a plain field written whole, and `watchers` is swapped
    # copy-on-write by `add_watcher!`, never grown in place, so the vector `_is_authorized`
    # iterates cannot be resized under it.
    snapshot = lock(() -> collect(values(store.task_registry)), store.registry_lock)
    tasks = TaskInfo[]
    for task_info in snapshot
        if status !== nothing && task_info.status != status
            continue
        end
        # Deliberately no owner -> ids index: the registry is already in RAM, so this
        # is a Dict scan either way, and an index would be new mutable state to keep
        # consistent across set_task!, delete_task!, cleanup_tasks! and clear_records!.
        _is_authorized(authority, task_info) || continue
        if queue_name !== nothing && task_info.queue_name != queue_name
            continue
        end
        push!(tasks, task_info)
    end
    return tasks
end

# Implemented rather than left to the default for parity with `PormGWorkerStore`, not for speed:
# the registry is already in RAM, so the default's listing would cost the same Dict scan.
function list_running_task_refs(store::InMemoryWorkerStore; after::Union{Nothing, String}=nothing,
                                 limit::Union{Nothing, Int}=nothing)
    paged = _check_page(after, limit)
    refs = lock(store.registry_lock) do
        RunningTaskRef[_running_ref(t) for t in values(store.task_registry) if t.status == RUNNING]
    end
    return paged ? _keyset_page(refs, after, limit) : refs
end

# -- The claim capability (#514) --
#
# Implemented for parity, so one conformance body runs over both backends (workers §6), and so a
# consumer loop can be exercised in one process. A store no other process can see cannot back a
# real external queue; refusing that is a deployment check, not a missing capability.
#
# Every new run below is a NEW object (`_successor_run`) installed in the registry. Mutating the
# claimed record's `run_id` in place would hand the new identity to whoever still holds the old
# object, and every fence they reach would then pass (#108).

function claim_next!(store::InMemoryWorkerStore, queue_name::String, consumer_id::String;
                     lease_seconds::Real, now::DateTime=current_time_utc())
    _check_claim_queue(queue_name)
    _check_consumer_id(consumer_id)
    lease = _lease_period(lease_seconds)
    lock(store.registry_lock) do
        head = nothing
        for t in values(store.task_registry)
            (t.status == PENDING && t.external && t.queue_name == queue_name) || continue
            if head === nothing || (t.created_at, t.id) < (head.created_at, head.id)
                head = t
            end
        end
        head === nothing && return nothing
        run = _successor_run(head)
        run.status = RUNNING
        run.claimed_by = consumer_id
        run.lease_expires_at = now + lease
        run.attempt = head.attempt + 1
        run.started_at = now
        store.task_registry[run.id] = run
        return run
    end
end

function renew_leases!(store::InMemoryWorkerStore, consumer_id::String,
                       runs::AbstractVector{LeaseRenewal};
                       lease_seconds::Real, now::DateTime=current_time_utc())
    _check_consumer_id(consumer_id)
    expires = now + _lease_period(lease_seconds)
    renewed = UUID[]
    lock(store.registry_lock) do
        for r in runs
            t = get(store.task_registry, r.id, nothing)
            (t !== nothing && t.run_id == r.run_id && t.status == RUNNING &&
             t.claimed_by == consumer_id) || continue
            t.lease_expires_at = expires
            @atomic t.progress = r.progress
            push!(renewed, r.run_id)
        end
    end
    return renewed
end

function release_claim!(store::InMemoryWorkerStore, task_id::String, run_id::UUID;
                        policy::LeasePolicy, now::DateTime=current_time_utc())
    lock(store.registry_lock) do
        t = get(store.task_registry, task_id, nothing)
        # `external` too: handing back a run this process executes itself would strand it at
        # PENDING, since no channel holds it and `claim_next!` takes only external rows.
        (t !== nothing && t.run_id == run_id && t.status == RUNNING && t.external) || return false
        err = _release_bound_error(t.queue_name, policy, t.attempt)
        if err === nothing
            store.task_registry[task_id] = _back_to_pending(t)
        else
            # In place, as `requeue_expired!` fails a run: the run that held the claim is over.
            t.error = err
            t.completed_at = now
            t.status = FAILED
        end
        return true
    end
end

function count_external_runs(store::InMemoryWorkerStore, statuses::AbstractVector{TaskStatus};
                             queue_name::Union{Nothing, String}=nothing,
                             submitter::Union{Nothing, String}=nothing)
    lock(store.registry_lock) do
        return count(values(store.task_registry)) do t
            t.external && t.status in statuses &&
                (queue_name === nothing || t.queue_name == queue_name) &&
                (submitter === nothing || (!isempty(t.watchers) && first(t.watchers) == submitter))
        end
    end
end

# Its records live in this process's memory, which no consumer process can read (#514).
_visible_across_processes(::InMemoryWorkerStore) = false

function requeue_expired!(store::InMemoryWorkerStore, now::DateTime;
                          policies::AbstractDict{String, LeasePolicy}, on_unknown_queue::Symbol = :fail)
    skip_unknown = _check_on_unknown_queue(on_unknown_queue) === :skip
    # The counts live inside the closure and come back as its value: assigned from inside it, they
    # would be captured in a `Core.Box` (#364).
    return lock(store.registry_lock) do
        requeued = failed = unknown = 0
        expired = [t for t in values(store.task_registry)
                   if t.status == RUNNING && t.lease_expires_at !== nothing && t.lease_expires_at < now &&
                      !(skip_unknown && _lease_policy(policies, t.queue_name) === nothing)]
        for t in expired
            policy = _lease_policy(policies, t.queue_name)
            err = _lease_expiry_error(t.queue_name, policy, t.attempt)
            if err === nothing
                store.task_registry[t.id] = _back_to_pending(t)
                requeued += 1
            else
                # In place: status and the error are state, and the run that held the lease is
                # over -- whoever holds this object should see it end, exactly as a cancel would.
                t.error = err
                t.completed_at = now
                t.status = FAILED
                failed += 1
                policy === nothing && (unknown += 1)
            end
        end
        return _ExpiryTally((requeued, failed, unknown, 0))
    end
end

# A claimed run, handed back to the queue as the next run of the same submission.
function _back_to_pending(t::TaskInfo)
    run = _successor_run(t)
    run.status = PENDING
    run.claimed_by = nothing
    run.lease_expires_at = nothing
    run.started_at = nothing
    @atomic run.progress = 0.0
    return run
end

function get_queue_authorizer(store::InMemoryWorkerStore)
    return store.queue_authorizer[]
end

function set_queue_authorizer!(store::InMemoryWorkerStore, authorizer)
    store.queue_authorizer[] = authorizer
    return authorizer
end

function get_error_redactor(store::InMemoryWorkerStore)
    return store.error_redactor[]
end

function set_error_redactor!(store::InMemoryWorkerStore, redactor)
    store.error_redactor[] = redactor
    return redactor
end

function get_watch_authorizer(store::InMemoryWorkerStore)
    return store.watch_authorizer[]
end

function set_watch_authorizer!(store::InMemoryWorkerStore, authorizer)
    store.watch_authorizer[] = authorizer
    return authorizer
end

# The registry is process state, so a reset may discard it -- see `clear_records!`.
clear_records!(store::InMemoryWorkerStore) = (lock(() -> empty!(store.task_registry), store.registry_lock); nothing)

task_locks(store::InMemoryWorkerStore) = store.locks
