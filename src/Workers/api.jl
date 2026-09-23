function _resolve_runtime(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    if !isnothing(runtime)
        return runtime
    end

    installed = worker_runtime(ctx; key)
    return installed isa WorkerRuntime ? installed : default_runtime()
end

"""
    recover_zombie_tasks!(; runtime::WorkerRuntime=default_runtime(),
                          zombie_min_age::Union{Nothing, Dates.Period}=nothing,
                          batch_size::Int=ZOMBIE_SWEEP_BATCH) -> Int

Sweeps the store and transitions any tasks in `RUNNING` state that do not have an active local
thread executing them into a `FAILED` state. Returns how many it transitioned.

# `zombie_min_age`: only adjudicate claims old enough to be dead

With `zombie_min_age = Hour(1)` the sweep considers only records whose run claimed them **more
than an hour ago** (`started_at` older than `now - zombie_min_age`). Younger ones are left
`RUNNING` for a later sweep. A record with no `started_at` is always considered: nothing shows
it is recent, and Nitro's own claims always stamp one.

`nothing`, the default, bounds nothing, which is exactly what this sweep did before
([#239](https://github.com/PingoLee/Nitro.jl/issues/239)).

**Set it in a multi-process deployment.** The liveness check below is process-local, so a node
that boots while another node's task is genuinely mid-run sees that task as a zombie and marks it
`FAILED`. The run-id fence (#88, #108) spares only a task that *finishes* between the read and the
write, not one that keeps running. An age bound turns "no local handle" back into evidence of
death: choose a window longer than any task legitimately runs, and a claim older than that cannot
belong to a live run anywhere.

The bound deliberately points this way, at **old** claims, and not the other way (only adjudicate
recent ones). A lower bound would leave every genuinely stranded old record `RUNNING` forever.
That is exactly the backlog [#237](https://github.com/PingoLee/Nitro.jl/issues/237) is about,
and it is invisible to retention, which retires only records with a `completed_at`.

The cost is on the single-process side. A task stranded by a crash is recovered only by a sweep
that runs after its claim is `zombie_min_age` old, and the sweep runs only at [`start!`](@ref). A
single process that restarts right after a crash therefore leaves that crash's tasks `RUNNING`
until a later boot. That is why the default stays `nothing`.

Nothing else needs to grow for this. Once the sweep marks a record `FAILED` it carries a
`completed_at`, and the retention sweep retires it like any other finished task. `cleanup_tasks!`
does not need a `RUNNING` escape hatch.

It walks the `RUNNING` records `batch_size` at a time, by keyset on the id
([#237](https://github.com/PingoLee/Nitro.jl/issues/237)), so no step of it materializes the
whole backlog. That backlog is exactly what a crash leaves: every task in flight at a `SIGKILL`
stays `RUNNING`, and nothing but this sweep ever retires it. Each batch is adjudicated before the
next is read. The store's task lock is still held for the whole sweep, as it was before, because
the lock is what orders the sweep against runs registering in this process.

It logs twice at `@info` ([#238](https://github.com/PingoLee/Nitro.jl/issues/238)).
`"Nitro.Workers: scanning for zombie tasks"` goes out before it takes the lock, and
`"Nitro.Workers: zombie recovery complete"` goes out when it finishes, **always**, including when
it recovered nothing. The completion line carries `candidates`, `recovered`, `spared_live`,
`too_recent` and `lost_race`. If a read fails, an `@error` with the same counts replaces the
completion line, and the sweep returns what it had recovered so far. A write that throws is
logged the same way and then rethrown. Every field is a count; no task's `result` or `error` is
ever logged.

The sweep runs after the startup banner and before the first request is served, so when a boot
seems to hang after announcing itself, these two lines are the first thing to look for.

Reads the **durable** records, not the live-overlaid listing: this is a decision about durable
state, and `get_active_task` is the whole liveness criterion either way. It reads them through
[`list_running_task_refs`](@ref), which asks only for the id, run id and start time of each
`RUNNING` record, never through the listing API. The listing deserializes every record in full,
and on `PormGWorkerStore` it swallowed a read error into an empty result. So one record with a
malformed `result` blob used to make this sweep see no candidates at all
([#236](https://github.com/PingoLee/Nitro.jl/issues/236)).

Since #176 that criterion is *correct* rather than conditionally correct: `shutdown!` drains, and
keeps the handle of a run it could not finish, so a teardown no longer manufactures zombies out of
tasks that are still executing. The window is narrower, not gone — handles never cross runtimes, so
a restart that builds a **new** `WorkerRuntime` over the same store still sees the previous
runtime's abandoned runs as dead. That is also what makes a genuine process crash recoverable, and
why this stays process-local rather than trying to be authoritative.
"""
function recover_zombie_tasks!(; runtime::WorkerRuntime=default_runtime(),
                               zombie_min_age::Union{Nothing, Dates.Period}=nothing,
                               batch_size::Int=ZOMBIE_SWEEP_BATCH)
    batch_size >= 1 || throw(ArgumentError("`batch_size` must be at least 1, got $batch_size"))
    _check_zombie_min_age(zombie_min_age)
    # One cutoff for the whole sweep, taken before the first read: a claim is "old enough" against
    # the moment the sweep began, however long the backlog takes to walk.
    cutoff = zombie_min_age === nothing ? nothing : current_time_utc() - zombie_min_age

    # Before the lock, not inside it (#238). This sweep runs at every `start!`, AFTER the banner
    # has announced the server and before the first request can be served, so a hang here used to
    # read as a server that said it was up and then went silent. Logging before `lock_tasks` also
    # separates "waiting for the lock" from "working through the backlog".
    @info "Nitro.Workers: scanning for zombie tasks" zombie_min_age batch_size
    tally = _ZombieTally()
    return lock_tasks(runtime) do
        cursor = nothing
        while true
            # A failed read costs this sweep, never the boot that runs it: before #236 the PormG
            # listing swallowed the error into an empty result, so startup carried on regardless,
            # and that stays true. What changes is that it now says so -- and that batches already
            # adjudicated keep their outcome.
            page = try
                list_running_task_refs(runtime.store; after=cursor, limit=batch_size)
            catch e
                e isa InterruptException && rethrow()
                @error "Nitro.Workers: zombie recovery could not read the RUNNING tasks; stopping early" _tally_kwargs(tally)... exception=(e, catch_backtrace())
                return tally.recovered
            end
            try
                _recover_zombie_page!(tally, runtime, page, cutoff)
            catch e
                # A WRITE that throws still escapes, exactly as before #238. Unlike a failed read,
                # it leaves the sweep not knowing whether that transition landed, which is not a
                # state to boot past quietly. What it no longer does is escape without the tally,
                # so the log shows how far the sweep got.
                e isa InterruptException && rethrow()
                @error "Nitro.Workers: zombie recovery failed mid-sweep" _tally_kwargs(tally)... exception=(e, catch_backtrace())
                rethrow()
            end
            # Short means exhausted: an implementation returns fewer than `limit` only when
            # nothing is left. A LONGER page is the default method's whole remainder, and the
            # next read past it comes back empty.
            if length(page) < batch_size
                # UNCONDITIONAL, `recovered = 0` included: silence must stop being ambiguous
                # between "ran and found nothing" and "never got there" (#238). Counts only --
                # never a task's `result` or `error`, which are application data.
                @info "Nitro.Workers: zombie recovery complete" _tally_kwargs(tally)...
                return tally.recovered
            end
            cursor = last(page).id
        end
    end
end

# What the sweep did, for its log line. Every field is a count.
mutable struct _ZombieTally
    candidates::Int     # RUNNING records read
    recovered::Int      # transitioned to FAILED
    spared_live::Int    # this process holds a live handle for the run
    too_recent::Int     # claimed inside `zombie_min_age` (#239): left for a later sweep, not absent
    lost_race::Int      # the fenced transition was refused: it finished, or was re-run, meanwhile
end
_ZombieTally() = _ZombieTally(0, 0, 0, 0, 0)

_tally_kwargs(t::_ZombieTally) = (candidates=t.candidates, recovered=t.recovered,
                                  spared_live=t.spared_live, too_recent=t.too_recent,
                                  lost_race=t.lost_race)

_check_zombie_min_age(age) =
    age === nothing || age >= zero(age) ||
        throw(ArgumentError("`zombie_min_age` must not be negative, got $age"))

# One batch. Its transitions move rows out of `RUNNING` at ids at or below the cursor, so they
# cannot disturb the next page, which starts strictly past it.
function _recover_zombie_page!(tally::_ZombieTally, runtime::WorkerRuntime, page::AbstractVector,
                               cutoff::Union{Nothing, DateTime})
    for task in page
        tally.candidates += 1
        # Too recent to call dead: see `zombie_min_age`. Checked in Julia over the projected
        # `started_at` rather than in SQL, so a row it excludes is still SEEN, and the sweep can
        # say how many it left for later.
        if !(cutoff === nothing || task.started_at === nothing || task.started_at <= cutoff)
            tally.too_recent += 1
            continue
        end
        if !isnothing(get_active_task(runtime, task.id))
            tally.spared_live += 1
            continue
        end
        # `get_active_task` is process-local, so in a multi-process deployment this
        # sweep sees another node's genuinely-running task as a zombie. Claiming the
        # transition rather than saving a decision means that if the task finishes
        # (or is cancelled) between the read and the write, the real outcome stands
        # and this sweep writes nothing — the same rule every other terminal write
        # now follows (#88).
        # Addressed to the run this sweep actually inspected. Between the read above
        # and this write the key may have been re-run (#108), and declaring someone else's
        # live run dead is the same defect as clobbering its result.
        if try_transition!(runtime.store, task.id, (RUNNING,), FAILED;
                           run_id=task.run_id,
                           error="Worker process terminated unexpectedly mid-execution.",
                           completed_at=current_time_utc())
            tally.recovered += 1
        else
            tally.lost_race += 1
        end
    end
    return tally
end

function recover_zombie_tasks!(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing,
                               zombie_min_age::Union{Nothing, Dates.Period}=nothing,
                               batch_size::Int=ZOMBIE_SWEEP_BATCH)
    return recover_zombie_tasks!(; runtime=_resolve_runtime(ctx; key, runtime), zombie_min_age, batch_size)
end

# `store` selects a BACKEND and builds a runtime over it; `runtime` adopts one that already
# exists. Passing both is a contradiction rather than a precedence puzzle, so it is refused.
function _start_runtime_for!(ctx::App, key::Symbol,
                             store::Union{Nothing, AbstractWorkerStore},
                             runtime::Union{Nothing, WorkerRuntime},
                             drain_timeout::Real)
    if !isnothing(store) && !isnothing(runtime)
        throw(ArgumentError(
            "pass `store` (build a runtime over this backend) or `runtime` (use this one), not both"))
    end
    !isnothing(runtime) && return install!(ctx, runtime; key, drain_timeout)

    existing = worker_runtime(ctx; key)

    if !isnothing(store)
        # Reuse the installed runtime when it already wraps this very backend, so repeated
        # `start!(app; store = s)` stays idempotent. Minting a fresh runtime each time would
        # displace the previous one mid-flight -- and a displaced runtime that nobody shut down
        # is the #29 leak, rebuilt one level up.
        existing isa WorkerRuntime && existing.store === store && return existing
        return install!(ctx, WorkerRuntime(store); key, drain_timeout)
    end

    return existing isa WorkerRuntime ? existing : install!(ctx; key, drain_timeout)
end

"""
    start!(ctx::App; queues, cleanup_enabled, ..., store=nothing, runtime=nothing,
           drain_timeout=WORKER_DRAIN_TIMEOUT_SECONDS) -> WorkerRuntime

Install a runtime on `ctx` and start it: sweep zombies, spawn a processor per named queue, and
start (or stop) the cleanup scheduler.

Returns the `WorkerRuntime` — that is the handle to pass as `runtime=` to the task API.

`drain_timeout` reaches only [`install!`](@ref)'s displacement path: starting over a runtime that
is already installed tears the old one down first, and that teardown drains like any other (#176).

`zombie_min_age` bounds the zombie sweep to claims older than that period. Leave it `nothing` for
a single process; **set it when several processes share one store**. The reasoning, and the
trade, are on [`recover_zombie_tasks!`](@ref) (#239).
"""
function start!(ctx::App;
    queues::AbstractVector{<:AbstractString}=String[],
    cleanup_enabled::Bool=true,
    cleanup_interval_hours::Real=24,
    cleanup_retain_days::Int=7,
    recover_zombies::Bool=true,
    zombie_min_age::Union{Nothing, Dates.Period}=nothing,
    key::Symbol=DEFAULT_EXTENSION_KEY,
    store::Union{Nothing, AbstractWorkerStore}=nothing,
    runtime::Union{Nothing, WorkerRuntime}=nothing,
    drain_timeout::Real=WORKER_DRAIN_TIMEOUT_SECONDS,
)
    resolved = _start_runtime_for!(ctx, key, store, runtime, drain_timeout)

    if recover_zombies
        recover_zombie_tasks!(; runtime=resolved, zombie_min_age)
    end

    for queue_name in queues
        _start_queue_processor(resolved, String(queue_name))
    end

    if cleanup_enabled
        start_cleanup_scheduler(; interval_hours=cleanup_interval_hours, retain_days=cleanup_retain_days, runtime=resolved)
    else
        stop_cleanup_scheduler!(resolved)
    end

    return resolved
end

function startup(ctx::App;
    queues::AbstractVector{<:AbstractString}=String[],
    cleanup_enabled::Bool=true,
    cleanup_interval_hours::Real=24,
    cleanup_retain_days::Int=7,
    recover_zombies::Bool=true,
    zombie_min_age::Union{Nothing, Dates.Period}=nothing,
    key::Symbol=DEFAULT_EXTENSION_KEY,
    store::Union{Nothing, AbstractWorkerStore}=nothing,
    runtime::Union{Nothing, WorkerRuntime}=nothing,
    drain_timeout::Real=WORKER_DRAIN_TIMEOUT_SECONDS,
)
    # Refused here, where the middleware is built, not from the startup hook once serving began.
    _check_zombie_min_age(zombie_min_age)
    queue_names = String.(collect(queues))

    passthrough = function(handle::Function)
        return function(req)
            return handle(req)
        end
    end

    on_startup = () -> begin
        start!(ctx;
            queues=queue_names,
            cleanup_enabled=cleanup_enabled,
            cleanup_interval_hours=cleanup_interval_hours,
            cleanup_retain_days=cleanup_retain_days,
            recover_zombies=recover_zombies,
            zombie_min_age=zombie_min_age,
            key=key,
            store=store,
            runtime=runtime,
            drain_timeout=drain_timeout,
        )
        return nothing
    end

    on_shutdown = () -> begin
        # `terminate` runs this BEFORE it closes the listener, so this drain and
        # `serve(shutdown_timeout = …)` are consecutive, not concurrent — the two budgets add
        # into the process's worst-case exit time (#176).
        uninstall!(ctx; key, drain_timeout)
        return nothing
    end

    return LifecycleMiddleware(; middleware=passthrough, on_startup, on_shutdown)
end

"""
    scoped_task_key(task_key, owner::Owner; scope=:user) -> String

Resolve the caller-supplied `task_key` to the id a task is actually stored under.

Task ids double as deduplication keys, so their scope decides who can collide with
whom:

- `:user` (the default) prefixes the key with its owner, so two users submitting
  `"export_42"` get two independent tasks and neither can reach the other's.
- `:global` stores the key verbatim, giving system-wide deduplication. A caller who
  is not already a watcher of an existing global key is refused unless the store's
  watch authorizer allows it — see [`set_watch_authorizer!`](@ref).

`submit_task` and `submit_sequential_task` return the resolved id; pass *that* to
`get_task_status` and `cancel_task` along with the [`TaskAuthority`](@ref) the call acts
under. Use this function when the return value was not kept.

Throws `ArgumentError` for an unknown `scope`, or when a `:global` `task_key` contains
`$(TASK_KEY_DELIMITER)` — that would let a caller submit `"victim$(TASK_KEY_DELIMITER)report"`
globally and squat the id `victim`'s own `:user`-scoped `"report"` resolves to. Together
with the two rules [`Owner`](@ref) enforces on construction, that keeps the invariant that
**a `:user` id and a `:global` id can never be the same string**.

Why `Owner` bars both `$(TASK_KEY_DELIMITER)` *and* a trailing `:`: a `:user`-scoped
`task_key` *may* contain the delimiter, and barring it in the owner alone is not enough,
since `(":report", "alice")` and `("report", "alice:")` would both resolve to
`"alice:::report"`. That is the *only* such collision — matching
`u₁ ‖ :: ‖ k₁ == u₂ ‖ :: ‖ k₂` with neither owner containing `::` forces `u₂ == u₁ * ":"`
— so rejecting a trailing `:` closes it completely, and a colon anywhere else in an owner
(`"google:12345"`) stays legal. [`owner_of`](@ref) is the inverse those rules make total.
"""
function scoped_task_key(task_key::AbstractString, owner::Owner; scope::Symbol=:user)
    if scope === :global
        if occursin(TASK_KEY_DELIMITER, task_key)
            throw(ArgumentError(
                "a :global task_key must not contain '$TASK_KEY_DELIMITER': it would collide with the :user-scoped id namespace"))
        end
        return String(task_key)
    elseif scope !== :user
        throw(ArgumentError("scope must be :user or :global, got :$scope"))
    end

    # The owner half needs no check here: `Owner` validated it on construction, which is
    # also what closed the hole where the `:global` branch above returned before the
    # owner was ever validated, admitting an id no `Owner` could later be built from.
    return string(owner.user_id, TASK_KEY_DELIMITER, task_key)
end

function _authorize_queue!(store::AbstractWorkerStore, queue_name::String, owner::Owner)
    authorizer = get_queue_authorizer(store)
    # The hook's `(queue_name, user_id)::Bool` contract is app-facing and unchanged.
    if authorizer !== nothing && !(Base.invokelatest(authorizer, queue_name, owner.user_id)::Bool)
        throw(AuthorizationError("User '$(owner.user_id)' is not authorized to submit tasks to queue '$queue_name'"))
    end
    return nothing
end

# Watcher membership is what grants read and cancel rights, so joining an existing
# task the caller does not already watch is an authorization decision, not a
# bookkeeping one. Denied unless the store opts in.
function _watch_allowed(store::AbstractWorkerStore, task_key::String, watchers::Vector{String}, user_id::String)
    authorizer = get_watch_authorizer(store)
    authorizer === nothing && return false
    return Base.invokelatest(authorizer, task_key, watchers, user_id)::Bool
end

# Authorize against the cached record, and only if that denies, re-check the durable one.
#
# The `task_info` handed in reached its caller through `get_task_info(runtime, ·)`, so for a
# running task it may be the live in-memory object, which pollers read to see fresh progress
# without a round-trip. That cache is per process, so a grant issued *elsewhere*
# is not in it — and #96's whole motivating case is a task submitted on one node and polled
# from another. Denying on the cache alone would refuse a user who is authorized in the
# durable record, making the grant work or not depending on which node answered.
#
# Ordering matters for cost: the cached check succeeds for the owner and for any watcher
# this process already knows, so the extra read is paid only on the path that was about to
# raise anyway. It can only ever turn a denial into an approval, never the reverse.
function _authorize_or_reload!(store::AbstractWorkerStore, authority::TaskAuthority,
                               task_info::TaskInfo, action::AbstractString)
    _is_authorized(authority, task_info) && return nothing

    # `get_task_info(store, ·)` is the DURABLE read -- it is what `reload_task` used to be, and
    # no store caches live objects any more (#167).
    # Authorize against the durable record, but keep serving the cached one: the durable
    # row for a *running* task holds only what was flushed at RUNNING-start, so returning
    # it would admit the cross-process grantee and then hand them a frozen progress bar —
    # the exact field #96 exists to expose. The decision needs the durable record; the
    # payload does not.
    durable = get_task_info(store, task_info.id)
    durable !== nothing && _is_authorized(authority, durable) && return nothing

    _authorize_task!(authority, task_info, action)   # raises
    return nothing
end

# A `watchers=` grant is authorized by the *owner* — but a `:global` task has no owner
# half in its id, and there the store's watch authorizer IS the whole access policy. Left
# ungated, any admitted watcher could hand access to an identity the authorizer explicitly
# refuses, which is transitive expansion the app never approved. So `:global` grants go
# through the same gate a direct join would.
#
# `:user`-scoped grants need no such check: the id names its owner, and an owner sharing
# their own task is exactly what the feature is for.
function _authorize_grant!(store::AbstractWorkerStore, task_key::String,
                           watchers::Vector{String}, grant::Owner)
    owner_of(task_key) === nothing || return nothing        # :user scope — owner's call
    grant.user_id in watchers && return nothing             # already admitted
    if !_watch_allowed(store, task_key, copy(watchers), grant.user_id)
        throw(AuthorizationError(
            "User '$(grant.user_id)' is not authorized to watch task '$task_key'"))
    end
    return nothing
end

# Returns the new run's `run_id` when the caller should START it, and `nothing` when the caller
# merely joined an existing one as a watcher.
#
# It returned a `Bool` until #182. **This is the only place a run's identity is known for certain,
# because it is where the run is minted**, so every fence downstream carries it from here rather
# than re-deriving it. Both submit paths do: `submit_sequential_task` puts it on the `QueueItem`,
# `submit_task` hands it to `_execute_task_async`.
#
# Three writes depend on that. A teardown abandoning the backlog records a terminal state
# ADDRESSED TO THE RUN that queued the item rather than to its key (#182, workers §6), and both
# execution paths check it before registering their run handles and fence their start claim on it
# (#191). Deriving any of them by re-reading the record does not work: by then the record may
# belong to a successor, so the abandon would cancel a run about to start and the start claim
# would agree with a run that is not the caller's.
function _register_or_watch!(runtime::WorkerRuntime, task_key::String, owner::Owner;
                             queue_name::Union{Nothing, String}=nothing,
                             grants::AbstractVector{Owner}=Owner[])
    uid = owner.user_id
    return lock_tasks(runtime) do
        # The DURABLE read, not the live-preferring one, by the rule in `get_task_info`: this is
        # a CLAIMING call -- it decides whether to build a new run and replace the record. It
        # consults only `status` and `watchers`, both of which the row carries authoritatively,
        # since `add_watcher!` writes the row first.
        task_info = get_task_info(runtime.store, task_key)

        # Gates both branches below: joining a live task grants the caller the
        # owner's read/cancel rights, and replacing a finished one destroys the
        # owner's stored result. `copy` keeps an app callback off the live list.
        #
        # There is no stale-cache re-read here, unlike the read paths: the record above already
        # IS the durable one, so a second read could only return the same answer.

        if task_info !== nothing && !_is_authorized(owner, task_info)
            if !_watch_allowed(runtime.store, task_key, copy(task_info.watchers), uid)
                throw(AuthorizationError(
                    "User '$uid' is not authorized to join or reuse task '$task_key'"))
            end
        end

        # Snapshot the watcher list ONCE, before anything is written, and show every
        # grant the same value. Reading it live instead made the app's authorizer hook
        # see a different `watchers` argument per backend and per timing: the in-memory
        # store's `add_watcher!` mutated the very object we hold, while the database store's
        # only patched a live copy when the task was already registered as active. Both now take
        # the single `add_watcher!(runtime, ·)` store-then-mirror path, so that particular
        # divergence is gone -- but the snapshot stays, because a hook written as
        # `all(w -> same_org(w, uid), watchers)` must see one value per call regardless.
        seen = task_info === nothing ? String[] : copy(task_info.watchers)

        # Authorize every grant before applying any. Otherwise a refusal partway through
        # throws with the earlier grants already durably written — and a submit that
        # raised would still have handed out access.
        for grant in grants
            _authorize_grant!(runtime.store, task_key, seen, grant)
        end

        if task_info !== nothing && task_info.status in (RUNNING, PENDING)
            # Atomic and idempotent in the store. Composing this out of
            # get + push! + set_task! under `lock_tasks` is what #88 was: that lock is
            # process-local for a database-backed store, so the read-modify-write was
            # last-write-wins across processes.
            add_watcher!(runtime, task_key, uid)
            for grant in grants
                add_watcher!(runtime, task_key, grant.user_id)
            end
            return nothing
        end

        # Re-running a finished key replaces the record and resets its watchers to the
        # resubmitter — the one place a whole record, watchers included, is written.
        # The record we are about to discard may still have a live run behind it. `run_id`
        # stops that run from writing (#108); this is the only thing that can reclaim the
        # thread it is sitting on. In-process only -- a run hosted on another node is
        # unreachable from here and will keep going until its callback returns.
        previous = get_active_task_info(runtime, task_key)
        previous === nothing || _request_cancel!(previous, :superseded)

        task_info = TaskInfo(task_key; queue_name)
        push!(task_info.watchers, uid)
        for grant in grants
            grant.user_id in task_info.watchers || push!(task_info.watchers, grant.user_id)
        end
        # Through the RUNTIME: publishing a successor also evicts the run it displaced from
        # the live caches, so nothing later reads a run that no longer owns this key.
        replace_task!(runtime, task_key, task_info)
        return task_info.run_id
    end
end

# `Threads.@spawn`, not `@async` (#30). `@async` creates a **sticky** task, pinned for life to
# the thread that created it -- here, a request-handling thread. A CPU-bound callback that never
# yields therefore starved every other coroutine on that thread, including the requests
# `parallel_stream_handler` had scheduled there, which is exactly the stall workers exist to
# prevent. `Threads.@spawn` creates a migratable task on the `:default` pool, which is the model
# nitro-core §2 asks for and the one `src/core/transport.jl` already uses per request (#39).
#
# What made this unlandable before was not thread affinity but exception injection: cancellation
# and timeout used to `schedule(…, error=true)` into this task, which is undefined behaviour
# against a task executing on another thread and aborted the process. #127 removed both
# injections, and that -- not any property of this function -- is what makes migration safe. Note
# the criterion is "does anything inject into this task?", not "is this the request path": with
# nothing injecting anywhere, `start_cleanup_scheduler` could migrate too, and stays `@async` only
# because it runs no user code.
#
# Nothing in `src/Workers/` depends on thread affinity: no `Threads.threadid()`, no task-local
# storage, no `SpinLock`. Every lock here is a `ReentrantLock`, which keys on `current_task()`, so
# a migrating task keeps what it holds, and `TaskInfo.progress` is `@atomic`. An **app** callback
# using the `buffers[Threads.threadid()]` pattern was already unsound under `@async` and is now
# visibly so.
#
# The cost this adds, stated plainly: a cancelled or timed-out callback that never polls
# `cancel_requested` now holds one of `Threads.nthreads()` `:default`-pool slots -- the same pool
# serving HTTP -- until it returns, instead of starving one thread's coroutines. See the timeout
# warning in `docs/src/tutorial/workers.md`.
#
# `run_id` is POSITIONAL and REQUIRED, never a defaulted keyword: the unfenced call must not be
# the shorter one to write (#48, #108). It is the identity `_register_or_watch!` minted for this
# run, and it is the only thing that makes the read below this run's own.
function _execute_task_async(runtime::WorkerRuntime, task_key::String, callback::Function, options::TaskOptions, run_id::UUID)
    # `_spawn_detached`, not `Threads.@spawn`: the run must not inherit the submitter's dynamic
    # scope, or `_claim_run!` below writes on the submitter's open PormG transaction (#209).
    task = _spawn_detached() do
        # The durable read, the #191 identity check against the CARRIED `run_id`, and the handle
        # publish, as one critical section under the store lock -- `_claim_run!` (`queue.jl`)
        # owns the rationale. Runs INSIDE the spawned task, because the handle it publishes is
        # `current_task()`.
        #
        # This path is DIFFERENTLY exposed to a supersede than the sequential one, not simply
        # less: its window is shorter in wall-clock -- a lock release, a `Threads.@spawn`
        # scheduling hand-off, and on `PormGWorkerStore` a database round-trip, against a queued
        # item that can sit in a `Channel(100)` behind a long job for minutes -- but its
        # CONSEQUENCE is worse. Where the sequential path usually serializes a stale item against
        # its successor on `exec_lock`, here both runs are spawned tasks by construction, so
        # nothing serializes them and the interleaving in which one stole the other's handles was
        # the ordinary case rather than an edge. A concurrent `cancel_task` plus re-submit needs
        # only `lock_tasks` -- which is exactly why the claim takes it (#191, #198).
        task_info = _claim_run!(runtime, task_key, run_id)
        task_info === nothing && return nothing

        # Starting is a CLAIMED transition, not an unconditional write. `set_task!` has no
        # precondition, so a `cancel_task` that already claimed PENDING -> CANCELLED was simply
        # overwritten here a moment later; the callback then ran and `_complete_task!`'s own CAS
        # succeeded from RUNNING, reporting COMPLETED for a task whose caller had been told
        # "Task cancelled". Silent, and not fixable by locking -- the two writes are strictly
        # sequential (#142). The CAS *is* the write, so there is no `set_task!` after it.
        #
        # In the ASYNC path this was masked, not absent: `cancel_task` also interrupted the worker
        # task, and a task that had not started yet never ran its body at all. The sequential path
        # had no such cover -- its processor is already `Threads.@spawn`ed, and a cancel can land
        # between its `get_task_info` and its start write. Removing the interrupt (#127) uncovers
        # the async path too, which is why this lands FIRST.
        started = current_time_utc()

        # The handles are already published -- `_claim_run!` did it BEFORE this claim of RUNNING,
        # not after; `_execute_queued_task` says why that order matters to `recover_zombie_tasks!`.
        #
        # `try`/`finally`, so this run's handles are released on EVERY exit -- including the
        # two that no terminal write covers: a store exception escaping the claim below (the
        # spawned task simply fails), and the `0:max_attempts` loop falling through when
        # `retry_on_failure=true` with a negative `max_retries`, which `TaskOptions` does not
        # reject. Both leaked a registration nothing ever removed. `shutdown!` used to sweep
        # those up by accident with `empty!(active_tasks)`; now that it drains and deliberately
        # KEEPS live handles, a leaked one can never settle -- so every later teardown on this
        # runtime would burn its whole `drain_timeout` and then warn about a run that ended long
        # ago (#176).
        #
        # `_deregister_run!` is fenced on `run_id` and idempotent, so this is a no-op on every
        # path `_finish_task!` already covered.
        try
            # The CARRIED identity, not the one read back a moment ago -- see the matching
            # comment in `_execute_queued_task` (#191).
            if !try_transition!(runtime.store, task_key, (PENDING,), RUNNING;
                                run_id=run_id, started_at=started)
                # Cancelled, or the record moved on between the read and this CAS. The `finally`
                # hands the handles back -- fenced, so we cannot tear down a successor's (#108).
                return task_info
            end

            task_info.status = RUNNING
            task_info.started_at = started

            max_attempts = options.retry_on_failure ? options.max_retries : 0
            for retry_count in 0:max_attempts
                try
                    result = timeout_call(callback, task_info; timeout=options.timeout)
                    return _complete_task!(runtime, task_info, result)
                catch error
                    unwrapped = _unwrap_exception(error)

                    # NOT dead code, however redundant it looks. `_fail_task!` below would lose
                    # its CAS against an already-CANCELLED record anyway -- but without this
                    # branch a cancelled task with `retry_on_failure` falls through to the
                    # backoff `sleep` and RE-RUNS. This is what short-circuits the retry loop.
                    #
                    # `unwrapped isa InterruptException` used to be an arm of this test, back when
                    # cancellation was delivered by injecting one. Nothing injects any more, so
                    # the only way one arrives is that the callback itself threw it -- and nothing
                    # set a cancel reason for it, so recording it as a cancellation would be a lie
                    # about who stopped the job (#127).
                    latest_info = get_task_info(runtime, task_key)
                    if latest_info !== nothing && latest_info.status == CANCELLED
                        return _cancel_task!(runtime, task_info)
                    end

                    # A timeout is terminal on the first attempt. Retrying it cannot help and can
                    # harm: nothing stops the attempt that timed out, so `max_retries = 3` would
                    # put four copies of the callback on the thread pool at once, sharing one
                    # `task_info` and one set of external side effects (#127). The token is not
                    # reset between attempts either, so a retry would start pre-cancelled.
                    if unwrapped isa TaskTimeoutError
                        return _fail_task!(runtime, task_info, _store_error_text(runtime.store, unwrapped))
                    end

                    if retry_count == max_attempts
                        return _fail_task!(runtime, task_info, _store_error_text(runtime.store, unwrapped))
                    end

                    # Cancellation-aware backoff. The catch above checks CANCELLED before sleeping and
                    # never after, and the interrupt that used to abort this sleep is gone (#127) -- so a
                    # cancel landing inside a 2/4/8s window re-invoked the user callback on a task that was
                    # already cancelled. Polling the token instead of sleeping blind also cuts cancellation
                    # latency during a backoff from seconds to milliseconds.
                    deadline = time() + 2.0 ^ (retry_count + 1)
                    while time() < deadline && !cancel_requested(task_info)
                        sleep(0.05)
                    end

                    # The token is process-local, so a cancel issued on another node sets nothing here. One
                    # durable read per ATTEMPT (not per poll) covers that without a round-trip every 50ms.
                    if cancel_requested(task_info)
                        return _cancel_task!(runtime, task_info)
                    end
                    resumed = get_task_info(runtime.store, task_key)
                    if resumed !== nothing && resumed.status == CANCELLED
                        return _cancel_task!(runtime, task_info)
                    end
                end
            end

            return task_info
        finally
            _deregister_run!(runtime, task_info)
        end
    end

    # No handle registration here. The body registers `current_task()` -- the very same Task
    # object -- as part of claiming its start (through `register_run!`), so this was always a
    # duplicate write of an identical value; under `@async` it merely happened first, because
    # the parent could not yield between the spawn and this line. Under `Threads.@spawn` the
    # body may complete and deregister BEFORE this line runs, re-registering a finished task that nothing will ever
    # clean up. Its one non-duplicate effect was on the early-return path above, where it
    # registered a handle for a key with no record at all -- a permanent leak that makes
    # `recover_zombie_tasks!` skip a later genuinely-dead run under the same key, since that
    # sweep asks only whether an entry exists.
    return task
end

"""
    submit_task(task_key, callback, owner::Owner; scope=:user, watchers=Owner[],
                options=TaskOptions(), runtime=default_runtime())

Run `callback` on its own task and return the id it was stored under.

`scope` decides how `task_key` is namespaced — see [`scoped_task_key`](@ref). The
returned id is what `get_task_status` and `cancel_task` expect; under the default
`:user` scope it is *not* the `task_key` that was passed in.

Unqueued tasks are still submissions, so the store's queue authorizer applies under
the name `$(DEFAULT_QUEUE_NAME)`.

# Granting a second identity access

`watchers` grants additional identities read, list and cancel access to the task, because
the identity that *submits* a task is not always the identity that *polls* it: a browser
may upload under a deliberately short-lived credential while the application's own backend,
holding a different long-lived one, drives the progress bar
([#96](https://github.com/PingoLee/Nitro.jl/issues/96)).

```julia
task_id = submit_task("import-42", cb, Owner("browser-client");
                      watchers = [Owner("backend-service")])
```

The grant is deliberately made **at submit time, by the owner**, rather than by a later
`add_watcher!(task_id, …)` call. Submitting is the moment the owner is already resolved and
authorized, so there is no separate authorization question to answer — and a post-hoc
public grant would be a second way to reach the watcher list, which is exactly the surface
[#19](https://github.com/PingoLee/Nitro.jl/issues/19) closed.

A granted identity gets the **same rights as the owner minus ownership**: read, list, and
**cancel**, since `cancel_task` gates on the same list. If that is more authority than you
want to hand out, do not grant it — there is no read-only grant today.

Re-running a *finished* key replaces the record and resets its watchers, so grants must be
passed again on each such resubmission. Granting an identity that is already a watcher —
including the owner — is a no-op.
"""
function submit_task(task_key::AbstractString, callback::Function, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), runtime::WorkerRuntime=default_runtime())
    _authorize_queue!(runtime.store, DEFAULT_QUEUE_NAME, owner)

    key = scoped_task_key(task_key, owner; scope)
    # The run identity is PLUMBED here, exactly as `submit_sequential_task` plumbs it onto the
    # `QueueItem`. This used to read "the async path does not carry the run identity ... only a
    # QUEUED item needs it, because it may sit in a buffer long enough for the record to move
    # on", and both halves were wrong (#191). A durable read is a LOOKUP, not a fence -- #167
    # says which record to read, never that reading it authenticates the reader. And "long
    # enough" is not a correctness criterion: the window here is a lock release plus a `@spawn`
    # scheduling hand-off, not a buffer wait, and it is unbounded under thread pressure.
    run_id = _register_or_watch!(runtime, key, owner; grants=watchers)
    if run_id !== nothing
        _execute_task_async(runtime, key, callback, options, run_id)
    end
    return key
end

function submit_task(ctx::App, task_key::AbstractString, callback::Function, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return submit_task(task_key, callback, owner; scope, watchers, options, runtime=_resolve_runtime(ctx; key, runtime))
end

"""
    submit_sequential_task(queue_name, task_key, callback, owner::Owner; scope=:user,
                           watchers=Owner[], options=TaskOptions(), runtime=default_runtime())

Queue `callback` for one-at-a-time execution on `queue_name` and return the id it was
stored under.

Identical to [`submit_task`](@ref) in how `scope` namespaces `task_key` and in what the
return value is for; the difference is ordered execution and that the queue authorizer
sees the real `queue_name`.
"""
function submit_sequential_task(queue_name::AbstractString, task_key::AbstractString, callback::Function, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), runtime::WorkerRuntime=default_runtime())
    queue_id = String(queue_name)

    _authorize_queue!(runtime.store, queue_id, owner)

    key = scoped_task_key(task_key, owner; scope)
    run_id = _register_or_watch!(runtime, key, owner; queue_name=queue_id, grants=watchers)
    if run_id !== nothing
        # One lookup, not two. `_start_queue_processor` already returns the queue it spawned a
        # processor for, and a second `_get_or_create_queue` can return a DIFFERENT object: since
        # `shutdown!` empties the registry, a teardown landing between the two calls makes the
        # second lookup mint a fresh queue with an open channel and no processor. The `put!` would
        # then succeed and the task would sit PENDING with nothing draining it -- a silent hang in
        # place of the loud `InvalidStateException` a closed channel raises.
        queue = _start_queue_processor(runtime, queue_id)
        item = QueueItem(key, run_id, callback, options)

        # A teardown landing between resolving the queue and handing it the item makes this
        # `put!` throw, and the record written a moment ago by `_register_or_watch!` is then
        # `PENDING` with nothing that will ever run it -- the same orphan #182 removes from the
        # buffered backlog, arriving through the one door closing the channel leaves open. It is
        # not rare: `close` raises in every submitter already blocked on a full `Channel(100)`,
        # so a busy queue torn down mid-deploy produces one of these per waiter.
        #
        # The exception still propagates -- the caller has to learn the submission failed, which
        # is the whole argument for the loud close over a silent hang -- but the record is now
        # terminal rather than abandoned.
        try
            put!(queue.channel, item)
        catch error
            error isa InvalidStateException || rethrow()
            try
                _abandon_queued_item!(runtime, item)
            catch abandon_error
                # Never let bookkeeping replace the caller's exception: the `put!` failure is
                # what they must see, and a store that is also down would otherwise mask it.
                @error "Worker task orphaned by a teardown could not be recorded" exception=(abandon_error, catch_backtrace()) task_key=key
            end
            rethrow()
        end
    end
    return key
end

function submit_sequential_task(ctx::App, queue_name::AbstractString, task_key::AbstractString, callback::Function, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return submit_sequential_task(queue_name, task_key, callback, owner; scope, watchers, options, runtime=_resolve_runtime(ctx; key, runtime))
end

function get_task_status(task_id::AbstractString, authority::TaskAuthority; runtime::WorkerRuntime=default_runtime())
    task_info = get_task_info(runtime, String(task_id))
    if task_info === nothing
        return Dict{Symbol, Any}(:error => "Task not found", :status => "NOT_FOUND")
    end

    _authorize_or_reload!(runtime.store, authority, task_info, "view")

    return Dict{Symbol, Any}(
        :id => task_info.id,
        :owner => owner_of(task_info.id),
        :status => string(task_info.status),
        :progress => task_info.progress,
        :result => task_info.result,
        :error => task_info.error,
        :created_at => task_info.created_at,
        :started_at => task_info.started_at,
        :completed_at => task_info.completed_at,
        :watcher_count => length(task_info.watchers),
        :queue_name => task_info.queue_name,
    )
end

function get_task_status(ctx::App, task_id::AbstractString, authority::TaskAuthority; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return get_task_status(task_id, authority; runtime=_resolve_runtime(ctx; key, runtime))
end

function cancel_task(task_id::AbstractString, authority::TaskAuthority; runtime::WorkerRuntime=default_runtime())
    return lock_tasks(runtime) do
        task_info = get_task_info(runtime, String(task_id))
        if task_info === nothing
            return Dict{Symbol, Any}(:error => "Task not found")
        end

        _authorize_or_reload!(runtime.store, authority, task_info, "cancel")

        if task_info.status in (COMPLETED, FAILED, CANCELLED)
            return Dict{Symbol, Any}(:error => "Task already finished with status $(task_info.status)")
        end

        # Claim the transition *before* interrupting anything. The status precondition
        # and the write are one atomic step in the store, so a task finishing
        # concurrently — in this process or another one sharing the database — either
        # loses the race and stays cancelled, or wins it and we report the truth.
        # Doing this with a read, a decision, and a full-record save under `lock_tasks`
        # was #88: that lock does not span processes.
        # Fencing this on `run_id` is an AUTHORIZATION fix, not merely bookkeeping.
        # `_authorize_or_reload!` above decided against the watcher list of the run we read,
        # and re-running a finished key RESETS that list (`replace_task!`). Cancelling the
        # successor on the predecessor's grant would be an authorization the app never issued
        # — reachable across processes, since `lock_tasks` is process-local for a
        # database-backed store (#108).
        cancelled_at = current_time_utc()
        claimed = try_transition!(runtime.store, task_info.id, (PENDING, RUNNING), CANCELLED;
                                  run_id=task_info.run_id,
                                  error=_cancel_message(:user), completed_at=cancelled_at)

        if !claimed
            # DURABLE: reaching here means the row is no longer in `(PENDING, RUNNING)`, or
            # failed the run fence. A live object still reporting RUNNING would render as
            # "already finished with status RUNNING" -- a sentence the CAS above just disproved.
            latest = get_task_info(runtime.store, task_info.id)
            latest === nothing && return Dict{Symbol, Any}(:error => "Task not found")
            if latest.run_id != task_info.run_id
                # Distinguished on purpose: reporting the successor's status here would say
                # "Task already finished with status PENDING", which is nonsense.
                return Dict{Symbol, Any}(
                    :error => "Task was re-submitted; the run you asked to cancel has already ended")
            end
            return Dict{Symbol, Any}(:error => "Task already finished with status $(latest.status)")
        end

        # Ask the callback to stop. This replaces
        # `schedule(worker_task, InterruptException(), error=true)`, which was only ever safe
        # while worker tasks were thread-pinned: `schedule(t, exc; error=true)` does not
        # check whether `t` is running, and injecting into a task executing on another
        # thread aborts the process in `jl_finish_task` (#127, blocking #30).
        #
        # `get_active_task_info`, NOT `get_task_info`: the latter falls back to a database
        # read for a database-backed store and hands back a throwaway object the callback
        # does not hold, so the write would be a silent no-op. The `run_id` guard keeps the
        # request off a successor run (#108).
        #
        # Nothing is deregistered here any more. That used to mean "this process is done
        # running it", which was true a moment later under the old model and is false now --
        # the callback keeps going. Leaving the handles in place keeps `get_active_task`
        # honest for `recover_zombie_tasks!` and keeps `get_task_info` serving live progress
        # for a task that is still producing it. `_finish_task!` tears them down whether or
        # not it wins its CAS, so nothing leaks.
        live = get_active_task_info(runtime, task_info.id)
        if live !== nothing && live.run_id == task_info.run_id
            # AFTER the durable claim above, which is why that write renders `:user` directly
            # rather than reading the token back. The two can legitimately disagree: if a drain
            # had already asked (`:shutdown`) without claiming anything, this CAS loses and the
            # token keeps `:shutdown` while the record says "Cancelled by user". Both are true of
            # what they describe -- the token says who asked FIRST, the record says who CLAIMED
            # it -- and the claim is the half an operator reads.
            _request_cancel!(live, :user)

            # Mirror the claim onto the live record, which is a REQUIREMENT now that this
            # function no longer deregisters it. `PormGWorkerStore.try_transition!` writes
            # only the database row, and its `get_task_info` prefers the live object -- so
            # without this a cancelled task kept reporting RUNNING until its callback
            # returned: `get_task_status` lied, a second `cancel_task` answered "already
            # finished with status RUNNING", and `_register_or_watch!` saw RUNNING and
            # silently refused to re-run the key. `InMemoryWorkerStore` never had the
            # problem because its CAS mutates the very object the registry holds, so
            # leaving this out made the two backends disagree.
            #
            # It also makes the `task_info.status == CANCELLED` poll that the tutorial has
            # always documented actually work under PormG, which it never did.
            live.status = CANCELLED
            live.error = _cancel_message(:user)
            live.completed_at = cancelled_at
        end

        return Dict{Symbol, Any}(:status => "Task cancelled")
    end
end

function cancel_task(ctx::App, task_id::AbstractString, authority::TaskAuthority; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return cancel_task(task_id, authority; runtime=_resolve_runtime(ctx; key, runtime))
end

"""
    get_all_tasks(authority, status=nothing; runtime=default_runtime(), after=nothing, limit=nothing)
        -> Vector{Dict{Symbol, Any}}

The tasks `authority` may see, optionally only those in `status`, sorted by `:created_at`.

Pass `limit` to read a large listing a page at a time instead of materializing it whole
([#237](https://github.com/PingoLee/Nitro.jl/issues/237)). A paged result is ordered by `:id`,
**not** by `:created_at`, because the page boundary is a cursor on the id. Pass the last entry's
`:id` as `after` to get the next page. A page shorter than `limit` is the last one.

```julia
page = get_all_tasks(System(); limit = 500)
while !isempty(page)
    foreach(handle, page)
    length(page) < 500 && break
    page = get_all_tasks(System(); limit = 500, after = last(page)[:id])
end
```
"""
function get_all_tasks(authority::TaskAuthority, filter_status::Union{Nothing, TaskStatus}=nothing;
                       runtime::WorkerRuntime=default_runtime(),
                       after::Union{Nothing, String}=nothing, limit::Union{Nothing, Int}=nothing)
    paged = _check_page(after, limit)
    task_infos = get_all_tasks(runtime, authority; status=filter_status, after, limit)
    tasks = Vector{Dict{Symbol, Any}}()
    for task_info in task_infos
        push!(tasks, Dict{Symbol, Any}(
            :id => task_info.id,
            :owner => owner_of(task_info.id),
            :status => string(task_info.status),
            :progress => task_info.progress,
            :watcher_count => length(task_info.watchers),
            :created_at => task_info.created_at,
            :started_at => task_info.started_at,
            :queue_name => task_info.queue_name,
        ))
    end
    # A page keeps the store's id order. Re-sorting it here would be wrong twice: by
    # `created_at` it breaks the "last `:id` is the cursor" rule, and even by id a Julia sort need
    # not agree with the collation the database paged under.
    paged || sort!(tasks, by=task -> task[:created_at])
    return tasks
end

function get_all_tasks(ctx::App, authority::TaskAuthority, filter_status::Union{Nothing, TaskStatus}=nothing;
                       key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing,
                       after::Union{Nothing, String}=nothing, limit::Union{Nothing, Int}=nothing)
    return get_all_tasks(authority, filter_status; runtime=_resolve_runtime(ctx; key, runtime), after, limit)
end

function cleanup_old_tasks(days::Int=7; runtime::WorkerRuntime=default_runtime())
    return cleanup_tasks!(runtime.store, days)
end

function cleanup_old_tasks(ctx::App, days::Int=7; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return cleanup_old_tasks(days; runtime=_resolve_runtime(ctx; key, runtime))
end

"""
    get_queue_status(queue_name, ::System; runtime=default_runtime()) -> Dict{Symbol, Any}

Queue-wide introspection: depth, whether the processor is running, the current task, and
the ids of everything pending on `queue_name`.

**This is an admin surface, and it takes `System()` only.** Queue depth and `:current_task`
are global facts about a queue, not facts about any one user, and `:pending_tasks`
enumerates ids that — since [#19](https://github.com/PingoLee/Nitro.jl/issues/19) — carry
their owner in the `"<owner>::<key>"` prefix. Handing it an `Owner` and filtering the id
list would produce something that *looks* user-scoped while still reporting another
tenant's queue depth, which is the shape [#87](https://github.com/PingoLee/Nitro.jl/issues/87)
exists to stop. An `Owner` is a `MethodError` here on purpose.

Mount it behind the same authorization you would put in front of Sidekiq Web, Oban Web or
a Hangfire dashboard — all-or-nothing, and not on a user-facing route. If you want to show
a user *their* place in a queue, build that from `get_all_tasks(Owner(uid), PENDING)`,
which reports only what they may see.
"""
function get_queue_status(queue_name::AbstractString, ::System; runtime::WorkerRuntime=default_runtime())
    qlock = get_queue_lock(runtime)
    queues = get_sequential_queues(runtime)

    lock(qlock) do
        queue = Base.get(queues, String(queue_name), nothing)
        if queue === nothing
            return Dict{Symbol, Any}(:error => "Queue not found")
        end

        pending_tasks = [task.id for task in get_all_tasks(runtime, System(); status=PENDING, queue_name=String(queue_name))]
        processing = queue.current_task !== nothing
        return Dict{Symbol, Any}(
            :queue_name => String(queue_name),
            :running => queue.running,
            :current_task => queue.current_task,
            :pending_count => Base.n_avail(queue.channel),
            :pending_tasks => pending_tasks,
            :status_text => processing ? "Processing" : (isempty(pending_tasks) ? "Idle" : "Queued"),
            :total_load => length(pending_tasks) + (processing ? 1 : 0),
        )
    end
end

function get_queue_status(ctx::App, queue_name::AbstractString, authority::System; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return get_queue_status(queue_name, authority; runtime=_resolve_runtime(ctx; key, runtime))
end

function start_cleanup_scheduler(; interval_hours::Real=24, retain_days::Int=7, runtime::WorkerRuntime=default_runtime())
    scheduler_ref = get_cleanup_scheduler(runtime)
    existing = scheduler_ref[]
    if !isnothing(existing) && !istaskdone(existing.task)
        return existing
    end

    stop_signal = Channel{Nothing}(1)
    interval_seconds = max(interval_hours * 3600, 0.01)
    # Deliberately `@async` while worker bodies are `Threads.@spawn` (#30). The old
    # discriminator -- "does anything `schedule(…, error=true)` this task?" -- stopped
    # discriminating when #127 removed every injection, so it is not the reason. The reason is
    # that this task runs no user code: it sleeps in `timedwait` and calls `cleanup_old_tasks`
    # once a day, so there is nothing here that could starve a thread and nothing to gain from
    # migrating it. It is stopped by a `Channel` signal, never by an interrupt.
    #
    # This is Nitro's fourth background janitor, and it stays hand-rolled rather than going
    # through `_janitor` (src/middleware/janitor.jl) on purpose: it is channel-signalled and
    # waited-on (`stop_cleanup_scheduler!` joins it, with no deadline), which is the second
    # shape #190 explicitly refused to fold into that helper. What it must share with the other
    # three is the discipline, not the helper -- and before #195 it shared none of it:
    #
    #   * `errormonitor`, because nothing waits on this task until teardown. Without it a throw
    #     that escapes the loop is stored in the `Task` and surfaces HOURS later, as a
    #     `TaskFailedException` out of `shutdown!` (#193) -- causally unrelated-looking to the
    #     03:00 fault that actually killed the sweep.
    #   * the `try` INSIDE the `while`. `cleanup_old_tasks` is `cleanup_tasks!` on a
    #     caller-supplied store -- for `PormGWorkerStore` a database DELETE -- so a connection
    #     blip, a lock timeout or a migration running against the table all throw. A throw must
    #     cost one tick, never the scheduler: this is the component whose entire job is bounding
    #     the task table, and with the `try` hoisted out (or absent, as it was) one transient
    #     error left rows accumulating for the life of the process (#169, #190, #195).
    #   * `_schedule_detached`, not a bare `@async` (#209). The scheduler is started from
    #     `start!`, which an app may well call inside its own bootstrap transaction, and it then
    #     issues a store DELETE on every tick for the life of the process. `@async`'s stickiness
    #     is kept; only the inherited dynamic scope is dropped.
    task = errormonitor(_schedule_detached() do
        while true
            # Closed counts as stopped: `stop_cleanup_scheduler!` signals by closing, and an
            # empty closed channel is never `isready`.
            wait_result = timedwait(() -> isready(stop_signal) || !isopen(stop_signal), interval_seconds)
            if wait_result == :ok
                break
            end
            try
                deleted = cleanup_old_tasks(retain_days; runtime=runtime)
                # A success line too (#238), so a quiet log means "nothing to retire" rather than
                # "never ran". It is `@info` only when the tick did something: the default cadence
                # is daily, but the interval is caller-supplied, and an unconditional line at a short
                # interval is noise. The boot-time zombie sweep is the one that logs
                # unconditionally -- it runs once, in the window where silence cost an incident.
                if deleted isa Integer && deleted > 0
                    @info "Nitro.Workers: task retention sweep complete" deleted retain_days
                else
                    @debug "Nitro.Workers: task retention sweep complete" deleted retain_days
                end
            catch e
                # Rethrow guard, per the idiom in src/utilities/misc.jl and
                # src/middleware/janitor.jl: a catch-all that eats `InterruptException` makes
                # Ctrl-C during a sweep a no-op.
                e isa InterruptException && rethrow()
                @error "Nitro.Workers: task retention sweep failed" exception=(e, catch_backtrace())
            end
        end
    end)

    scheduler = CleanupScheduler(task, stop_signal)
    scheduler_ref[] = scheduler
    return scheduler
end

function start_cleanup_scheduler(ctx::App; interval_hours::Real=24, retain_days::Int=7, key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return start_cleanup_scheduler(; interval_hours, retain_days, runtime=_resolve_runtime(ctx; key, runtime))
end

function stop_cleanup_scheduler!(scheduler::CleanupScheduler)
    # `close`, not `put!`. Nothing ever `take!`s this signal -- the scheduler only polls it -- so a
    # `Channel(1)` that already holds the token blocks the next `put!` forever, and the
    # `isopen && !isready` guard is a check-then-act that two concurrent teardowns can both pass.
    # That race was previously hard to reach; `shutdown!` is now called for every backend, from
    # both `uninstall!` and `reset_runtime!`, so it is not. Closing is idempotent and needs no guard.
    close(scheduler.stop_signal)
    # `wait` on a task that has already FAILED rethrows its exception as a `TaskFailedException`,
    # and before #193 that escaped here -- straight out of `shutdown!`, whose first step this is,
    # ahead of the queue close, the #182 backlog abandon and the #176 drain. A scheduler that had
    # died at 03:00 therefore made the 17:00 teardown throw, skip the entire drain, and leave the
    # slot populated so the next `start_cleanup_scheduler` respawned over a runtime that was never
    # torn down. Since #195 the loop cannot die from a sweep failure, so this is a backstop; but a
    # teardown propagating a scheduler fault ahead of the drain is the wrong order of priorities
    # whatever killed it. Only `TaskFailedException` is caught -- it is the one that means "the
    # task was already dead". An `InterruptException` delivered to the WAITING task is not that,
    # and still propagates.
    try
        wait(scheduler.task)
    catch e
        e isa TaskFailedException || rethrow()
        @error "Nitro.Workers: the retention scheduler had already died; teardown continues" exception=(e, catch_backtrace())
    end
    return nothing
end

function stop_cleanup_scheduler!(runtime::WorkerRuntime=default_runtime())
    scheduler_ref = get_cleanup_scheduler(runtime)
    scheduler = scheduler_ref[]
    if !isnothing(scheduler)
        stop_cleanup_scheduler!(scheduler)
        scheduler_ref[] = nothing
    end
    return nothing
end
