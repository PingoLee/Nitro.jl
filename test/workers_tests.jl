@testitem "Workers" tags=[:core, :workers] setup=[NitroCommon] begin

using Test
using Dates
using HTTP
using JSON
using Nitro
using Nitro.Workers
# The store contract and the run/queue internals stopped being exported in #323; this suite
# exercises them directly, so it names them.
using Nitro.Workers: get_task_info, set_task!, replace_task!, add_watcher!, try_transition!,
    delete_task!, try_delete_task!, cleanup_tasks!, clear_records!, list_running_task_refs,
    RunningTaskRef, lock_tasks, get_active_task, get_active_task_info, register_run!,
    SequentialQueue, QueueItem, get_sequential_queues, get_queue_lock
using Nitro.Errors: AuthorizationError, StoreInterfaceError, WorkerUnavailableError, WorkerCapacityError
using Base.ScopedValues: ScopedValue, with

function wait_for(predicate::Function; timeout::Real=5.0)
    return timedwait(predicate, timeout)
end

# The ONE answer a read or cancel gives both for a task that does not exist and for a task the
# caller may not see (#323). Compared whole, so a denial that leaks even an extra key fails.
is_not_found(d) = d == Dict{Symbol, Any}(:error => "Task not found", :status => "NOT_FOUND")

# A stand-in for any `ScopedValue` an app might have open at submit time -- PormG's
# `_tx_context` is the one #209 is about, but nothing here needs PormG to say what a spawn
# inherits. `:outer` is the default, i.e. what a correctly DETACHED worker run must observe.
const _SCOPE_PROBE = ScopedValue(:outer)

# Records the dynamic scope its retention sweep runs under.
#
# Implements ONLY `cleanup_tasks!` on purpose: the cleanup scheduler reaches nothing else on
# the store, and the contract's missing-method errors are raised lazily at the call rather than
# at construction — so a one-method store is the smallest thing that can observe `api.jl`'s
# scheduler spawn without dragging in a 16-method backend.
struct ScopeProbeStore <: AbstractWorkerStore
    seen::Channel{Symbol}

    ScopeProbeStore() = new(Channel{Symbol}(8))
end

# `isready ||`, so the sweep NEVER blocks. `timedwait`'s poll interval has a 0.1s floor, so a
# scheduler asked for a 0.01s tick fires ~10x a second while the test takes exactly one entry.
# An unguarded `put!` on a bounded channel would fill it within a second and then block the
# scheduler INSIDE `cleanup_tasks!` -- no longer parked in `timedwait`, so it never observes the
# stop signal, and `stop_cleanup_scheduler!` joins it with no deadline (workers §6). That hangs
# the CI leg instead of failing it, which is the worse outcome by a distance.
Nitro.Workers.cleanup_tasks!(s::ScopeProbeStore, ::Int) =
    (isready(s.seen) || put!(s.seen, _SCOPE_PROBE[]); 0)

# A store that implements nothing. Declared at item scope because a bare `struct` inside a
# `@testset` body would still work, but this one is referenced from two testsets.
struct NothingWorkerStore <: AbstractWorkerStore end

# Types its task id more loosely than the contract does, which is legal and common.
struct WideStore <: AbstractWorkerStore end
Nitro.Workers.get_task_info(::WideStore, ::AbstractString) = "wide"

# Implements only the one contract method whose store argument is not first.
struct OnlyLockStore <: AbstractWorkerStore end
Nitro.Workers.lock_tasks(callback::Function, ::OnlyLockStore) = callback()

# Two shapes of third-party store written before `try_transition!` gained its `run_id` fence.
struct StaleKwStore <: AbstractWorkerStore end
Nitro.Workers.try_transition!(::StaleKwStore, ::String, from, ::TaskStatus;
                              error=nothing, completed_at=nothing) = false

struct StaleNoKwStore <: AbstractWorkerStore end
Nitro.Workers.try_transition!(::StaleNoKwStore, ::String, from, ::TaskStatus) = false

# A conforming backend that implements the 16 data-and-policy rows and NOTHING else: no
# `shutdown!`, no queue or scheduler accessor, no run-handle cache, no `clear_records!`. It is
# the proof that #167 closed the CLASS of the #29 leak rather than one instance of it — under
# the pre-#167 contract this type could not be written at all, because teardown was the store's
# job and a store that forgot it leaked silently.
#
# Deliberately the naive implementation a third party would write: it stores whatever object it
# is handed, exactly as `InMemoryWorkerStore` does.
struct DataOnlyStore <: AbstractWorkerStore
    rows::Dict{String, TaskInfo}
    lk::ReentrantLock
    qa::Base.RefValue{Any}
    wa::Base.RefValue{Any}
    er::Base.RefValue{Any}

    DataOnlyStore() = new(Dict{String, TaskInfo}(), ReentrantLock(),
                          Ref{Any}(nothing), Ref{Any}(nothing), Ref{Any}(nothing))
end

Nitro.Workers.lock_tasks(callback::Function, s::DataOnlyStore) = lock(callback, s.lk)
Nitro.Workers.get_task_info(s::DataOnlyStore, id::String) = lock(() -> get(s.rows, id, nothing), s.lk)
Nitro.Workers.set_task!(s::DataOnlyStore, id::String, t::TaskInfo) = lock(() -> (s.rows[id] = t), s.lk)
Nitro.Workers.replace_task!(s::DataOnlyStore, id::String, t::TaskInfo) = lock(() -> (s.rows[id] = t), s.lk)
Nitro.Workers.delete_task!(s::DataOnlyStore, id::String) = (lock(() -> delete!(s.rows, id), s.lk); nothing)
Nitro.Workers.try_delete_task!(s::DataOnlyStore, id::String, from; run_id) = lock(s.lk) do
    t = get(s.rows, id, nothing)
    (t === nothing || !(t.status in from) || !(run_id === nothing || t.run_id == run_id)) && return false
    delete!(s.rows, id)
    return true
end

function Nitro.Workers.add_watcher!(s::DataOnlyStore, id::String, user_id::String)
    lock(s.lk) do
        t = get(s.rows, id, nothing)
        t === nothing && return false
        user_id in t.watchers || push!(t.watchers, user_id)
        return true
    end
end

function Nitro.Workers.try_transition!(s::DataOnlyStore, id::String, from, to::TaskStatus;
                                       run_id, error=nothing, completed_at=nothing,
                                       started_at=nothing, result=Nitro.Workers.UNSUPPLIED,
                                       progress=nothing)
    lock(s.lk) do
        t = get(s.rows, id, nothing)
        t === nothing && return false
        t.status in from || return false
        run_id === nothing || t.run_id == run_id || return false
        error === nothing || (t.error = error)
        completed_at === nothing || (t.completed_at = completed_at)
        started_at === nothing || (t.started_at = started_at)
        result === Nitro.Workers.UNSUPPLIED || (t.result = result)
        progress === nothing || (@atomic t.progress = Float64(progress))
        t.status = to
        return true
    end
end

function Nitro.Workers.cleanup_tasks!(s::DataOnlyStore, retain_days::Int)
    cutoff = Dates.now(Dates.UTC) - Dates.Day(retain_days)
    lock(s.lk) do
        gone = [k for (k, t) in s.rows
                if t.completed_at !== nothing && t.completed_at < cutoff &&
                   t.status in (COMPLETED, FAILED, CANCELLED)]
        foreach(k -> delete!(s.rows, k), gone)
        return length(gone)
    end
end

function Nitro.Workers.get_all_tasks(s::DataOnlyStore, authority::TaskAuthority;
                                     status=nothing, queue_name=nothing)
    lock(s.lk) do
        return TaskInfo[t for t in values(s.rows)
                        if (status === nothing || t.status == status) &&
                           (queue_name === nothing || t.queue_name == queue_name) &&
                           Nitro.Workers._is_authorized(authority, t)]
    end
end

Nitro.Workers.get_queue_authorizer(s::DataOnlyStore) = s.qa[]
Nitro.Workers.set_queue_authorizer!(s::DataOnlyStore, f) = (s.qa[] = f)
Nitro.Workers.get_watch_authorizer(s::DataOnlyStore) = s.wa[]
Nitro.Workers.set_watch_authorizer!(s::DataOnlyStore, f) = (s.wa[] = f)
Nitro.Workers.get_error_redactor(s::DataOnlyStore) = s.er[]
Nitro.Workers.set_error_redactor!(s::DataOnlyStore, f) = (s.er[] = f)

@testset "Worker store contract is discoverable and loud" begin
    # The shipped backend conforms. This is the assertion a third-party store copies.
    @test isempty(missing_store_methods(InMemoryWorkerStore))

    # ...and the check can actually fail, which is what makes the line above mean something.
    missing_names = missing_store_methods(NothingWorkerStore)
    @test length(missing_names) == length(Nitro.Workers.WORKER_STORE_INTERFACE)
    @test :get_task_info in missing_names
    @test :lock_tasks in missing_names          # the callback-first row
    @test :try_transition! in missing_names

    # The lifecycle rows LEFT the contract in #167, so a store owes none of them.
    for gone in (:shutdown!, :reload_task, :get_cleanup_scheduler, :get_sequential_queues,
                 :get_queue_lock, :get_active_task, :register_active_task!,
                 :deregister_active_task!, :get_active_task_info,
                 :register_active_task_info!, :deregister_active_task_info!)
        @test !(gone in missing_names)
    end

    # Reaching a contract method on an incomplete store names the method and the type.
    err = try
        get_task_info(NothingWorkerStore(), "task-1")
        nothing
    catch e
        e
    end
    @test err isa StoreInterfaceError
    @test err.store_type === NothingWorkerStore
    rendered = sprint(showerror, err)
    @test occursin("get_task_info", rendered)
    @test occursin("NothingWorkerStore", rendered)

    # A CALLER-side mistake must not be mislabelled as a missing backend method. The fallbacks
    # widen every non-store parameter to `Any` (see below for why), so they do catch these calls;
    # `store_contract_error` is what tells the two apart, by asking whether the store's own type
    # contributed a method at all.
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    @test_throws MethodError get_task_info(store, 42)
    @test_throws MethodError cleanup_tasks!(store, "not-a-day-count")

    # A store that implements the contract never reaches a fallback for a keyword it does not
    # accept: it is more specific on the positional arguments, so it is the one that rejects.
    @test_throws MethodError try_transition!(store, "task-1", (PENDING,), RUNNING;
                                             run_id=nothing, no_such_keyword=1)
end

@testset "A stale store's missing run_id fence is refused by both dispatch routes" begin
    # `try_transition!`'s docstring promises that a third-party store predating the `run_id`
    # precondition cannot silently accept the call and reintroduce #108. There are TWO routes to
    # that refusal and they behave differently, so a single `@test_throws MethodError` proves
    # nothing -- it passed against `main`, where no fallback existed at all, and it passes
    # whichever route runs.

    # Route 1: the stale method still takes keywords, so it wins dispatch and rejects `run_id`
    # itself. Julia's message names the keywords.
    stale_kw = try
        try_transition!(StaleKwStore(), "t", (PENDING,), RUNNING; run_id=nothing)
        nothing
    catch e
        e
    end
    @test stale_kw isa MethodError
    @test occursin("keyword argument", sprint(showerror, stale_kw))

    # Route 2: the stale method has NO keyword parameters, so keyword dispatch cannot see it at
    # all and the call lands on the contract fallback. `store_contract_error` must recognize that
    # the store DID implement the method and raise a MethodError rather than mislabelling the
    # backend as unimplemented -- which is the whole reason it checks at runtime.
    stale_nokw = try
        try_transition!(StaleNoKwStore(), "t", (PENDING,), RUNNING; run_id=nothing)
        nothing
    catch e
        e
    end
    @test stale_nokw isa MethodError
    # Assert the SEPARATION, not just one side of it. The discrimination above lives in an upstream
    # message string, so a reworded Julia release could make both routes match and the route-1
    # assertion would silently stop discriminating instead of failing.
    @test !occursin("keyword argument", sprint(showerror, stale_nokw))

    # Both stores implement the method, so neither is reported missing.
    @test !(:try_transition! in missing_store_methods(StaleKwStore))
    @test !(:try_transition! in missing_store_methods(StaleNoKwStore))

    # ...and on a CONFORMING store the fence is the keyword being required with no default, so
    # omitting it is refused rather than quietly defaulting to "no run precondition" (#48's shape:
    # the unfenced call must never be the shorter one).
    @test_throws UndefKeywordError try_transition!(InMemoryWorkerStore(), "t", (PENDING,), RUNNING)
end

@testset "Contract fallbacks never shadow a backend that types its arguments differently" begin
    # The fallbacks CANNOT be pinned to the contract's exact argument types. `(WideStore,
    # AbstractString)` and `(AbstractWorkerStore, String)` are mutually ambiguous -- neither is
    # more specific -- so an exact-typed fallback can win the call and the store's own method
    # never runs. `::AbstractString` is not a contrived choice either: Nitro's own
    # `submit_task`/`submit_sequential_task` are written that way.
    @test get_task_info(WideStore(), "id") == "wide"
    @test !(:get_task_info in missing_store_methods(WideStore))

    # The callback-first row is the one whose store is not the first argument, so a detector that
    # assumed position 1 would mis-handle exactly this method and nothing else.
    @test !(:lock_tasks in missing_store_methods(OnlyLockStore))
    @test length(missing_store_methods(OnlyLockStore)) ==
          length(Nitro.Workers.WORKER_STORE_INTERFACE) - 1
end

@testset "shutdown! releases the scheduler, the queues and every settled handle (#167, #176)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store; queues = ["teardown-q"])

    try
        # A real sequential queue with a live processor, and a real cleanup scheduler.
        owner = Owner("user-teardown")
        task_id = submit_sequential_task("teardown-q", "one", () -> "done", owner; runtime=rt_store)
        @test wait_for(() -> get_task_status(task_id, owner; runtime=rt_store)[:status] == "COMPLETED") == :ok

        scheduler = start_cleanup_scheduler(; interval_hours=1, retain_days=7, runtime=rt_store)
        @test get_cleanup_scheduler(rt_store)[] === scheduler

        queues = get_sequential_queues(rt_store)
        @test haskey(queues, "teardown-q")
        channel = queues["teardown-q"].channel
        @test isopen(channel)

        # A run handle and its live object, as an executing task would have published them.
        # The two must be treated differently below, which is the whole point of the pairing.
        #
        # `wait` before the teardown, deliberately. Since #176 a handle is released only once its
        # task is DONE, so "the handles are gone" is now a claim about a finished task -- and
        # letting `shutdown!`'s own yielding be what completes this one would make the assertion
        # below true by timing rather than by contract, and silently false the next time this
        # function yields less. A handle that is still live is covered by its own testset.
        in_flight = TaskInfo("in-flight")
        settled_handle = @async nothing
        wait(settled_handle)
        Nitro.Workers.register_active_task!(rt_store, "in-flight", settled_handle)
        Nitro.Workers.register_active_task_info!(rt_store, "in-flight", in_flight)

        @test shutdown!(rt_store) == true

        # The scheduler is stopped AND its slot cleared, so a restart does not see a dead one.
        @test get_cleanup_scheduler(rt_store)[] === nothing
        @test istaskdone(scheduler.task)

        # The channel is closed -- that is the processor's stop signal -- and the registry is
        # emptied, not merely drained. A closed-but-present queue is the reuse hazard: `get!` in
        # `_get_or_create_queue` would hand the dead one straight back.
        @test !isopen(channel)
        @test isempty(get_sequential_queues(rt_store))
        @test isempty(rt_store.active_tasks)

        # ...but the live-`TaskInfo` cache SURVIVES, because `cancel_task` resolves a run's
        # object through it. Clearing it would make a run that outlives a teardown the one
        # thing it must never be: uncancellable. This used to be asserted for PormG only, and
        # `InMemoryWorkerStore` satisfied it by accident -- its `get_active_task_info` aliased
        # the registry, which `shutdown!` also left alone. One mechanism now, asserted here.
        @test haskey(rt_store.active_task_infos, "in-flight")
        @test get_active_task_info(rt_store, "in-flight") === in_flight

        # So the runtime is genuinely reusable, rather than poisoned for sequential work.
        again = submit_sequential_task("teardown-q", "two", () -> "again", owner; runtime=rt_store)
        @test wait_for(() -> get_task_status(again, owner; runtime=rt_store)[:status] == "COMPLETED") == :ok
        @test get_sequential_queues(rt_store)["teardown-q"].channel !== channel

        # A RESET is total where a teardown is not: it also drops the live cache.
        reset_runtime!(rt_store)
        @test isempty(rt_store.active_task_infos)
        @test isempty(store.task_registry)
    finally
        reset_runtime!(rt_store)
    end
end

@testset "Graceful worker drain (#176)" begin
    # Every callback below PARKS -- on the cancellation token via `timedwait`, or on a
    # `Base.Event` the test releases. None of them spins. #143 records that a CPU-bound spin
    # probe wedges the ReTestItems worker into its 600s timeout on roughly half of `-t 2` runs
    # once the full suite is around it, and a drain needs no spinning to be observable.
    #
    # Elapsed-time bounds are deliberately loose. The first `@warn` on the expiry path compiles
    # inside the measured region and can cost a second on its own, so timing is only ever used
    # to separate "waited" from "did not wait" -- never to pin a duration. The contract itself
    # is asserted through state.

    @testset "a cooperative run finishes inside the drain" begin
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        entered = Base.Event()
        saw_token = Threads.Atomic{Bool}(false)
        try
            id = submit_task("coop", function (task_info)
                notify(entered)
                # Parks until asked to stop -- the shape the tutorial documents.
                timedwait(() -> cancel_requested(task_info), 10.0; pollint=0.02)
                saw_token[] = cancel_requested(task_info)
                return "stopped early"
            end, Owner("u"); runtime=rt)

            wait(entered)
            @test get_task_status(id, Owner("u"); runtime=rt)[:status] == "RUNNING"

            # The whole point: when this returns, the run is over. Before #176 `shutdown!`
            # returned with the callback still parked and the record still RUNNING.
            @test shutdown!(rt) == true
            @test get_task_status(id, System(); runtime=rt)[:status] == "COMPLETED"
            @test isempty(rt.active_tasks)

            # The token is set BEFORE the wait, not as a parting nudge on expiry. Were it set
            # afterwards, the callback above could never have returned in time.
            @test saw_token[] == true
        finally
            reset_runtime!(rt)
        end
    end

    @testset "a run that outlives the drain keeps its handle, so the sweep spares it" begin
        # THE issue. Against the pre-#176 `empty!(active_tasks)` the handle is gone here, the
        # sweep counts 1, the record reads FAILED, and the callback's real result is discarded
        # when its own run-fenced write loses.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        entered = Base.Event()
        release = Base.Event()
        try
            id = submit_task("uncoop", function (task_info)
                notify(entered)
                wait(release)            # never polls the token
                return "finished anyway"
            end, Owner("u"); runtime=rt)

            wait(entered)
            @test shutdown!(rt; drain_timeout=0.2) == false

            @test get_active_task(rt, id) !== nothing
            @test recover_zombie_tasks!(; runtime=rt) == 0
            @test get_task_status(id, System(); runtime=rt)[:status] == "RUNNING"

            # Keeping the handle is a deferral, not a leak: the run reclaims it through
            # `_finish_task!` the moment the callback actually returns.
            notify(release)
            @test wait_for(() -> get_active_task(rt, id) === nothing) == :ok
            @test wait_for(() -> get_task_status(id, System(); runtime=rt)[:status] ==
                                 "COMPLETED") == :ok
        finally
            notify(release)
            reset_runtime!(rt)
        end
    end

    @testset "drain_timeout=0 is the pre-#176 behaviour, exactly" begin
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        entered = Base.Event()
        release = Base.Event()
        token_at_exit = Threads.Atomic{Bool}(true)
        returned = Threads.Atomic{Bool}(false)
        try
            submit_task("old-way", function (task_info)
                notify(entered)
                wait(release)
                token_at_exit[] = cancel_requested(task_info)
                returned[] = true
                return "x"
            end, Owner("u"); runtime=rt)

            wait(entered)
            started = time()
            # `false`, because it abandoned a live run rather than settling it -- the same thing
            # `_shutdown_server` reports when `timeout = 0` sends it straight to a force-close.
            @test shutdown!(rt; drain_timeout=0) == false
            @test time() - started < 2.0          # did not wait on anything

            # Handles dropped, so the sweep still declares the live run dead. That is the old
            # damage, kept reachable on purpose as the documented escape hatch.
            @test isempty(rt.active_tasks)
            @test recover_zombie_tasks!(; runtime=rt) == 1

            # And no token was set: asking a callback to abandon work on the way out of a
            # teardown that was never going to wait for the answer is pure harm.
            notify(release)
            @test wait_for(() -> returned[]) == :ok
            @test token_at_exit[] == false
        finally
            notify(release)
            reset_runtime!(rt)
        end
    end

    @testset "a sequential run settles on its info, not on the shared processor task" begin
        # The sequential path registers `current_task()` -- the long-lived queue processor. If
        # `_run_settled` probed only `istaskdone`, this drain could not finish until the
        # processor had also worked through `b`, which is parked on an Event the test holds.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store; queues = ["q"])
        owner = Owner("u")
        hold = Base.Event()
        try
            a = submit_sequential_task("q", "a", function (task_info)
                timedwait(() -> cancel_requested(task_info), 10.0; pollint=0.02)
                return "a"
            end, owner; runtime=rt)
            submit_sequential_task("q", "b", (task_info) -> (wait(hold); "b"), owner; runtime=rt)

            @test wait_for(() -> get_task_status(a, owner; runtime=rt)[:status] == "RUNNING") == :ok

            started = time()
            @test shutdown!(rt; drain_timeout=8.0) == true
            @test time() - started < 8.0           # did not ride the ceiling out
            @test get_task_status(a, System(); runtime=rt)[:status] == "COMPLETED"
        finally
            notify(hold)
            reset_runtime!(rt)
        end
    end

    @testset "the release sweep is fenced, so it cannot evict a successor's handle" begin
        # White-box, because the interleaving it guards is not reachable deterministically from
        # outside: the drain spans seconds, so a snapshotted run can finish and a re-run publish
        # a NEW run under the same key entirely inside the window. An id-keyed delete would then
        # tear down the live successor -- the #108/#167 defect through a much wider door.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        park = Base.Event()
        try
            predecessor = TaskInfo("alice::drain-fence")
            predecessor.status = RUNNING
            replace_task!(store, predecessor.id, predecessor)
            finished = @async nothing
            wait(finished)
            snapshot = [Nitro.Workers.DrainEntry(predecessor.id, predecessor.run_id,
                                                 predecessor, finished)]

            # The successor takes over the key while the "drain" is notionally still waiting.
            successor = TaskInfo("alice::drain-fence")
            successor.status = RUNNING
            replace_task!(store, successor.id, successor)
            successor_handle = @async wait(park)
            register_run!(rt, successor.id, successor, successor_handle)

            Nitro.Workers._release_settled_handles!(rt, snapshot)

            @test get_active_task(rt, "alice::drain-fence") === successor_handle
            @test recover_zombie_tasks!(; runtime=rt) == 0
            @test get_task_info(store, "alice::drain-fence").status == RUNNING
        finally
            notify(park)
            reset_runtime!(rt)
        end
    end

    @testset "the drain releases handles but never the live TaskInfo cache" begin
        # `cancel_task` resolves a run's live object through `active_task_infos`, so a teardown
        # that cleared it would make a run outliving the teardown uncancellable. The sweep is
        # `active_tasks`-only for exactly that reason.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        try
            info = TaskInfo("settled")
            handle = @async nothing
            wait(handle)
            register_run!(rt, "settled", info, handle)

            @test shutdown!(rt) == true
            @test get_active_task(rt, "settled") === nothing
            @test get_active_task_info(rt, "settled") === info
        finally
            reset_runtime!(rt)
        end
    end

    @testset "shutdown! from inside a callback does not wait for its own run" begin
        # Reachable through `resetstate()` and through an app callback calling `terminate()`.
        # The caller's run cannot settle while it is blocked in the wait, so without the
        # re-entrancy skip this stalls for the whole window and then warns about itself.
        #
        # `task === current_task()` alone does NOT catch it: with a deadline (the default)
        # `timeout_call` runs the callback on a child task while the registered handle is the
        # parent parked in `timedwait`. The task-local `CURRENT_RUN_KEY` marker closes that.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        elapsed = Threads.Atomic{Float64}(-1.0)
        try
            submit_task("self-teardown", function (task_info)
                started = time()
                shutdown!(rt; drain_timeout=8.0)
                elapsed[] = time() - started
                return "ok"
            end, Owner("u"); runtime=rt)

            @test wait_for(() -> elapsed[] >= 0; timeout=20.0) == :ok
            @test elapsed[] < 8.0
        finally
            reset_runtime!(rt)
        end
    end

    @testset "reset_runtime! does not drain by default, but honours drain_timeout" begin
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        entered = Base.Event()
        release = Base.Event()
        token_at_exit = Threads.Atomic{Bool}(true)
        returned = Threads.Atomic{Bool}(false)
        try
            submit_task("reset-me", function (task_info)
                notify(entered)
                wait(release)
                token_at_exit[] = cancel_requested(task_info)
                returned[] = true
                return "x"
            end, Owner("u"); runtime=rt)
            wait(entered)

            # A reset is TOTAL -- it erases the live cache and, here, the records themselves --
            # so waiting for an outcome it is about to delete buys nothing. It also keeps every
            # `finally` in this file, and `resetstate()`, off the drain path.
            started = time()
            reset_runtime!(rt)
            @test time() - started < 2.0
            @test isempty(rt.active_tasks)
            @test isempty(rt.active_task_infos)

            # "Returned fast with both dicts empty" is ALSO true of the pre-#176 code, which never
            # drained and always emptied both -- so on its own it constrains nothing. The token is
            # what discriminates: a reset that had drained would have set it.
            notify(release)
            @test wait_for(() -> returned[]) == :ok
            @test token_at_exit[] == false
        finally
            notify(release)
            reset_runtime!(rt)
        end

        rt2 = WorkerRuntime(InMemoryWorkerStore())
        entered2 = Base.Event()
        drained_at = Threads.Atomic{Bool}(false)
        try
            submit_task("reset-drain", function (task_info)
                notify(entered2)
                timedwait(() -> cancel_requested(task_info), 10.0; pollint=0.02)
                drained_at[] = cancel_requested(task_info)
                return "x"
            end, Owner("u"); runtime=rt2)
            wait(entered2)

            reset_runtime!(rt2; drain_timeout=8.0)
            # It waited: the callback had returned before the reset did.
            @test drained_at[] == true
            @test isempty(rt2.active_tasks)
        finally
            reset_runtime!(rt2)
        end
    end

    @testset "uninstall! drains, and displacement drains the runtime it displaces" begin
        app = Nitro.Core.App()
        rt_a = WorkerRuntime(InMemoryWorkerStore())
        entered = Base.Event()
        try
            start!(app; runtime=rt_a, cleanup_enabled=false, recover_zombies=false)
            id = submit_task("via-app", function (task_info)
                notify(entered)
                timedwait(() -> cancel_requested(task_info), 10.0; pollint=0.02)
                return "done"
            end, Owner("u"); runtime=rt_a)
            wait(entered)

            uninstall!(app)
            @test get_task_status(id, System(); runtime=rt_a)[:status] == "COMPLETED"
            @test worker_runtime(app) === nothing
        finally
            reset_runtime!(rt_a)
        end

        # Displacement is the teardown-then-restart-in-one-process shape: `start!` runs the
        # zombie sweep against the SAME store microseconds later, so not draining here is the
        # bug firing immediately.
        app2 = Nitro.Core.App()
        shared = InMemoryWorkerStore()
        rt_b = WorkerRuntime(shared)
        rt_c = WorkerRuntime(shared)
        entered2 = Base.Event()
        try
            install!(app2, rt_b)
            id2 = submit_task("displaced", function (task_info)
                notify(entered2)
                timedwait(() -> cancel_requested(task_info), 10.0; pollint=0.02)
                return "done"
            end, Owner("u"); runtime=rt_b)
            wait(entered2)

            install!(app2, rt_c)
            @test get_task_status(id2, System(); runtime=rt_c)[:status] == "COMPLETED"
            @test recover_zombie_tasks!(; runtime=rt_c) == 0
        finally
            reset_runtime!(rt_b)
            reset_runtime!(rt_c)
        end
    end

    @testset "worker_startup's shutdown hook carries drain_timeout" begin
        # The kwarg has to survive being captured by `startup`'s `on_shutdown` closure; that is
        # the only path a served app ever takes.
        app = Nitro.Core.App()
        rt = WorkerRuntime(InMemoryWorkerStore())
        entered = Base.Event()
        try
            lifecycle = Nitro.Workers.startup(app; runtime=rt, cleanup_enabled=false,
                                              recover_zombies=false, drain_timeout=8.0)
            Nitro.Core.Types.startup(lifecycle)

            id = submit_task("served", function (task_info)
                notify(entered)
                timedwait(() -> cancel_requested(task_info), 10.0; pollint=0.02)
                return "done"
            end, Owner("u"); runtime=rt)
            wait(entered)

            Nitro.Core.Types.shutdown(lifecycle)
            @test get_task_status(id, System(); runtime=rt)[:status] == "COMPLETED"
        finally
            reset_runtime!(rt)
        end
    end

    @testset "drain_timeout is validated, and a quiet runtime tears down silently" begin
        rt = WorkerRuntime(InMemoryWorkerStore())
        try
            @test_throws ArgumentError shutdown!(rt; drain_timeout=-1)
            # Nothing in flight: no wait, no warning. This is the path every `finally` in this
            # file takes, so it has to stay free.
            @test (@test_logs shutdown!(rt)) == true
            @test (@test_logs shutdown!(rt; drain_timeout=0)) == true
        finally
            reset_runtime!(rt)
        end
    end

    @testset "a teardown abandons the queue backlog instead of running it (#182)" begin
        # Closing the channel only stopped SUBMISSIONS. The processor kept `take!`-ing what was
        # already buffered, so a teardown started runs that were never in the drain's snapshot --
        # no token, no wait, a RUNNING record published into a runtime being torn down.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store; queues = ["reports"])
        owner = Owner("u")
        entered = Base.Event()
        backlog_ran = Threads.Atomic{Int}(0)
        try
            # One run in flight, holding the processor until the drain asks it to stop.
            slow_id = submit_sequential_task("reports", "slow", function (task_info)
                notify(entered)
                while !cancel_requested(task_info)
                    sleep(0.01)
                end
                return "stopped on $(cancel_reason(task_info))"
            end, owner; runtime=rt)

            wait(entered)

            # ...and three behind it, which must never execute.
            backlog = [submit_sequential_task("reports", "backlog-$i", function (task_info)
                           Threads.atomic_add!(backlog_ran, 1)
                           return "ran"
                       end, owner; runtime=rt) for i in 1:3]

            @test shutdown!(rt; drain_timeout=8.0) == true

            # The whole point. Not a timing assertion: `draining` is set and the buffer collected
            # under `queue_lock` BEFORE any token is set, so the processor cannot be released back
            # to the channel until there is nothing left in it to take.
            @test backlog_ran[] == 0

            for id in backlog
                status = get_task_status(id, System(); runtime=rt)
                @test status[:status] == "CANCELLED"
                @test status[:error] == "Cancelled by worker shutdown"
            end

            # The in-flight run is unaffected: it returned on the token, so it records its own
            # outcome -- and the string proves the drain, not this test, is what stopped it.
            slow = get_task_status(slow_id, System(); runtime=rt)
            @test slow[:status] == "COMPLETED"
            @test slow[:result] == "stopped on shutdown"
        finally
            reset_runtime!(rt)
        end
    end

    @testset "drain_timeout=0 still abandons the backlog (#182)" begin
        # `drain_timeout=0` means "do not WAIT". Abandoning the backlog costs no wait, so
        # declining the wait is not a request to execute a queue's backlog on the way out. This is
        # the one respect in which 0 is no longer byte-for-byte the pre-#176 behaviour, and the
        # UPGRADING entry says so.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store; queues = ["q0"])
        owner = Owner("u")
        entered = Base.Event()
        release = Base.Event()
        ran = Threads.Atomic{Int}(0)
        try
            submit_sequential_task("q0", "holder", function (task_info)
                notify(entered)
                wait(release)          # deliberately does NOT poll the token: 0 never sets one
                return "held"
            end, owner; runtime=rt)
            wait(entered)

            queued = submit_sequential_task("q0", "queued", function (task_info)
                Threads.atomic_add!(ran, 1)
                return "ran"
            end, owner; runtime=rt)

            @test shutdown!(rt; drain_timeout=0) == false   # it abandoned a live run, honestly
            @test get_task_status(queued, System(); runtime=rt)[:status] == "CANCELLED"
            @test get_task_status(queued, System(); runtime=rt)[:error] ==
                  "Cancelled by worker shutdown"
            @test ran[] == 0
        finally
            notify(release)
            reset_runtime!(rt)
        end
    end

    @testset "abandoning a queued item is run-fenced and idempotent (#182)" begin
        # White-box, and it has to be. `shutdown!` drains the buffer itself, so the processor's
        # `draining` check only ever catches an item it had ALREADY taken when the teardown began
        # -- a window not reachable deterministically from the public API. Both properties of the
        # abandon write are asserted here directly instead of being inferred from a race.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        try
            # A queued item whose key is re-run before the teardown records it. The successor owns
            # the record, so this write must LOSE -- an id-addressed write here would clobber a
            # live successor, the #108/#167 defect through a teardown-wide door.
            predecessor = Nitro.Workers.TaskInfo("u::fenced")
            push!(predecessor.watchers, "u")
            replace_task!(store, predecessor.id, predecessor)
            # Queued FOR the predecessor -- the identity `_register_or_watch!` handed the submit.
            item = Nitro.Workers.QueueItem("u::fenced", predecessor.run_id,
                                           task_info -> "never", TaskOptions())

            # The key moves on while the item is still buffered, and the successor is PENDING:
            # about to be started, possibly on the async path where nothing is abandoning it.
            successor = Nitro.Workers.TaskInfo("u::fenced")
            push!(successor.watchers, "u")
            replace_task!(store, successor.id, successor)

            @test Nitro.Workers._abandon_queued_item!(rt, item) == false
            @test get_task_info(store, "u::fenced").run_id == successor.run_id
            @test get_task_info(store, "u::fenced").status == PENDING

            # It writes once and only once: `shutdown!`'s own sweep and the processor's `draining`
            # branch can both reach one item, so a second call must be a no-op rather than a
            # second terminal write.
            plain = Nitro.Workers.TaskInfo("u::plain")
            push!(plain.watchers, "u")
            replace_task!(store, plain.id, plain)
            plain_item = Nitro.Workers.QueueItem("u::plain", plain.run_id,
                                                 task_info -> "never", TaskOptions())

            @test Nitro.Workers._abandon_queued_item!(rt, plain_item) == true
            @test Nitro.Workers._abandon_queued_item!(rt, plain_item) == false
            @test get_task_info(store, "u::plain").status == CANCELLED
            @test get_task_info(store, "u::plain").error == "Cancelled by worker shutdown"

            # A record that vanished between queueing and teardown is not an error.
            gone = Nitro.Workers.QueueItem("u::gone", Nitro.Workers.uuid4(),
                                           task_info -> "never", TaskOptions())
            @test Nitro.Workers._abandon_queued_item!(rt, gone) == false
        finally
            reset_runtime!(rt)
        end
    end

    @testset "a full queue refuses the next submit, and a parked put! still tears down (#182, #324)" begin
        # The regression the first version of the #182 patch shipped. The collect loop was
        # `while isready(channel)`, and `isready` is `n_avail > 0` -- which counts tasks blocked
        # in `put!` as well as buffered items. On a full `Channel(100)` with one submitter waiting
        # it reports 101 with 100 to take, so the last `take!` threw on the empty closed channel:
        # every collected item was discarded back to PENDING, the registry was never emptied, and
        # the whole #176 drain never ran. A busy queue torn down mid-deploy was exactly that state.
        #
        # Since #324 a SUBMIT can no longer park in `put!`: past the buffer it is refused at once.
        # (This test used to park one through the public API and assert its record ended
        # CANCELLED; that submitter is now unreachable, which is the fix.) The collect loop must
        # still survive a `put!` parked on a full channel, so one is parked here white-box.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store; queues = ["full"])
        owner = Owner("u")
        entered = Base.Event()
        ran = Threads.Atomic{Int}(0)
        try
            # Fill the buffer to its 100-item ceiling, with one run in flight holding the
            # processor so nothing is consumed.
            submit_sequential_task("full", "holder", function (task_info)
                notify(entered)
                while !cancel_requested(task_info)
                    sleep(0.01)
                end
                return "stopped"
            end, owner; runtime=rt)
            wait(entered)

            queued = [submit_sequential_task("full", "buffered-$i", function (task_info)
                          Threads.atomic_add!(ran, 1)
                          return "ran"
                      end, owner; runtime=rt) for i in 1:100]

            # One more PUBLIC submit is refused at once, with nothing written (#324)...
            refused_key = scoped_task_key("refused", owner)
            @test_throws WorkerCapacityError submit_sequential_task("full", "refused",
                                                                    task_info -> "ran", owner; runtime=rt)
            @test get_task_info(store, refused_key) === nothing

            # ...so the parked `put!` that inflates `n_avail` is made by hand.
            queue = Nitro.Workers._get_or_create_queue(rt, "full")
            stray = QueueItem(scoped_task_key("stray", owner), Nitro.Workers.uuid4(),
                              task_info -> "ran", TaskOptions())
            blocked = Threads.@spawn try
                put!(queue.channel, stray)
            catch error
                error                     # InvalidStateException once the channel closes
            end
            @test timedwait(() -> Base.n_avail(queue.channel) > 100, 10.0; pollint=0.02) === :ok

            # Before the fix this THREW instead of returning.
            @test shutdown!(rt; drain_timeout=8.0) == true

            # ...and the teardown was total: registry emptied, nothing executed, every record
            # terminal rather than stranded PENDING.
            @test isempty(Nitro.Workers.get_sequential_queues(rt))
            @test ran[] == 0
            for id in queued
                status = get_task_status(id, System(); runtime=rt)
                @test status[:status] == "CANCELLED"
                @test status[:error] == "Cancelled by worker shutdown"
            end

            # `close` woke the parked `put!` with an exception rather than letting it in.
            @test fetch(blocked) isa InvalidStateException
        finally
            reset_runtime!(rt)
        end
    end

    @testset "the processor abandons an item it had already taken when draining (#182)" begin
        # White-box on purpose. `shutdown!` collects the buffer itself, so the processor's
        # `draining` branch only ever sees an item it had ALREADY taken -- not reachable
        # deterministically through the public API, but trivially reachable here. Without this the
        # branch can be deleted outright and the suite stays green, which is what the reviewer
        # found.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        owner = Owner("u")
        ran = Threads.Atomic{Int}(0)
        try
            # Start a processor, then mark its queue draining WITHOUT closing the channel, so the
            # `take!` still succeeds and the `draining` check is what decides.
            queue = Nitro.Workers._start_queue_processor(rt, "manual")
            @atomic queue.draining = true

            key = scoped_task_key("taken-while-draining", owner)
            record = Nitro.Workers.TaskInfo(key; queue_name="manual")
            push!(record.watchers, owner.user_id)
            replace_task!(store, key, record)

            put!(queue.channel, Nitro.Workers.QueueItem(key, record.run_id, function (task_info)
                Threads.atomic_add!(ran, 1)
                return "ran"
            end, TaskOptions()))

            @test timedwait(() -> get_task_info(store, key).status == CANCELLED,
                            10.0; pollint=0.02) === :ok
            @test get_task_info(store, key).error == "Cancelled by worker shutdown"
            @test ran[] == 0

            # It kept draining rather than stopping: the branch `continue`s. Asserted by feeding
            # it a SECOND item rather than by `!istaskdone`, which only says the task has not
            # finished *yet* -- a `break` regression would be caught by that solely because the
            # poll interval usually beats it, which is a race dressed up as an invariant.
            second = scoped_task_key("second-while-draining", owner)
            second_record = Nitro.Workers.TaskInfo(second; queue_name="manual")
            push!(second_record.watchers, owner.user_id)
            replace_task!(store, second, second_record)
            put!(queue.channel, Nitro.Workers.QueueItem(second, second_record.run_id,
                                                        function (task_info)
                Threads.atomic_add!(ran, 1)
                return "ran"
            end, TaskOptions()))

            @test timedwait(() -> get_task_info(store, second).status == CANCELLED,
                            10.0; pollint=0.02) === :ok
            @test ran[] == 0
        finally
            reset_runtime!(rt)
        end
    end

    @testset "a runtime reused after shutdown! gets a queue that is not draining (#182)" begin
        # The reason `draining` lives on the SequentialQueue and not on the WorkerRuntime: a
        # runtime-level flag would need resetting here, and the reset races a concurrent submit.
        # `shutdown!` empties the registry, so the fresh queue is not draining by construction.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store; queues = ["after"])
        owner = Owner("u")
        try
            @test shutdown!(rt) == true      # no queues at all yet

            done = Base.Event()
            id = submit_sequential_task("after", "runs-normally", function (task_info)
                notify(done)
                return "ok"
            end, owner; runtime=rt)

            @test timedwait(() -> get_task_status(id, System(); runtime=rt)[:status] == "COMPLETED",
                            15.0; pollint=0.05) === :ok
            @test get_task_status(id, System(); runtime=rt)[:result] == "ok"
        finally
            reset_runtime!(rt)
        end
    end

    @testset "a drain landing in the retry backoff ends the run CANCELLED" begin
        # The drain writes no terminal state itself, but it still decides one: the retry backoff
        # polls the SAME token (`api.jl`, `queue.jl`), so a shutdown landing inside one exits the
        # backoff and takes the `_cancel_task!` branch.
        #
        # #176 pinned this recording "Cancelled by user" on the async path and "Cancelled" on the
        # sequential one, deliberately -- the record could not name its cause, and inventing a
        # string was out of that issue's scope. #183 gave the token a reason, so BOTH paths now
        # render "Cancelled by worker shutdown" from `:shutdown` and the asymmetry is gone.
        # Overwriting #176's recorded intent is the point of #183, not a convenience.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        entered = Base.Event()
        attempts = Threads.Atomic{Int}(0)
        try
            id = submit_task("retrying", function (task_info)
                Threads.atomic_add!(attempts, 1)
                attempts[] == 1 && notify(entered)
                error("transient failure")
            end, Owner("u"); options=TaskOptions(retry_on_failure=true, max_retries=2), runtime=rt)

            wait(entered)
            # No further synchronisation, and none is available: `notify` fires inside attempt 1,
            # so anything polling `attempts[] == 1` here is a tautology that would only look like
            # a guarantee. What actually holds the test up is that the outcome is the SAME on
            # either side of the throw -- if the token lands before the exception finishes
            # unwinding, the catch block runs, the record is still RUNNING, it is not a timeout,
            # a retry remains, and the backoff's `while` condition is evaluated before its first
            # `sleep`, so an already-set token falls straight through to the same `_cancel_task!`.
            # The budget is the 2s first backoff, which these adjacent statements cannot outrun.
            @test shutdown!(rt; drain_timeout=3.0) == true

            status = get_task_status(id, System(); runtime=rt)
            @test status[:status] == "CANCELLED"
            @test status[:error] == "Cancelled by worker shutdown"   # NOT "Cancelled by user"
            # And it did NOT run a second attempt: the backoff bailed instead of retrying.
            @test attempts[] == 1
        finally
            reset_runtime!(rt)
        end

        # The sequential path records the SAME string, which is the half #183 fixed. `_cancel_task!`
        # no longer takes a message at all -- it renders from the run's own reason -- so there is no
        # longer a parameter the two paths could pass differently.
        store_q = InMemoryWorkerStore()
        rt_q = WorkerRuntime(store_q; queues = ["retry-q"])
        owner_q = Owner("u")
        entered_q = Base.Event()
        attempts_q = Threads.Atomic{Int}(0)
        try
            qid = submit_sequential_task("retry-q", "retrying", function (task_info)
                Threads.atomic_add!(attempts_q, 1)
                attempts_q[] == 1 && notify(entered_q)
                error("transient failure")
            end, owner_q; options=TaskOptions(retry_on_failure=true, max_retries=2), runtime=rt_q)

            wait(entered_q)
            @test shutdown!(rt_q; drain_timeout=3.0) == true

            status_q = get_task_status(qid, System(); runtime=rt_q)
            @test status_q[:status] == "CANCELLED"
            @test status_q[:error] == "Cancelled by worker shutdown"  # identical to the async path
            @test attempts_q[] == 1
        finally
            reset_runtime!(rt_q)
        end
    end

    @testset "the four cancellation causes are distinguishable (#183)" begin
        # The vocabulary itself, unit-level: `cancel_requested` is exactly "the reason is not
        # :none", so the flag and the cause cannot disagree -- which is the whole argument for one
        # field over two. A second field would need every setter to write reason-before-flag, a
        # convention no test can hold in place.
        t = Nitro.Workers.TaskInfo("u::k")
        @test cancel_reason(t) === :none
        @test cancel_requested(t) == false

        # Pinned exactly, not iterated. The loop below walks `CANCEL_REASONS` itself, so dropping
        # a member would silently shrink what it tests and stay green.
        @test Nitro.Workers.CANCEL_REASONS === (:user, :timeout, :superseded, :shutdown)

        for reason in Nitro.Workers.CANCEL_REASONS
            fresh = Nitro.Workers.TaskInfo("u::k")
            @test Nitro.Workers._request_cancel!(fresh, reason) == true
            @test cancel_reason(fresh) === reason
            @test cancel_requested(fresh) == true
        end

        # FIRST cause wins, and the setter reports whether it was the one that won. A person who
        # cancels a job seconds before a deploy must still read as `:user`: the drain fires on
        # every in-flight run at once, so last-write-wins would make a shutdown the most likely
        # writer to land last and would rewrite that attribution wholesale.
        first_wins = Nitro.Workers.TaskInfo("u::k")
        @test Nitro.Workers._request_cancel!(first_wins, :user) == true
        @test Nitro.Workers._request_cancel!(first_wins, :shutdown) == false
        @test cancel_reason(first_wins) === :user

        # One renderer, and `:none` still yields a sentence rather than an error: the durable-read
        # branches of the retry loop cancel on a record another process wrote, so nothing set a
        # local token. Those writes always lose their CAS, so the text is never stored -- but it
        # must not be a crash on the way to losing.
        @test Nitro.Workers._cancel_message(:user) == "Cancelled by user"
        @test Nitro.Workers._cancel_message(:timeout) == "Cancelled by timeout"
        @test Nitro.Workers._cancel_message(:superseded) == "Cancelled by a re-run of this task key"
        @test Nitro.Workers._cancel_message(:shutdown) == "Cancelled by worker shutdown"
        @test Nitro.Workers._cancel_message(:none) == "Cancelled"
    end

    @testset "a user's cancel is the ONLY thing that records \"Cancelled by user\" (#183)" begin
        # The inversion #183 exists to fix, pinned from the correct side. Before it, a genuine
        # `cancel_task` stored "Cancelled" -- its own CAS claims the record first, so the run's
        # `_cancel_task!` lost and its "Cancelled by user" was never written. The only cause that
        # writes nothing of its own is a drain, so "Cancelled by user" reached a record ONLY when
        # no user had cancelled anything. It is now exactly the other way round.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        owner = Owner("u")
        entered = Base.Event()
        # Captured rather than returned: the callback's value is discarded here, because
        # `cancel_task` already claimed CANCELLED and `_complete_task!`'s CAS loses.
        seen = Ref{Symbol}(:unset)
        try
            id = submit_task("cancellable", function (task_info)
                notify(entered)
                while !cancel_requested(task_info)
                    sleep(0.01)
                end
                seen[] = cancel_reason(task_info)
                return "stopped"
            end, owner; runtime=rt)

            wait(entered)
            @test cancel_task(id, owner; runtime=rt)[:status] == "Task cancelled"

            status = get_task_status(id, System(); runtime=rt)
            @test status[:status] == "CANCELLED"
            @test status[:error] == "Cancelled by user"

            # The callback saw :user too, so the token and the record agree about provenance.
            @test timedwait(() -> seen[] !== :unset, 10.0; pollint=0.02) === :ok
            @test seen[] === :user
        finally
            reset_runtime!(rt)
        end
    end

    @testset "a superseding re-run marks its predecessor :superseded (#183)" begin
        # `_register_or_watch!` sets the token on the run it is displacing. That run's own terminal
        # write then fails the `run_id` fence (#108), so the reason never reaches a record -- it
        # exists so the displaced CALLBACK can tell "I was replaced" from "a person cancelled me".
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        owner = Owner("u")
        try
            predecessor = Nitro.Workers.TaskInfo("u::job")
            push!(predecessor.watchers, "u")
            predecessor.status = COMPLETED          # finished record, still-live run
            replace_task!(store, predecessor.id, predecessor)
            Nitro.Workers.register_active_task_info!(rt, predecessor.id, predecessor)

            # Re-running the finished key replaces the record and asks the predecessor to stop.
            submit_task("job", task_info -> "second run", owner; runtime=rt)

            @test cancel_requested(predecessor) == true
            @test cancel_reason(predecessor) === :superseded
        finally
            reset_runtime!(rt)
        end
    end

    @testset "a timeout marks the run :timeout and still records FAILED (#183)" begin
        # A deadline is the one cause that must NOT start rendering a cancel message: it throws
        # `TaskTimeoutError`, which is terminal FAILED on the first attempt because nothing can
        # stop the attempt that timed out (#127). The reason exists for the callback's benefit --
        # `cancel_requested` on a FAILED task has always meant "the deadline fired", and this is
        # what says so outright instead of leaving it to be inferred from the status.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        seen = Ref{Symbol}(:unset)
        try
            id = submit_task("slow", function (task_info)
                while !cancel_requested(task_info)
                    sleep(0.02)
                end
                seen[] = cancel_reason(task_info)
                return "noticed"
            end, Owner("u"); options=TaskOptions(timeout=1), runtime=rt)

            @test timedwait(() -> get_task_status(id, System(); runtime=rt)[:status] == "FAILED",
                            15.0; pollint=0.05) === :ok
            status = get_task_status(id, System(); runtime=rt)
            @test status[:error] == "Timeout of 1s exceeded"
            @test !occursin("Cancelled", something(status[:error], ""))

            @test timedwait(() -> seen[] !== :unset, 10.0; pollint=0.05) === :ok
            @test seen[] === :timeout
        finally
            reset_runtime!(rt)
        end
    end

    @testset "the run marker is restored, so a long-lived task carries no stale one" begin
        # `_invoke_task_callback` marks the executing task with its run id and restores the
        # previous value on the way out. With `TaskOptions(timeout=0)` the callback runs directly
        # on the long-lived sequential queue PROCESSOR, so without the restore that processor
        # keeps a finished run's id between items -- and an entry wrongly skipped from a drain's
        # snapshot is never token-set, never waited for, and has its handle released, which is
        # #176 itself arriving silently.
        #
        # Asserted against the processor task's own storage, because that is the task that
        # outlives a run. Reading `task_local_storage()` from inside a callback would prove
        # nothing: the marker for the *current* run is written before the callback is invoked, so
        # it reads the same with or without the restore.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store; queues = ["marker-q"])
        owner = Owner("u")
        marker_during = Ref{Any}(:unset)
        try
            id = submit_sequential_task("marker-q", "one", function (task_info)
                marker_during[] = Base.get(task_local_storage(),
                                           Nitro.Workers.CURRENT_RUN_KEY, :absent)
                return "one"
            end, owner; options=TaskOptions(timeout=0), runtime=rt)
            @test wait_for(() -> get_task_status(id, owner; runtime=rt)[:status] ==
                                 "COMPLETED") == :ok

            # Set while the callback ran...
            @test marker_during[] isa Base.UUID

            # ...and gone once it returned. `processor_task` is the task the callback ran on,
            # since `timeout=0` bypasses `timeout_call`'s child.
            processor = get_sequential_queues(rt)["marker-q"].processor_task
            @test processor !== nothing
            storage = processor.storage
            @test storage === nothing || !haskey(storage, Nitro.Workers.CURRENT_RUN_KEY)
        finally
            reset_runtime!(rt)
        end
    end
    @testset "a run that ends without a terminal write still releases its handle" begin
        # `TaskOptions` does not validate `max_retries`, so `retry_on_failure=true` with a
        # negative count is reachable: `for retry_count in 0:-1` never runs, and the execute
        # path returns having written no terminal state at all. Before #176 wrapped that path in
        # `try`/`finally`, the registration leaked -- and `shutdown!`'s unconditional
        # `empty!(active_tasks)` swept the orphan up by accident. Now that a teardown KEEPS live
        # handles, such an orphan could never settle: every later teardown on this runtime would
        # burn its whole window and then warn about a run that ended long ago.
        store = InMemoryWorkerStore()
        rt = WorkerRuntime(store)
        try
            submit_task("no-terminal-write", () -> "never reached", Owner("u");
                        options=TaskOptions(retry_on_failure=true, max_retries=-1), runtime=rt)

            @test wait_for(() -> isempty(rt.active_tasks)) == :ok
            @test isempty(rt.active_task_infos)

            started = time()
            @test (@test_logs shutdown!(rt)) == true
            @test time() - started < 2.0
        finally
            reset_runtime!(rt)
        end
    end
end


@testset "a store that implements no lifecycle method at all still works (#167)" begin
    # The inversion of #29/#166. That pair made `shutdown!` a REQUIRED store method, so a
    # backend owning nothing had to write `shutdown!(::MyStore) = nothing` out loud -- which
    # closed the instance and left the class open: every future backend still had to get
    # teardown right. `DataOnlyStore` below implements the 16 data-and-policy rows and NOTHING
    # else, and it cannot exist on the pre-#167 contract.
    @test isempty(missing_store_methods(DataOnlyStore))
    @test !hasmethod(shutdown!, Tuple{DataOnlyStore})
    # `hasmethod` would say `true` here: the point is that the only method it finds is the
    # abstract no-op, i.e. this store contributed none of its own.
    @test !Nitro.Core.Errors.implements_contract_method(clear_records!, DataOnlyStore, AbstractWorkerStore, 1)

    rt = WorkerRuntime(DataOnlyStore(); queues = ["dataonly-q"])
    owner = Owner("user-dataonly")

    try
        # A sequential queue (a `Channel` plus a spawned processor) and a cleanup scheduler --
        # the exact resources #29 leaked -- over a store that knows about none of them.
        task_id = submit_sequential_task("dataonly-q", "one", () -> "done", owner; runtime=rt)
        @test wait_for(() -> get_task_status(task_id, owner; runtime=rt)[:status] == "COMPLETED") == :ok

        scheduler = start_cleanup_scheduler(; interval_hours=1, retain_days=7, runtime=rt)
        channel = get_sequential_queues(rt)["dataonly-q"].channel

        # Does not raise, and actually releases: teardown is the runtime's, not the backend's.
        shutdown!(rt)

        @test istaskdone(scheduler.task)
        @test !isopen(channel)
        @test isempty(get_sequential_queues(rt))
        @test get_cleanup_scheduler(rt)[] === nothing
    finally
        reset_runtime!(rt)
    end

    # `clear_records!` defaults to a no-op in the SAFE direction: for a durable backend the
    # registry is rows that outlive the process, so a reset must not delete them.
    keeper = DataOnlyStore()
    keeper.rows["kept"] = TaskInfo("kept")
    reset_runtime!(WorkerRuntime(keeper))
    @test haskey(keeper.rows, "kept")
end

@testset "publishing a successor evicts the run it displaced from the live caches (#167)" begin
    # The live caches are keyed by task id but each entry describes one RUN, and `replace_task!`
    # is the moment a run stops owning its key. Leaving the predecessor behind opens a window
    # between that write and the successor's `register_run!` in which every reader
    # sees a run that no longer owns the record -- usually a terminal one. `cancel_task` then
    # refuses to cancel a live successor, `get_task_status` reports it finished, and a concurrent
    # submit replaces the record again instead of deduplicating onto it.
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    owner = Owner("user-displaced")
    key = scoped_task_key("displaced", owner)

    try
        predecessor = TaskInfo(key)
        predecessor.status = CANCELLED
        push!(predecessor.watchers, owner.user_id)
        replace_task!(store, key, predecessor)
        handle = @async nothing
        Nitro.Workers.register_active_task_info!(rt_store, key, predecessor)
        Nitro.Workers.register_active_task!(rt_store, key, handle)

        successor = TaskInfo(key)
        successor.status = PENDING
        push!(successor.watchers, owner.user_id)
        @test successor.run_id != predecessor.run_id

        # Through the RUNTIME -- the path `_register_or_watch!` takes.
        replace_task!(rt_store, key, successor)

        # Both caches, together: `_deregister_run!` assumes they agree about which run owns the
        # key, so a half-eviction would strand the handle until the successor finished.
        @test get_active_task_info(rt_store, key) === nothing
        @test get_active_task(rt_store, key) === nothing

        # Every reader now sees the run that actually owns the record.
        @test get_task_info(rt_store, key).run_id == successor.run_id
        @test get_task_status(key, owner; runtime=rt_store)[:status] == "PENDING"
        @test cancel_task(key, owner; runtime=rt_store)[:status] == "Task cancelled"
        @test get_task_info(store, key).status == CANCELLED

        wait(handle)
    finally
        reset_runtime!(rt_store)
    end
end

@testset "a re-submit deduplicates onto a pending successor rather than replacing it (#167)" begin
    # The claiming half of the same rule: `_register_or_watch!` reads the STORE, because it
    # decides whether to build a new run, and it consults only `status` and `watchers` -- which
    # the row carries authoritatively. `false` means "watch the run that already exists", which
    # is the whole point of deduplicating on a task key.
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    owner = Owner("user-window")
    key = scoped_task_key("windowed", owner)

    try
        # Deliberately registered and deliberately NOT evicted: this is the stale state the rule
        # is about, and without it the live and durable reads return the same object and the
        # assertion below cannot tell the two apart.
        predecessor = TaskInfo(key)
        predecessor.status = CANCELLED
        push!(predecessor.watchers, owner.user_id)
        Nitro.Workers.register_active_task_info!(rt_store, key, predecessor)

        successor = TaskInfo(key)
        successor.status = PENDING
        push!(successor.watchers, owner.user_id)
        replace_task!(store, key, successor)

        # `nothing` is "joined, do not start" -- this returned `false` until #182 gave it the new
        # run's `run_id` to hand the queue. The meaning under test is unchanged: the successor is
        # PENDING, so this joins it rather than minting a third run.
        @test Nitro.Workers._register_or_watch!(rt_store, key, owner) === nothing
        @test get_task_info(store, key).run_id == successor.run_id
    finally
        reset_runtime!(rt_store)
    end
end

@testset "a late predecessor cannot evict a live successor's run handle (#167)" begin
    # `_deregister_run!` fences on `run_id` read off the live `TaskInfo`, and probes and deletes
    # in ONE critical section. This covers that fence: a predecessor finishing after a successor
    # has published must not drop the successor's handle, because `recover_zombie_tasks!` reads
    # exactly that as death -- marking a genuinely running task FAILED, the #108 defect the fence
    # exists to prevent.
    #
    # It does NOT cover the other half of that fix, and cannot: publishing the handle and the info
    # as two writes rather than one left a window in which the handle was visible and the fence's
    # oracle was not, and that window is not observable from outside the runtime. `register_run!`
    # closes it structurally instead -- it is the single publish path, so the state simply cannot
    # be built. Reviewing that is reading the call sites, not running this.
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    owner = Owner("user-fence")
    key = scoped_task_key("fenced", owner)
    handles = Task[]

    try
        predecessor = TaskInfo(key)
        predecessor.status = RUNNING
        push!(predecessor.watchers, owner.user_id)
        replace_task!(store, key, predecessor)
        p_handle = @async nothing
        push!(handles, p_handle)
        Nitro.Workers.register_active_task_info!(rt_store, key, predecessor)
        Nitro.Workers.register_active_task!(rt_store, key, p_handle)

        successor = TaskInfo(key)
        successor.status = PENDING
        push!(successor.watchers, owner.user_id)
        replace_task!(rt_store, key, successor)

        # The successor starts. ONE atomic publish, which is what the execute paths do -- a
        # handle can never be visible without the info the fence reads its `run_id` from.
        s_handle = @async nothing
        push!(handles, s_handle)
        register_run!(rt_store, key, successor, s_handle)

        # ...and only now does the predecessor finish.
        Nitro.Workers._deregister_run!(rt_store, predecessor)

        @test get_active_task(rt_store, key) === s_handle
        @test get_active_task_info(rt_store, key) === successor


        # The proof that it matters: the sweep must not claim a live run.
        successor.status = RUNNING
        set_task!(store, key, successor)
        @test recover_zombie_tasks!(; runtime=rt_store) == 0
        @test get_task_info(store, key).status == RUNNING
    finally
        foreach(wait, handles)
        reset_runtime!(rt_store)
    end
end

@testset "displacing a runtime tears the old one down (#167)" begin
    # The extension slot IS the ownership handle, so a runtime the app no longer points at is
    # unreachable -- and `uninstall!` only ever sees the occupant. Leaving it running would be
    # the #29 leak with one more level of indirection, which is the leak this whole issue closes.
    app = Nitro.Core.App()
    store = InMemoryWorkerStore()

    try
        first_runtime = start!(app; queues=["displaced-q"], store=store, recover_zombies=false)
        scheduler = get_cleanup_scheduler(first_runtime)[]
        channel = get_sequential_queues(first_runtime)["displaced-q"].channel

        # Same backend: `start!` must be idempotent rather than mint a second runtime over it.
        @test start!(app; queues=["displaced-q"], store=store, recover_zombies=false) === first_runtime
        @test !istaskdone(scheduler.task)
        @test isopen(channel)

        # A genuinely different runtime displaces it -- and takes it down on the way.
        second_runtime = WorkerRuntime(store)
        @test install!(app, second_runtime) === second_runtime
        @test worker_runtime(app) === second_runtime
        @test istaskdone(scheduler.task)
        @test !isopen(channel)
        @test isempty(get_sequential_queues(first_runtime))
    finally
        uninstall!(app)
    end
end

@testset "one store can back several runtimes (#167)" begin
    # Inexpressible before the split: the queues and the scheduler were fields ON the store, so
    # two apps sharing a backend shared one set of processors and either one's `uninstall!` shut
    # the other's down. This is the sharpest single proof that ownership moved -- and it is the
    # shape Sidekiq and River have, where several `Launcher`s/`Client`s can sit over one datastore.
    store = InMemoryWorkerStore()
    rt_a = WorkerRuntime(store; queues = ["shared-q"])
    rt_b = WorkerRuntime(store; queues = ["shared-q"])
    owner = Owner("user-shared")

    try
        a_id = submit_sequential_task("shared-q", "from-a", () -> "a", owner; runtime=rt_a)
        b_id = submit_sequential_task("shared-q", "from-b", () -> "b", owner; runtime=rt_b)
        @test wait_for(() -> get_task_status(a_id, owner; runtime=rt_a)[:status] == "COMPLETED") == :ok
        @test wait_for(() -> get_task_status(b_id, owner; runtime=rt_b)[:status] == "COMPLETED") == :ok

        # Same queue NAME, two independent queues -- the resources are per runtime.
        @test get_sequential_queues(rt_a)["shared-q"] !== get_sequential_queues(rt_b)["shared-q"]

        # ...but one set of records, because the store is shared.
        @test get_task_status(a_id, owner; runtime=rt_b)[:result] == "a"

        b_channel = get_sequential_queues(rt_b)["shared-q"].channel
        shutdown!(rt_a)

        # Tearing one down leaves the other running, which is the whole point.
        @test isempty(get_sequential_queues(rt_a))
        @test isopen(b_channel)
        again = submit_sequential_task("shared-q", "still-b", () -> "b2", owner; runtime=rt_b)
        @test wait_for(() -> get_task_status(again, owner; runtime=rt_b)[:status] == "COMPLETED") == :ok
        @test get_sequential_queues(rt_b)["shared-q"].channel === b_channel
    finally
        reset_runtime!(rt_a)
        reset_runtime!(rt_b)
    end
end

@testset "the default runtime stays concretely typed (#167)" begin
    # `DEFAULT_RUNTIME` is `Ref(WorkerRuntime(...))`, NOT `Ref{WorkerRuntime}(...)`, so this
    # infers a concrete type and the store calls behind it devirtualize. Widening the Ref would
    # make every default-argument `submit_task` a dynamic dispatch on the request path, which is
    # the nitro-core §7 hard stop -- and it would do so silently.
    @test only(Base.return_types(default_runtime, ())) === WorkerRuntime{InMemoryWorkerStore}
    @test isconcretetype(typeof(default_runtime()))
    @test only(Base.return_types(worker_store, (WorkerRuntime{InMemoryWorkerStore},))) === InMemoryWorkerStore
end

@testset "Stored task error text is bounded and redactable (#140)" begin
    # The sentinel is chosen so the POSITIVE assertion below can actually fail: it has to be
    # something an ordinary exception really does echo. `ArgumentError` interpolates whatever it
    # is handed, so it does. The positive assertion comes first on purpose -- without it, every
    # negative assertion here would pass just as happily against a sentinel that never reached
    # the message in the first place, and the guard would be theater.
    sentinel = "tok-91fe3c"

    @testset "the cap holds, and does not fire on ordinary messages" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("user-cap")
        try
            long_tail = repeat("x", MAX_STORED_ERROR_CHARS * 2)
            id = submit_task("capped", () -> throw(ArgumentError(long_tail)), owner; runtime=rt_store)
            @test wait_for(() -> get_task_status(id, owner; runtime=rt_store)[:status] == "FAILED") == :ok

            stored = get_task_status(id, owner; runtime=rt_store)[:error]
            # Exactly the cap, not the cap plus slack: the truncation marker counts against
            # MAX_STORED_ERROR_CHARS rather than being appended past it, so the knowable bound is
            # the one to assert. A `<= MAX + 64` bound passes even when the constant is not the cap.
            @test length(stored) <= MAX_STORED_ERROR_CHARS
            @test occursin("truncated", stored)
            # Truncation is by character, so what lands is still valid UTF-8 and still says what
            # kind of failure it was.
            @test isvalid(stored)
            @test occursin("ArgumentError", stored)

            short_id = submit_task("uncapped", () -> throw(ArgumentError("plain failure")), owner; runtime=rt_store)
            @test wait_for(() -> get_task_status(short_id, owner; runtime=rt_store)[:status] == "FAILED") == :ok
            short_stored = get_task_status(short_id, owner; runtime=rt_store)[:error]
            @test occursin("plain failure", short_stored)
            @test !occursin("truncated", short_stored)
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a redactor sees the full text and keeps it out of the store" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("user-redact")
        seen = Ref("")
        try
            # The hook is handed the FULL rendering, before truncation, so it can decide about the
            # whole message rather than a prefix.
            set_error_redactor!(store, function(exc, rendered)
                seen[] = rendered
                return string(nameof(typeof(exc)), " (details withheld)")
            end)
            @test get_error_redactor(store) !== nothing

            id = submit_task("redacted", () -> throw(ArgumentError("bad token: $(sentinel)")), owner; runtime=rt_store)
            @test wait_for(() -> get_task_status(id, owner; runtime=rt_store)[:status] == "FAILED") == :ok

            # POSITIVE: the sentinel really is in the raw exception, so the negative below means
            # something.
            @test occursin(sentinel, seen[])
            @test occursin(sentinel, format_error(ArgumentError("bad token: $(sentinel)")))

            # NEGATIVE: and it does not survive into the stored value.
            stored = get_task_status(id, owner; runtime=rt_store)[:error]
            @test !occursin(sentinel, stored)
            @test stored == "ArgumentError (details withheld)"
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a redactor that throws loses the detail, not the failure -- and does not log it" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("user-throwing")
        try
            # The redactor INTERPOLATES what it was handed into its own exception. That is not a
            # contrived shape -- it is what any redactor that parses or validates the text does,
            # because Julia's parsers quote their input. A test whose redactor throws
            # `error("broken")` quotes nothing and so cannot see the leak this guards.
            set_error_redactor!(store, (exc, rendered) -> error("refusing to handle: $(rendered)"))

            logged, id = Test.collect_test_logs() do
                inner = submit_task("boom", () -> throw(ArgumentError("bad token: $(sentinel)")), owner; runtime=rt_store)
                @test wait_for(() -> get_task_status(inner, owner; runtime=rt_store)[:status] == "FAILED") == :ok
                inner
            end

            # The task still reports FAILED, and the stored text degrades to the exception type --
            # never back to the unredacted rendering, which is the content the app just told us it
            # did not want stored.
            stored = get_task_status(id, owner; runtime=rt_store)[:error]
            @test stored == "ArgumentError"
            @test !occursin(sentinel, stored)

            # POSITIVE: the redactor's own exception really does carry the sentinel, so the
            # negative assertion below is not passing because there was nothing to leak.
            leaky = try
                error("refusing to handle: $(format_error(ArgumentError("bad token: $(sentinel)")))")
            catch e
                e
            end
            @test occursin(sentinel, sprint(showerror, leaky))

            # NEGATIVE: and none of it reaches the log. Logging `exception=` here would republish,
            # on the error channel, exactly the content the redactor exists to suppress.
            rendered_logs = join((string(r.message, " ", r.kwargs) for r in logged), "
")
            @test !occursin(sentinel, rendered_logs)
            @test any(r -> occursin("redactor threw", string(r.message)), logged)
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a redactor that returns a non-string degrades instead of poisoning the field" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("user-nonstring")
        try
            # A Julia function falls off its end into its last expression, so returning `nothing`
            # is an easy mistake. Stringifying it would store the literal "nothing".
            set_error_redactor!(store, (exc, rendered) -> nothing)

            id = submit_task("nonstring", () -> throw(ArgumentError("bad token: $(sentinel)")), owner; runtime=rt_store)
            @test wait_for(() -> get_task_status(id, owner; runtime=rt_store)[:status] == "FAILED") == :ok

            stored = get_task_status(id, owner; runtime=rt_store)[:error]
            @test stored == "ArgumentError"
            @test stored != "nothing"
            @test !occursin(sentinel, stored)
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "no redactor is still the default, and format_error stays unbounded" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        @test get_error_redactor(store) === nothing

        # `format_error` is exported and is the plain rendering utility; #140 bounds what is
        # STORED, not what this returns. Capping it here would silently change every caller.
        long_tail = repeat("y", MAX_STORED_ERROR_CHARS * 2)
        @test length(format_error(ArgumentError(long_tail))) > MAX_STORED_ERROR_CHARS
    end
end

@testset "Immediate task execution and deduplication" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    calls = Ref(0)
    gate = Base.Event()

    try
        task_id = submit_task("immediate-task", () -> begin
            calls[] += 1
            wait(gate)
            return "done"
        end, Owner("user-a"); runtime=rt_store)

        # Same user, same key, still running: deduplicates onto the live task.
        duplicate_id = submit_task("immediate-task", () -> begin
            calls[] += 100
            return "duplicate"
        end, Owner("user-a"); runtime=rt_store)

        @test task_id == "user-a::immediate-task"
        @test duplicate_id == task_id

        notify(gate)
        @test wait_for(() -> get_task_status(task_id, Owner("user-a"); runtime=rt_store)[:status] == "COMPLETED") == :ok

        status = get_task_status(task_id, Owner("user-a"); runtime=rt_store)
        @test status[:result] == "done"
        @test status[:watcher_count] == 1
        @test calls[] == 1
    finally
        notify(gate)
        reset_runtime!(rt_store)
    end
end

@testset "Sequential callbacks defined after the processor spawned still run (#86)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store; queues = ["wq86"])
    auth = Owner("user-a")

    try
        # Defined BEFORE the processor spawns, so it is inside the processor's frozen world.
        @eval mixed_cb() = "zero-arg (old)"

        # The FIRST sequential submit spawns the queue processor, freezing its world age.
        first_id = submit_sequential_task("wq86", "first", () -> "first", auth; runtime=rt_store)
        @test wait_for(() -> get_task_status(first_id, auth; runtime=rt_store)[:status] == "COMPLETED") == :ok

        # `@eval` is the whole point of this test: it defines methods at a world age LATER than
        # the processor's. A closure literal written here would not -- it is compiled with the
        # rest of this block, so it predates the processor and cannot reproduce #86. That is
        # exactly why "Sequential queues preserve order" (one shared closure in a loop) missed it.
        @eval late_one_arg(task_info) = "late one-arg"
        @eval late_zero_arg() = "late zero-arg"

        second_id = submit_sequential_task("wq86", "second", late_one_arg, auth; runtime=rt_store)
        @test wait_for(() -> get_task_status(second_id, auth; runtime=rt_store)[:status] == "COMPLETED") == :ok
        @test get_task_status(second_id, auth; runtime=rt_store)[:result] == "late one-arg"

        third_id = submit_sequential_task("wq86", "third", late_zero_arg, auth; runtime=rt_store)
        @test wait_for(() -> get_task_status(third_id, auth; runtime=rt_store)[:status] == "COMPLETED") == :ok
        @test get_task_status(third_id, auth; runtime=rt_store)[:result] == "late zero-arg"

        # The sharper half of #86: not just "throws for a method that exists", but SILENTLY
        # CALLS THE WRONG ARITY. `mixed_cb` has a zero-arg method from before the processor
        # spawned; the one-arg method arrives after. A world-age-frozen `applicable` cannot see
        # the newer method, falls through to the zero-arg branch, and runs the callback WITHOUT
        # its task_info -- no error, wrong behaviour. This is what Revise adding a parameter to
        # a live callback looks like.
        @eval mixed_cb(task_info) = "one-arg (new)"
        fourth_id = submit_sequential_task("wq86", "fourth", mixed_cb, auth; runtime=rt_store)
        @test wait_for(() -> get_task_status(fourth_id, auth; runtime=rt_store)[:status] == "COMPLETED") == :ok
        @test get_task_status(fourth_id, auth; runtime=rt_store)[:result] == "one-arg (new)"
    finally
        reset_runtime!(rt_store)
    end
end

@testset "Sequential queues preserve order" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store; queues = ["reports"])
    observed = String[]

    try
        ids = String[]
        for index in 1:3
            push!(ids, submit_sequential_task("reports", "queued-$(index)", task_info -> begin
                push!(observed, task_info.id)
                sleep(0.05)
                return task_info.id
            end, Owner("user"); runtime=rt_store))
        end

        @test ids == ["user::queued-1", "user::queued-2", "user::queued-3"]
        @test wait_for(() -> all(get_task_status(id, Owner("user"); runtime=rt_store)[:status] == "COMPLETED" for id in ids)) == :ok
        @test observed == ids

        queue_status = get_queue_status("reports", System(); runtime=rt_store)
        @test queue_status[:running] == true
        @test queue_status[:current_task] === nothing
        @test queue_status[:total_load] == 0
    finally
        reset_runtime!(rt_store)
    end
end

@testset "Retry, cancellation, and cleanup" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    attempts = Ref(0)
    started = Base.Event()

    try
        retry_id = submit_task("retry-task", () -> begin
            attempts[] += 1
            if attempts[] < 3
                error("retry me")
            end
            return "ok"
        end, Owner("user"); options=TaskOptions(retry_on_failure=true, max_retries=2), runtime=rt_store)

        @test wait_for(() -> get_task_status(retry_id, Owner("user"); runtime=rt_store)[:status] == "COMPLETED"; timeout=10.0) == :ok
        @test attempts[] == 3

        # Cooperative, because cancellation IS cooperative now (#127). Nitro no longer
        # interrupts the task, so a `while true` callback would outlive the testset and spin
        # for the rest of the process.
        cancel_id = submit_task("cancel-task", task_info -> begin
            notify(started)
            while !cancel_requested(task_info)
                sleep(0.01)
            end
            return task_info.id
        end, Owner("user"); runtime=rt_store)

        wait(started)
        cancel_result = cancel_task(cancel_id, Owner("user"); runtime=rt_store)
        @test cancel_result[:status] == "Task cancelled"
        @test wait_for(() -> get_task_status(cancel_id, Owner("user"); runtime=rt_store)[:status] == "CANCELLED") == :ok

        lock(store.task_lock) do
            expired = TaskInfo("expired-task")
            expired.status = COMPLETED
            expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
            store.task_registry[expired.id] = expired
        end

        @test cleanup_old_tasks(7; runtime=rt_store) == 1
        @test get_task_status("expired-task", System(); runtime=rt_store)[:status] == "NOT_FOUND"
    finally
        reset_runtime!(rt_store)
    end
end

@testset "Cleanup scheduler and per-context stores" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    ctx_one = Nitro.Core.App()
    ctx_two = Nitro.Core.App()

    try
        install!(ctx_one; store=store)
        other_runtime = install!(ctx_two)

        @test worker_store(ctx_one) === store
        @test worker_store(ctx_two) === other_runtime.store

        lock(store.task_lock) do
            expired = TaskInfo("scheduled-expired")
            expired.status = COMPLETED
            expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
            store.task_registry[expired.id] = expired
        end

        scheduler = start_cleanup_scheduler(; interval_hours=0.00005, retain_days=7, runtime=rt_store)
        @test wait_for(() -> get_task_status("scheduled-expired", System(); runtime=rt_store)[:status] == "NOT_FOUND") == :ok
        stop_cleanup_scheduler!(scheduler)

        ctx_task_id = submit_task(ctx_one, "ctx-task", () -> "ctx-one", Owner("user"))
        @test ctx_task_id == "user::ctx-task"
        @test wait_for(() -> get_task_status(ctx_one, ctx_task_id, Owner("user"))[:status] == "COMPLETED") == :ok
        @test get_task_status(ctx_one, ctx_task_id, Owner("user"))[:result] == "ctx-one"
        @test get_task_status(ctx_two, ctx_task_id, Owner("user"))[:status] == "NOT_FOUND"
    finally
        uninstall!(ctx_one)
        uninstall!(ctx_two)
        reset_runtime!(rt_store)
    end
end

@testset "a throwing retention sweep costs one tick, not the scheduler (#195)" begin
    # #195, the fourth instance of #169. The sweep was a bare `@async` loop with no `try` around
    # the tick and no `errormonitor`, so ANY throw from `cleanup_tasks!` -- on a
    # `PormGWorkerStore`, a transient DB error -- ended the loop, mute, for the life of the
    # process, while the task table it exists to bound kept growing.
    #
    # A store whose `cleanup_tasks!` throws on its first `failures_left` sweeps and then forwards
    # to the `InMemoryWorkerStore` it wraps. Mirrors `FlakyStore` (test/session_tests.jl) and
    # `FlakyBucketStore` (test/middleware/lifecycle_middleware_tests.jl), which guard the same
    # property for the middleware janitors. The scheduler calls `cleanup_tasks!` and nothing
    # else; `lock_tasks` and `get_task_info` are forwarded defensively, so the wrapper stays a
    # valid store if the `finally` teardown below ever reaches one of them.
    mutable struct FlakyCleanupStore <: AbstractWorkerStore
        inner         :: InMemoryWorkerStore
        failures_left :: Int
        sweeps        :: Int
    end
    function Nitro.Workers.cleanup_tasks!(s::FlakyCleanupStore, retain_days::Int)
        s.sweeps += 1
        if s.failures_left > 0
            s.failures_left -= 1
            error("simulated sweep failure")
        end
        return Nitro.Workers.cleanup_tasks!(s.inner, retain_days)
    end
    Nitro.Workers.lock_tasks(f::Function, s::FlakyCleanupStore) = Nitro.Workers.lock_tasks(f, s.inner)
    Nitro.Workers.get_task_info(s::FlakyCleanupStore, id::String) = Nitro.Workers.get_task_info(s.inner, id)

    inner = InMemoryWorkerStore()
    lock(inner.task_lock) do
        expired = TaskInfo("flaky-expired")
        expired.status = COMPLETED
        expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
        inner.task_registry[expired.id] = expired
    end
    store = FlakyCleanupStore(inner, 3, 0)
    rt = WorkerRuntime(store)

    try
        # Started INSIDE `@test_logs`, so the spawned task inherits the capturing logger: a
        # failing tick must be LOGGED, not swallowed -- silence was #169's other half.
        scheduler = @test_logs (:error, r"task retention sweep failed") match_mode=:any begin
            scheduler = start_cleanup_scheduler(; interval_hours=0.00005, retain_days=7, runtime=rt)
            # Against the unpatched loop the first throw ends the task: `sweeps` stays at 1, the
            # expired row is never reaped, and both of these time out.
            @test wait_for(() -> store.sweeps > 3) == :ok
            @test wait_for(() -> Nitro.Workers.get_task_info(inner, "flaky-expired") === nothing) == :ok
            scheduler
        end
        @test store.sweeps > 3
        @test !istaskdone(scheduler.task)     # survived every failing tick and is still sweeping
        @test Nitro.Workers.get_task_info(inner, "flaky-expired") === nothing

        # A scheduler that survived its failures stops cleanly, exactly as a healthy one does.
        @test stop_cleanup_scheduler!(scheduler) === nothing
        @test istaskdone(scheduler.task)
        @test !istaskfailed(scheduler.task)
    finally
        reset_runtime!(rt)
    end
end

@testset "shutdown! drains even when the retention scheduler already died (#193)" begin
    # #193. `stop_cleanup_scheduler!` closes the signal and then `wait`s on the task, and `wait`
    # on a task that failed rethrows `TaskFailedException`. `shutdown!` called it unguarded, as
    # its FIRST step, so a scheduler that died at 03:00 made the 17:00 teardown throw before the
    # queue close, the #182 backlog abandon and the #176 drain -- in-flight runs neither drained
    # nor recorded, `scheduler_ref[]` left populated -- hours after, and causally
    # unrelated-looking to, the fault that actually killed the sweep.
    #
    # Since #195 the loop cannot die from a sweep failure, so the dead task is CONSTRUCTED here
    # rather than provoked: a `CleanupScheduler` over a task that has already failed is exactly
    # the state the unpatched code met, whatever produced it.
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store; queues = ["dead-sweep-q"])

    try
        owner = Owner("user-dead-sweep")
        task_id = submit_sequential_task("dead-sweep-q", "one", () -> "done", owner; runtime=rt)
        @test wait_for(() -> get_task_status(task_id, owner; runtime=rt)[:status] == "COMPLETED") == :ok
        channel = get_sequential_queues(rt)["dead-sweep-q"].channel
        @test isopen(channel)

        # A settled run handle, as in the #167 testset above: it must be released by the drain.
        settled_handle = @async nothing
        wait(settled_handle)
        Nitro.Workers.register_active_task!(rt, "dead-sweep-handle", settled_handle)
        Nitro.Workers.register_active_task_info!(rt, "dead-sweep-handle", TaskInfo("dead-sweep-handle"))

        dead = @async error("simulated: the sweep died hours ago")
        @test wait_for(() -> istaskdone(dead)) == :ok
        @test istaskfailed(dead)
        get_cleanup_scheduler(rt)[] = CleanupScheduler(dead, Channel{Nothing}(1))

        # Against the unpatched code this line throws `TaskFailedException` and nothing below it
        # happens: the queue stays open, the registry stays populated, the handle stays.
        @test (@test_logs (:error, r"retention scheduler had already died") match_mode=:any shutdown!(rt)) == true

        @test get_cleanup_scheduler(rt)[] === nothing
        @test !isopen(channel)
        @test isempty(get_sequential_queues(rt))
        @test !haskey(rt.active_tasks, "dead-sweep-handle")

        # The runtime is reusable afterwards: a fresh scheduler, alive, that stops cleanly.
        fresh = start_cleanup_scheduler(; interval_hours=1, retain_days=7, runtime=rt)
        @test fresh.task !== dead
        @test !istaskdone(fresh.task)
        stop_cleanup_scheduler!(fresh)
        @test istaskdone(fresh.task)
        @test !istaskfailed(fresh.task)

        # The runtime-argument form -- what `startup(cleanup_enabled=false)` calls -- clears the
        # slot for a dead task too, instead of throwing before it gets there.
        get_cleanup_scheduler(rt)[] = CleanupScheduler(dead, Channel{Nothing}(1))
        @test (@test_logs (:error, r"retention scheduler had already died") match_mode=:any stop_cleanup_scheduler!(rt)) === nothing
        @test get_cleanup_scheduler(rt)[] === nothing
    finally
        reset_runtime!(rt)
    end
end

@testset "Public worker startup API bootstraps lifecycle" begin
    ctx = Nitro.Core.App()

    lifecycle = startup(
        ctx;
        queues=["reports"],
        cleanup_enabled=true,
        cleanup_interval_hours=0.00005,
        cleanup_retain_days=7,
    )

    processed = Nitro.Core.process_middleware(ctx, [lifecycle])
    @test length(processed) == 1
    # Installed when the middleware was BUILT (#322), so there is no window before `on_startup`
    # in which an App-first call finds nothing -- this asserted `isnothing` before, which was
    # exactly that window. Nothing is RUNNING yet, though: no processor, no scheduler.
    built = worker_runtime(ctx)
    @test built isa WorkerRuntime
    @test get_cleanup_scheduler(built)[] === nothing

    lifecycle.on_startup()

    store = worker_store(ctx)
    @test worker_runtime(ctx) === built
    @test store isa InMemoryWorkerStore
    @test get_queue_status(ctx, "reports", System())[:running] == true
    @test get_cleanup_scheduler(worker_runtime(ctx))[] isa CleanupScheduler

    lock(store.task_lock) do
        expired = TaskInfo("lifecycle-expired")
        expired.status = COMPLETED
        expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
        store.task_registry[expired.id] = expired
    end

    @test wait_for(() -> get_task_status(ctx, "lifecycle-expired", System())[:status] == "NOT_FOUND") == :ok

    lifecycle.on_shutdown()
    @test isnothing(worker_store(ctx))
end

@testset "User access control and queue authorization" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store; queues = ["admin-queue"])
    # Declared out here so the `finally` below can release the callback -- see the note at
    # the `task-access` submit.
    access_started = Base.Event()
    access_release = Base.Event()
    
    # Configure a mock queue authorizer
    set_queue_authorizer!(store, (queue_name, user_id) -> begin
        if queue_name == "admin-queue"
            return user_id == "admin-user"
        end
        return true
    end)

    try
        # 1. Queue Authorization test
        # Authorized user succeeds
        task1 = submit_sequential_task("admin-queue", "task-auth-ok", () -> "ok", Owner("admin-user"); runtime=rt_store)
        @test task1 == "admin-user::task-auth-ok"

        # Unauthorized user throws AuthorizationError
        @test_throws AuthorizationError submit_sequential_task("admin-queue", "task-auth-fail", () -> "fail", Owner("other-user"); runtime=rt_store)

        # 2. Task querying and watchers access control
        # submit a task by user-a (so user-a is the first watcher)
        #
        # The callback is held open rather than returning immediately. This testset asserts an
        # AUTHORIZATION property -- that the owner may cancel and a stranger may not -- and a
        # cancel can only demonstrate that against a task still running. `() -> "data"` used to
        # be safe here only by accident: under `@async` the body was pinned to the submitting
        # thread and could not start until this test task yielded, so the cancel always won.
        # Once worker bodies moved to `Threads.@spawn` (#30) it finishes first on the other
        # thread and the cancel correctly reports "already finished" -- turning an
        # authorization assertion into a race. Hold it open and the property is tested again.
        task_id = submit_task("task-access", task_info -> begin
            notify(access_started)
            wait(access_release)
            return "data"
        end, Owner("user-a"); runtime=rt_store)
        wait(access_started)
        @test task_id == "user-a::task-access"

        # user-a can check status
        status_a = get_task_status(task_id, Owner("user-a"); runtime=rt_store)
        @test status_a[:id] == task_id

        # user-b cannot check status, and is told exactly what a missing id gets (#323)
        @test is_not_found(get_task_status(task_id, Owner("user-b"); runtime=rt_store))

        # The bypass still exists, but it is now a value you have to name.
        @test get_task_status(task_id, System(); runtime=rt_store)[:id] == task_id

        # ...and there is no arity that reaches it by omission. This is #48: the
        # unsafe call used to be the SHORTER one, so a call site that had merely
        # forgotten to scope was indistinguishable from one that meant not to.
        @test_throws MethodError get_task_status(task_id; runtime=rt_store)
        @test_throws MethodError cancel_task(task_id; runtime=rt_store)
        @test_throws MethodError get_all_tasks(; runtime=rt_store)
        @test_throws MethodError get_all_tasks(RUNNING; runtime=rt_store)
        # A bare user id is not an authority either — `""` used to be a second,
        # quieter bypass, reachable by reading a missing claim into an empty string.
        @test_throws MethodError get_task_status(task_id, "user-a"; runtime=rt_store)

        # 3. Listing tasks (get_all_tasks)
        # add another task by user-b
        task_b_id = submit_task("task-user-b", () -> "data", Owner("user-b"); runtime=rt_store)

        # get_all_tasks for user-a only returns task-access
        tasks_a = get_all_tasks(Owner("user-a"); runtime=rt_store)
        @test length(tasks_a) == 1
        @test tasks_a[1][:id] == task_id

        # get_all_tasks for user-b only returns task-user-b
        tasks_b = get_all_tasks(Owner("user-b"); runtime=rt_store)
        @test length(tasks_b) == 1
        @test tasks_b[1][:id] == task_b_id

        # get_all_tasks without user returns both
        all_tasks = get_all_tasks(System(); runtime=rt_store)
        @test length(all_tasks) == 3 # task-auth-ok + task-access + task-user-b

        # 4. Cancellation access control
        # user-b cannot cancel user-a's task
        @test is_not_found(cancel_task(task_id, Owner("user-b"); runtime=rt_store))

        # user-a can cancel their own task
        cancel_res = cancel_task(task_id, Owner("user-a"); runtime=rt_store)
        @test cancel_res[:status] == "Task cancelled"
    finally
        notify(access_release)
        reset_runtime!(rt_store)
    end
end

@testset "watchers= grants a second identity access at submit time (#96)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        # The motivating case: the identity that submits is not the one that polls.
        # A browser uploads under a short-lived credential; the backend, holding a
        # different long-lived one, drives the progress bar.
        task_id = submit_task("import-42", () -> "imported", Owner("browser-client");
                              watchers=[Owner("backend-service")], runtime=rt_store)

        @test wait_for(() -> get_task_status(task_id, Owner("browser-client"); runtime=rt_store)[:status] == "COMPLETED") == :ok

        # The grantee can read and list...
        @test get_task_status(task_id, Owner("backend-service"); runtime=rt_store)[:result] == "imported"
        @test only(get_all_tasks(Owner("backend-service"); runtime=rt_store))[:id] == task_id
        # ...but ownership stays with the submitter: it is derived from the id.
        @test get_task_status(task_id, Owner("backend-service"); runtime=rt_store)[:owner] == "browser-client"

        # Nobody else is admitted by the grant.
        @test is_not_found(get_task_status(task_id, Owner("stranger"); runtime=rt_store))

        # Granting an identity that is already a watcher is a no-op, owner included.
        again = submit_task("solo", () -> "x", Owner("alice");
                            watchers=[Owner("alice")], runtime=rt_store)
        @test get_task_status(again, Owner("alice"); runtime=rt_store)[:watcher_count] == 1
    finally
        reset_runtime!(rt_store)
    end
end

@testset "a :global grant is still subject to the watch authorizer (#96)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    org = Dict("victim" => "A", "bob" => "A", "mallory" => "B")
    set_watch_authorizer!(store, (task_key, watchers, user_id) ->
        get(org, first(watchers), nothing) == get(org, user_id, nothing))

    try
        gid = submit_task("shared-index", () -> "secret", Owner("victim");
                          scope=:global, runtime=rt_store)

        # A direct join by an out-of-org user is refused — that is #19's gate.
        @test_throws AuthorizationError submit_task("shared-index", () -> "x", Owner("mallory");
                                                   scope=:global, runtime=rt_store)

        # ...so a grant must not be a way around it. For a :global task there is no owner
        # in the id, which makes the watch authorizer the entire access policy; letting an
        # admitted watcher hand access onward would be transitive expansion the app never
        # approved — and it would carry cancel rights too.
        @test_throws AuthorizationError submit_task("shared-index", () -> "x", Owner("bob");
                                                   scope=:global, watchers=[Owner("mallory")],
                                                   runtime=rt_store)
        @test is_not_found(get_task_status(gid, Owner("mallory"); runtime=rt_store))

        # The refused submit must not have persisted the grants that preceded the
        # refusal: a submit that raised should not have handed out any access.
        @test_throws AuthorizationError submit_task("shared-index", () -> "x", Owner("victim");
                                                   scope=:global,
                                                   watchers=[Owner("bob"), Owner("mallory")],
                                                   runtime=rt_store)
        @test is_not_found(get_task_status(gid, Owner("bob"); runtime=rt_store))

        # An in-org grantee the authorizer accepts still goes through.
        @test submit_task("shared-index", () -> "x", Owner("victim");
                          scope=:global, watchers=[Owner("bob")], runtime=rt_store) == gid
        @test get_task_status(gid, Owner("bob"); runtime=rt_store)[:id] == gid
    finally
        reset_runtime!(rt_store)
    end
end

@testset "a :user grant needs no authorizer — the owner owns the task (#96)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    # An authorizer that refuses everyone. It governs :global key reuse only, so it must
    # not reach a :user-scoped owner sharing their own task.
    set_watch_authorizer!(store, (task_key, watchers, user_id) -> false)

    try
        task_id = submit_task("report", () -> "mine", Owner("alice");
                              watchers=[Owner("helper")], runtime=rt_store)
        @test get_task_status(task_id, Owner("helper"); runtime=rt_store)[:id] == task_id
    finally
        reset_runtime!(rt_store)
    end
end

@testset "watchers= grants cancel too, and does not survive a record reset (#96)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    started = Base.Event()
    try
        task_id = submit_task("long-job", task_info -> begin
            notify(started)
            while !cancel_requested(task_info)
                sleep(0.01)
            end
        end, Owner("owner-a"); watchers=[Owner("helper")], runtime=rt_store)
        wait(started)

        # A grantee gets the owner's rights minus ownership, and `cancel_task` gates on
        # the same list -- so the grant carries cancel. Documented, not incidental.
        @test cancel_task(task_id, Owner("helper"); runtime=rt_store)[:status] == "Task cancelled"
        @test wait_for(() -> get_task_status(task_id, Owner("owner-a"); runtime=rt_store)[:status] == "CANCELLED") == :ok

        # Re-running a finished key replaces the record, so its watcher list resets to
        # the resubmitter and grants must be passed again.
        again = submit_task("long-job", () -> "second", Owner("owner-a"); runtime=rt_store)
        @test again == task_id
        @test wait_for(() -> get_task_status(task_id, Owner("owner-a"); runtime=rt_store)[:result] == "second") == :ok
        @test is_not_found(get_task_status(task_id, Owner("helper"); runtime=rt_store))
    finally
        notify(started)
        reset_runtime!(rt_store)
    end
end

@testset "store write primitives are atomic and intent-scoped (#88)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        info = TaskInfo("alice::job")
        push!(info.watchers, "alice")
        replace_task!(store, info.id, info)

        @testset "add_watcher! is idempotent and reports absence" begin
            @test add_watcher!(store, "alice::job", "bob") == true
            @test add_watcher!(store, "alice::job", "bob") == true       # idempotent
            @test get_task_info(store, "alice::job").watchers == ["alice", "bob"]
            @test add_watcher!(store, "no-such-task", "bob") == false    # absent, not an error
        end

        @testset "set_task! carries state, never grants" begin
            # The #88 regression, expressed against the store contract: an ordinary
            # state transition must not carry a stale watcher list along with it.
            # A caller holding a TaskInfo read *before* a grant was added...
            stale = TaskInfo("alice::job")           # a view that predates the grant
            push!(stale.watchers, "alice")
            stale.status = COMPLETED

            set_task!(store, "alice::job", stale)    # ...saves progress/status only

            @test "bob" in get_task_info(store, "alice::job").watchers

            # replace_task! is the one call that *may* reset them, and is what the
            # documented "re-running a finished key resets watchers" path uses.
            fresh = TaskInfo("alice::job")
            push!(fresh.watchers, "carol")
            replace_task!(store, "alice::job", fresh)
            @test get_task_info(store, "alice::job").watchers == ["carol"]
        end

        @testset "try_transition! only fires from the expected status" begin
            t = TaskInfo("alice::cas")
            replace_task!(store, t.id, t)            # starts PENDING

            @test try_transition!(store, "alice::cas", (PENDING, RUNNING), CANCELLED;
                                  run_id=t.run_id,
                                  error="Cancelled", completed_at=Dates.now(Dates.UTC)) == true
            after = get_task_info(store, "alice::cas")
            @test after.status == CANCELLED
            @test after.error == "Cancelled"

            # Already left the `from` set: no second transition, and nothing written.
            @test try_transition!(store, "alice::cas", (PENDING, RUNNING), COMPLETED;
                                  run_id=nothing) == false
            @test get_task_info(store, "alice::cas").status == CANCELLED
            @test try_transition!(store, "no-such-task", (PENDING,), CANCELLED;
                                  run_id=nothing) == false
        end

        @testset "concurrent add_watcher! loses no grant" begin
            t = TaskInfo("alice::concurrent")
            push!(t.watchers, "alice")
            replace_task!(store, t.id, t)

            @sync for i in 1:20
                Threads.@spawn add_watcher!(store, "alice::concurrent", "u$(i)")
            end

            got = get_task_info(store, "alice::concurrent").watchers
            @test length(got) == 21
            @test Set(got) == Set(vcat("alice", ["u$(i)" for i in 1:20]))
        end
    finally
        reset_runtime!(rt_store)
    end
end

@testset "terminal writes are addressed to a run, not just a task id (#108)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        # Deliberately driven through the store primitives rather than through real tasks.
        # The bug is a property of the compare-and-set, and asserting it directly makes the
        # test deterministic -- no sleeps, no scheduling, nothing to flake.
        @testset "a stale run's terminal write cannot land on its successor" begin
            a = TaskInfo("alice::report")            # run A, still in flight
            a.status = RUNNING
            replace_task!(store, a.id, a)

            b = TaskInfo("alice::report")            # the resubmit: fresh PENDING record
            replace_task!(store, b.id, b)
            @test b.run_id != a.run_id

            # Verbatim the CAS `_finish_task!` issues. B's record satisfies the STATUS
            # precondition -- PENDING is in `from` -- which is exactly why the status alone
            # was never enough.
            @test try_transition!(store, a.id, (PENDING, RUNNING), COMPLETED;
                                  run_id=a.run_id, result="stale",
                                  completed_at=Dates.now(Dates.UTC)) == false

            live = get_task_info(store, a.id)
            @test live.status == PENDING             # A's write landed nowhere...
            @test live.result === nothing
            @test live.run_id == b.run_id

            # ...and B's own write still wins.
            @test try_transition!(store, b.id, (PENDING, RUNNING), COMPLETED;
                                  run_id=b.run_id, result="fresh") == true
            @test get_task_info(store, b.id).result == "fresh"
        end

        @testset "run_id = nothing is the named, unconditional bypass" begin
            c = TaskInfo("alice::bypass")
            replace_task!(store, c.id, c)
            @test try_transition!(store, c.id, (PENDING,), CANCELLED; run_id=nothing) == true
            @test get_task_info(store, c.id).status == CANCELLED
        end

        @testset "every TaskInfo is its own run" begin
            @test TaskInfo("alice::x").run_id != TaskInfo("alice::x").run_id
        end

        @testset "set_task! never writes run_id; replace_task! does" begin
            original = TaskInfo("alice::split")
            replace_task!(store, original.id, original)

            # A DIFFERENT object carrying a different run id -- the shape a stale worker
            # holds. `set_task!` must carry its state across and leave the identity alone,
            # exactly as it already does for `watchers`.
            stale = TaskInfo("alice::split")
            stale.status = RUNNING
            set_task!(store, stale.id, stale)

            stored = get_task_info(store, "alice::split")
            @test stored.run_id == original.run_id   # identity untouched
            @test stored.status == RUNNING           # state carried

            # ...and the one sanctioned way to publish a new run's identity.
            replace_task!(store, stale.id, stale)
            @test get_task_info(store, "alice::split").run_id == stale.run_id
        end

        @testset "a stale run's teardown cannot evict its successor's live handle" begin
            a = TaskInfo("alice::handles")
            a.status = RUNNING
            replace_task!(store, a.id, a)
            Nitro.Workers.register_active_task!(rt_store, a.id, @async sleep(0.01))

            b = TaskInfo("alice::handles")           # the resubmit takes over the key
            b.status = RUNNING
            replace_task!(store, b.id, b)
            b_handle = @async (sleep(30); nothing)
            Nitro.Workers.register_active_task!(rt_store, b.id, b_handle)
            Nitro.Workers.register_active_task_info!(rt_store, b.id, b)

            # Run A finally finishes. Its CAS correctly writes nothing -- but before #108
            # the teardown that follows was keyed by ID, so it deleted B's handle too.
            Nitro.Workers._finish_task!(rt_store, a, COMPLETED; result="stale")

            @test get_active_task(rt_store, "alice::handles") === b_handle
            @test get_task_info(store, "alice::handles").status == RUNNING

            # Why that mattered: zombie recovery decides liveness from exactly that handle,
            # so an unfenced teardown made a genuinely-running successor look dead.
            recover_zombie_tasks!(; runtime=rt_store)
            @test get_task_info(store, "alice::handles").status == RUNNING
        end
    finally
        reset_runtime!(rt_store)
    end
end

@testset "a cancel that lands before the body starts is not overwritten (#142)" begin
    @testset "the start write is a claim, so it cannot undo a cancellation" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        try
            t = TaskInfo("alice::early")
            replace_task!(store, t.id, t)

            @test try_transition!(store, t.id, (PENDING,), CANCELLED;
                                  run_id=t.run_id, error="Cancelled") == true

            # THE property. Starting used to be an unconditional `set_task!`, so this write
            # landed regardless and put the record back to RUNNING -- after which
            # `_complete_task!`'s own CAS succeeded and reported COMPLETED for a task whose
            # caller had been told "Task cancelled".
            @test try_transition!(store, t.id, (PENDING,), RUNNING;
                                  run_id=t.run_id,
                                  started_at=Dates.now(Dates.UTC)) == false
            @test get_task_info(store, t.id).status == CANCELLED
            @test get_task_info(store, t.id).started_at === nothing
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a claimed cancel is never followed by COMPLETED" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        try
            # Cancel IMMEDIATELY after submit, without waiting for the callback to start --
            # the window every other cancel test in this file deliberately closes by first
            # waiting on an Event notified from *inside* the callback.
            id = submit_task("race", () -> "done", Owner("u"); runtime=rt_store)
            @test cancel_task(id, Owner("u"); runtime=rt_store)[:status] == "Task cancelled"

            # A NEGATIVE, time-bounded assertion, and that direction is the point: a slow
            # machine still times out, so this cannot flake into a false failure -- it can
            # only fail if the status actually leaves CANCELLED, which is the bug. Asserting
            # `wait_for(status == "CANCELLED")` instead would be useless here, since
            # `timedwait` evaluates its predicate once up front and the record is already
            # CANCELLED at that instant; the overwrite lands later.
            @test timedwait(() -> get_task_status(id, Owner("u"); runtime=rt_store)[:status] !=
                                  "CANCELLED", 2.0) == :timed_out
            @test get_task_status(id, Owner("u"); runtime=rt_store)[:status] == "CANCELLED"
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a queued item cancelled before it is dequeued never runs its callback" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        ran = Threads.Atomic{Bool}(false)
        try
            t = TaskInfo("alice::queued"; queue_name="reports")
            replace_task!(store, t.id, t)
            @test try_transition!(store, t.id, (PENDING,), CANCELLED;
                                  run_id=t.run_id, error="Cancelled") == true

            # Driven synchronously on purpose: the sequential processor calls exactly this,
            # so the assertion is about the function rather than about scheduling.
            item = Nitro.Workers.QueueItem(t.id, t.run_id, () -> (ran[] = true; "done"), TaskOptions())
            Nitro.Workers._execute_queued_task(rt_store, item)

            @test ran[] == false
            @test get_task_info(store, t.id).status == CANCELLED
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a queued item does not run against a successor's record (#191)" begin
        # The run-start claim used to fence on the `run_id` it read out of the record it had
        # just read, which agrees with whoever currently owns the key -- so it was no fence.
        # Driven synchronously: the sequential processor calls exactly this, and the whole
        # scenario is deterministic because a cancel and a re-submit need no concurrency.
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("u")
        ran = String[]
        first_cb = task_info -> (push!(ran, "FIRST"); "first")
        second_cb = task_info -> (push!(ran, "SECOND"); "second")
        try
            key = scoped_task_key("K", owner)

            # The predecessor: registered, queued, then cancelled while still buffered.
            predecessor_run = Nitro.Workers._register_or_watch!(rt_store, key, owner; queue_name="q")
            @test predecessor_run !== nothing
            stale = Nitro.Workers.QueueItem(key, predecessor_run, first_cb, TaskOptions())
            @test cancel_task(key, owner; runtime=rt_store)[:status] == "Task cancelled"

            # The re-submit replaces the terminal record with a fresh run, and queues its own
            # item. Both items are now buffered; the STALE one is at the head.
            successor_run = Nitro.Workers._register_or_watch!(rt_store, key, owner; queue_name="q")
            @test successor_run !== nothing
            @test successor_run != predecessor_run
            surviving = Nitro.Workers.QueueItem(key, successor_run, second_cb, TaskOptions())

            # The stale item must decline. Before the fix it ran `first_cb` here and stored
            # "first" as the SUCCESSOR's result.
            @test Nitro.Workers._execute_queued_task(rt_store, stale) === nothing
            @test ran == String[]

            record = get_task_info(store, key)
            @test record.status == PENDING
            @test record.run_id == successor_run
            @test record.result === nothing
            @test record.started_at === nothing

            # It registered no handles either -- the check runs BEFORE `register_run!`, so the
            # stale run never becomes the oracle for the successor's later fences (#167).
            @test get_active_task(rt_store, key) === nothing
            @test get_active_task_info(rt_store, key) === nothing

            # And the surviving item still runs, which is the half a bare "the stale one did
            # nothing" assertion would miss: the fix must not strand the key.
            Nitro.Workers._execute_queued_task(rt_store, surviving)
            @test ran == ["SECOND"]
            finished = get_task_info(store, key)
            @test finished.status == COMPLETED
            @test finished.result == "second"
            @test finished.run_id == successor_run
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a stale queued item leaves a live successor's handles alone (#191, #167)" begin
        # The collateral harm, and the reason the identity check precedes `register_run!`
        # rather than merely the claim. A stale item that registered would publish the
        # SUCCESSOR's `run_id` into the runtime, and its own `finally _deregister_run!` would
        # then match that fence and delete handles belonging to a genuinely-running job --
        # after which `recover_zombie_tasks!` sees RUNNING with no active task and writes FAILED.
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("u")
        stale_ran = Threads.Atomic{Bool}(false)
        never = task_info -> (stale_ran[] = true; "never")
        try
            key = scoped_task_key("K", owner)
            predecessor_run = Nitro.Workers._register_or_watch!(rt_store, key, owner; queue_name="q")
            stale = Nitro.Workers.QueueItem(key, predecessor_run, never, TaskOptions())
            cancel_task(key, owner; runtime=rt_store)

            # A successor that is genuinely RUNNING with its handles published, as it would be
            # a moment after starting on the async path or on a second queue.
            successor_run = Nitro.Workers._register_or_watch!(rt_store, key, owner; queue_name="q")
            live_info = get_task_info(store, key)
            @test live_info.run_id == successor_run
            handle = @async sleep(0.05)
            Nitro.Workers.register_run!(rt_store, key, live_info, handle)
            @test try_transition!(store, key, (PENDING,), RUNNING; run_id=successor_run) == true

            Nitro.Workers._execute_queued_task(rt_store, stale)

            @test stale_ran[] == false

            # The successor still owns its handles, so the zombie sweep leaves it alone.
            @test get_active_task(rt_store, key) === handle
            @test get_active_task_info(rt_store, key) === live_info
            @test recover_zombie_tasks!(runtime=rt_store) == 0
            @test get_task_info(store, key).status == RUNNING
            wait(handle)
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "cancel-then-resubmit on a held queue runs the surviving callback (#191)" begin
        # The issue's own reproduction, end to end through the public API. Worth having beside
        # the synchronous test: it is the shape a caller actually hits, and it also pins that
        # the surviving item is reached at all rather than stranded behind the stale one.
        #
        # Both callbacks are defined before the processor spawns -- `_invoke_task_callback`
        # gates on `applicable`, which is world-age sensitive.
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store; queues = ["q"])
        owner = Owner("u")
        gate = Base.Event()
        entered = Base.Event()
        order_lock = ReentrantLock()
        ran = String[]
        note(name) = lock(order_lock) do
            push!(ran, name)
        end
        holder_cb = task_info -> (notify(entered); wait(gate); "held")
        first_cb = task_info -> (note("FIRST"); "first")
        second_cb = task_info -> (note("SECOND"); "second")
        try
            # Hold the processor so nothing is consumed while the scenario is set up. This is
            # the "busy queue" the issue notes is all the buffering the bug needs.
            submit_sequential_task("q", "holder", holder_cb, owner; runtime=rt_store)
            wait(entered)

            id = submit_sequential_task("q", "K", first_cb, owner; runtime=rt_store)
            @test cancel_task(id, owner; runtime=rt_store)[:status] == "Task cancelled"
            id2 = submit_sequential_task("q", "K", second_cb, owner; runtime=rt_store)
            # Same key, so the caller's surviving submission is the second callback.
            @test id2 == id

            notify(gate)
            @test timedwait(() -> get_task_info(store, id).status == COMPLETED, 10.0;
                            pollint=0.02) === :ok

            # Before the fix this was ["FIRST"], with "first" stored as the second run's result.
            @test ran == ["SECOND"]
            @test get_task_info(store, id).result == "second"
        finally
            notify(gate)
            reset_runtime!(rt_store)
        end
    end

    @testset "an async task superseded before its run starts does not run (#191)" begin
        # `submit_task` has no queue, so the window is the `@spawn` hand-off rather than a
        # buffer wait -- narrower in wall-clock, wider in consequence, since both runs are
        # spawned tasks and neither serializes against the other. Driven directly for the same
        # reason the queued test is: the window is not deterministically reachable from outside.
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("u")
        ran = Threads.Atomic{Bool}(false)
        never = task_info -> (ran[] = true; "first")
        try
            key = scoped_task_key("async-K", owner)
            predecessor_run = Nitro.Workers._register_or_watch!(rt_store, key, owner)
            cancel_task(key, owner; runtime=rt_store)
            successor_run = Nitro.Workers._register_or_watch!(rt_store, key, owner)
            @test successor_run != predecessor_run

            # The spawned body carries the identity it was submitted with, which no longer owns
            # the record. It must decline rather than claim the successor's PENDING record.
            wait(Nitro.Workers._execute_task_async(rt_store, key, never, TaskOptions(), predecessor_run))

            @test ran[] == false
            record = get_task_info(store, key)
            @test record.status == PENDING
            @test record.run_id == successor_run
            @test record.started_at === nothing
            @test get_active_task(rt_store, key) === nothing
            @test get_active_task_info(rt_store, key) === nothing
        finally
            reset_runtime!(rt_store)
        end
    end
end

@testset "a stale run cannot publish over a live successor's handles (#198)" begin
    # `register_run!` used to ASSIGN both caches with no precondition. Both execute paths verify
    # that the record still belongs to their run before calling it (#191), but that check and
    # the publish were two steps: a cancel plus a re-submit landing between them let the stale
    # predecessor overwrite the live successor's entries, and the predecessor's own fenced
    # `finally` then deleted them -- a genuinely-running job with no handle, which
    # `recover_zombie_tasks!` reads as death and `cancel_task` can no longer reach.
    #
    # Two halves close it. `register_run!` is a compare-and-set on the live `run_id`, so a
    # foreign publish is REFUSED rather than applied; and `_claim_run!` performs the durable
    # read, the identity check and the publish under `lock_tasks` -- the lock every supersede
    # holds -- so a run that verifies ownership finds the slot empty or its own by construction.
    # The first half is what these tests can hold in place; the second is a lock discipline,
    # reviewed by reading `_claim_run!`, for the same reason the #167 two-write window was.
    @testset "register_run! is a compare-and-set on the live run" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        handles = Task[]
        try
            key = "alice::cas"
            successor = TaskInfo(key)
            successor.status = RUNNING
            push!(successor.watchers, "alice")
            replace_task!(store, key, successor)
            s_handle = @async sleep(0.05)
            push!(handles, s_handle)

            # An empty slot accepts the publish.
            @test register_run!(rt_store, key, successor, s_handle) == true
            @test get_active_task(rt_store, key) === s_handle
            @test get_active_task_info(rt_store, key) === successor

            # A different run under the same key is refused, and the slot is untouched.
            # Before the fix this returned the stale info and overwrote both entries.
            stale = TaskInfo(key)
            stale.status = RUNNING
            @test stale.run_id != successor.run_id
            p_handle = @async nothing
            push!(handles, p_handle)
            @test register_run!(rt_store, key, stale, p_handle) == false
            @test get_active_task(rt_store, key) === s_handle
            @test get_active_task_info(rt_store, key) === successor

            # Re-publishing one's OWN run is idempotent, not refused.
            @test register_run!(rt_store, key, successor, s_handle) == true
            @test get_active_task(rt_store, key) === s_handle

            # The refused predecessor finishes. Its fence does not match the live run, so the
            # successor's handles survive and the sweep has nothing to claim. Before the fix
            # the fence MATCHED -- the slot held the predecessor's own object -- and this
            # deleted a live run's handles.
            Nitro.Workers._deregister_run!(rt_store, stale)
            @test get_active_task(rt_store, key) === s_handle
            @test get_active_task_info(rt_store, key) === successor
            @test recover_zombie_tasks!(; runtime=rt_store) == 0
            @test get_task_info(store, key).status == RUNNING
        finally
            foreach(wait, handles)
            reset_runtime!(rt_store)
        end
    end

    @testset "a predecessor publishing after its successor cannot strand the successor" begin
        # The issue's interleaving on the real objects. P read its record and passed the #191
        # identity check (T0); a cancel and a re-submit minted S, and S registered and claimed
        # RUNNING (T1); only then does P reach `register_run!` with the record it read (T2).
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("u")
        handles = Task[]
        try
            key = scoped_task_key("K", owner)
            predecessor_run = Nitro.Workers._register_or_watch!(rt_store, key, owner; queue_name="q")
            p_info = get_task_info(store, key)            # what P read at T0
            @test p_info.run_id == predecessor_run
            @test cancel_task(key, owner; runtime=rt_store)[:status] == "Task cancelled"

            successor_run = Nitro.Workers._register_or_watch!(rt_store, key, owner; queue_name="q")
            @test successor_run != predecessor_run
            s_info = get_task_info(store, key)
            @test s_info.run_id == successor_run
            s_handle = @async sleep(0.05)
            push!(handles, s_handle)
            @test register_run!(rt_store, key, s_info, s_handle) == true
            @test try_transition!(store, key, (PENDING,), RUNNING; run_id=successor_run) == true

            # T2: P publishes late. Before the fix this overwrote S's entries...
            p_handle = @async nothing
            push!(handles, p_handle)
            @test register_run!(rt_store, key, p_info, p_handle) == false
            # ...P's start CAS then correctly lost on `run_id`...
            @test try_transition!(store, key, (PENDING,), RUNNING; run_id=predecessor_run) == false
            # ...and P's own fenced teardown found its own object in the slot and deleted it.
            Nitro.Workers._deregister_run!(rt_store, p_info)

            @test get_active_task(rt_store, key) === s_handle
            @test get_active_task_info(rt_store, key) === s_info
            @test recover_zombie_tasks!(; runtime=rt_store) == 0
            @test get_task_info(store, key).status == RUNNING

            # S is still cancellable: the live lookup reaches S's own object and sets ITS token.
            @test cancel_task(key, owner; runtime=rt_store)[:status] == "Task cancelled"
            @test cancel_reason(s_info) == :user
            @test cancel_reason(p_info) == :none
        finally
            foreach(wait, handles)
            reset_runtime!(rt_store)
        end
    end

    @testset "a run whose slot is held by a foreign run declines at claim time" begin
        # The out-of-band state the CAS guards. Under `lock_tasks` nothing in production can put
        # a foreign run in the slot between the identity check and the publish -- every mint
        # goes through `replace_task!(runtime, ·)`, which evicts under that same lock -- so a
        # refusal here means either test-only state, as below, or a refactor that moved the read
        # back outside the lock. That is why it is a `@warn` and not a `@debug`.
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("u")
        ran = Threads.Atomic{Bool}(false)
        never = task_info -> (ran[] = true; "never")
        try
            key = scoped_task_key("K", owner)
            run = Nitro.Workers._register_or_watch!(rt_store, key, owner; queue_name="q")
            item = Nitro.Workers.QueueItem(key, run, never, TaskOptions())

            foreign = TaskInfo(key)
            @test foreign.run_id != run
            Nitro.Workers.register_active_task_info!(rt_store, key, foreign)

            # Sequential path. Before the fix it overwrote the foreign info and ran to COMPLETED.
            @test (@test_logs (:warn, r"foreign run") Nitro.Workers._execute_queued_task(rt_store, item)) === nothing
            @test ran[] == false
            record = get_task_info(store, key)
            @test record.status == PENDING
            @test record.run_id == run
            @test record.started_at === nothing
            @test get_active_task_info(rt_store, key) === foreign
            @test get_active_task(rt_store, key) === nothing

            # Async path, same claim. The spawned body inherits the test logger.
            @test_logs (:warn, r"foreign run") wait(Nitro.Workers._execute_task_async(rt_store, key, never, TaskOptions(), run))
            @test ran[] == false
            @test get_task_info(store, key).status == PENDING
            @test get_active_task_info(rt_store, key) === foreign
            @test get_active_task(rt_store, key) === nothing
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a cancelled record is declined at claim time on both paths" begin
        # The sequential path used to check CANCELLED before publishing; the async path
        # published, lost its start CAS, and deregistered. Both now decline inside the claim,
        # so a cancelled run never has handles at all, and the claim's return says so.
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        owner = Owner("u")
        ran = Threads.Atomic{Bool}(false)
        never = task_info -> (ran[] = true; "never")
        try
            key = scoped_task_key("K", owner)
            run = Nitro.Workers._register_or_watch!(rt_store, key, owner; queue_name="q")
            @test cancel_task(key, owner; runtime=rt_store)[:status] == "Task cancelled"

            @test Nitro.Workers._claim_run!(rt_store, key, run) === nothing
            @test get_active_task_info(rt_store, key) === nothing

            @test Nitro.Workers._execute_queued_task(rt_store, Nitro.Workers.QueueItem(key, run, never, TaskOptions())) === nothing
            wait(Nitro.Workers._execute_task_async(rt_store, key, never, TaskOptions(), run))
            @test ran[] == false
            @test get_task_info(store, key).status == CANCELLED
            @test get_active_task(rt_store, key) === nothing
        finally
            reset_runtime!(rt_store)
        end
    end
end

@testset "cancellation is cooperative, never injected (#127)" begin
    @testset "cancel_task sets the run's token, and the callback observes it" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        entered = Base.Event()
        saw_token = Threads.Atomic{Bool}(false)
        ran_finally = Threads.Atomic{Bool}(false)
        try
            id = submit_task("cooperative", task_info -> begin
                notify(entered)
                try
                    while !cancel_requested(task_info)
                        sleep(0.01)
                    end
                    saw_token[] = true
                    return "stopped"
                finally
                    # Under the old model this ran because the injected exception unwound
                    # the callback. Now it runs only because the callback RETURNS -- which
                    # is the whole behavioural change apps have to absorb.
                    ran_finally[] = true
                end
            end, Owner("u"); runtime=rt_store)

            wait(entered)
            @test cancel_requested(get_task_info(store, id)) == false
            @test cancel_task(id, Owner("u"); runtime=rt_store)[:status] == "Task cancelled"

            @test wait_for(() -> saw_token[]) == :ok
            @test wait_for(() -> ran_finally[]) == :ok
            @test get_task_status(id, Owner("u"); runtime=rt_store)[:status] == "CANCELLED"
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "an uncooperative callback is not stopped, and cancel does not block on it" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        entered = Base.Event()
        release = Base.Event()
        returned = Threads.Atomic{Bool}(false)
        try
            id = submit_task("uncooperative", () -> begin
                notify(entered)
                wait(release)               # never polls the token
                returned[] = true
                return "finished anyway"
            end, Owner("u"); runtime=rt_store)

            wait(entered)
            # Returns immediately: the terminal state is recorded by the CAS, and there is
            # nothing to wait for. This is the contract the docs claimed and the interrupt
            # never actually delivered.
            @test cancel_task(id, Owner("u"); runtime=rt_store)[:status] == "Task cancelled"
            @test get_task_status(id, Owner("u"); runtime=rt_store)[:status] == "CANCELLED"
            @test returned[] == false       # still running, as documented

            notify(release)
            @test wait_for(() -> returned[]) == :ok
            # It ran to completion -- and still must not overwrite the cancellation.
            @test wait_for(() -> get_task_status(id, Owner("u"); runtime=rt_store)[:status] ==
                                 "CANCELLED") == :ok
        finally
            notify(release)
            reset_runtime!(rt_store)
        end
    end

    @testset "a timeout sets the token, records FAILED, and is never retried" begin
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        entries = Threads.Atomic{Int}(0)
        try
            # retry_on_failure is ON on purpose: a timeout must still be terminal on the
            # first attempt. Retrying would put a second copy of the callback beside the
            # first, since nothing can stop the one that timed out.
            # No `@suppress_err` here, deliberately. It would wrap only this call, which
            # returns immediately, while the timeout `@warn` fires about a second later from
            # the worker task -- so it suppressed nothing and merely looked like it did. The
            # warning is expected output for this testset, and seeing it in CI is a feature:
            # it is the only signal an abandoned callback produces.
            id = submit_task("slow", () -> begin
                Threads.atomic_add!(entries, 1)
                sleep(2.0)                  # outruns the deadline, ignores the token
                return "too late"
            end, Owner("u");
            options=TaskOptions(timeout=1, retry_on_failure=true, max_retries=2), runtime=rt_store)

            @test wait_for(() -> get_task_status(id, Owner("u"); runtime=rt_store)[:status] ==
                                 "FAILED"; timeout=10.0) == :ok
            status = get_task_status(id, Owner("u"); runtime=rt_store)
            @test occursin("Timeout of 1s exceeded", status[:error])
            @test entries[] == 1
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a fast task leaves no handle behind" begin
        # `_execute_task_async` used to also `register_active_task!` from the PARENT, after the
        # spawn. Under `@async` that was a duplicate write of the same Task object and merely
        # happened first; under `Threads.@spawn` the body can finish and deregister before the
        # parent gets there, re-registering a completed task that nothing ever cleans up (#30).
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        try
            id = submit_task("quick", () -> "done", Owner("u"); runtime=rt_store)
            @test wait_for(() -> get_task_status(id, Owner("u"); runtime=rt_store)[:status] ==
                                 "COMPLETED") == :ok
            @test wait_for(() -> !haskey(rt_store.active_tasks, id)) == :ok
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "a cancelled task stops reporting RUNNING, on both backends" begin
        # Regression guard for the store-parity gap that removing `cancel_task`'s
        # deregisters opened. `PormGWorkerStore.try_transition!` writes only the row while
        # its `get_task_info` prefers the live in-memory record, so without mirroring the
        # claim onto that record a cancelled task kept reporting RUNNING until its callback
        # returned -- and `_register_or_watch!` then refused to re-run the key.
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        entered = Base.Event()
        release = Base.Event()
        try
            id = submit_task("mirror", () -> (notify(entered); wait(release); "done"),
                             Owner("u"); runtime=rt_store)
            wait(entered)
            @test cancel_task(id, Owner("u"); runtime=rt_store)[:status] == "Task cancelled"

            # Asserted while the callback is STILL RUNNING -- that is the whole window.
            live = get_active_task_info(rt_store, id)
            @test live === nothing || live.status == CANCELLED
            @test get_task_status(id, Owner("u"); runtime=rt_store)[:status] == "CANCELLED"

            # The two downstream consequences the stale record caused.
            @test haskey(cancel_task(id, Owner("u"); runtime=rt_store), :error)
            again = submit_task("mirror", () -> "second", Owner("u"); runtime=rt_store)
            @test again == id
            @test wait_for(() -> get_task_status(id, Owner("u"); runtime=rt_store)[:result] ==
                                 "second") == :ok
        finally
            notify(release)
            reset_runtime!(rt_store)
        end
    end

    @testset "a cancel during the retry backoff does not re-run the callback" begin
        # The catch block checks CANCELLED before sleeping and never after, and #127 removed
        # the interrupt that used to abort that sleep -- so a cancel landing inside a 2/4/8s
        # backoff window used to burn another attempt against an already-cancelled task.
        store = InMemoryWorkerStore()
        rt_store = WorkerRuntime(store)
        attempts = Threads.Atomic{Int}(0)
        entered = Base.Event()
        try
            id = submit_task("backoff", () -> begin
                n = Threads.atomic_add!(attempts, 1) + 1
                n == 1 && notify(entered)
                error("attempt $n failed")
            end, Owner("u");
            options=TaskOptions(retry_on_failure=true, max_retries=3), runtime=rt_store)

            wait(entered)          # attempt 1 has STARTED; it has not necessarily failed yet

            # Land the cancel INSIDE the backoff, which is the window under test. Without
            # this pause the cancel usually arrives before the catch block evaluates its own
            # CANCELLED check, that check short-circuits, and the retry loop is never
            # reached -- so the test passed against the broken code. 0.3s is far more than
            # the callback needs to throw and be caught, and far less than the 2s backoff.
            sleep(0.3)
            @test cancel_task(id, Owner("u"); runtime=rt_store)[:status] == "Task cancelled"

            @test wait_for(() -> get_task_status(id, Owner("u"); runtime=rt_store)[:status] ==
                                 "CANCELLED"; timeout=10.0) == :ok

            # The point: the backoff was abandoned rather than slept through. This has to
            # outlast the 2s first backoff, and it has to be a NEGATIVE assertion -- the
            # obvious `@test attempts[] == 1` passes against the broken code too, because it
            # is evaluated long before the sleep would have expired and the second attempt
            # started. A time-bounded "this never happens" is the only form that discriminates,
            # and it cannot flake into a false failure on a slow machine.
            @test timedwait(() -> attempts[] > 1, 3.5) == :timed_out
            @test attempts[] == 1
        finally
            reset_runtime!(rt_store)
        end
    end

    @testset "nothing in Workers injects an exception into a task" begin
        # A source assertion, because the property is "no site in this module does this"
        # rather than "this function behaves thus" -- and reintroducing the injection is
        # the specific regression that would make worker bodies unsafe to migrate again.
        for file in ("api.jl", "execution.jl", "queue.jl")
            src = read(joinpath(pkgdir(Nitro), "src", "Workers", file), String)
            # Comments are stripped first: the sites that were removed are DESCRIBED in
            # comments right where they used to be, and a guard that cannot tell an
            # explanation from a call would fail on its own documentation.
            code = join((line for line in eachsplit(src, "
")
                         if !startswith(strip(line), "#")), "
")
            @test !occursin("error=true", code)
            @test !occursin("error = true", code)
        end
    end
end

# NOT HERE: the probe #127 asked for -- "submit a CPU-bound callback, wait until it is provably
# running, then cancel, at -t 2". It was written, and it wedged the ReTestItems worker into a
# 600s timeout on roughly half of -t 2 runs. Recorded so the next attempt does not rediscover it:
#
#   * Nitro is not the stall. Tracing every branch of the worker path showed it reached
#     `_invoke_task_callback` EVERY time and stopped before the callback's first statement.
#     `body-claim-FAILED` never appeared once, so the claimed start (#142) is not implicated.
#   * The same scenario runs 25/25 clean standalone at -t 2. It needs the full suite around it.
#   * Disabling only this testset: 6/6 clean at -t 2. The swap itself is stable.
#   * Three fixes were tried and NONE worked: `GC.safepoint()` in the spin, replacing the spin
#     with allocating work, and pre-compiling the callback on the test task before submitting.
#
# So the gap is real and is written down rather than papered over: nothing here cancels a task
# that is genuinely executing on another thread. Every cancel test above uses a `sleep` loop,
# and a task in `sleep` is PARKED -- which is exactly the weak probe that let the first attempt
# at #30 ship a process abort. Tracked in #143, with the full trace evidence.

@testset "queue introspection is an admin surface (#87)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store; queues = ["reports"])
    try
        submit_sequential_task("reports", "job", () -> "ok", Owner("user-a"); runtime=rt_store)

        # `:pending_tasks` and `:current_task` enumerate ids that carry their owner in
        # the "<owner>::<key>" prefix, and queue depth is a fact about the queue rather
        # than about any one user. So there is no scoped form: an Owner does not compile.
        @test get_queue_status("reports", System(); runtime=rt_store)[:running] == true
        @test_throws MethodError get_queue_status("reports", Owner("user-a"); runtime=rt_store)
        # ...and, as everywhere else, omitting the authority is not a way in either.
        @test_throws MethodError get_queue_status("reports"; runtime=rt_store)

        # `is_task_running` took no user id at all — any caller who could name an id
        # learned whether it was live. Retired rather than hardened; it had no tests and
        # no docs, and `get_task_status` answers the same question with authorization.
        @test !isdefined(Nitro.Workers, :is_task_running)
    finally
        reset_runtime!(rt_store)
    end
end

@testset "Owner validates its identity; System is the named bypass" begin
    # Every shape that would make the owner half of a `:user` id ambiguous, plus the
    # empty id, which used to mean "skip the ownership check".
    @test_throws ArgumentError Owner("")
    @test_throws ArgumentError Owner("::")
    @test_throws ArgumentError Owner("bad::uid")
    @test_throws ArgumentError Owner("alice:")

    # A colon anywhere else in an owner stays legal — "google:12345" is a real shape.
    @test Owner("google:12345").user_id == "google:12345"
    @test Owner("user-a") isa TaskAuthority
    @test System() isa TaskAuthority
end

@testset "owner_of derives ownership from the id" begin
    @test owner_of("user-a::export_42") == "user-a"
    # A :user *key* may contain the delimiter; the first occurrence is the split.
    @test owner_of("user-a::a::b") == "user-a"
    # The rival parse here is owner "alice:", which `Owner` cannot construct.
    @test owner_of("alice:::report") == "alice"
    # :global ids are stored verbatim and have no owner half.
    @test owner_of("export_42") === nothing
    # Not producible by the API, but must fail closed rather than yield "".
    @test owner_of("::x") === nothing
    @test owner_of("") === nothing

    # The round trip, and the equivalence the SQL pre-filter in the PormG store
    # depends on: `owner_of(id) == u` iff `startswith(id, u * "::")`.
    for (key, uid) in [("export_42", "user-a"), ("a::b", "user-a"), (":report", "alice"),
                       ("report", "google:12345")]
        id = scoped_task_key(key, Owner(uid))
        @test owner_of(id) == uid
        @test startswith(id, uid * "::")
    end
end

@testset "ownership comes from the id, watchers only add to it" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        # A :user task: the owner is derivable from the id, so emptying `watchers`
        # cannot revoke it. That is the authorization half of #88 — a lost append,
        # or a full-row write from another process, can no longer evict an owner
        # from their own task.
        uid = submit_task("report", () -> "secret", Owner("alice"); runtime=rt_store)
        info = get_task_info(store, uid)
        empty!(info.watchers)
        set_task!(store, uid, info)

        @test isempty(get_task_info(store, uid).watchers)
        @test get_task_status(uid, Owner("alice"); runtime=rt_store)[:id] == uid
        @test get_task_status(uid, Owner("alice"); runtime=rt_store)[:owner] == "alice"
        @test is_not_found(get_task_status(uid, Owner("mallory"); runtime=rt_store))
        # It still lists for its owner, with no watcher entry backing that up.
        @test length(get_all_tasks(Owner("alice"); runtime=rt_store)) == 1

        # A :global task has no owner half, so `watchers` remains the whole gate and
        # emptying it authorizes nobody — including the submitter. The asymmetry is
        # deliberate: B adds an authority source for :user ids, it removes none.
        gid = submit_task("shared", () -> "x", Owner("gus"); scope=:global, runtime=rt_store)
        @test owner_of(gid) === nothing
        ginfo = get_task_info(store, gid)
        empty!(ginfo.watchers)
        set_task!(store, gid, ginfo)

        @test is_not_found(get_task_status(gid, Owner("gus"); runtime=rt_store))
        @test get_task_status(gid, System(); runtime=rt_store)[:id] == gid
        @test isempty(get_all_tasks(Owner("gus"); runtime=rt_store))
    finally
        reset_runtime!(rt_store)
    end
end

@testset "get_all_tasks returns owned and granted tasks, and nothing else" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        mine = submit_task("mine", () -> "a", Owner("alice"); runtime=rt_store)
        theirs = submit_task("theirs", () -> "b", Owner("bob"); runtime=rt_store)
        # A :global task alice is a watcher of but does not own.
        shared = submit_task("shared", () -> "c", Owner("carol"); scope=:global, runtime=rt_store)
        info = get_task_info(store, shared)
        push!(info.watchers, "alice")
        set_task!(store, shared, info)

        ids = Set(t[:id] for t in get_all_tasks(Owner("alice"); runtime=rt_store))
        @test ids == Set([mine, shared])       # owned by prefix, granted by watchers
        @test !(theirs in ids)
        @test Set(t[:id] for t in get_all_tasks(Owner("bob"); runtime=rt_store)) == Set([theirs])
        @test length(get_all_tasks(System(); runtime=rt_store)) == 3
    finally
        reset_runtime!(rt_store)
    end
end

@testset "scoped_task_key resolves and validates the stored id" begin
    @test scoped_task_key("export_42", Owner("user-a")) == "user-a::export_42"
    @test scoped_task_key("export_42", Owner("user-a"); scope=:user) == "user-a::export_42"
    @test scoped_task_key("export_42", Owner("user-a"); scope=:global) == "export_42"

    # A :user task key may contain the delimiter; the owner may not, or
    # ("a", "::b") and ("a::", "b") would resolve to the same id. The owner half is
    # now rejected by `Owner` on construction, so it can never reach this function.
    @test scoped_task_key("a::b", Owner("user-a")) == "user-a::a::b"

    # An owner ending in ':' is the one remaining collision: without this rule
    # (":report", "alice") and ("report", "alice:") both give "alice:::report".
    @test scoped_task_key(":report", Owner("alice")) == "alice:::report"
    # A colon elsewhere in the owner is still legal and stays unambiguous.
    @test scoped_task_key("report", Owner("google:12345")) == "google:12345::report"

    # A :global key may not contain it at all, or it could forge a :user id:
    # global "victim::export_42" is exactly what victim's own "export_42" resolves to.
    @test_throws ArgumentError scoped_task_key("victim::export_42", Owner("attacker"); scope=:global)
    @test scoped_task_key("victim::export_42", Owner("attacker")) == "attacker::victim::export_42"

    @test_throws ArgumentError scoped_task_key("export_42", Owner("user-a"); scope=:tenant)

    # The submit paths route through it, including the validation.
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        @test submit_task("k", () -> 1, Owner("u"); scope=:global, runtime=rt_store) == "k"
        @test_throws ArgumentError submit_task("k3", () -> 1, Owner("u"); scope=:tenant, runtime=rt_store)
        @test_throws ArgumentError submit_sequential_task("q", "k4", () -> 1, Owner("u"); scope=:tenant, runtime=rt_store)

        # A global submit cannot squat a user-scoped id.
        @test_throws ArgumentError submit_task("victim::k5", () -> 1, Owner("attacker"); scope=:global, runtime=rt_store)
        @test_throws ArgumentError submit_sequential_task("q", "victim::k6", () -> 1, Owner("attacker"); scope=:global, runtime=rt_store)
    finally
        reset_runtime!(rt_store)
    end
end

@testset "Sequential submits share the cross-user gate (#19)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store; queues = ["reports"])
    release = Base.Event()

    try
        owner_id = submit_sequential_task("reports", "nightly-rollup", task_info -> begin
            wait(release)
            return "owner-result"
        end, Owner("owner"); scope=:global, runtime=rt_store)
        @test owner_id == "nightly-rollup"

        @test_throws AuthorizationError submit_sequential_task(
            "reports", "nightly-rollup", () -> "noop", Owner("attacker"); scope=:global, runtime=rt_store)

        notify(release)
        @test wait_for(() -> get_task_status(owner_id, Owner("owner"); runtime=rt_store)[:status] == "COMPLETED") == :ok
        @test get_task_status(owner_id, Owner("owner"); runtime=rt_store)[:result] == "owner-result"
        @test is_not_found(get_task_status(owner_id, Owner("attacker"); runtime=rt_store))

        # Terminal state is gated on the sequential path too.
        @test_throws AuthorizationError submit_sequential_task(
            "reports", "nightly-rollup", () -> "noop", Owner("attacker"); scope=:global, runtime=rt_store)
    finally
        notify(release)
        reset_runtime!(rt_store)
    end
end

@testset "User-scoped keys isolate same-key submissions across users (#19)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    a_calls = Ref(0)
    b_calls = Ref(0)
    release = Base.Event()

    try
        # Both users submit the SAME caller-supplied key.
        a_id = submit_task("export_report_42", () -> begin
            a_calls[] += 1
            wait(release)
            return "victim-secret"
        end, Owner("user-a"); runtime=rt_store)

        b_id = submit_task("export_report_42", () -> begin
            b_calls[] += 1
            wait(release)
            return "attacker-data"
        end, Owner("user-b"); runtime=rt_store)

        @test a_id == "user-a::export_report_42"
        @test b_id == "user-b::export_report_42"
        @test a_id != b_id

        # Two independent tasks: no deduplication across users, so both run.
        notify(release)
        @test wait_for(() -> get_task_status(a_id, Owner("user-a"); runtime=rt_store)[:status] == "COMPLETED") == :ok
        @test wait_for(() -> get_task_status(b_id, Owner("user-b"); runtime=rt_store)[:status] == "COMPLETED") == :ok
        @test a_calls[] == 1
        @test b_calls[] == 1

        # Neither user became a watcher of the other's task.
        @test get_task_status(a_id, Owner("user-a"); runtime=rt_store)[:watcher_count] == 1
        @test get_task_status(b_id, Owner("user-b"); runtime=rt_store)[:watcher_count] == 1

        # The escalation the issue reports: reading and cancelling across users.
        @test get_task_status(a_id, Owner("user-a"); runtime=rt_store)[:result] == "victim-secret"
        @test is_not_found(get_task_status(a_id, Owner("user-b"); runtime=rt_store))
        @test is_not_found(cancel_task(a_id, Owner("user-b"); runtime=rt_store))
    finally
        notify(release)
        reset_runtime!(rt_store)
    end
end

@testset "Global-scoped keys refuse cross-user join and reuse (#19)" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    release = Base.Event()
    attacker_calls = Ref(0)

    try
        owner_id = submit_task("shared-export", () -> begin
            wait(release)
            return "victim-secret"
        end, Owner("victim"); scope=:global, runtime=rt_store)
        @test owner_id == "shared-export"

        # Case 1 — the task is live. Joining it would hand over read/cancel rights.
        @test_throws AuthorizationError submit_task("shared-export", () -> begin
            attacker_calls[] += 1
            return "noop"
        end, Owner("attacker"); scope=:global, runtime=rt_store)

        # The refused submit left no trace on the victim's task.
        @test get_task_status(owner_id, Owner("victim"); runtime=rt_store)[:watcher_count] == 1
        @test is_not_found(get_task_status(owner_id, Owner("attacker"); runtime=rt_store))
        @test is_not_found(cancel_task(owner_id, Owner("attacker"); runtime=rt_store))

        notify(release)
        @test wait_for(() -> get_task_status(owner_id, Owner("victim"); runtime=rt_store)[:status] == "COMPLETED") == :ok

        # Case 2 — the task is finished. Re-running the key would overwrite the
        # owner's stored result and drop them from the watcher list.
        @test_throws AuthorizationError submit_task("shared-export", () -> begin
            attacker_calls[] += 1
            return "noop"
        end, Owner("attacker"); scope=:global, runtime=rt_store)

        after = get_task_status(owner_id, Owner("victim"); runtime=rt_store)
        @test after[:status] == "COMPLETED"
        @test after[:result] == "victim-secret"
        @test after[:watcher_count] == 1
        @test attacker_calls[] == 0

        # The owner may still re-run their own finished key.
        again = submit_task("shared-export", () -> "second-run", Owner("victim"); scope=:global, runtime=rt_store)
        @test again == owner_id
        @test wait_for(() -> get_task_status(owner_id, Owner("victim"); runtime=rt_store)[:result] == "second-run") == :ok
    finally
        notify(release)
        reset_runtime!(rt_store)
    end
end

@testset "Watch authorizer opts back into cross-user sharing" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    release = Base.Event()
    seen = Ref{Any}(nothing)

    set_watch_authorizer!(store, (task_key, watchers, user_id) -> begin
        seen[] = (task_key, watchers, user_id)
        return user_id == "teammate"
    end)

    try
        owner_id = submit_task("team-export", () -> begin
            wait(release)
            return "shared-result"
        end, Owner("owner"); scope=:global, runtime=rt_store)

        # Denied: the hook says no.
        @test_throws AuthorizationError submit_task("team-export", () -> "noop", Owner("stranger"); scope=:global, runtime=rt_store)
        @test seen[] == ("team-export", ["owner"], "stranger")

        # Allowed: the hook says yes, so the teammate joins as a watcher and
        # deduplicates onto the running task rather than starting a second one.
        joined = submit_task("team-export", () -> error("must not run"), Owner("teammate"); scope=:global, runtime=rt_store)
        @test joined == owner_id

        notify(release)
        @test wait_for(() -> get_task_status(owner_id, Owner("owner"); runtime=rt_store)[:status] == "COMPLETED") == :ok

        status = get_task_status(owner_id, Owner("teammate"); runtime=rt_store)
        @test status[:result] == "shared-result"
        @test status[:watcher_count] == 2
        @test is_not_found(get_task_status(owner_id, Owner("stranger"); runtime=rt_store))

        # The hook is not consulted for a user who already watches the task.
        seen[] = nothing
        @test submit_task("team-export", () -> "re-run", Owner("owner"); scope=:global, runtime=rt_store) == owner_id
        @test seen[] === nothing

        # Re-running a finished key REPLACES the record, so the watcher list resets to
        # the submitter and previously-authorized sharers are evicted. Documented on
        # set_watch_authorizer! — asserted here so the behavior cannot drift silently.
        @test wait_for(() -> get_task_status(owner_id, Owner("owner"); runtime=rt_store)[:result] == "re-run") == :ok
        @test get_task_status(owner_id, Owner("owner"); runtime=rt_store)[:watcher_count] == 1
        @test is_not_found(get_task_status(owner_id, Owner("teammate"); runtime=rt_store))
    finally
        notify(release)
        reset_runtime!(rt_store)
    end
end

@testset "submit_task is subject to the queue authorizer under DEFAULT_QUEUE_NAME" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    calls = Ref(Tuple{String, String}[])

    set_queue_authorizer!(store, (queue_name, user_id) -> begin
        push!(calls[], (queue_name, user_id))
        return user_id == "allowed"
    end)

    try
        @test DEFAULT_QUEUE_NAME == "default"

        ok_id = submit_task("job", () -> "ran", Owner("allowed"); runtime=rt_store)
        @test ok_id == "allowed::job"
        @test wait_for(() -> get_task_status(ok_id, Owner("allowed"); runtime=rt_store)[:status] == "COMPLETED") == :ok

        @test_throws AuthorizationError submit_task("job", () -> "ran", Owner("denied"); runtime=rt_store)

        # The denied submission never reached the store.
        @test get_task_status("denied::job", System(); runtime=rt_store)[:status] == "NOT_FOUND"

        @test calls[] == [(DEFAULT_QUEUE_NAME, "allowed"), (DEFAULT_QUEUE_NAME, "denied")]
    finally
        reset_runtime!(rt_store)
    end
end

@testset "Zombie task recovery on startup" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)

    try
        # Setup a running task that has NO live execution handle
        lock(store.task_lock) do
            t1 = TaskInfo("zombie-running")
            t1.status = RUNNING
            t1.created_at = Dates.now(Dates.UTC)
            store.task_registry[t1.id] = t1

            # And a running task that DOES have a live execution handle (should NOT be recovered)
            t2 = TaskInfo("active-running")
            t2.status = RUNNING
            t2.created_at = Dates.now(Dates.UTC)
            store.task_registry[t2.id] = t2

            # Register in-memory active task
            rt_store.active_tasks[t2.id] = @async sleep(0.05)
        end

        # Run recovery
        recovered_count = recover_zombie_tasks!(; runtime=rt_store)
        @test recovered_count == 1

        # Test zombie is marked FAILED
        zombie_status = get_task_status("zombie-running", System(); runtime=rt_store)
        @test zombie_status[:status] == "FAILED"
        @test zombie_status[:error] == "Worker process terminated unexpectedly mid-execution."
        @test zombie_status[:completed_at] isa DateTime

        # Test active running task is untouched
        active_status = get_task_status("active-running", System(); runtime=rt_store)
        @test active_status[:status] == "RUNNING"

        # Cleanup active task
        wait(rt_store.active_tasks["active-running"])
    finally
        reset_runtime!(rt_store)
    end
end

@testset "the recovery scan is an optional store method with a working default (#236)" begin
    started = DateTime(2026, 1, 2, 3, 4, 5)
    seed_rows!(store_rows) = begin
        running = TaskInfo("scan-running"); running.status = RUNNING; running.started_at = started
        pending = TaskInfo("scan-pending")
        done = TaskInfo("scan-done"); done.status = COMPLETED
        for t in (running, pending, done)
            store_rows[t.id] = t
        end
        running
    end

    # The in-memory backend implements it, and reports only RUNNING records, with the run id
    # the fenced transition is addressed to and the start time.
    mem = InMemoryWorkerStore()
    running = lock(() -> seed_rows!(mem.task_registry), mem.task_lock)
    @test Nitro.Core.Errors.implements_contract_method(list_running_task_refs, InMemoryWorkerStore, AbstractWorkerStore, 1)
    @test list_running_task_refs(mem) == [RunningTaskRef((running.id, running.run_id, started))]

    # A backend that never heard of it still conforms, and still recovers: the default reads the
    # listing. Adding it as a REQUIRED row would have broken every third-party store for a method
    # whose whole purpose is an optimization.
    legacy = DataOnlyStore()
    legacy_running = seed_rows!(legacy.rows)
    @test isempty(missing_store_methods(DataOnlyStore))
    @test !(:list_running_task_refs in [nameof(f) for (f, _) in Nitro.Workers.WORKER_STORE_INTERFACE])
    @test !Nitro.Core.Errors.implements_contract_method(list_running_task_refs, DataOnlyStore, AbstractWorkerStore, 1)
    @test list_running_task_refs(legacy) == [RunningTaskRef((legacy_running.id, legacy_running.run_id, started))]
    @test recover_zombie_tasks!(; runtime=WorkerRuntime(legacy)) == 1
    @test legacy.rows["scan-running"].status == FAILED
end

@testset "listings and the recovery scan page by keyset on the id (#237)" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store)
    owner = Owner("alice")
    try
        lock(store.task_lock) do
            # Inserted out of order, so a page that came back in Dict order would show it.
            for (id, watchers, status) in (("alice::3", ["alice"], RUNNING), ("a-global", ["alice"], PENDING),
                                           ("bob::1", ["bob"], RUNNING), ("alice::1", String[], RUNNING),
                                           ("alice~w", ["carol", "alice"], RUNNING), ("alice::2", ["alice"], RUNNING))
                t = TaskInfo(id)
                append!(t.watchers, watchers)
                t.status = status
                store.task_registry[id] = t
            end
        end
        expected = ["a-global", "alice::1", "alice::2", "alice::3", "alice~w"]

        walk(fetch, limit) = begin
            ids, after = String[], nothing
            while true
                page = fetch(after, limit)
                @test length(page) <= limit
                append!(ids, page)
                length(page) < limit && return ids
                after = last(page)
            end
        end

        for limit in (1, 2, 5)
            # The store, the runtime, and the public Dict API page identically. Paging is applied
            # after the authority gate, so bob's task never takes a slot in a page.
            @test walk((a, n) -> [t.id for t in get_all_tasks(store, owner; after=a, limit=n)], limit) == expected
            @test walk((a, n) -> [t.id for t in get_all_tasks(rt, owner; after=a, limit=n)], limit) == expected
            @test walk((a, n) -> [t[:id] for t in get_all_tasks(owner; runtime=rt, after=a, limit=n)], limit) == expected
        end
        # Unpaged keeps its contract: everything, sorted by created_at rather than by id.
        @test sort([t[:id] for t in get_all_tasks(owner; runtime=rt)]) == expected
        @test_throws ArgumentError get_all_tasks(owner; runtime=rt, limit=0)

        # The scan pages the same way, over RUNNING only and with no authority.
        @test walk((a, n) -> [r.id for r in list_running_task_refs(store; after=a, limit=n)], 2) ==
              ["alice::1", "alice::2", "alice::3", "alice~w", "bob::1"]

        # Recovery walks the backlog one record at a time and still reaches all of it.
        @test recover_zombie_tasks!(; runtime=rt, batch_size=1) == 5
        @test isempty(list_running_task_refs(store))
        @test_throws ArgumentError recover_zombie_tasks!(; runtime=rt, batch_size=0)
    finally
        reset_runtime!(rt)
    end

    # A store written before paging existed keeps every UNPAGED call: the runtime only forwards
    # the keywords when one is set. Recovery over it pages through the default scan, which hands
    # back the whole remainder in one page, and still reaches every row.
    legacy = DataOnlyStore()
    for i in 1:3
        t = TaskInfo("legacy::$i"); t.status = RUNNING
        legacy.rows[t.id] = t
    end
    rt_legacy = WorkerRuntime(legacy)
    @test length(get_all_tasks(rt_legacy, System())) == 3
    @test_throws MethodError get_all_tasks(rt_legacy, System(); limit=1)
    @test recover_zombie_tasks!(; runtime=rt_legacy, batch_size=1) == 3

    # The default scan's FIRST page is id-ordered too, not the store's Dict order: the sweep's
    # cursor is that page's last id, so an unsorted page makes the cursor arbitrary, and the next
    # page re-reads rows already adjudicated and still RUNNING, counting them twice. Twenty ids,
    # so a Dict order cannot pass by luck.
    many = DataOnlyStore()
    ids = ["many::$(lpad(i, 2, '0'))" for i in 1:20]
    for id in ids
        t = TaskInfo(id); t.status = RUNNING
        many.rows[id] = t
    end
    @test [r.id for r in list_running_task_refs(many; limit=1)] == ids
end

@testset "the zombie sweep always says it ran, and what it did (#238)" begin
    record(logs, msg) = filter(r -> r.message == msg, logs)
    SCAN = "Nitro.Workers: scanning for zombie tasks"
    DONE = "Nitro.Workers: zombie recovery complete"

    # Nothing to recover is exactly the case that used to be silent, and so exactly the one a
    # hung boot could not be told apart from.
    logs, n = Test.collect_test_logs() do
        recover_zombie_tasks!(; runtime=WorkerRuntime(InMemoryWorkerStore()))
    end
    @test n == 0
    @test length(record(logs, SCAN)) == 1
    done = only(record(logs, DONE))
    @test done.level == Base.CoreLogging.Info
    @test done.kwargs[:recovered] == 0
    @test done.kwargs[:candidates] == 0
    @test findfirst(r -> r.message == SCAN, logs) < findfirst(r -> r.message == DONE, logs)

    # Every counter, and no task payload. The sentinel sits in exactly the two fields the issue
    # names, `result` and `error`, on a record the sweep reads and transitions.
    sentinel = "zombie-secret-7c1e"
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store)
    live = @async sleep(0.05)
    try
        lock(store.task_lock) do
            for (id, started) in (("log::zombie", nothing), ("log::zombie2", nothing),
                                  ("log::live", nothing), ("log::young", Dates.now(Dates.UTC)))
                t = TaskInfo(id)
                t.status = RUNNING
                t.started_at = started
                t.result = Dict("token" => sentinel)
                t.error = "partial: $sentinel"
                store.task_registry[id] = t
            end
        end
        Nitro.Workers.register_active_task!(rt, "log::live", live)

        logs, n = Test.collect_test_logs() do
            recover_zombie_tasks!(; runtime=rt, zombie_min_age=Dates.Hour(1), batch_size=3)
        end
        @test n == 2
        done = only(record(logs, DONE))
        @test done.kwargs[:candidates] == 4
        @test done.kwargs[:recovered] == 2
        @test done.kwargs[:spared_live] == 1
        @test done.kwargs[:too_recent] == 1
        @test done.kwargs[:lost_race] == 0
        @test !any(r -> occursin(sentinel, string(r.message, " ", r.kwargs)), logs)
    finally
        wait(live)
        reset_runtime!(rt)
    end
end

@testset "a retention tick that retired rows says so (#238)" begin
    store = InMemoryWorkerStore()
    lock(store.task_lock) do
        expired = TaskInfo("retire-me")
        expired.status = COMPLETED
        expired.completed_at = Dates.now(Dates.UTC) - Dates.Day(10)
        store.task_registry[expired.id] = expired
    end
    rt = WorkerRuntime(store)
    sink = Test.TestLogger()
    try
        # Started under the sink, so the spawned scheduler inherits it. `TestLogger` takes no lock,
        # so its log vector is read only once the scheduler has STOPPED: reading it while the
        # scheduler task may still push is a data race at two threads. The line is written in the
        # same tick as the delete, and `stop_cleanup_scheduler!` joins the task, so both are done
        # by the time it returns.
        Base.CoreLogging.with_logger(() -> start_cleanup_scheduler(; interval_hours=0.00005, retain_days=7, runtime=rt), sink)
        @test wait_for(() -> get_task_info(store, "retire-me") === nothing) == :ok
        stop_cleanup_scheduler!(rt)
        done(r) = r.message == "Nitro.Workers: task retention sweep complete" && r.level == Base.CoreLogging.Info
        line = only(filter(done, sink.logs))
        @test line.kwargs[:deleted] == 1
        @test line.kwargs[:retain_days] == 7
    finally
        reset_runtime!(rt)
    end
end

@testset "a write that throws mid-sweep is logged with the tally, then rethrown (#238)" begin
    # Delegates everything to an in-memory store except the transition, which throws -- the shape
    # of a connection dropped on the UPDATE.
    struct ThrowingTransitionStore <: AbstractWorkerStore
        inner::InMemoryWorkerStore
    end
    Nitro.Workers.lock_tasks(f::Function, s::ThrowingTransitionStore) = Nitro.Workers.lock_tasks(f, s.inner)
    Nitro.Workers.list_running_task_refs(s::ThrowingTransitionStore; kw...) =
        Nitro.Workers.list_running_task_refs(s.inner; kw...)
    Nitro.Workers.try_transition!(::ThrowingTransitionStore, ::String, from, ::TaskStatus; run_id, kw...) =
        error("simulated connection drop on the transition")

    inner = InMemoryWorkerStore()
    lock(inner.task_lock) do
        t = TaskInfo("throws::1"); t.status = RUNNING
        inner.task_registry[t.id] = t
    end
    rt = WorkerRuntime(ThrowingTransitionStore(inner))
    logs, threw = Test.collect_test_logs() do
        try
            recover_zombie_tasks!(; runtime=rt)
            false
        catch e
            occursin("simulated connection drop", sprint(showerror, e))
        end
    end
    @test threw
    failed = only(filter(r -> r.message == "Nitro.Workers: zombie recovery failed mid-sweep", logs))
    @test failed.level == Base.CoreLogging.Error
    @test failed.kwargs[:candidates] == 1
    @test failed.kwargs[:recovered] == 0
    @test isempty(filter(r -> r.message == "Nitro.Workers: zombie recovery complete", logs))
end

# #266. With `zombie_min_age` set, the boot sweep defers claims younger than the window, and
# before this nothing ever came back for them: the sweep ran only at `start!`. The retention tick
# now re-runs the bounded sweep. Every scheduler below ticks every ~0.2s (`timedwait`'s poll floor
# is 0.1s). A sink is read only AFTER `stop_cleanup_scheduler!` has joined the task, per the #238
# retention test above: `TestLogger` takes no lock.
const _ZOMBIE_TICK_HOURS = 0.00005
const _ZOMBIE_DONE = "Nitro.Workers: zombie recovery complete"
const _ZOMBIE_SCAN = "Nitro.Workers: scanning for zombie tasks"
const _ZOMBIE_ERROR = "Worker process terminated unexpectedly mid-execution."

function _seed!(store::InMemoryWorkerStore, id::String, status::TaskStatus;
                started_at=nothing, completed_at=nothing, result=nothing)
    lock(store.task_lock) do
        t = TaskInfo(id)
        t.status = status
        t.started_at = started_at
        t.completed_at = completed_at
        t.result = result
        store.task_registry[id] = t
    end
end

# The expired COMPLETED row is the tick-proof: retention deletes it on the same tick, and AFTER
# the zombie sweep, so once it is gone at least one whole tick -- sweep included -- has run.
_seed_expired!(store, id) =
    _seed!(store, id, COMPLETED; completed_at=Dates.now(Dates.UTC) - Dates.Day(10))

@testset "the retention tick recovers a claim the boot sweep deferred as too recent (#266)" begin
    sentinel = "periodic-zombie-secret-4b2d"
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store)
    # Claimed just now, so no sweep may touch it yet -- exactly what a crash followed by a quick
    # restart leaves behind.
    _seed!(store, "tick::young", RUNNING; started_at=Dates.now(Dates.UTC), result=Dict("token" => sentinel))
    # Old enough, but this runtime holds its handle: a live run, and it must stay RUNNING.
    _seed!(store, "tick::live", RUNNING; started_at=Dates.now(Dates.UTC) - Dates.Hour(1))
    Nitro.Workers.register_active_task!(rt, "tick::live", @async nothing)
    sink = Test.TestLogger()
    try
        # The boot sweep defers it; nothing about this test depends on a boot having run.
        @test recover_zombie_tasks!(; runtime=rt, zombie_min_age=Dates.Second(3)) == 0
        @test get_task_info(store, "tick::young").status == RUNNING

        Base.CoreLogging.with_logger(sink) do
            start_cleanup_scheduler(; interval_hours=_ZOMBIE_TICK_HOURS, retain_days=7,
                                    zombie_min_age=Dates.Second(3), runtime=rt)
        end
        @test wait_for(() -> get_task_info(store, "tick::young").status == FAILED; timeout=10.0) == :ok
        stop_cleanup_scheduler!(rt)

        young = get_task_info(store, "tick::young")
        @test young.error == _ZOMBIE_ERROR
        @test young.completed_at !== nothing
        @test get_task_info(store, "tick::live").status == RUNNING

        # Quiet like retention: no @info scan line on a tick, and the @info completion line only
        # from the tick that recovered something. Counts, never the record's payload.
        @test isempty(filter(r -> r.message == _ZOMBIE_SCAN, sink.logs))
        done = filter(r -> r.message == _ZOMBIE_DONE, sink.logs)
        @test length(done) == 1
        @test only(done).level == Base.CoreLogging.Info
        @test only(done).kwargs[:recovered] == 1
        @test only(done).kwargs[:spared_live] == 1
        @test !any(r -> occursin(sentinel, string(r.message, " ", r.kwargs)), sink.logs)
    finally
        reset_runtime!(rt)
    end
end

@testset "a periodic tick that recovers nothing logs nothing at @info (#266)" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store)
    _seed!(store, "quiet::young", RUNNING; started_at=Dates.now(Dates.UTC))
    _seed_expired!(store, "quiet::expired")
    sink = Test.TestLogger()
    try
        Base.CoreLogging.with_logger(sink) do
            start_cleanup_scheduler(; interval_hours=_ZOMBIE_TICK_HOURS, retain_days=7,
                                    zombie_min_age=Dates.Hour(1), runtime=rt)
        end
        @test wait_for(() -> get_task_info(store, "quiet::expired") === nothing) == :ok
        stop_cleanup_scheduler!(rt)
        @test get_task_info(store, "quiet::young").status == RUNNING
        @test !any(r -> r.message in (_ZOMBIE_SCAN, _ZOMBIE_DONE), sink.logs)
    finally
        reset_runtime!(rt)
    end
end

@testset "without zombie_min_age the retention tick never sweeps zombies (#266)" begin
    # An unbounded sweep on a timer would fail another process's live runs on every tick, so the
    # tick sweeps only with a bound. This row is handle-less and a day old: any sweep would take it.
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store)
    _seed!(store, "unbounded::old", RUNNING; started_at=Dates.now(Dates.UTC) - Dates.Day(1))
    _seed_expired!(store, "unbounded::expired")
    try
        start_cleanup_scheduler(; interval_hours=_ZOMBIE_TICK_HOURS, retain_days=7, runtime=rt)
        @test wait_for(() -> get_task_info(store, "unbounded::expired") === nothing) == :ok
        stop_cleanup_scheduler!(rt)
        @test get_task_info(store, "unbounded::old").status == RUNNING
    finally
        reset_runtime!(rt)
    end
end

@testset "start! wires the periodic sweep only when recover_zombies is on (#266)" begin
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())

    # On: the boot sweep defers the young claim, and the tick recovers it once it ages past the
    # window. 3s, not 1s: the RUNNING precondition must survive a first compile of `start!`.
    store = InMemoryWorkerStore()
    ctx = Nitro.Core.App()
    _seed!(store, "start::young", RUNNING; started_at=Dates.now(Dates.UTC))
    try
        quiet() do
            start!(ctx; store, cleanup_interval_hours=_ZOMBIE_TICK_HOURS, zombie_min_age=Dates.Second(3))
        end
        @test get_task_info(store, "start::young").status == RUNNING
        @test wait_for(() -> get_task_info(store, "start::young").status == FAILED; timeout=10.0) == :ok
    finally
        uninstall!(ctx)
    end

    # Off: `recover_zombies = false` means no sweep at all, the periodic half included.
    store = InMemoryWorkerStore()
    ctx = Nitro.Core.App()
    _seed!(store, "start::old", RUNNING; started_at=Dates.now(Dates.UTC) - Dates.Day(1))
    _seed_expired!(store, "start::expired")
    try
        quiet() do
            start!(ctx; store, cleanup_interval_hours=_ZOMBIE_TICK_HOURS,
                   recover_zombies=false, zombie_min_age=Dates.Second(1))
        end
        @test wait_for(() -> get_task_info(store, "start::expired") === nothing) == :ok
        stop_cleanup_scheduler!(worker_runtime(ctx))
        @test get_task_info(store, "start::old").status == RUNNING
    finally
        uninstall!(ctx)
    end
end

@testset "a periodic sweep that throws costs that tick's sweep, not retention or the scheduler (#266)" begin
    # `ThrowingTransitionStore` is the #238 testset's: every transition throws. Retention delegates.
    Nitro.Workers.cleanup_tasks!(s::ThrowingTransitionStore, days::Int) = Nitro.Workers.cleanup_tasks!(s.inner, days)
    inner = InMemoryWorkerStore()
    _seed!(inner, "tick-throws::1", RUNNING)   # no `started_at`: always eligible
    _seed_expired!(inner, "tick-throws::expired")
    rt = WorkerRuntime(ThrowingTransitionStore(inner))
    sink = Test.TestLogger()
    try
        scheduler = Base.CoreLogging.with_logger(sink) do
            start_cleanup_scheduler(; interval_hours=_ZOMBIE_TICK_HOURS, retain_days=7,
                                    zombie_min_age=Dates.Second(0), runtime=rt)
        end
        @test wait_for(() -> get_task_info(inner, "tick-throws::expired") === nothing) == :ok
        @test !istaskdone(scheduler.task)
        stop_cleanup_scheduler!(rt)
        @test get_task_info(inner, "tick-throws::1").status == RUNNING
        # Logged ONCE per tick, with the tally: the periodic sweep absorbs the write failure it
        # has just logged, rather than rethrowing it for the tick to log a second time.
        failed = filter(r -> r.message == "Nitro.Workers: zombie recovery failed mid-sweep", sink.logs)
        @test !isempty(failed)
        @test all(r -> r.level == Base.CoreLogging.Error && r.kwargs[:candidates] == 1, failed)
        @test isempty(filter(r -> r.message == "Nitro.Workers: periodic zombie sweep failed", sink.logs))
    finally
        # Not `reset_runtime!`: this store implements only what the two sweeps reach.
        stop_cleanup_scheduler!(rt)
    end
end

@testset "start_cleanup_scheduler refuses a negative zombie_min_age at the call (#266)" begin
    rt = WorkerRuntime(InMemoryWorkerStore())
    @test_throws ArgumentError start_cleanup_scheduler(; zombie_min_age=Dates.Second(-1), runtime=rt)
    @test get_cleanup_scheduler(rt)[] === nothing
end

@testset "cancel_task is atomic: completed task result is never overwritten" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        # Regression: cancel_task used to read status outside the task lock,
        # so a concurrent _complete_task! could overwrite COMPLETED→CANCELLED.
        task_id = submit_task("race-task", () -> "safe-result", Owner("user"); runtime=rt_store)
        @test wait_for(() -> get_task_status(task_id, Owner("user"); runtime=rt_store)[:status] == "COMPLETED") == :ok

        # Cancelling an already-completed task must return an error, not overwrite the result.
        result = cancel_task(task_id, Owner("user"); runtime=rt_store)
        @test haskey(result, :error)

        final = get_task_status(task_id, Owner("user"); runtime=rt_store)
        @test final[:status] == "COMPLETED"
        @test final[:result] == "safe-result"
    finally
        reset_runtime!(rt_store)
    end
end

@testset "terminal state fields are consistent: error and completed_at visible with status" begin
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        # Regression: _fail_task! and _cancel_task! used to write status before error/completed_at,
        # so concurrent readers could observe status=FAILED with error=nothing.
        task_id = submit_task("fail-task", () -> error("boom"), Owner("user"); runtime=rt_store)
        @test wait_for(() -> get_task_status(task_id, Owner("user"); runtime=rt_store)[:status] == "FAILED"; timeout=10.0) == :ok

        status = get_task_status(task_id, Owner("user"); runtime=rt_store)
        @test status[:error] !== nothing
        @test occursin("boom", status[:error])
        @test status[:completed_at] !== nothing
    finally
        reset_runtime!(rt_store)
    end

    store2 = InMemoryWorkerStore()
    rt_store2 = WorkerRuntime(store2)
    started = Base.Event()
    try
        task_id2 = submit_task("cancel-fields-task", task_info -> begin
            notify(started)
            while !cancel_requested(task_info); sleep(0.01); end
        end, Owner("user"); runtime=rt_store2)

        wait(started)
        cancel_task(task_id2, Owner("user"); runtime=rt_store2)
        @test wait_for(() -> get_task_status(task_id2, Owner("user"); runtime=rt_store2)[:status] == "CANCELLED") == :ok

        status2 = get_task_status(task_id2, Owner("user"); runtime=rt_store2)
        @test status2[:error] !== nothing
        @test status2[:completed_at] !== nothing
    finally
        reset_runtime!(rt_store2)
    end
end

@testset "concurrent cancel and task completion: always reaches a consistent terminal state" begin
    # Stress test for the TOCTOU race between cancel_task and _complete_task!.
    # Without the lock_tasks fix both could write to the same task, leaving it
    # CANCELLED with result=nothing even though the callback completed.
    store = InMemoryWorkerStore()
    rt_store = WorkerRuntime(store)
    try
        for trial in 1:30
            reset_runtime!(rt_store)
            gate = Base.Event()

            task_id = submit_task("race-$(trial)", () -> begin
                notify(gate)
                sleep(0.001)
                return "result-$(trial)"
            end, Owner("user"); runtime=rt_store)

            wait(gate)
            cancel_task(task_id, Owner("user"); runtime=rt_store)

            # Let either path finish.
            wait_for(() -> get_task_status(task_id, Owner("user"); runtime=rt_store)[:status] in ("COMPLETED", "CANCELLED"))

            final = get_task_status(task_id, Owner("user"); runtime=rt_store)
            @test final[:status] in ("COMPLETED", "CANCELLED")
            if final[:status] == "COMPLETED"
                @test final[:result] == "result-$(trial)"
            else
                @test final[:error] !== nothing
                @test final[:completed_at] !== nothing
            end
        end
    finally
        reset_runtime!(rt_store)
    end
end

@testset "a worker run does not inherit the submitter's dynamic scope (#209)" begin
    # `Threads.@spawn` inherits the spawning task's `ScopedValue` bindings. PormG tracks
    # transaction state in one, so a task submitted inside `run_in_transaction` used to run its
    # run-start write -- before any callback code -- on the submitter's transaction connection,
    # and kept writing on it after the block committed and returned it to the pool.
    #
    # Everything here is backend-agnostic by construction: the hazard is the spawn, not the
    # store, and an app on `InMemoryWorkerStore` whose callback queries PormG had it too.
    # `test/extensions/pormg_worker_tests.jl` carries the PormG-specific proof.

    @testset "the control: a plain Threads.@spawn DOES inherit" begin
        # Without this, every assertion below would pass just as well against an unpatched
        # `_spawn_detached` that did nothing -- `:outer` is also what you see when no scope
        # was ever opened. This is the assertion that makes the rest mean something.
        inherited = with(_SCOPE_PROBE => :inner) do
            fetch(Threads.@spawn _SCOPE_PROBE[])
        end
        @test inherited === :inner
    end

    @testset "_spawn_detached drops the scope and nothing else" begin
        detached = with(_SCOPE_PROBE => :inner) do
            fetch(Nitro.Workers._spawn_detached(() -> _SCOPE_PROBE[]))
        end
        @test detached === :outer

        # Parity with `Threads.@spawn` on every other axis. `_spawn_detached` reaches two Base
        # internals -- the `Task.scope` setter and `Threads._spawn_set_thrpool` -- and a bare
        # `Task` does NOT land in the `:default` pool on its own, so this is the assertion that
        # goes red if either moves, instead of worker runs quietly migrating pools.
        probe = Nitro.Workers._spawn_detached(() -> nothing)
        reference = Threads.@spawn nothing
        wait(probe); wait(reference)
        @test Threads.threadpool(probe) === Threads.threadpool(reference) === :default
        @test probe.sticky === reference.sticky === false
    end

    @testset "the LOGGER survives the detach, because it is scope-carried too" begin
        # `Base.CoreLogging.CURRENT_LOGSTATE` is a `ScopedValue`, so a blanket detach would
        # also cut a run off from any `with_logger(...)` its submitter was inside — every
        # worker `@warn` and `@error` silently lost for an app that configures logging that
        # way. A logger is not a pooled resource, so there was never a reason to drop it; the
        # connection state is what had to go. Three testsets in this file failed exactly this
        # way before the logstate was carried across.
        sink = Test.TestLogger()
        got = Base.CoreLogging.with_logger(sink) do
            fetch(Nitro.Workers._spawn_detached() do
                @warn "from a detached run"
                return _SCOPE_PROBE[]
            end)
        end

        # The scope is still gone...
        @test got === :outer
        # ...but the log reached the submitter's logger.
        @test any(r -> occursin("from a detached run", string(r.message)), sink.logs)
    end

    @testset "_schedule_detached drops the scope and keeps @async's stickiness" begin
        detached = with(_SCOPE_PROBE => :inner) do
            fetch(Nitro.Workers._schedule_detached(() -> _SCOPE_PROBE[]))
        end
        @test detached === :outer

        probe = Nitro.Workers._schedule_detached(() -> nothing)
        reference = @async nothing
        wait(probe); wait(reference)
        @test probe.sticky === reference.sticky === true
    end

    @testset "submit_task" begin
        rt = WorkerRuntime(InMemoryWorkerStore())
        try
            seen = Channel{Symbol}(1)
            id = with(_SCOPE_PROBE => :inner) do
                submit_task("scope-async", () -> (put!(seen, _SCOPE_PROBE[]); "done"),
                            Owner("user-1"); runtime=rt)
            end
            @test wait_for(() -> isready(seen)) == :ok
            @test take!(seen) === :outer
            @test wait_for(() -> get_task_status(id, Owner("user-1"); runtime=rt)[:status] == "COMPLETED") == :ok
        finally
            reset_runtime!(rt)
        end
    end

    @testset "the FIRST submit_sequential_task into an unstarted queue" begin
        # This submit is the one that spawns the queue's processor (`_start_queue_processor`),
        # so before #209 it pinned a PROCESS-LIFETIME task in one caller's scope -- and every
        # item that queue ever ran afterwards inherited it, whoever submitted them.
        rt = WorkerRuntime(InMemoryWorkerStore(); queues = ["reports"])
        try
            @test isempty(get_sequential_queues(rt))       # nothing spawned yet
            seen = Channel{Symbol}(2)
            with(_SCOPE_PROBE => :inner) do
                submit_sequential_task("reports", "scope-seq-1",
                                       () -> (put!(seen, _SCOPE_PROBE[]); nothing),
                                       Owner("user-1"); runtime=rt)
            end
            @test wait_for(() -> isready(seen)) == :ok
            @test take!(seen) === :outer

            # ...and a later item on that same processor is unaffected too.
            submit_sequential_task("reports", "scope-seq-2",
                                   () -> (put!(seen, _SCOPE_PROBE[]); nothing),
                                   Owner("user-2"); runtime=rt)
            @test wait_for(() -> isready(seen)) == :ok
            @test take!(seen) === :outer
        finally
            reset_runtime!(rt)
        end
    end

    @testset "a processor spawned by start! inside a scope" begin
        app = Nitro.Core.App()
        rt = WorkerRuntime(InMemoryWorkerStore())
        try
            with(_SCOPE_PROBE => :inner) do
                start!(app; queues=["reports"], cleanup_enabled=false,
                       recover_zombies=false, runtime=rt)
            end
            seen = Channel{Symbol}(1)
            # Submitted from OUTSIDE the scope: only the processor could carry it in.
            submit_sequential_task("reports", "scope-started",
                                   () -> (put!(seen, _SCOPE_PROBE[]); nothing),
                                   Owner("user-1"); runtime=rt)
            @test wait_for(() -> isready(seen)) == :ok
            @test take!(seen) === :outer
        finally
            reset_runtime!(rt)
        end
    end

    @testset "the cleanup scheduler" begin
        # `start!` is the call an app makes from its bootstrap, which may well be inside a
        # transaction; the scheduler it spawns then issues a store DELETE on every tick for the
        # life of the process.
        rt = WorkerRuntime(ScopeProbeStore())
        try
            with(_SCOPE_PROBE => :inner) do
                start_cleanup_scheduler(interval_hours=0, retain_days=1, runtime=rt)
            end
            @test wait_for(() -> isready(rt.store.seen); timeout=10.0) == :ok
            @test take!(rt.store.seen) === :outer
        finally
            stop_cleanup_scheduler!(rt)
        end
    end
end


@testset "#323: a denial is a 403, and a foreign task reads exactly like a missing one" begin
    app = App(mod = @__MODULE__)
    store = InMemoryWorkerStore()
    install!(app; store = store)
    set_queue_authorizer!(store, (queue, uid) -> uid != "mallory")
    gate = Channel{Nothing}(1)

    urlpatterns(app, "",
        path("/submit", function (req)
            q = getquery(req)
            id = submit_task(app, q["key"], () -> (take!(gate); "done"), Owner(q["uid"]))
            return Res.json(Dict("id" => id))
        end),
        # The corrected tutorial recipe: NOT_FOUND is a 404, whoever's task it is.
        path("/status", function (req)
            q = getquery(req)
            s = get_task_status(app, q["id"], Owner(q["uid"]))
            s[:status] == "NOT_FOUND" && return Res.json(Dict("error" => "unknown task"); status = 404)
            return Res.json(s)
        end),
    )
    get_(target) = internalrequest(app, HTTP.Request("GET", target))

    try
        # Refused by the queue authorizer: a 403 with a fixed body, never a 500.
        denied = get_("/submit?uid=mallory&key=probe")
        @test denied.status == 403
        @test JSON.parse(Nitro.text(denied)) == Dict("message" => "403: Forbidden")

        ok = get_("/submit?uid=alice&key=payroll")
        @test ok.status == 200
        alice_id = JSON.parse(Nitro.text(ok))["id"]
        @test alice_id == "alice::payroll"

        # The oracle, closed: bob probing alice's real id and a made-up id cannot tell them apart.
        foreign = get_("/status?uid=bob&id=$(HTTP.escapeuri(alice_id))")
        missing_id = get_("/status?uid=bob&id=$(HTTP.escapeuri("alice::nothing-here"))")
        @test foreign.status == missing_id.status == 404
        @test Nitro.text(foreign) == Nitro.text(missing_id)
        @test get_("/status?uid=alice&id=$(HTTP.escapeuri(alice_id))").status == 200

        # Same for cancel, and a foreign cancel changes nothing.
        rt = worker_runtime(app)
        @test is_not_found(cancel_task(alice_id, Owner("bob"); runtime = rt))
        @test is_not_found(cancel_task("alice::nothing-here", Owner("bob"); runtime = rt))
        @test get_task_status(alice_id, Owner("alice"); runtime = rt)[:status] in ("PENDING", "RUNNING")
    finally
        put!(gate, nothing)
        uninstall!(app; drain_timeout = 5)
    end
end

@testset "#323: a grant on a NEW :global key is checked against the submitter, not an empty list" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store)
    org = Dict("alice" => "acme", "bob" => "acme", "eve" => "evil")
    try
        # The documented shape. On an empty list `first(watchers)` threw BoundsError -> a 500.
        set_watch_authorizer!(store, (key, watchers, uid) -> org[first(watchers)] == org[uid])
        gid = submit_task("team-report", () -> "ok", Owner("alice"); scope = :global,
                          watchers = [Owner("bob")], runtime = rt)
        @test wait_for(() -> get_task_status(gid, Owner("bob"); runtime = rt)[:status] == "COMPLETED") == :ok

        # An `all(...)` hook was VACUOUSLY TRUE on the empty list, so a cross-org grant passed.
        set_watch_authorizer!(store, (key, watchers, uid) -> all(w -> org[w] == org[uid], watchers))
        @test_throws AuthorizationError submit_task("team-report-2", () -> "ok", Owner("alice");
                                                    scope = :global, watchers = [Owner("eve")], runtime = rt)
        # ...and a refused submit wrote nothing.
        @test is_not_found(get_task_status("team-report-2", System(); runtime = rt))
    finally
        reset_runtime!(rt)
    end
end

@testset "#323: release_task! reclaims a finished task, admin-only and run-fenced" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store)
    gate = Channel{Nothing}(1)
    try
        # A squatted :global key: alice ran it first, so bob is refused until retention runs.
        gid = submit_task("warm-price-cache", () -> "alice's", Owner("alice"); scope = :global, runtime = rt)
        @test wait_for(() -> get_task_status(gid, System(); runtime = rt)[:status] == "COMPLETED") == :ok
        @test_throws AuthorizationError submit_task("warm-price-cache", () -> "bob's", Owner("bob");
                                                    scope = :global, runtime = rt)

        # Admin only, by dispatch.
        @test_throws MethodError release_task!(gid, Owner("alice"); runtime = rt)

        @test release_task!(gid, System(); runtime = rt) == Dict{Symbol, Any}(:status => "Task released")
        @test is_not_found(get_task_status(gid, System(); runtime = rt))
        @test is_not_found(release_task!(gid, System(); runtime = rt))

        # The key is free again: bob's submit now creates it, and bob can read it.
        @test submit_task("warm-price-cache", () -> "bob's", Owner("bob"); scope = :global, runtime = rt) == gid
        @test wait_for(() -> get_task_status(gid, Owner("bob"); runtime = rt)[:status] == "COMPLETED") == :ok
        @test get_task_status(gid, Owner("bob"); runtime = rt)[:result] == "bob's"

        # An unfinished task is refused, and left alone.
        running = submit_task("slow", () -> (take!(gate); "slow"), Owner("carol"); runtime = rt)
        refused = release_task!(running, System(); runtime = rt)
        @test occursin("cancel it", refused[:error])
        @test get_task_status(running, Owner("carol"); runtime = rt)[:status] in ("PENDING", "RUNNING")

        # The fence itself: a delete addressed to another run removes nothing.
        record = get_task_info(store, gid)
        @test !try_delete_task!(store, gid, (COMPLETED,); run_id = Nitro.Workers.uuid4())
        @test !try_delete_task!(store, gid, (PENDING,); run_id = record.run_id)
        @test get_task_info(store, gid) !== nothing
        @test try_delete_task!(store, gid, (COMPLETED,); run_id = record.run_id)
        @test get_task_info(store, gid) === nothing
    finally
        put!(gate, nothing)
        reset_runtime!(rt)
    end
end

@testset "#323: a successor's durable grant does not authorize a live predecessor" begin
    # Two runtimes over one store: rt1 still hosts alice's cancelled-but-running run while rt2
    # re-runs the key for bob. Bob is authorized on the SUCCESSOR's record only, so reading
    # through rt1 must serve him the successor -- never alice's run on bob's grant.
    store = InMemoryWorkerStore()
    rt1 = WorkerRuntime(store)
    rt2 = WorkerRuntime(store)
    gate = Channel{Nothing}(1)
    set_watch_authorizer!(store, (key, watchers, uid) -> uid == "bob")
    try
        gid = submit_task("shared-job", () -> (take!(gate); "alice's"), Owner("alice");
                          scope = :global, runtime = rt1)
        @test wait_for(() -> get_active_task_info(rt1, gid) !== nothing) == :ok
        @test cancel_task(gid, Owner("alice"); runtime = rt1)[:status] == "Task cancelled"

        @test submit_task("shared-job", () -> "bob's", Owner("bob"); scope = :global, runtime = rt2) == gid
        @test wait_for(() -> get_task_status(gid, Owner("bob"); runtime = rt2)[:status] == "COMPLETED") == :ok
        # rt1 still holds alice's live object, a different run.
        @test get_active_task_info(rt1, gid) !== nothing
        @test get_active_task_info(rt1, gid).run_id != get_task_info(store, gid).run_id

        seen = get_task_status(gid, Owner("bob"); runtime = rt1)
        @test seen[:status] == "COMPLETED"
        @test seen[:result] == "bob's"

        # Alice is authorized on the live predecessor, and is still served HER run.
        @test get_task_status(gid, Owner("alice"); runtime = rt1)[:status] == "CANCELLED"

        # The listing path, under the same rule: listing through rt1 must not overlay alice's live
        # run onto bob's record -- on this store that overlay OVERWROTE the stored record.
        listed = only(get_all_tasks(Owner("bob"); runtime = rt1))
        @test listed[:status] == "COMPLETED"
        @test get_task_info(store, gid).status == COMPLETED
        @test get_task_info(store, gid).result == "bob's"
    finally
        put!(gate, nothing)
        reset_runtime!(rt1)
        reset_runtime!(rt2)
    end
end


@testset "#322: an App with no runtime is refused, never served by the process-wide one" begin
    app = App(mod = @__MODULE__)
    @test worker_runtime(app) === nothing
    # Every App-first form refuses; none of them reaches `default_runtime()`, which carries none
    # of the app's policy -- no queue authorizer, no redactor, no retention.
    @test_throws WorkerUnavailableError submit_task(app, "k", () -> 1, Owner("u"))
    @test_throws WorkerUnavailableError submit_sequential_task(app, "q", "k", () -> 1, Owner("u"))
    @test_throws WorkerUnavailableError get_task_status(app, "u::k", Owner("u"))
    @test_throws WorkerUnavailableError cancel_task(app, "u::k", Owner("u"))
    @test_throws WorkerUnavailableError release_task!(app, "k", System())
    @test_throws WorkerUnavailableError get_all_tasks(app, Owner("u"))
    @test_throws WorkerUnavailableError get_queue_status(app, "q", System())
    @test_throws WorkerUnavailableError cleanup_old_tasks(app)
    @test_throws WorkerUnavailableError recover_zombie_tasks!(app)
    @test_throws WorkerUnavailableError start_cleanup_scheduler(app)
    # ...and nothing landed in the default runtime's store on the way.
    @test get_task_info(default_store(), "u::k") === nothing

    # Over HTTP: a 503 with a fixed body, never the fallback.
    urlpatterns(app, "", path("/submit", req -> Res.json(Dict("id" => submit_task(app, "k", () -> 1, Owner("u"))))))
    r = internalrequest(app, HTTP.Request("GET", "/submit"))
    @test r.status == 503
    @test JSON.parse(Nitro.text(r)) == Dict("message" => "503: Service Unavailable")
end

@testset "#322: worker_startup installs the runtime when it is built, before serve opens the listener" begin
    app = App(mod = @__MODULE__)
    store = InMemoryWorkerStore()
    set_queue_authorizer!(store, (queue, uid) -> uid != "mallory")
    lifecycle = worker_startup(app; store = store, queues = ["reports"], cleanup_enabled = false,
                               recover_zombies = false)
    try
        # Installed already -- the startup window a request could land in before `on_startup`
        # runs is covered by the app's own runtime and so by its own policy.
        rt = worker_runtime(app)
        @test rt isa WorkerRuntime
        @test worker_store(app) === store
        @test_throws AuthorizationError submit_task(app, "purge", () -> "ran", Owner("mallory"))
        @test get_task_info(default_store(), "mallory::purge") === nothing

        # `on_startup` starts THAT runtime; it does not mint a second one.
        lifecycle.on_startup()
        @test worker_runtime(app) === rt
        @test get_queue_status(app, "reports", System())[:running] == true

        # A second serve after terminate re-installs the same runtime, policy included.
        lifecycle.on_shutdown()
        @test worker_runtime(app) === nothing
        lifecycle.on_startup()
        @test worker_runtime(app) === rt
        @test_throws AuthorizationError submit_task(app, "purge", () -> "ran", Owner("mallory"))
    finally
        uninstall!(app; drain_timeout = 0)
    end
end

@testset "#322: a startup misconfiguration fails at build time and installs nothing" begin
    app = App(mod = @__MODULE__)
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(InMemoryWorkerStore())
    @test_throws ArgumentError startup(app; store = store, runtime = rt)
    @test worker_runtime(app) === nothing
    @test_throws ArgumentError startup(app; zombie_min_age = Dates.Minute(-1))
    @test worker_runtime(app) === nothing
    # Refused before the install too: installed, it could never be torn down (`uninstall!` would
    # throw on it from `on_shutdown`).
    @test_throws ArgumentError startup(app; drain_timeout = -1)
    @test worker_runtime(app) === nothing
end

@testset "#322: bare worker_startup shares default_runtime() with the bare task API" begin
    ctx = Nitro.CONTEXT[]
    previous = worker_runtime(ctx)
    @test previous === nothing || previous === default_runtime()
    lifecycle = worker_startup(; queues = String[], cleanup_enabled = false, recover_zombies = false)
    try
        # The bare startup and a bare `submit_task` now resolve to ONE runtime, so policy set
        # on `default_store()` is the policy both see.
        @test worker_runtime(ctx) === default_runtime()

        # A backend the bare task API could never see is refused, not silently split off.
        @test_throws ArgumentError worker_startup(; store = InMemoryWorkerStore())
        @test_throws ArgumentError worker_startup(; runtime = WorkerRuntime(InMemoryWorkerStore()))
        @test worker_runtime(ctx) === default_runtime()
    finally
        lifecycle.on_shutdown()
    end
    @test worker_runtime(ctx) === nothing

    # A different runtime already installed on CONTEXT[] is refused rather than shut down.
    other = install!(ctx; store = InMemoryWorkerStore())
    try
        @test_throws ArgumentError worker_startup()
        @test worker_runtime(ctx) === other
    finally
        uninstall!(ctx; drain_timeout = 0)
    end
end


# Reservations are what #324's limits read; every test below ends by checking they are all back.
capacity_idle(rt) = isempty(rt.reservations) && isempty(rt.owner_runs) && rt.async_runs[] == 0

@testset "#324: the runtime-wide cap refuses a submit before anything is written" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store; max_concurrent_runs = 2)
    gate = Channel{Nothing}(10)
    try
        a = submit_task("a", () -> take!(gate), Owner("u1"); runtime = rt)
        b = submit_task("b", () -> take!(gate), Owner("u2"); runtime = rt)
        @test rt.async_runs[] == 2

        err = try
            submit_task("c", () -> "never", Owner("u3"); runtime = rt); nothing
        catch e
            e
        end
        @test err isa WorkerCapacityError && err.kind === :runtime
        @test get_task_info(store, "u3::c") === nothing          # nothing written
        @test rt.async_runs[] == 2

        # Joining a live run is not a new run, and costs nothing.
        @test submit_task("a", () -> "dup", Owner("u1"); runtime = rt) == a

        put!(gate, nothing); put!(gate, nothing)
        @test wait_for(() -> get_task_status(a, System(); runtime = rt)[:status] == "COMPLETED" &&
                             get_task_status(b, System(); runtime = rt)[:status] == "COMPLETED") == :ok
        @test wait_for(() -> capacity_idle(rt)) == :ok
        c = submit_task("c", () -> "ran", Owner("u3"); runtime = rt)
        @test wait_for(() -> get_task_status(c, System(); runtime = rt)[:status] == "COMPLETED") == :ok
        @test wait_for(() -> capacity_idle(rt)) == :ok
    finally
        foreach(_ -> isready(gate) || put!(gate, nothing), 1:4)
        reset_runtime!(rt)
    end
    @test_throws ArgumentError WorkerRuntime(InMemoryWorkerStore(); max_concurrent_runs = 0)
    @test_throws ArgumentError WorkerCapacityError(:elsewhere, "x")
end

@testset "#324: a refused submit does not supersede the run it would have replaced" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store; max_concurrent_runs = 1)
    gate = Channel{Nothing}(1)
    try
        id = submit_task("job", () -> take!(gate), Owner("u"); runtime = rt)
        @test wait_for(() -> get_active_task_info(rt, id) !== nothing) == :ok
        live = get_active_task_info(rt, id)
        # Cancelled, but the callback ignores the token, so it still holds the only slot.
        @test cancel_task(id, Owner("u"); runtime = rt)[:status] == "Task cancelled"
        @test_throws WorkerCapacityError submit_task("job", () -> "again", Owner("u"); runtime = rt)
        @test cancel_reason(live) === :user                     # not :superseded
        @test get_task_info(store, id).run_id == live.run_id    # the record was not replaced
    finally
        put!(gate, nothing)
        @test wait_for(() -> capacity_idle(rt)) == :ok
        reset_runtime!(rt)
    end
end

@testset "#324: the per-owner quota counts both paths and is a 429" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store; max_runs_per_owner = 2, queues = ["q"])
    gate = Channel{Nothing}(10)
    try
        submit_task("a1", () -> take!(gate), Owner("alice"); runtime = rt)
        submit_sequential_task("q", "a2", () -> take!(gate), Owner("alice"); runtime = rt)
        err = try
            submit_task("a3", () -> "never", Owner("alice"); runtime = rt); nothing
        catch e
            e
        end
        @test err isa WorkerCapacityError && err.kind === :owner
        @test_throws WorkerCapacityError submit_sequential_task("q", "a4", () -> "never", Owner("alice"); runtime = rt)
        # Another owner is unaffected.
        bob = submit_task("b1", () -> "bob", Owner("bob"); runtime = rt)
        @test wait_for(() -> get_task_status(bob, Owner("bob"); runtime = rt)[:status] == "COMPLETED") == :ok
    finally
        foreach(_ -> put!(gate, nothing), 1:2)
        @test wait_for(() -> capacity_idle(rt)) == :ok
        reset_runtime!(rt)
    end
end

@testset "#324: a full queue refuses at once instead of blocking the submitter" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store; queues = ["small"])
    # White-box: a two-slot queue, put in place before its first use.
    get_sequential_queues(rt)["small"] = SequentialQueue(2)
    gate = Channel{Nothing}(10)
    try
        first = submit_sequential_task("small", "k1", () -> take!(gate), Owner("u"); runtime = rt)
        # The processor TOOK the first item, so its slot is free again: two more fit.
        @test wait_for(() -> get_task_status(first, System(); runtime = rt)[:status] == "RUNNING") == :ok
        submit_sequential_task("small", "k2", () -> take!(gate), Owner("u"); runtime = rt)
        submit_sequential_task("small", "k3", () -> take!(gate), Owner("u"); runtime = rt)

        started = time()
        err = try
            submit_sequential_task("small", "k4", () -> "never", Owner("u"); runtime = rt); nothing
        catch e
            e
        end
        @test time() - started < 2.0                              # refused, not parked in put!
        @test err isa WorkerCapacityError && err.kind === :queue
        @test get_task_info(store, "u::k4") === nothing

        foreach(_ -> put!(gate, nothing), 1:3)
        @test wait_for(() -> all(k -> get_task_status("u::$k", System(); runtime = rt)[:status] == "COMPLETED",
                                 ("k1", "k2", "k3")); timeout = 10.0) == :ok
        @test wait_for(() -> capacity_idle(rt) && (@atomic get_sequential_queues(rt)["small"].reserved) == 0) == :ok
    finally
        foreach(_ -> isready(gate) || put!(gate, nothing), 1:4)
        reset_runtime!(rt)
    end
end

@testset "#324: only declared queue names get a queue" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store; queues = ["reports"])
    try
        @test_throws AuthorizationError submit_sequential_task("made-up-name", "k", () -> 1, Owner("u"); runtime = rt)
        @test !haskey(get_sequential_queues(rt), "made-up-name")    # no queue, no processor
        ok = submit_sequential_task("reports", "k", () -> "ok", Owner("u"); runtime = rt)
        @test wait_for(() -> get_task_status(ok, System(); runtime = rt)[:status] == "COMPLETED") == :ok

        # `start!` declares what it starts; `reset_runtime!` goes back to the constructor's set.
        app = App(mod = @__MODULE__)
        start!(app; runtime = rt, queues = ["imports"], cleanup_enabled = false, recover_zombies = false)
        imp = submit_sequential_task(app, "imports", "k", () -> "ok", Owner("u"))
        @test wait_for(() -> get_task_status(app, imp, System())[:status] == "COMPLETED") == :ok
        uninstall!(app; drain_timeout = 0)
        reset_runtime!(rt)
        @test_throws AuthorizationError submit_sequential_task("imports", "k2", () -> 1, Owner("u"); runtime = rt)
    finally
        reset_runtime!(rt)
    end

    # The opt-out.
    open_rt = WorkerRuntime(InMemoryWorkerStore(); allow_undeclared_queues = true)
    try
        id = submit_sequential_task("anything", "k", () -> "ok", Owner("u"); runtime = open_rt)
        @test wait_for(() -> get_task_status(id, System(); runtime = open_rt)[:status] == "COMPLETED") == :ok
    finally
        reset_runtime!(open_rt)
    end
end

@testset "#324: a timed-out callback keeps its slot until it actually returns" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store; max_concurrent_runs = 1, queues = ["q"])
    gate = Channel{Nothing}(2)
    try
        # Ignores the token: the deadline ends the wait, not the work.
        id = submit_task("slow", () -> take!(gate), Owner("u"); runtime = rt,
                         options = TaskOptions(timeout = 1))
        @test wait_for(() -> get_task_status(id, System(); runtime = rt)[:status] == "FAILED"; timeout = 10.0) == :ok
        # The record is terminal, but the callback still holds a thread -- and so the slot.
        @test rt.async_runs[] == 1
        @test_throws WorkerCapacityError submit_task("next", () -> "x", Owner("u"); runtime = rt)

        put!(gate, nothing)
        @test wait_for(() -> capacity_idle(rt)) == :ok
        nxt = submit_task("next", () -> "x", Owner("u"); runtime = rt)
        @test wait_for(() -> get_task_status(nxt, System(); runtime = rt)[:status] == "COMPLETED") == :ok

        # The sequential path hands the OWNER's reservation over the same way.
        qid = submit_sequential_task("q", "slowq", () -> take!(gate), Owner("v"); runtime = rt,
                                     options = TaskOptions(timeout = 1))
        @test wait_for(() -> get_task_status(qid, System(); runtime = rt)[:status] == "FAILED"; timeout = 10.0) == :ok
        @test get(rt.owner_runs, "v", 0) == 1
        put!(gate, nothing)
        @test wait_for(() -> capacity_idle(rt)) == :ok
    finally
        foreach(_ -> isready(gate) || put!(gate, nothing), 1:2)
        reset_runtime!(rt)
    end
end

@testset "#324: every other exit gives the reservation back" begin
    store = InMemoryWorkerStore()
    rt = WorkerRuntime(store; queues = ["q"])
    gate = Channel{Nothing}(10)
    try
        # Failure.
        f = submit_task("fails", () -> error("boom"), Owner("u"); runtime = rt)
        @test wait_for(() -> get_task_status(f, System(); runtime = rt)[:status] == "FAILED") == :ok
        @test wait_for(() -> capacity_idle(rt)) == :ok

        # Cancelled while queued, so the run is declined at its claim.
        head = submit_sequential_task("q", "head", () -> take!(gate), Owner("u"); runtime = rt)
        @test wait_for(() -> get_task_status(head, System(); runtime = rt)[:status] == "RUNNING") == :ok
        queued = submit_sequential_task("q", "queued", () -> "never", Owner("u"); runtime = rt)
        @test cancel_task(queued, Owner("u"); runtime = rt)[:status] == "Task cancelled"
        put!(gate, nothing)
        @test wait_for(() -> capacity_idle(rt)) == :ok

        # Abandoned by a teardown while still buffered.
        head2 = submit_sequential_task("q", "head2", () -> take!(gate), Owner("u"); runtime = rt)
        @test wait_for(() -> get_task_status(head2, System(); runtime = rt)[:status] == "RUNNING") == :ok
        submit_sequential_task("q", "buffered", () -> "never", Owner("u"); runtime = rt)
        shutdown!(rt; drain_timeout = 0)
        @test get_task_status("u::buffered", System(); runtime = rt)[:status] == "CANCELLED"
        @test get(rt.owner_runs, "u", 0) == 1          # only head2, still running
        put!(gate, nothing)
        @test wait_for(() -> capacity_idle(rt)) == :ok
    finally
        foreach(_ -> isready(gate) || put!(gate, nothing), 1:4)
        reset_runtime!(rt)
    end
end

@testset "#324: capacity refusals over HTTP are a 503, a quota a 429, an undeclared queue a 403" begin
    app = App(mod = @__MODULE__)
    rt = WorkerRuntime(InMemoryWorkerStore(); max_concurrent_runs = 1, max_runs_per_owner = 1,
                       queues = ["q"])
    install!(app, rt)
    gate = Channel{Nothing}(4)
    urlpatterns(app, "",
        path("/async", function (req)
            q = getquery(req)
            return Res.json(Dict("id" => submit_task(app, q["key"], () -> take!(gate), Owner(q["uid"]))))
        end),
        path("/queue", function (req)
            q = getquery(req)
            return Res.json(Dict("id" => submit_sequential_task(app, q["queue"], q["key"], () -> "ok", Owner(q["uid"]))))
        end),
    )
    get_(target) = internalrequest(app, HTTP.Request("GET", target))
    try
        @test get_("/async?uid=alice&key=one").status == 200
        busy = get_("/async?uid=bob&key=two")          # runtime cap of 1
        @test busy.status == 503
        @test JSON.parse(Nitro.text(busy)) == Dict("message" => "503: Service Unavailable")
        quota = get_("/queue?uid=alice&queue=q&key=three")   # alice's one run is live
        @test quota.status == 429
        @test JSON.parse(Nitro.text(quota)) == Dict("message" => "429: Too Many Requests")
        @test get_("/queue?uid=carol&queue=nope&key=four").status == 403
    finally
        put!(gate, nothing)
        uninstall!(app; drain_timeout = 5)
    end
end

end
