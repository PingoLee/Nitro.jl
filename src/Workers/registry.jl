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
| `set_task!(store, task_id::String, task_info::TaskInfo)` | Write volatile state; must never write `watchers` or `run_id` |
| `replace_task!(store, task_id::String, task_info::TaskInfo)` | Write the whole record, `watchers` and `run_id` included |
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
| `lock_tasks(callback::Function, store)` | **Callback-first**, so it is called `lock_tasks(store) do … end` |

# What a store is NOT asked for

Nothing here runs, schedules, or holds a handle to a live `Task`. The sequential queues and their
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

# Obligations that are not methods

- **Live objects.** `get_task_info` is the **durable** read and is free to reconstruct a fresh
  object every time; a store must *not* cache live ones. Serving a running callback's own object
  to a reader is [`WorkerRuntime`](@ref)'s job, and doing it here instead breaks run-start, which
  needs the durable record to fence its own transition (#167).

  `InMemoryWorkerStore` is not an exception: its records simply *are* the objects callbacks hold,
  because it stores whatever it is handed.
- **`run_id` round-trips, but `try_transition!` never writes it.** It is a precondition, not state.
- **`watchers` is populated on every read path.** Authorization reads it off whatever
  `get_task_info` returns, so a store that omits it silently denies everyone.
- **`lock_tasks` is process-local.** For a database-backed store it guards this process only, so
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

Use [`add_watcher!`](@ref) to add a grant and [`replace_task!`](@ref) to write a whole
record, watchers and run id included.

The return value is **unspecified** — a store may return the caller's object or the record
it holds. Do not rely on it, and do not rely on it being the same across backends.
"""
function set_task! end

"""
    replace_task!(store, task_id::String, task_info::TaskInfo)

Write a task record **in full, `watchers` and `run_id` included**, replacing whatever is
stored.

The counterpart to [`set_task!`](@ref), and the only sanctioned way to reset a watcher
list — or to publish a new run's identity. There is exactly one caller: re-running a *finished* task key, which by documented
design replaces the record and resets its watchers to the resubmitter.

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
`watchers=` keyword on `submit_task` / `submit_sequential_task`.
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
[`delete_task!`](@ref) is a read-modify-write that another process can interleave. Between the
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
`run_id` a fenced [`try_transition!`](@ref) is addressed to, and the `started_at` its run claimed
it at (`nothing` when the record carries none).
"""
const RunningTaskRef = @NamedTuple{id::String, run_id::UUID, started_at::Union{Nothing, DateTime}}

_running_ref(task::TaskInfo) = RunningTaskRef((task.id, task.run_id, task.started_at))

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

**The hook runs while the store's task lock is held.** That lock also serializes
`set_task!`, `cancel_task`, and zombie recovery, so blocking in the hook stalls the whole
worker subsystem — make it a pure in-memory predicate over data the app already has.
Do not query a database from it, and never `fetch` a spawned task that touches the same
store: the child cannot take a `ReentrantLock` its parent holds, so that deadlocks.

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
function lock_tasks end

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
    # -- Process-local serialization of store operations --
    (lock_tasks,                    (Function, AbstractWorkerStore)),
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
for (f, argtypes) in WORKER_STORE_INTERFACE
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
function missing_store_methods(S::Type{<:AbstractWorkerStore})
    names = Symbol[]
    for (f, argtypes) in WORKER_STORE_INTERFACE
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
    task_lock::ReentrantLock
    queue_authorizer::Ref{Any}
    watch_authorizer::Ref{Any}
    error_redactor::Ref{Any}

    function InMemoryWorkerStore()
        return new(
            Dict{String, TaskInfo}(),
            ReentrantLock(),
            Ref{Any}(nothing),
            Ref{Any}(nothing),
            Ref{Any}(nothing),
        )
    end
end

# -- Implement interface methods for InMemoryWorkerStore --

function get_task_info(store::InMemoryWorkerStore, task_id::String)
    lock(store.task_lock) do
        return get(store.task_registry, task_id, nothing)
    end
end

function set_task!(store::InMemoryWorkerStore, task_id::String, task_info::TaskInfo)
    lock(store.task_lock) do
        existing = Base.get(store.task_registry, task_id, nothing)
        # Callers almost always save the very object they read, so there is nothing to
        # reconcile and the record simply stands.
        if existing === nothing || existing === task_info
            store.task_registry[task_id] = task_info
            return task_info
        end

        # A different object: copy the volatile state across and keep the *stored*
        # record's watchers, run_id AND cancel_reason — precisely what the serializing
        # store achieves by omitting those columns. The list below is otherwise "copy every
        # field", so those three absences ARE the rule.
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
    lock(store.task_lock) do
        store.task_registry[task_id] = task_info
    end
    return task_info
end

function add_watcher!(store::InMemoryWorkerStore, task_id::String, user_id::String)
    lock(store.task_lock) do
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
    lock(store.task_lock) do
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
    lock(store.task_lock) do
        delete!(store.task_registry, task_id)
    end
    return nothing
end

function try_delete_task!(store::InMemoryWorkerStore, task_id::String, from;
                          run_id::Union{Nothing, UUID})
    lock(store.task_lock) do
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

    lock(store.task_lock) do
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
    # `task_lock` -- the lock every submit, claim, finish and cancel needs -- so one owner listing
    # a 200k-record registry stalled the whole worker subsystem for its duration. Copying the
    # values is a pointer copy; the per-record work below then contends with nothing.
    #
    # Reading a record outside the lock is the same thing `get_task_status` already does with a
    # live object: `status` is a plain field written whole, and `watchers` is swapped
    # copy-on-write by `add_watcher!`, never grown in place, so the vector `_is_authorized`
    # iterates cannot be resized under it.
    snapshot = lock(() -> collect(values(store.task_registry)), store.task_lock)
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
    refs = lock(store.task_lock) do
        RunningTaskRef[_running_ref(t) for t in values(store.task_registry) if t.status == RUNNING]
    end
    return paged ? _keyset_page(refs, after, limit) : refs
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
clear_records!(store::InMemoryWorkerStore) = (lock(() -> empty!(store.task_registry), store.task_lock); nothing)

function lock_tasks(callback::Function, store::InMemoryWorkerStore)
    return lock(store.task_lock) do
        callback()
    end
end
