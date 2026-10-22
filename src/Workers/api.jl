# No fallback (#322). This used to answer `default_runtime()` whenever `ctx` had nothing
# installed, and that runtime carries none of the app's policy: no queue authorizer, no error
# redactor, no retention. It was reachable in three ordinary ways -- a request in the window
# between `serve()` opening its listener and the startup hook installing the runtime, the
# tutorial's bare `worker_startup` paired with App-first calls, and a `start!` that threw before
# installing -- and in each one a submission silently skipped the app's authorization. An App
# with no runtime is now refused; `worker_startup(app)` installs one when it is BUILT, so the
# startup window no longer exists for it.
function _resolve_runtime(ctx::App; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    if !isnothing(runtime)
        return runtime
    end

    installed = worker_runtime(ctx; key)
    installed isa WorkerRuntime && return installed
    throw(WorkerUnavailableError(
        "no worker runtime is installed on this App under key :$key. Add `worker_startup(app)` " *
        "to `serve(app; middleware = [...])`, or call `install!(app)` / `start!(app)` first."))
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

A task stranded by a crash is recovered only by a sweep that runs after its claim is
`zombie_min_age` old, so a restart that comes right after the crash defers that crash's tasks.
With a bound set, [`start!`](@ref) therefore also re-runs this sweep on every tick of the
retention scheduler ([#266](https://github.com/PingoLee/Nitro.jl/issues/266)). A deferred claim
is recovered at most `zombie_min_age + cleanup_interval_hours` after it was made, not at some
later boot. That periodic sweep needs `cleanup_enabled = true`, since it rides the retention
tick, and it never runs without a bound. An unbounded sweep on a timer would mark another
node's live runs `FAILED` on every tick. It would also gain a single process nothing, because
that process's boot sweep already took everything. Once a claim is older than the window, it is
exactly as safe to adjudicate from a tick as from a boot, because the same process-local caveat
applies to both.

The default stays `nothing` because a single process loses nothing with it: its crashed tasks
are recovered on the very next start.

Nothing else needs to grow for this. Once the sweep marks a record `FAILED` it carries a
`completed_at`, and the retention sweep retires it like any other finished task. `cleanup_tasks!`
does not need a `RUNNING` escape hatch.

It walks the `RUNNING` records `batch_size` at a time, by keyset on the id
([#237](https://github.com/PingoLee/Nitro.jl/issues/237)), so no step of it materializes the
whole backlog. That backlog is exactly what a crash leaves: every task in flight at a `SIGKILL`
stays `RUNNING`, and nothing but this sweep ever retires it. Each batch is adjudicated before the
next is read. Each record's verdict is taken under that task's lock, which is what orders it
against a run registering in this process; nothing is held across the listing, so submissions and
runs of other tasks proceed while the sweep works through a backlog
([#711](https://github.com/PingoLee/Nitro.jl/issues/711)).

It logs twice at `@info` ([#238](https://github.com/PingoLee/Nitro.jl/issues/238)).
`"Nitro.Workers: scanning for zombie tasks"` goes out before its first read, and
`"Nitro.Workers: zombie recovery complete"` goes out when it finishes, **always**, including when
it recovered nothing. The completion line carries `candidates`, `recovered`, `spared_live`,
`too_recent`, `lost_race` and `leased`. If a read fails, an `@error` with the same counts replaces the
completion line, and the sweep returns what it had recovered so far. A write that throws is
logged the same way and then rethrown. Every field is a count; no task's `result` or `error` is
ever logged.

The sweep runs after the startup banner and before the first request is served, so when a boot
seems to hang after announcing itself, these two lines are the first thing to look for. That
unconditional pair belongs to this call, the boot sweep. The periodic sweep on the retention tick
logs the way the retention sweep does: `@info` only when it recovered something, `@debug`
otherwise, and `@error` on a failure, which costs that tick and nothing else.

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

**A leased run is never this sweep's** ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)).
A run a consumer process claimed has no handle in any process but that consumer's, so the
criterion above would fail every run a consumer is executing. Its liveness is its lease instead,
and [`requeue_expired!`](@ref) adjudicates it once the lease expires. The sweep reads `claimed_by`
off each ref, skips those runs, and counts them as `leased`.
"""
function recover_zombie_tasks!(; runtime::WorkerRuntime=default_runtime(),
                               zombie_min_age::Union{Nothing, Dates.Period}=nothing,
                               batch_size::Int=ZOMBIE_SWEEP_BATCH)
    return _recover_zombie_tasks!(runtime, zombie_min_age, batch_size; periodic=false)
end

# `periodic` changes the LOGGING and nothing the sweep decides. The boot sweep's `@info` pair is
# unconditional (#238); the retention tick's re-sweep (#266) logs like the retention sweep beside
# it, because an unconditional pair on a caller-supplied interval is noise. A write failure ends
# either sweep; only the boot one rethrows it after logging.
function _recover_zombie_tasks!(runtime::WorkerRuntime, zombie_min_age::Union{Nothing, Dates.Period},
                                batch_size::Int; periodic::Bool)
    batch_size >= 1 || throw(ArgumentError("`batch_size` must be at least 1, got $batch_size"))
    _check_zombie_min_age(zombie_min_age)
    # One cutoff for the whole sweep, taken before the first read: a claim is "old enough" against
    # the moment the sweep began, however long the backlog takes to walk.
    cutoff = zombie_min_age === nothing ? nothing : current_time_utc() - zombie_min_age

    # First, before any read (#238). The boot sweep runs at every `start!`, AFTER the banner has
    # announced the server and before the first request can be served, so a hang here used to read
    # as a server that said it was up and then went silent. The sweep holds no lock across the
    # listing since #711 -- each verdict takes its own key's stripe -- so this line now separates
    # "never started" from "working through the backlog".
    if periodic
        @debug "Nitro.Workers: scanning for zombie tasks" zombie_min_age batch_size
    else
        @info "Nitro.Workers: scanning for zombie tasks" zombie_min_age batch_size
    end
    tally = _ZombieTally()
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
            @error "Nitro.Workers: zombie recovery could not read the RUNNING tasks; stopping early" _tally_kwargs(tally)... exception=(loggable(e), catch_backtrace())
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
            @error "Nitro.Workers: zombie recovery failed mid-sweep" _tally_kwargs(tally)... exception=(loggable(e), catch_backtrace())
            # The periodic sweep stops here instead (#266). The rethrow exists so a boot does
            # not carry on quietly, and a tick carries on either way: its caller would only
            # log this same exception a second time, on every tick of a persistent fault.
            periodic && return tally.recovered
            rethrow()
        end
        # Short means exhausted: an implementation returns fewer than `limit` only when
        # nothing is left. A LONGER page is the default method's whole remainder, and the
        # next read past it comes back empty.
        if length(page) < batch_size
            # UNCONDITIONAL, `recovered = 0` included: silence must stop being ambiguous
            # between "ran and found nothing" and "never got there" (#238). Counts only --
            # never a task's `result` or `error`, which are application data. The periodic
            # re-sweep (#266) is the exception, and says so only when it recovered something.
            if !periodic || tally.recovered > 0
                @info "Nitro.Workers: zombie recovery complete" _tally_kwargs(tally)...
            else
                @debug "Nitro.Workers: zombie recovery complete" _tally_kwargs(tally)...
            end
            return tally.recovered
        end
        cursor = last(page).id
    end
end

# What the sweep did, for its log line. Every field is a count.
mutable struct _ZombieTally
    candidates::Int     # RUNNING records read
    recovered::Int      # transitioned to FAILED
    spared_live::Int    # this process holds a live handle for the run
    too_recent::Int     # claimed inside `zombie_min_age` (#239): left for a later sweep, not absent
    lost_race::Int      # the fenced transition was refused: it finished, or was re-run, meanwhile
    leased::Int         # a consumer process holds it under a lease (#514): `requeue_expired!`'s call
end
_ZombieTally() = _ZombieTally(0, 0, 0, 0, 0, 0)

_tally_kwargs(t::_ZombieTally) = (candidates=t.candidates, recovered=t.recovered,
                                  spared_live=t.spared_live, too_recent=t.too_recent,
                                  lost_race=t.lost_race, leased=t.leased)

# A ref built before `claimed_by` existed has no such field; it describes an unleased run.
_ref_claimed_by(ref) = hasproperty(ref, :claimed_by) ? ref.claimed_by : nothing

_check_zombie_min_age(age) =
    age === nothing || age >= zero(age) ||
        throw(ArgumentError("`zombie_min_age` must not be negative, got $age"))

# One batch. Its transitions move rows out of `RUNNING` at ids at or below the cursor, so they
# cannot disturb the next page, which starts strictly past it.
function _recover_zombie_page!(tally::_ZombieTally, runtime::WorkerRuntime, page::AbstractVector,
                               cutoff::Union{Nothing, DateTime})
    for task in page
        tally.candidates += 1
        # A run a consumer process holds under a lease (#514). Its liveness is the lease, not a
        # handle in THIS process, so the criterion below would call every such run dead -- in the
        # web process, every run a consumer is executing. `requeue_expired!` adjudicates it
        # instead, once the lease has actually expired. First, so it is never counted as anything
        # else; and still counted, so the log says how many runs were someone else's.
        if _ref_claimed_by(task) !== nothing
            tally.leased += 1
            continue
        end
        # Too recent to call dead: see `zombie_min_age`. Checked in Julia over the projected
        # `started_at` rather than in SQL, so a row it excludes is still SEEN, and the sweep can
        # say how many it left for later.
        if !(cutoff === nothing || task.started_at === nothing || task.started_at <= cutoff)
            tally.too_recent += 1
            continue
        end
        # The verdict and its write under the key's stripe, one key at a time (#711). That is
        # what keeps this process's own runs safe: `_claim_run!` publishes a run's handle under
        # the same stripe before its RUNNING claim, so a row this sweep reads as RUNNING either
        # has its handle by now or belongs to no run here. A sweep-wide lock bought nothing
        # more, and it held every submit in the process for the length of the backlog.
        verdict = lock_tasks(runtime, String(task.id)) do
            isnothing(get_active_task(runtime, task.id)) || return :spared_live
            # `get_active_task` is process-local, so in a multi-process deployment this
            # sweep sees another node's genuinely-running task as a zombie. Claiming the
            # transition rather than saving a decision means that if the task finishes
            # (or is cancelled) between the read and the write, the real outcome stands
            # and this sweep writes nothing — the same rule every other terminal write
            # now follows (#88).
            # Addressed to the run this sweep actually inspected. Between the read above
            # and this write the key may have been re-run (#108), and declaring someone else's
            # live run dead is the same defect as clobbering its result.
            won = try_transition!(runtime.store, task.id, (RUNNING,), FAILED;
                                  run_id=task.run_id,
                                  error="Worker process terminated unexpectedly mid-execution.",
                                  completed_at=current_time_utc())
            return won ? :recovered : :lost_race
        end
        if verdict === :spared_live
            tally.spared_live += 1
        elseif verdict === :recovered
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

# The runtime `_start_runtime_for!` would START, when it would reuse one rather than build it --
# `nothing` otherwise. Mirrors its branches, so a queue declaration can be checked against that
# runtime BEFORE anything is installed: a refused `start!` must not have displaced the runtime it
# was refused on (#513).
function _runtime_to_reuse(ctx::App, key::Symbol,
                           store::Union{Nothing, AbstractWorkerStore},
                           runtime::Union{Nothing, WorkerRuntime})
    runtime === nothing || return runtime
    existing = worker_runtime(ctx; key)
    existing isa WorkerRuntime || return nothing
    return (store === nothing || existing.store === store) ? existing : nothing
end

# Shape first (`_queue_specs`), then conflicts with the runtime about to be started, both before
# `_start_runtime_for!` installs anything. A freshly built runtime has no declarations to conflict
# with, so there is nothing more to check for it.
function _checked_queue_specs(ctx::App, key::Symbol, store, runtime, queues::AbstractVector)
    # The same refusal `_start_runtime_for!` makes, first, so `store` + `runtime` together reports
    # as that rather than as whatever the declarations happen to conflict with.
    if !isnothing(store) && !isnothing(runtime)
        throw(ArgumentError(
            "pass `store` (build a runtime over this backend) or `runtime` (use this one), not both"))
    end
    # The keyword's own list first, so an `External(…)` passed there is refused as that, with a
    # pointer at `declare_queues!`, before the app's declarations are merged in.
    _queue_specs(queues)
    specs, external = _placement_specs(Any[_app_placements(ctx)..., queues...])
    target = _runtime_to_reuse(ctx, key, store, runtime)
    target === nothing || _check_queue_declarations(target, specs, external)
    _check_external_store(_target_store(ctx, key, store, runtime), external)
    return specs, external
end

# The store `_start_runtime_for!` would start a runtime over, or `nothing` when it would build a
# fresh default runtime, whose store is a new `InMemoryWorkerStore`.
function _target_store(ctx::App, key::Symbol, store::Union{Nothing, AbstractWorkerStore},
                       runtime::Union{Nothing, WorkerRuntime})
    runtime === nothing || return runtime.store
    store === nothing || return store
    existing = worker_runtime(ctx; key)
    return existing isa WorkerRuntime ? existing.store : nothing
end

# Refused at start, never later (#514): an external queue whose runs no consumer process could
# ever claim. `nothing` is the default in-memory store a fresh runtime would get.
function _check_external_store(store::Union{Nothing, AbstractWorkerStore},
                               external::Vector{Pair{String, External}})
    isempty(external) && return nothing
    names = join(("\"$(first(p))\"" for p in external), ", ")
    if store !== nothing && !supports_claims(store)
        throw(ArgumentError(
            "the External(…) queue(s) $names need a store with the claim capability, and " *
            "$(typeof(store)) lacks $(join(missing_claim_methods(typeof(store)), ", "))"))
    end
    if store === nothing || !_visible_across_processes(store)
        what = store === nothing ? "a new InMemoryWorkerStore" : string(typeof(store))
        throw(ArgumentError(
            "the External(…) queue(s) $names need a store another process can read, and this " *
            "runtime's is $what, which lives in this process's memory: a run submitted there " *
            "would never be claimed. Pass a persistent store, such as `pormg_nitro_worker(…)`"))
    end
    return nothing
end

# -- The app's queue declarations (#514) --

# Per App, in its extension slot like the job registry and for the same reasons: the declarations
# are made by the app's setup function, before any runtime is installed, and must outlive the
# runtime `uninstall!` drops on every `terminate`. They are also what a consumer process reads,
# and it installs no runtime at all.
struct QueueDeclarations
    specs::Vector{Pair{String, Int}}
    external::Vector{Pair{String, External}}
    lock::ReentrantLock
end
QueueDeclarations() = QueueDeclarations(Pair{String, Int}[], Pair{String, External}[], ReentrantLock())

const QUEUE_DECLARATIONS_KEY = :workers_queues

function _queue_declarations(ctx::App)
    return lock(ctx.service.extensions_lock) do
        decl = get_extension(ctx, QUEUE_DECLARATIONS_KEY, nothing)
        decl isa QueueDeclarations && return decl
        fresh = QueueDeclarations()
        set_extension!(ctx, QUEUE_DECLARATIONS_KEY, fresh)
        return fresh
    end
end

# A snapshot of the app's declarations, as one `queues`-shaped list.
function _app_placements(ctx::App)
    decl = get_extension(ctx, QUEUE_DECLARATIONS_KEY, nothing)
    decl isa QueueDeclarations || return Any[]
    return lock(() -> Any[decl.specs..., decl.external...], decl.lock)
end

# The app's `External(…)` declarations, which `consume!` reads.
function _app_external_queues(ctx::App)
    decl = get_extension(ctx, QUEUE_DECLARATIONS_KEY, nothing)
    decl isa QueueDeclarations || return Pair{String, External}[]
    return lock(() -> copy(decl.external), decl.lock)
end

"""
    declare_queues!(app::App, queues::AbstractVector; key = :workers) -> App

Declare the queues `app` submits to, and where each one runs
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)):

```julia
function setup_workers!(app)                       # called by the web process AND the consumer
    declare_queues!(app, ["email", "compute" => 4, "heavy" => External(on_lease_expiry = :requeue)])
    register_job!(app, "fit_model", FitArgs) do task_info, args
        fit(args)
    end
end
```

- A bare name, or `name => k`, runs **in-process**, at most `k` items at once, exactly as
  `worker_startup(app; queues)` declares it.
- `name => External(…)` runs in a **separate consumer process**: this process only records the
  submit, and a consumer claims it from the shared store. See [`External`](@ref).

The declarations belong to the app, not to a runtime, so they can be made before
`worker_startup(app; …)` builds one, they survive a `terminate` and re-serve, and a consumer
process, which serves nothing, reads the same ones. `worker_startup(app; queues)` and
`start!(app; queues)` merge their own `queues` with them. If a runtime is already installed under
`key`, it learns the new declarations at once.

A name is declared once, with one setting: declaring it again with the same one is a no-op, and
with another one is an `ArgumentError`, as is declaring it both in-process and external. Every
name is checked before any is recorded, so a refused call declares nothing. An external queue on a
store no other process can read (`InMemoryWorkerStore`), or one without the claim capability, is
refused too, here when a runtime is installed and otherwise when one starts.
"""
function declare_queues!(ctx::App, queues::AbstractVector; key::Symbol=DEFAULT_EXTENSION_KEY)
    new_specs, new_external = _placement_specs(queues)
    decl = _queue_declarations(ctx)
    lock(decl.lock) do
        specs, external = _placement_specs(Any[decl.specs..., decl.external..., new_specs..., new_external...])
        runtime = worker_runtime(ctx; key)
        if runtime isa WorkerRuntime
            _check_external_store(runtime.store, new_external)
            _declare_queues!(runtime, new_specs, new_external)
        end
        # Recorded only once nothing refused it.
        copy!(decl.specs, specs)
        copy!(decl.external, external)
    end
    return ctx
end

# Declare `specs` and `external` on `runtime` together with the app's declarations as they stand
# NOW, under the declarations' lock, and return what was declared. `_checked_queue_specs` merged a
# snapshot taken before the runtime was installed; a `declare_queues!` that ran in between found no
# runtime, so it recorded its queues on the App alone. Under this lock it either ran first, and is
# merged here, or runs after, and finds the runtime installed. Lock order: the declarations' lock,
# then `queue_lock`, as in `declare_queues!`.
#
# It runs AFTER the install, so it is the one refusal that can come too late to leave nothing
# installed: only a declaration that lands between the pre-install check and here, and conflicts,
# reaches it. Do not rely on `_checked_queue_specs` alone to have seen every declaration.
function _declare_with_app!(ctx::App, runtime::WorkerRuntime, specs::Vector{Pair{String, Int}},
                            external::Vector{Pair{String, External}})
    decl = _queue_declarations(ctx)
    return lock(decl.lock) do
        merged_specs, merged_external = _placement_specs(Any[decl.specs..., decl.external..., specs..., external...])
        _check_external_store(runtime.store, merged_external)
        _declare_queues!(runtime, merged_specs, merged_external)
        return merged_specs, merged_external
    end
end

# A queue the web now runs in-process may still hold rows queued for a consumer before the switch
# (#514's switch procedure). They stay claimable by a consumer still running, and nothing here
# runs them, so the operator is told, with the count, at every start. Never fatal: a read failure
# costs the warning, not the start.
function _warn_stranded_external(runtime::WorkerRuntime, specs::Vector{Pair{String, Int}})
    (isempty(specs) || !supports_claims(runtime.store)) && return nothing
    for (queue_name, _) in specs
        try
            stranded = count_external_runs(runtime.store, [PENDING]; queue_name)
            stranded > 0 && @warn "Nitro.Workers: a queue declared in-process still holds runs " *
                "queued for a consumer process; only a consumer can run them" queue = queue_name stranded
        catch e
            e isa InterruptException && rethrow()
            @error "Nitro.Workers: could not count a queue's external runs at start" queue = queue_name exception = (loggable(e), catch_backtrace())
        end
    end
    return nothing
end

"""
    start!(ctx::App; queues, cleanup_enabled, ..., store=nothing, runtime=nothing,
           drain_timeout=WORKER_DRAIN_TIMEOUT_SECONDS) -> WorkerRuntime

Install a runtime on `ctx` and start it: sweep zombies, spawn each declared queue's processors,
and start (or stop) the cleanup scheduler.

`queues` declares the queue names [`submit_queued_task`](@ref) may use, each with a concurrency:
`queues = ["email", "compute" => 6]` runs `"email"` one item at a time and up to six `"compute"`
items at once ([#513](https://github.com/PingoLee/Nitro.jl/issues/513)). Give CPU-bound work a
queue with a concurrency below `Threads.nthreads(:default)`, so the threads it cannot take stay
free for request handlers. A name already declared on this runtime cannot be re-declared with a
different concurrency (an `ArgumentError`).

The app's own [`declare_queues!`](@ref) declarations are merged in, under the same rule. An
`External(…)` queue among them gets **no processor** here: a consumer process runs it, and this
process only records its submits ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)). An
external queue on a store no other process can read, or one without the claim capability, is
refused before anything is installed. Runs left waiting for a consumer on a queue now declared
in-process are reported with one `@warn`. With `cleanup_enabled`, the cleanup scheduler also
adjudicates the expired leases of this runtime's own external queues on each tick (`requeue_expired!`),
as a fallback for a queue whose consumers are gone; another queue's are left to its consumers.

Returns the `WorkerRuntime` — that is the handle to pass as `runtime=` to the task API.

`drain_timeout` reaches only [`install!`](@ref)'s displacement path: starting over a runtime that
is already installed tears the old one down first, and that teardown drains like any other (#176).

`zombie_min_age` bounds the zombie sweep to claims older than that period. Leave it `nothing` for
a single process; **set it when several processes share one store**. The reasoning, and the
trade, are on [`recover_zombie_tasks!`](@ref) (#239). With a bound set and `recover_zombies`
on, the cleanup scheduler also re-runs that bounded sweep on every tick, so a claim deferred at
boot is recovered once it ages past the window. Without `cleanup_enabled` there is no tick, and
so no re-sweep (#266). A later `start!` that reuses the runtime also reuses its running
scheduler, so it cannot change that scheduler's `zombie_min_age`, `cleanup_interval_hours` or
`cleanup_retain_days`, and a `recover_zombies = false` there does not stop an already-running
re-sweep. Call `stop_cleanup_scheduler!` first.
"""
function start!(ctx::App;
    queues::AbstractVector=String[],
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
    # Checked first, so a malformed or conflicting `queues` is refused before anything is installed,
    # displaced or swept.
    queue_specs, external = _checked_queue_specs(ctx, key, store, runtime, queues)
    resolved = _start_runtime_for!(ctx, key, store, runtime, drain_timeout)

    if recover_zombies
        recover_zombie_tasks!(; runtime=resolved, zombie_min_age)
    end

    # Declared before its processors start: these are the names a submit may use (#324), and the
    # concurrency each one runs at (#513). An external queue gets no processor here: a consumer
    # process runs it (#514).
    queue_specs, _ = _declare_with_app!(ctx, resolved, queue_specs, external)
    for (queue_name, _) in queue_specs
        _start_queue_processor(resolved, queue_name)
    end
    _warn_stranded_external(resolved, queue_specs)

    if cleanup_enabled
        # `recover_zombies = false` turns the sweep off, periodic half included (#266) -- for a
        # scheduler started here. One already running is returned as is; see the docstring.
        start_cleanup_scheduler(; interval_hours=cleanup_interval_hours, retain_days=cleanup_retain_days,
                                zombie_min_age=recover_zombies ? zombie_min_age : nothing, runtime=resolved)
    else
        stop_cleanup_scheduler!(resolved)
    end

    return resolved
end

function startup(ctx::App;
    queues::AbstractVector=String[],
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
    # Every check runs BEFORE the install below, so a refused call leaves nothing installed. A
    # negative `drain_timeout` would otherwise install fine and then throw from `uninstall!` in
    # `on_shutdown`, leaving a runtime nothing ever tears down.
    _check_zombie_min_age(zombie_min_age)
    drain_timeout >= 0 || throw(ArgumentError(
        "drain_timeout must be >= 0 (got $(drain_timeout)); 0 releases without waiting"))
    # Checked here so a malformed or conflicting declaration is refused when the middleware is
    # built, before the install below, not from `on_startup`, whose exception is only logged.
    queue_specs, external = _checked_queue_specs(ctx, key, store, runtime, queues)

    # Installed NOW, when the middleware is built, not in `on_startup` (#322). `serve()` opens its
    # listener before it runs the startup hooks, so a runtime installed by the hook left a window
    # in which App-first calls found nothing installed -- and they used to fall back to the
    # process-wide runtime, skipping the app's queue authorizer. `_start_runtime_for!` also refuses
    # `store` + `runtime` together here, at boot, instead of from a hook whose exception is only
    # logged. Only the INSTALL moves: the zombie sweep, the queue processors and the scheduler
    # still start in `on_startup`.
    installed = _start_runtime_for!(ctx, key, store, runtime, drain_timeout)
    # Declared now too, not only by `start!` in the hook (#324): a submit in the startup window
    # would otherwise be refused as an undeclared queue.
    # A new name, not `queue_specs` reassigned: `on_startup` below captures it, and a captured
    # variable that is assigned twice is a `Core.Box` (#364).
    declared_specs, _ = _declare_with_app!(ctx, installed, queue_specs, external)

    passthrough = function(handle::Function)
        return function(req)
            return handle(req)
        end
    end

    on_startup = () -> begin
        # `runtime = installed`, never `store = store`: the store form mints a runtime whenever
        # the slot holds a different one, and after `terminate`'s `uninstall!` the slot is empty.
        # Re-serving must put back THIS runtime, the one policy may already hang off.
        start!(ctx;
            queues=declared_specs,
            cleanup_enabled=cleanup_enabled,
            cleanup_interval_hours=cleanup_interval_hours,
            cleanup_retain_days=cleanup_retain_days,
            recover_zombies=recover_zombies,
            zombie_min_age=zombie_min_age,
            key=key,
            runtime=installed,
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

`submit_task` and `submit_queued_task` return the resolved id; pass *that* to
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

# What a caller who may not see a task is told, and what a caller asking for a task that does not
# exist is told -- ONE value for both (#323). They used to differ: a missing id answered this, a
# foreign one raised `AuthorizationError`, and the difference let any authenticated user probe
# `"<victim>::<key>"` ids (usually derived from resource ids, so guessable) and learn who ran what.
_not_found() = Dict{Symbol, Any}(:error => "Task not found", :status => "NOT_FOUND")

# The record `authority` may be served for `task_id`, or `nothing` -- which the callers answer with
# `_not_found()`, so "not yours" and "not there" are indistinguishable (#323).
#
# **Live first, and only if it authorizes.** Pollers read the live object for fresh progress
# without a round-trip. But that cache is per process, so a grant issued *elsewhere* is not in it --
# #96's whole motivating case is a task submitted on one node and polled from another. So a live
# object that denies is not the answer; the durable record decides.
#
# **The durable record authorizes only ITS OWN run.** The live object can be a predecessor still
# executing after a re-run replaced the record (cancellation is cooperative), and re-running a key
# resets its watcher list. Authorizing the predecessor's object against the successor's watchers
# served one identity's run on another identity's grant, which is the Info item of #323. So when
# the runs differ, the durable record is what gets served; the live object is served only when it
# is the same run, which keeps a cross-process grantee's progress bar live, as #96 requires.
#
# **One durable read on every refusal path.** A missing id and a foreign id both reach the store
# exactly once and stop there, so they do not differ in ROUND-TRIPS -- a second read only on the
# "exists but not yours" path would have put the oracle back as a gross timing difference.
#
# **Authorized before it is decoded** (#565). A full read decodes the row, `result` included, so a
# foreign id with a large result used to cost a decode a missing id does not: measurable over many
# probes, and a foreign row whose stored `result` no longer decodes threw where a missing id
# answers NOT_FOUND. `_may_read_durable` refuses first where the store can tell cheaply -- the
# PormG store reads the watcher column alone -- so a refusal reads that projection and stops, for a
# foreign id and a missing one alike. A caller the id does not name pays the projection and then
# the full read: a grantee, and every reader of a `:global` task, whose id names no owner. The
# owner, whom the id alone authorizes, pays only the full read.
function _visible_record(runtime::WorkerRuntime, authority::TaskAuthority, task_id::String)
    live = get_active_task_info(runtime, task_id)
    live !== nothing && _is_authorized(authority, live) && return live

    _may_read_durable(runtime.store, authority, task_id) || return nothing
    # `get_task_info(store, ·)` is the DURABLE read -- no store caches live objects (#167).
    durable = get_task_info(runtime.store, task_id)
    (durable === nothing || !_is_authorized(authority, durable)) && return nothing
    return live !== nothing && live.run_id == durable.run_id ? live : durable
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
# than re-deriving it. Both submit paths do: `submit_queued_task` puts it on the `QueueItem`,
# `submit_task` hands it to `_execute_task_async`.
#
# Three writes depend on that. A teardown abandoning the backlog records a terminal state
# ADDRESSED TO THE RUN that queued the item rather than to its key (#182, workers §6), and both
# execution paths check it before registering their run handles and fence their start claim on it
# (#191). Deriving any of them by re-reading the record does not work: by then the record may
# belong to a successor, so the abandon would cancel a run about to start and the start claim
# would agree with a run that is not the caller's.
#
# `queue` is the declared queue the new run will be enqueued on, or `nothing` for an async run.
# It decides which capacity the run reserves (#324) -- a slot in that queue's buffer, or one of the
# runtime's concurrent async runs -- on top of its owner's quota. Only a run that is MINTED here
# reserves; joining a live one costs nothing. The caller owns giving it back.
function _register_or_watch!(runtime::WorkerRuntime, task_key::String, owner::Owner;
                             queue_name::Union{Nothing, String}=nothing,
                             grants::AbstractVector{Owner}=Owner[],
                             queue::Union{Nothing, WorkerQueue}=nothing,
                             job_name::Union{Nothing, String}=nothing,
                             job_args::Union{Nothing, String}=nothing,
                             external::Union{Nothing, External}=nothing)
    uid = owner.user_id
    return lock_tasks(runtime, task_key) do
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
        #
        # And the value is the list the record WILL have once the submitter is in it, never an
        # empty one (#323). A new `:global` key used to be authorized against `String[]`, so an
        # `all(...)` hook was vacuously true and the documented `ORG_OF[first(watchers)]` threw
        # `BoundsError` -- a 500. Which list that is follows the same status test as the branch
        # below: joining a live run keeps its watchers and adds the submitter; a new or replaced
        # record starts from the submitter alone, because `replace_task!` resets the list.
        joining = task_info !== nothing && task_info.status in (RUNNING, PENDING)
        seen = joining ? copy(task_info.watchers) : String[]
        uid in seen || push!(seen, uid)

        # Authorize every grant before applying any. Otherwise a refusal partway through
        # throws with the earlier grants already durably written — and a submit that
        # raised would still have handed out access.
        for grant in grants
            _authorize_grant!(runtime.store, task_key, seen, grant)
        end

        if joining
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

        # A bound counts every record of its queue, so its count and the write it admits must
        # not interleave with another key's submit in this process. The key's stripe does not
        # cover that (#711); the admission lock does, and only on the path that counts.
        if _admission_counts(runtime, external)
            return _lock_admission(runtime.store) do
                _mint_run!(runtime, task_key, uid, grants, queue, queue_name, job_name, job_args, external)
            end
        end
        return _mint_run!(runtime, task_key, uid, grants, queue, queue_name, job_name, job_args, external)
    end
end

# Whether minting this run reads a count `_admit_external!` bounds, and so needs the admission lock.
_admission_counts(runtime::WorkerRuntime, external::Union{Nothing, External}) =
    external !== nothing && (external.max_pending !== nothing || runtime.max_runs_per_owner !== nothing)

# Mint a new run of `task_key` and publish it: `_register_or_watch!`'s replace branch, under the
# key's stripe and, when a bound counts, the admission lock. Returns the new `run_id`.
function _mint_run!(runtime::WorkerRuntime, task_key::String, uid::String, grants::AbstractVector{Owner},
                    queue::Union{Nothing, WorkerQueue}, queue_name::Union{Nothing, String},
                    job_name::Union{Nothing, String}, job_args::Union{Nothing, String},
                    external::Union{Nothing, External})
    # Re-running a finished key replaces the record and resets its watchers to the
    # resubmitter — the one place a whole record, watchers included, is written.
    # The record we are about to discard may still have a live run behind it. `run_id`
    # stops that run from writing (#108); this is the only thing that can reclaim the
    # thread it is sitting on. In-process only -- a run hosted on another node is
    # unreachable from here and will keep going until its callback returns.
    #
    # The new run reserves its capacity FIRST (#324), before the predecessor is asked to
    # stop and before the record is replaced, so a refused submit changes nothing: no record,
    # and no superseded run.
    #
    # An external run (#514) reserves nothing here: no process-local run will ever release it,
    # because a consumer process runs it. It is admitted against counts the store keeps instead.
    task_info = TaskInfo(task_key; queue_name, external = external !== nothing, job_name, job_args)
    if external === nothing
        _reserve_capacity!(runtime, queue, task_info.run_id, uid)
    else
        _admit_external!(runtime, external, something(queue_name), uid)
    end
    try
        previous = get_active_task_info(runtime, task_key)
        previous === nothing || _request_cancel!(previous, :superseded)

        push!(task_info.watchers, uid)
        for grant in grants
            grant.user_id in task_info.watchers || push!(task_info.watchers, grant.user_id)
        end
        # Through the RUNTIME: publishing a successor also evicts the run it displaced from
        # the live caches, so nothing later reads a run that no longer owns this key.
        replace_task!(runtime, task_key, task_info)
    catch
        # A store write that throws leaves no run to release it later.
        external === nothing && _release_capacity!(runtime, queue, task_info.run_id)
        rethrow()
    end
    return task_info.run_id
end

# The submit-time bounds of an external queue (#514), read from the store, because the runs they
# bound are claimed and executed by other processes and hold nothing in this one. Called under the
# key's `lock_tasks` stripe and the admission lock, where the run is about to be minted, so joining
# a live run is never refused by them; `count_external_runs` is a plain read, the one
# claim-capability method allowed there. The admission lock makes them exact against this
# process's own submits; against other processes' they are approximate: they bound the backlog
# against runaway callers (the #324 class), they are not quotas.
function _admit_external!(runtime::WorkerRuntime, placement::External, queue_name::String, uid::String)
    cap = placement.max_pending
    if cap !== nothing && count_external_runs(runtime.store, [PENDING]; queue_name) >= cap
        throw(WorkerCapacityError(:queue,
            "the external queue already holds its maximum of $cap pending runs; retry once it drains"))
    end
    quota = runtime.max_runs_per_owner
    if quota !== nothing
        # This process's own live runs of the owner, plus the external runs it submitted, wherever
        # they run -- by submitter, so a `:global` submit counts and a grant from someone else does
        # not. A consumer applies no owner limit at claim time: this is where the owner is bounded.
        held = lock(() -> Base.get(runtime.owner_runs, uid, 0), runtime.reservation_lock)
        if held + count_external_runs(runtime.store, [PENDING, RUNNING]; submitter = uid) >= quota
            throw(WorkerCapacityError(:owner, "this identity already has its maximum of $quota live tasks"))
        end
    end
    return nothing
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
# nothing injecting anywhere, `start_cleanup_scheduler` could migrate too -- and since #369 it has,
# because a sticky task parked on thread 1 is where a REPL's Ctrl-C lands.
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
        # publish, as one critical section under the key's stripe -- `_claim_run!` (`queue.jl`)
        # owns the rationale. Runs INSIDE the spawned task, because the handle it publishes is
        # `current_task()`.
        #
        # This path is DIFFERENTLY exposed to a supersede than the queued one, not simply
        # less: its window is shorter in wall-clock -- a lock release, a `Threads.@spawn`
        # scheduling hand-off, and on `PormGWorkerStore` a database round-trip, against a queued
        # item that can sit in a `Channel(100)` behind a long job for minutes -- but its
        # CONSEQUENCE is worse. Where a concurrency-1 queue serializes a stale item against its
        # successor on its single processor, here both runs are spawned tasks by construction, so
        # nothing serializes them and the interleaving in which one stole the other's handles was
        # the ordinary case rather than an edge. A queue with concurrency `k > 1` (#513) is in the
        # same position, since two of its processors can hold the two items at once. A concurrent
        # `cancel_task` plus re-submit needs only the key's `lock_tasks` stripe -- which is exactly
        # why the claim takes it (#191, #198).
        #
        # Every way out gives back the run's capacity reservation (#324) exactly once, except a
        # timed-out callback, which keeps it until it actually returns (`_RunHandoff`).
        task_info = try
            _claim_run!(runtime, task_key, run_id)
        catch
            _release_run!(runtime, run_id)
            rethrow()
        end
        task_info === nothing && (_release_run!(runtime, run_id); return nothing)
        handoff = Ref(_RunHandoff(() -> _release_run!(runtime, run_id)))

        # Starting is a CLAIMED transition, not an unconditional write. `set_task!` has no
        # precondition, so a `cancel_task` that already claimed PENDING -> CANCELLED was simply
        # overwritten here a moment later; the callback then ran and `_complete_task!`'s own CAS
        # succeeded from RUNNING, reporting COMPLETED for a task whose caller had been told
        # "Task cancelled". Silent, and not fixable by locking -- the two writes are strictly
        # sequential (#142). The CAS *is* the write, so there is no `set_task!` after it.
        #
        # In the ASYNC path this was masked, not absent: `cancel_task` also interrupted the worker
        # task, and a task that had not started yet never ran its body at all. The queued path
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

            # The attempt loop is shared with the queued executor and a consumer process (#514).
            return _run_attempts!(runtime, task_info, callback, options, handoff)
        finally
            _deregister_run!(runtime, task_info)
            _handed_off(handoff[]) || _release_run!(runtime, run_id)
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
    submit_task(app, task_key, callback_or_job, owner::Owner; scope, watchers, options, key, runtime)

Run `callback` on its own task and return the id it was stored under.

On an `App`, a [`Job`](@ref)`(name, args)` registered with [`register_job!`](@ref) can stand in
for the callback ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)). Its arguments are
checked and encoded before anything is written, and recorded on the task as JSON.

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
    return _submit_task(runtime, task_key, _ClosureRun(callback), owner, scope, watchers, options)
end

# A named job has no registry without its App (#514), so only the App-first form takes one.
submit_task(::AbstractString, ::Job, ::Owner; kwargs...) = _throw_job_needs_app("submit_task")

function submit_task(ctx::App, task_key::AbstractString, job::Job, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    resolved = _resolve_runtime(ctx; key, runtime)
    return _submit_task(resolved, task_key, _PendingJob(_job_registry(ctx), job), owner, scope, watchers, options)
end

# The body of both `submit_task` forms. `work` is resolved by `_prepare_run` AFTER the authorizer
# and the key checks, so a caller the queue authorizer refuses learns nothing about the job, and
# a named job's encoding (#514) costs nothing until the submit is allowed. It runs before the
# record is written, so a refused job writes nothing and reserves nothing.
function _submit_task(runtime::WorkerRuntime, task_key::AbstractString, work, owner::Owner,
                      scope::Symbol, watchers::AbstractVector{Owner}, options::TaskOptions)
    _authorize_queue!(runtime.store, DEFAULT_QUEUE_NAME, owner)

    key = scoped_task_key(task_key, owner; scope)
    callback, job_name, job_args = _prepare_run(work)
    # The run identity is PLUMBED here, exactly as `submit_queued_task` plumbs it onto the
    # `QueueItem`. This used to read "the async path does not carry the run identity ... only a
    # QUEUED item needs it, because it may sit in a buffer long enough for the record to move
    # on", and both halves were wrong (#191). A durable read is a LOOKUP, not a fence -- #167
    # says which record to read, never that reading it authenticates the reader. And "long
    # enough" is not a correctness criterion: the window here is a lock release plus a `@spawn`
    # scheduling hand-off, not a buffer wait, and it is unbounded under thread pressure.
    run_id = _register_or_watch!(runtime, key, owner; grants=watchers, job_name, job_args)
    if run_id !== nothing
        try
            _execute_task_async(runtime, key, callback, options, run_id)
        catch
            _release_run!(runtime, run_id)   # no run was spawned to give the reservation back
            rethrow()
        end
    end
    return key
end

function submit_task(ctx::App, task_key::AbstractString, callback::Function, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return submit_task(task_key, callback, owner; scope, watchers, options, runtime=_resolve_runtime(ctx; key, runtime))
end

"""
    submit_queued_task(queue_name, task_key, callback, owner::Owner; scope=:user,
                       watchers=Owner[], options=TaskOptions(), runtime=default_runtime())
    submit_queued_task(app, queue_name, task_key, callback_or_job, owner::Owner; scope, watchers, options, key, runtime)

Queue `callback` on the declared queue `queue_name` and return the id it was stored under. On an
`App`, a [`Job`](@ref) can stand in for the callback, as on [`submit_task`](@ref); closures and
named jobs share any queue.

A queue runs at most its declared concurrency of items at once, starting them in the order they
were submitted: `start!(app; queues = ["email", "compute" => 6])` runs `"email"` strictly one at a
time and up to six `"compute"` items side by side
([#513](https://github.com/PingoLee/Nitro.jl/issues/513)). A submit past that waits in the
queue's buffer; a submit to a full buffer is refused with
`WorkerCapacityError(:queue, …)`. That bound is what makes a queue the place for CPU-bound
work, where [`submit_task`](@ref)'s runtime-wide `max_concurrent_runs` is sized for I/O.

Identical to [`submit_task`](@ref) in how `scope` namespaces `task_key` and in what the
return value is for; the difference is the queue's bound and order, and that the queue
authorizer sees the real `queue_name`.

This was `submit_sequential_task` until #513, which gave a queue a concurrency.
"""
function submit_queued_task(queue_name::AbstractString, task_key::AbstractString, callback::Function, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), runtime::WorkerRuntime=default_runtime())
    return _submit_queued_task(runtime, queue_name, task_key, _ClosureRun(callback), owner, scope, watchers, options)
end

submit_queued_task(::AbstractString, ::AbstractString, ::Job, ::Owner; kwargs...) =
    _throw_job_needs_app("submit_queued_task")

function submit_queued_task(ctx::App, queue_name::AbstractString, task_key::AbstractString, job::Job, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    resolved = _resolve_runtime(ctx; key, runtime)
    return _submit_queued_task(resolved, queue_name, task_key, _PendingJob(_job_registry(ctx), job), owner, scope, watchers, options)
end

# The body of both `submit_queued_task` forms; see `_submit_task`.
function _submit_queued_task(runtime::WorkerRuntime, queue_name::AbstractString, task_key::AbstractString,
                             work, owner::Owner, scope::Symbol,
                             watchers::AbstractVector{Owner}, options::TaskOptions)
    queue_id = String(queue_name)

    _authorize_queue!(runtime.store, queue_id, owner)

    key = scoped_task_key(task_key, owner; scope)

    # Only a DECLARED queue name gets a queue (#324). Every name used to mint a queue plus a
    # processor task that lives as long as the runtime, so a handler taking the name from request
    # data minted one per distinct name. Checked before `_start_queue_processor`, so a refused name
    # never mints anything; after `scoped_task_key`, so a malformed key still reports as that.
    if !_queue_declared(runtime, queue_id)
        _warn_undeclared_queue(runtime, queue_id)
        throw(AuthorizationError(
            "Queue '$queue_id' is not declared on this worker runtime; declare it with " *
            "`start!(app; queues = [...])` / `worker_startup(app; queues = [...])`"))
    end

    # An external queue (#514): the run is recorded here and executed by a consumer process, so
    # there is no queue to mint, no processor, and no item to hand over. After the declared check,
    # so a caller the authorizer refuses learns nothing about the queue.
    placement = _external_placement(runtime, queue_id)
    if placement !== nothing
        work isa _ClosureRun && throw(ArgumentError(
            "queue '$queue_id' is External(…): its runs execute in a consumer process, which cannot " *
            "run a closure. Register the job with `register_job!(app, name, ArgsType)` and submit " *
            "`Job(name, args)` through the App-first `submit_queued_task(app, …)`"))
        options == TaskOptions() || throw(ArgumentError(
            "queue '$queue_id' is External(…): a consumer process runs it with the queue's own " *
            "options, so a submit cannot pass `options`. Set them on the declaration, " *
            "`External(…; options = TaskOptions(…))`"))
        _, job_name, job_args = _prepare_run(work)
        _register_or_watch!(runtime, key, owner; queue_name=queue_id, grants=watchers, job_name,
                            job_args, external=placement)
        return key
    end

    callback, job_name, job_args = _prepare_run(work)

    # One lookup, not two -- and it now comes BEFORE the record is written, because the new run
    # reserves its slot in THIS queue's buffer while the record is claimed (#324). A second
    # `_get_or_create_queue` could return a DIFFERENT object: `shutdown!` empties the registry, so
    # a teardown landing between the two lookups would mint a fresh queue with an open channel and
    # no processor. The `put!` would then succeed and the task would sit PENDING with nothing
    # draining it -- a silent hang in place of the loud `InvalidStateException` a closed channel
    # raises. Resolving it first widens the window a teardown can land in (it now spans the
    # record write), but it stays loud: the `put!` below still hits the closed channel.
    #
    # Outside `lock_tasks`, deliberately: `queue_lock` is never taken inside a stripe (`TaskLocks`),
    # because `get_queue_status` holds `queue_lock` across a store listing.
    queue = _start_queue_processor(runtime, queue_id)
    run_id = _register_or_watch!(runtime, key, owner; queue_name=queue_id, grants=watchers, queue, job_name, job_args)
    if run_id !== nothing
        item = QueueItem(key, run_id, callback, options)

        # A teardown landing between resolving the queue and handing it the item makes this
        # `put!` throw, and the record written a moment ago by `_register_or_watch!` is then
        # `PENDING` with nothing that will ever run it -- the same orphan #182 removes from the
        # buffered backlog, arriving through the one door closing the channel leaves open. Before
        # #324 it was not rare -- `close` raised in every submitter blocked on a full queue --
        # but no submitter blocks any more, so now it takes a teardown landing in that window.
        #
        # The exception still propagates -- the caller has to learn the submission failed, which
        # is the whole argument for the loud close over a silent hang -- but the record is now
        # terminal rather than abandoned.
        #
        # The `put!` itself can no longer BLOCK: the slot reserved above guarantees room in the
        # buffer (#324). A full queue refuses the submit instead of parking the request here.
        try
            put!(queue.channel, item)
        catch error
            # Unconditionally, whatever went wrong: the item never reached the buffer.
            _release_capacity!(runtime, queue, run_id)
            error isa InvalidStateException || rethrow()
            try
                _abandon_queued_item!(runtime, item)
            catch abandon_error
                # Never let bookkeeping replace the caller's exception: the `put!` failure is
                # what they must see, and a store that is also down would otherwise mask it.
                @error "Worker task orphaned by a teardown could not be recorded" exception=(loggable(abandon_error), catch_backtrace()) task_key=key
            end
            rethrow()
        end
    end
    return key
end

function submit_queued_task(ctx::App, queue_name::AbstractString, task_key::AbstractString, callback::Function, owner::Owner; scope::Symbol=:user, watchers::AbstractVector{Owner}=Owner[], options::TaskOptions=TaskOptions(), key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return submit_queued_task(queue_name, task_key, callback, owner; scope, watchers, options, runtime=_resolve_runtime(ctx; key, runtime))
end

"""
    get_task_status(task_id, authority::TaskAuthority; runtime=default_runtime()) -> Dict{Symbol, Any}

The task `task_id` as `authority` may see it.

A task that does not exist and a task `authority` may not see get the **same** answer,
`Dict(:error => "Task not found", :status => "NOT_FOUND")`, so a route should turn that into a
`404` either way ([#323](https://github.com/PingoLee/Nitro.jl/issues/323)). It never raises
`AuthorizationError`: that difference let any authenticated user probe another user's task ids.
"""
function get_task_status(task_id::AbstractString, authority::TaskAuthority; runtime::WorkerRuntime=default_runtime())
    task_info = _visible_record(runtime, authority, String(task_id))
    task_info === nothing && return _not_found()

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

"""
    cancel_task(task_id, authority::TaskAuthority; runtime=default_runtime()) -> Dict{Symbol, Any}

Ask `task_id` to stop, as `authority`.

Like [`get_task_status`](@ref), a task `authority` may not see is answered exactly as a missing
one, with `:status => "NOT_FOUND"` ([#323](https://github.com/PingoLee/Nitro.jl/issues/323)).
"""
function cancel_task(task_id::AbstractString, authority::TaskAuthority; runtime::WorkerRuntime=default_runtime())
    id = String(task_id)
    return lock_tasks(runtime, id) do
        # Several rounds, only for an EXTERNAL submission a consumer process claimed, released or
        # requeued between this read and the claim below (#514). Each of those publishes a new
        # run of the same submission under a fresh `run_id`, so the fenced claim loses -- and the
        # cancel the caller asked for would be lost with it, answered as a re-submit it was not.
        # Every round starts again from `_visible_record`, so it re-authorizes against the record
        # it is about to cancel. The key's stripe already orders every in-process writer of its
        # `run_id` against this, so for a submission this process runs itself there is only ever
        # one round.
        for _ in 1:_CANCEL_CLAIM_ROUNDS
            outcome = _cancel_once(runtime, authority, id)
            outcome === nothing || return outcome
        end
        return Dict{Symbol, Any}(
            :error => "Task is being claimed by consumers faster than it can be cancelled; try again")
    end
end

# How many times `cancel_task` re-reads a submission whose run changed under it (#514).
const _CANCEL_CLAIM_ROUNDS = 8

# Is `latest` a later run of the SAME submission `read` was a run of -- claimed, handed back or
# requeued -- rather than a re-submit of the key? Only an external submission gets new runs
# without a new submission, and a re-submit is a new `TaskInfo` with its own `created_at`. Gating on
# `external` keeps every submission an app runs in-process on the pre-#514 answer, whatever the
# clock resolution.
_same_submission(read::TaskInfo, latest::TaskInfo) =
    read.external && latest.external && read.created_at == latest.created_at

# One round of `cancel_task`: its answer, or `nothing` to go round again on a newer run.
function _cancel_once(runtime::WorkerRuntime, authority::TaskAuthority, task_id::String)
    # The record served here is the one the fenced claim below addresses: when a live
    # predecessor and a durable successor disagree, `_visible_record` hands back the run the
    # caller is authorized on, so the claim can never cancel a run on another run's grant.
    task_info = _visible_record(runtime, authority, task_id)
    task_info === nothing && return _not_found()

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
    # `_visible_record` above decided against the watcher list of the run we read,
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
        latest === nothing && return _not_found()
        if latest.run_id != task_info.run_id
            # A consumer took, gave back or lost the claim since we read it (#514): still the
            # run the caller asked to cancel, as far as they can tell. Go round again.
            _same_submission(task_info, latest) && return nothing
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

function cancel_task(ctx::App, task_id::AbstractString, authority::TaskAuthority; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return cancel_task(task_id, authority; runtime=_resolve_runtime(ctx; key, runtime))
end

const _TERMINAL_STATUSES = (COMPLETED, FAILED, CANCELLED)

"""
    release_task!(task_id, ::System; runtime=default_runtime()) -> Dict{Symbol, Any}

Delete a **finished** task's record now, so the next submitter of its key starts fresh instead
of being refused. Returns `Dict(:status => "Task released")`, or a dict with `:error`.

This is how an administrator reclaims a squatted `:global` key
([#323](https://github.com/PingoLee/Nitro.jl/issues/323)). A `:global` id has no owner half, so
the first submitter of a predictable key (`"warm-price-cache"`, `"report-2026-09-25"`) becomes
its only watcher, and until retention deletes the record, 7 days after it finished by default,
every other user is refused unless a watch authorizer lets them in. **Derive `:global` keys from
system data, never from request input**, and use this when one is squatted anyway.

**Admin only: it takes `System()`, and an `Owner` is a `MethodError`**, like
[`get_queue_status`](@ref). Deleting a finished record discards its result, which is the owner's.

A task that has not finished is refused. Cancel it first. The delete is fenced on the run it
inspected ([`try_delete_task!`](@ref Nitro.Workers.try_delete_task!)), so if another process
re-runs the key in between, its fresh record survives and this reports what it found instead.

A run of the released key that is still executing in this process (a cancelled callback that
has not returned yet) keeps its live handle until it returns, and a reader in this process may
still be served that run meanwhile. Its terminal write finds no record and stores nothing.
"""
function release_task!(task_id::AbstractString, ::System; runtime::WorkerRuntime=default_runtime())
    id = String(task_id)
    return lock_tasks(runtime, id) do
        # The DURABLE read: this decides whether to destroy a record, which is a claiming call
        # (workers §2), and the live object may be a predecessor of what the row now holds.
        task_info = get_task_info(runtime.store, id)
        task_info === nothing && return _not_found()

        if !(task_info.status in _TERMINAL_STATUSES)
            return Dict{Symbol, Any}(
                :error => "Task is still $(task_info.status); cancel it before releasing it")
        end

        # Fenced on the run this call inspected, so a successor published by another process in
        # the meantime (`lock_tasks` does not span processes) is not deleted -- it would never run.
        if !try_delete_task!(runtime.store, id, _TERMINAL_STATUSES; run_id=task_info.run_id)
            latest = get_task_info(runtime.store, id)
            latest === nothing && return _not_found()
            return Dict{Symbol, Any}(
                :error => "Task changed while it was being released; it is now $(latest.status)")
        end
        return Dict{Symbol, Any}(:status => "Task released")
    end
end

function release_task!(ctx::App, task_id::AbstractString, authority::System; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return release_task!(task_id, authority; runtime=_resolve_runtime(ctx; key, runtime))
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

An empty result always means "no tasks": a store that cannot be read **throws**, paged or not
([#267](https://github.com/PingoLee/Nitro.jl/issues/267)). A persistent store may leave out a
record it can no longer decode, and it logs that record's id when it does.
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

Queue-wide introspection: depth, whether its processors are running, its concurrency, the ids
it is executing, and the ids of everything pending on `queue_name`.

`:current_tasks` is a `Vector{String}` with one entry per busy processor, so at most
`:concurrency` of them. It was a single `:current_task` id until #513 gave a queue more than one
processor.

**This is an admin surface, and it takes `System()` only.** Queue depth and `:current_tasks`
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

`:pending_tasks` is read from the store, so a store that cannot be read makes this **throw**
rather than report an empty queue ([#267](https://github.com/PingoLee/Nitro.jl/issues/267)).

An `External(…)` queue ([#514](https://github.com/PingoLee/Nitro.jl/issues/514)) is answered from
the store alone, with the same keys plus `:external => true`: `:current_tasks` are its runs a
consumer holds (`RUNNING`), `:running` is whether there is one, and `:concurrency` is `nothing`,
because each consumer process sets its own.
"""
function get_queue_status(queue_name::AbstractString, ::System; runtime::WorkerRuntime=default_runtime())
    # An external queue (#514) has no queue object here: its state is the store's. Read outside
    # `queue_lock`, since every answer below comes from the store.
    name = String(queue_name)
    _external_placement(runtime, name) === nothing || return _external_queue_status(runtime, name)

    qlock = get_queue_lock(runtime)
    queues = get_worker_queues(runtime)

    lock(qlock) do
        queue = Base.get(queues, String(queue_name), nothing)
        if queue === nothing
            return Dict{Symbol, Any}(:error => "Queue not found")
        end

        pending_tasks = [task.id for task in get_all_tasks(runtime, System(); status=PENDING, queue_name=String(queue_name))]
        current_tasks = copy(queue.current_tasks)
        processing = !isempty(current_tasks)
        return Dict{Symbol, Any}(
            :queue_name => String(queue_name),
            :running => any(t -> !istaskdone(t), queue.processors),
            :concurrency => queue.concurrency,
            :current_tasks => current_tasks,
            :pending_count => Base.n_avail(queue.channel),
            :pending_tasks => pending_tasks,
            :status_text => processing ? "Processing" : (isempty(pending_tasks) ? "Idle" : "Queued"),
            :total_load => length(pending_tasks) + length(current_tasks),
        )
    end
end

# Its own function, not a branch of the one above: the in-process branch assigns the same names
# inside a `lock` closure, and sharing them would box them (#364).
function _external_queue_status(runtime::WorkerRuntime, name::String)
    listed(status) = [task.id for task in get_all_tasks(runtime, System(); status, queue_name=name)
                      if task.external]
    pending_tasks = listed(PENDING)
    current_tasks = listed(RUNNING)
    processing = !isempty(current_tasks)
    return Dict{Symbol, Any}(
        :queue_name => name,
        :external => true,
        :running => processing,
        :concurrency => nothing,
        :current_tasks => current_tasks,
        :pending_count => length(pending_tasks),
        :pending_tasks => pending_tasks,
        :status_text => processing ? "Processing" : (isempty(pending_tasks) ? "Idle" : "Queued"),
        :total_load => length(pending_tasks) + length(current_tasks),
    )
end

function get_queue_status(ctx::App, queue_name::AbstractString, authority::System; key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return get_queue_status(queue_name, authority; runtime=_resolve_runtime(ctx; key, runtime))
end

"""
    start_cleanup_scheduler(; interval_hours=24, retain_days=7, zombie_min_age=nothing,
                            runtime=default_runtime()) -> CleanupScheduler

Start the runtime's background housekeeping. Every `interval_hours` it retires finished tasks
older than `retain_days` (`cleanup_old_tasks`).

With `zombie_min_age` set, each tick first re-runs the bounded zombie sweep
([`recover_zombie_tasks!`](@ref) with that bound), so a claim the boot sweep deferred as too
recent is recovered once it ages past the window, instead of waiting for a later boot
([#266](https://github.com/PingoLee/Nitro.jl/issues/266)). With `nothing`, the default, the tick
does not sweep zombies at all: an unbounded sweep on a timer would mark another process's live
runs `FAILED` on every tick. [`start!`](@ref) passes its own `zombie_min_age` here when
`recover_zombies` is on.

The two sweeps fail independently. A throw costs that sweep one tick, never the other sweep and
never the scheduler. Each logs at `@info` only when it did something.

The scheduler runs on the `:default` thread pool and, between ticks, waits once rather than
polling ([#369](https://github.com/PingoLee/Nitro.jl/issues/369)). While Julia has an
interactive thread, which is the 1.12 default for `julia` and `julia -t auto`, a Ctrl-C at the
REPL therefore reaches `serve` and not this task. Under `julia -t 1` every task shares one thread,
and under `julia -t N,0` thread 1 is a default thread, so it can land here. The scheduler then
logs a warning and stops normally, rather than dying with an unhandled error or swallowing that
press and every later one. Retention is off until the scheduler is started again.

The bound works by age alone, so choose it as you would for the boot sweep: longer than any task
legitimately runs. `Second(0)` passes validation but bounds nothing, which on a timer is exactly
the unbounded periodic sweep described above.

The zombie sweep runs while requests are being served. It locks one task at a time, for its
verdict on that task, so submissions and runs of other tasks do not wait for the scan
([#711](https://github.com/PingoLee/Nitro.jl/issues/711)). Each tick re-reads every `RUNNING`
record, including other processes' live runs, which it counts `too_recent` and leaves alone. At
the daily default that cost is negligible; a short `interval_hours` pays it on every tick.

Idempotent while a scheduler is running: a second call returns the running one, and its
arguments, `zombie_min_age` included, are ignored. Stop it with `stop_cleanup_scheduler!`
first to change them.
"""
function start_cleanup_scheduler(; interval_hours::Real=24, retain_days::Int=7,
                                 zombie_min_age::Union{Nothing, Dates.Period}=nothing,
                                 runtime::WorkerRuntime=default_runtime())
    # Refused at the call, not from inside the loop, where a throw would only be logged per tick.
    _check_zombie_min_age(zombie_min_age)
    scheduler_ref = get_cleanup_scheduler(runtime)
    existing = scheduler_ref[]
    if !isnothing(existing) && !istaskdone(existing.task)
        return existing
    end

    stop_signal = Channel{Nothing}(1)
    wake = Base.Event(true)
    interval_seconds = max(interval_hours * 3600, 0.01)
    # `_spawn_detached` -- the `:default` pool, NOT sticky -- and that placement is the #369 fix,
    # more than the wait below is. With `exit_on_sigint(false)` (every REPL) Julia throws SIGINT
    # into whichever task PARKED LAST on thread 1, and under Julia 1.12's default layout thread 1
    # is the interactive thread, which a `:default`-pool task never runs on. Probed on 1.12.7:
    # a sticky task parked there takes the interrupt even when it does not poll, the moment it is
    # the last to park; a `:default`-pool one never does. This used to be `_schedule_detached`
    # (sticky, `@async`-shaped) on the argument that it "runs no user code" -- but its sweep is
    # `cleanup_tasks!` on a caller-supplied store, a database DELETE for `PormGWorkerStore`, which
    # is exactly the shape src/middleware/janitor.jl already refuses to pin to a request thread.
    # Nothing injects into this task (#127), so migrating it is free.
    #
    # Idle, it is parked in ONE `wait(wake)` per tick, woken once by the tick's `Timer` or by
    # `stop_cleanup_scheduler!`. It used to sit in `timedwait`, which POLLS at its 0.1s default --
    # 864,000 wake-ups a day for a daily job, and each one re-parked it on thread 1, which is what
    # kept making it the last task to park there. The `Timer` callback inherits this task's
    # non-stickiness and pool (`Timer(cb, t)` copies the creator's `sticky`), so it is off
    # thread 1 as well. It is stopped by closing `stop_signal` and notifying `wake`, never by an
    # interrupt.
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
    #   * detached, not a bare `Threads.@spawn` (#209). The scheduler is started from `start!`,
    #     which an app may well call inside its own bootstrap transaction, and it then issues a
    #     store DELETE on every tick for the life of the process. The inherited dynamic scope is
    #     dropped.
    task = errormonitor(_spawn_detached() do
        _cleanup_scheduler_loop(runtime, stop_signal, wake, interval_seconds, retain_days, zombie_min_age)
    end)

    scheduler = CleanupScheduler(task, stop_signal, wake)
    scheduler_ref[] = scheduler
    return scheduler
end

# The scheduler's loop, named for the reason `_janitor_loop` is (src/middleware/janitor.jl): the
# placement of its `try`s and of its interrupt handler is the whole point, and a named function
# keeps them readable and lets a test drive the loop without going through the spawn.
#
# ── An interrupt that lands here anyway (#369) ──
#
# Only reachable when there IS no interactive thread (`julia -t 1`, `JULIA_NUM_THREADS=1`): then
# every task shares thread 1, and whichever parked last takes the Ctrl-C. The answer is to STOP,
# say so, and return normally. Each alternative was ruled out:
#
#   * Rethrow (the old behavior): the task dies with an `Unhandled Task ERROR`, `serve` keeps
#     running, and teardown logs "already died". The interrupt reaches nobody who can act on it.
#   * Swallow and keep looping: the loop re-parks, is the last task to park again, and takes the
#     NEXT Ctrl-C too -- probed, three presses in a row were all eaten and the main task never saw
#     one. Ctrl-C could then never stop the server.
#   * Forward it to the task blocked in `serve`: that is `schedule(t, exc; error=true)`, the
#     injection #127 removed because it aborts the process when `t` is running on another thread,
#     and a runtime does not know which `App`'s serve task, if any, it belongs to.
#
# Ending the task means it is no longer parked anywhere, so the next press goes elsewhere.
# Retention stops until the scheduler is started again, and the `@warn` says so -- the one thing
# the old rethrow did right was not being silent about it. The per-tick `rethrow` guards below
# stay: they route an interrupt that lands INSIDE a sweep to this same handler.
function _cleanup_scheduler_loop(runtime::WorkerRuntime, stop_signal::Channel{Nothing},
                                 wake::Base.Event, interval_seconds::Real, retain_days::Int,
                                 zombie_min_age::Union{Nothing, Dates.Period})
    try
        while true
            timer = Timer(_ -> notify(wake), interval_seconds)
            try
                # Closed counts as stopped. Checked before parking: a stop that landed during the
                # previous sweep has already set `wake`, so this `wait` would return at once
                # anyway -- checking first just skips the round trip.
                isopen(stop_signal) && wait(wake)
            finally
                close(timer)
            end
            isopen(stop_signal) || break
            # Zombies FIRST, and in a `try` of their own (#266). A failed write is logged and
            # absorbed inside the periodic sweep; this `try` is the backstop for anything else, so
            # a failed sweep costs this tick's sweep and never the retention pass below, which is
            # the scheduler's original job. First, because a
            # record it fails carries a fresh `completed_at` and so is never retired on the same
            # tick either way; the order is only about which failure the log reports first.
            #
            # Gated on a bound, never unconditional: see the docstring. Each verdict takes its key's
            # `lock_tasks` stripe, as the boot sweep does, and this runtime's own runs are spared by
            # `get_active_task`, because `_claim_run!` publishes a run's handle under that stripe
            # before its RUNNING claim.
            if zombie_min_age !== nothing
                try
                    _recover_zombie_tasks!(runtime, zombie_min_age, ZOMBIE_SWEEP_BATCH; periodic=true)
                catch e
                    e isa InterruptException && rethrow()
                    @error "Nitro.Workers: periodic zombie sweep failed" exception=(loggable(e), catch_backtrace())
                end
            end
            # Expired leases next, in their own `try` too (#514): the fallback adjudicator for an
            # external queue whose last consumer is gone, since each consumer also runs it on its
            # own heartbeat. Only this runtime's external queues, and a no-op on a runtime with none.
            try
                _requeue_expired_tick!(runtime)
            catch e
                e isa InterruptException && rethrow()
                @error "Nitro.Workers: periodic lease adjudication failed" exception=(loggable(e), catch_backtrace())
            end
            try
                deleted = cleanup_old_tasks(retain_days; runtime=runtime)
                # A success line too (#238), so a quiet log means "nothing to retire" rather than
                # "never ran". It is `@info` only when the tick did something: the default cadence
                # is daily, but the interval is caller-supplied, and an unconditional line at a short
                # interval is noise. The boot-time zombie sweep is the one that logs
                # unconditionally -- it runs once, in the window where silence cost an incident.
                # Its periodic re-run above follows this rule, not that one.
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
                @error "Nitro.Workers: task retention sweep failed" exception=(loggable(e), catch_backtrace())
            end
        end
    catch e
        e isa InterruptException || rethrow()
        @warn "Nitro.Workers: an interrupt (Ctrl-C) reached the task retention scheduler " *
              "instead of the server. The scheduler has stopped, so finished tasks are not " *
              "retired until it is started again. Press Ctrl-C again to stop the server. Outside " *
              "a REPL, that press can end the process without running its shutdown hooks."
    end
    return nothing
end

# One `requeue_expired!` over this runtime's external queues, logged like the retention pass:
# `@info` only when it adjudicated something. It throws on a read failure; the caller's `try` owns
# that, as it does for the other two passes. `:skip`, not the consumer's fail-closed `:fail`: a
# queue this runtime does not declare may be another app's on the same store, or one a newer
# deploy added, so its expired runs are left to the consumers that declare it.
function _requeue_expired_tick!(runtime::WorkerRuntime)
    policies = _external_policies(runtime)
    (isempty(policies) || !supports_claims(runtime.store)) && return nothing
    tally = requeue_expired!(runtime.store, current_time_utc(); policies, on_unknown_queue = :skip)
    if tally.requeued + tally.failed > 0
        @info "Nitro.Workers: expired leases adjudicated" requeued = tally.requeued failed = tally.failed unknown_queue = tally.unknown_queue lost_race = tally.lost_race
    else
        @debug "Nitro.Workers: expired leases adjudicated" requeued = tally.requeued failed = tally.failed unknown_queue = tally.unknown_queue lost_race = tally.lost_race
    end
    return tally
end

function start_cleanup_scheduler(ctx::App; interval_hours::Real=24, retain_days::Int=7,
                                 zombie_min_age::Union{Nothing, Dates.Period}=nothing,
                                 key::Symbol=DEFAULT_EXTENSION_KEY, runtime::Union{Nothing, WorkerRuntime}=nothing)
    return start_cleanup_scheduler(; interval_hours, retain_days, zombie_min_age, runtime=_resolve_runtime(ctx; key, runtime))
end

function stop_cleanup_scheduler!(scheduler::CleanupScheduler)
    # `close`, not `put!`. Nothing ever `take!`s this signal -- the scheduler only checks `isopen`
    # on it -- so a `Channel(1)` that already holds the token blocks the next `put!` forever, and
    # the `isopen && !isready` guard is a check-then-act that two concurrent teardowns can both
    # pass. That race was previously hard to reach; `shutdown!` is now called for every backend,
    # from both `uninstall!` and `reset_runtime!`, so it is not. Closing is idempotent and needs no
    # guard, and so is the `notify`.
    #
    # Close THEN notify, in that order: the loop re-checks `isopen` after every wake, so the
    # notify only has to get it out of `wait` once the close is already visible (#369). A notify
    # that arrives before the loop parks is held by the autoreset `Event`, not lost.
    close(scheduler.stop_signal)
    notify(scheduler.wake)
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
        @error "Nitro.Workers: the retention scheduler had already died; teardown continues" exception=(loggable(e), catch_backtrace())
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
