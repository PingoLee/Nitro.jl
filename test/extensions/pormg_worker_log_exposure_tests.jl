@testitem "worker logs never carry a store's live database error (#651)" tags=[:extension, :pormg, :workers, :security] setup=[NitroCommon] begin

using Test
using Dates
using Nitro
using Nitro.Workers
using Nitro.Workers: lock_tasks, try_transition!, cleanup_tasks!, list_running_task_refs
import PormG

# #646 gave `PormGWorkerStore`'s own warnings the `loggable` shape, and then rethrew. Every caller
# in `src/Workers` logged what it caught as the live exception, so the `PormG.DatabaseError` reached
# the log one frame up. On PostgreSQL its `.cause` is LibPQ's error, which holds the server's
# DETAIL line, and a constraint violation's DETAIL quotes the row. This is that error, with
# sentinels where the row's owner, key and arguments would be.
const DETAIL = "duplicate key value violates unique constraint \"nitro_task_pkey\"\n" *
               "DETAIL:  Key (id)=(S3NT1NEL-owner::job) already exists.\n" *
               "DETAIL:  Failing row contains (S3NT1NEL-owner::job, {\"card\":\"S3NT1NEL-arg\"})."
db_error() = PormG.IntegrityError("postgresql", ErrorException(DETAIL); sqlstate = "23505",
                                  constraint = "nitro_task_pkey", table = "nitro_task",
                                  message = "duplicate key value violates unique constraint")

# Everything a structured sink could write: the message, the kwargs as `show`n, and the exception
# under `showerror` and `dump`.
function rendered(l)
    out = string(l.message, sprint(show, l.kwargs))
    ex = get(l.kwargs, :exception, nothing)
    ex isa Tuple && (ex = ex[1])
    ex isa Exception && (out *= sprint(showerror, ex) * sprint(dump, ex))
    return out
end

# An `InMemoryWorkerStore` whose listed operations throw `db_error()`. `fail` holds `:read`
# (`list_running_task_refs`), `:cleanup` (`cleanup_tasks!`), or a `TaskStatus`, which fails every
# `try_transition!` TO it -- so a run's own claim and completion still go through.
mutable struct LeakyStore <: AbstractWorkerStore
    inner :: InMemoryWorkerStore
    fail  :: Set{Any}
    calls :: Threads.Atomic{Int}
end
LeakyStore(fail...) = LeakyStore(InMemoryWorkerStore(), Set{Any}(fail), Threads.Atomic{Int}(0))

function _failing!(s::LeakyStore, what)
    what in s.fail || return nothing
    Threads.atomic_add!(s.calls, 1)
    throw(db_error())
end

for f in (:get_task_info, :set_task!, :replace_task!, :add_watcher!, :delete_task!,
          :try_delete_task!, :get_all_tasks, :get_queue_authorizer, :set_queue_authorizer!,
          :get_error_redactor, :set_error_redactor!, :get_watch_authorizer,
          :set_watch_authorizer!)
    @eval Nitro.Workers.$f(s::LeakyStore, args...; kw...) = Nitro.Workers.$f(s.inner, args...; kw...)
end
Nitro.Workers.clear_records!(s::LeakyStore) = Nitro.Workers.clear_records!(s.inner)
Nitro.Workers.lock_tasks(f::Function, s::LeakyStore) = lock_tasks(f, s.inner)
function Nitro.Workers.list_running_task_refs(s::LeakyStore; kw...)
    _failing!(s, :read)
    return list_running_task_refs(s.inner; kw...)
end
function Nitro.Workers.cleanup_tasks!(s::LeakyStore, retain_days::Int)
    _failing!(s, :cleanup)
    return cleanup_tasks!(s.inner, retain_days)
end
function Nitro.Workers.try_transition!(s::LeakyStore, task_id::String, from, to::TaskStatus; kw...)
    _failing!(s, to)
    return try_transition!(s.inner, task_id, from, to; kw...)
end

function seed_running!(s::LeakyStore, id::String)
    lock(s.inner.task_lock) do
        t = TaskInfo(id)
        t.status = RUNNING
        s.inner.task_registry[id] = t
    end
end

# `TestLogger` takes no lock of its own on reads, and a teardown's or a scheduler's records are
# written from other tasks: copy under its lock.
records(logger) = lock(() -> copy(logger.logs), logger.lock)

# The record named `message` exists, carries a `LoggedException` of the original's type name, and
# no record at all quotes the row.
function check(logs, message)
    hits = filter(l -> occursin(message, string(l.message)), logs)
    @test !isempty(hits)
    for record in hits
        ex = record.kwargs[:exception]
        logged = ex isa Tuple ? ex[1] : ex
        @test logged isa Nitro.Errors.LoggedException
        logged isa Nitro.Errors.LoggedException || continue
        @test logged.type === :IntegrityError
        @test occursin("nitro_task_pkey", logged.text)  # the console text is kept
    end
    @test !any(l -> occursin("S3NT1NEL", rendered(l)), logs)
end

@testset "the live error does quote the row (positive control)" begin
    @test occursin("S3NT1NEL", sprint(dump, db_error()))
    @test !occursin("S3NT1NEL", sprint(showerror, Nitro.Errors.loggable(db_error())))
end

@testset "zombie recovery: a failed read" begin
    store = LeakyStore(:read)
    rt = WorkerRuntime(store)
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Info)
    try
        Base.CoreLogging.with_logger(() -> recover_zombie_tasks!(; runtime = rt), logger)
        @test store.calls[] == 1
        check(records(logger), "zombie recovery could not read the RUNNING tasks")
    finally
        empty!(store.fail)
        reset_runtime!(rt)
    end
end

@testset "zombie recovery: a failed write is logged, then rethrown" begin
    store = LeakyStore(FAILED)
    seed_running!(store, "zombie::1")
    rt = WorkerRuntime(store)
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Info)
    try
        threw = Base.CoreLogging.with_logger(logger) do
            try
                recover_zombie_tasks!(; runtime = rt)
                nothing
            catch e
                e
            end
        end
        @test threw isa PormG.IntegrityError     # the caller still gets the real thing
        check(records(logger), "zombie recovery failed mid-sweep")
    finally
        empty!(store.fail)
        reset_runtime!(rt)
    end
end

@testset "a served app: the startup hook that receives the rethrown error" begin
    # The path a served app takes: `serve` runs the worker middleware's `on_startup`, whose boot
    # sweep logs the failed write and rethrows it into `LifecycleMiddleware`'s `startup`, which
    # logs it a second time. Both records must be safe, not only the sweep's own.
    store = LeakyStore(FAILED)
    seed_running!(store, "zombie::2")
    app = Nitro.Core.App()
    rt = WorkerRuntime(store)
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Info)
    try
        lifecycle = Nitro.Workers.startup(app; runtime = rt, cleanup_enabled = false)
        Base.CoreLogging.with_logger(() -> Nitro.Core.Types.startup(lifecycle), logger)
        @test store.calls[] == 1
        logs = records(logger)
        check(logs, "zombie recovery failed mid-sweep")
        check(logs, "Error in LifecycleMiddleware.on_startup")
        empty!(store.fail)
        Nitro.Core.Types.shutdown(lifecycle)
    finally
        empty!(store.fail)
        reset_runtime!(rt)
    end
end

@testset "teardown: a backlog item that could not be recorded as abandoned" begin
    # The #182 shape: one run holds the processor, one item waits behind it, and `shutdown!`
    # abandons the backlog by a PENDING -> CANCELLED transition, which this store fails.
    store = LeakyStore(CANCELLED)
    rt = WorkerRuntime(store; queues = ["reports"])
    owner = Owner("u")
    entered = Base.Event()
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Info)
    try
        Base.CoreLogging.with_logger(logger) do
            submit_queued_task("reports", "slow", function (task_info)
                notify(entered)
                while !cancel_requested(task_info)
                    sleep(0.01)
                end
                return "stopped"
            end, owner; runtime = rt)
            wait(entered)
            submit_queued_task("reports", "backlog", task_info -> "ran", owner; runtime = rt)
            shutdown!(rt; drain_timeout = 8.0)
        end
        @test store.calls[] >= 1
        check(records(logger), "abandoned but not recorded during teardown")
    finally
        empty!(store.fail)
        reset_runtime!(rt)
    end
end

@testset "the retention tick: a failed sweep" begin
    store = LeakyStore(:cleanup)
    rt = WorkerRuntime(store)
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Info)
    try
        # Started under the logger, so the scheduler's task inherits it.
        Base.CoreLogging.with_logger(logger) do
            start_cleanup_scheduler(; interval_hours = 0.00005, retain_days = 7, runtime = rt)
        end
        @test timedwait(() -> store.calls[] >= 2, 10.0; pollint = 0.05) === :ok
        stop_cleanup_scheduler!(rt)          # joins the task: every record is written
        check(records(logger), "task retention sweep failed")
    finally
        empty!(store.fail)
        reset_runtime!(rt)
    end
end

# The source scan that every `exception=` in `src/` goes through `loggable` is in
# test/middleware/log_exposure_tests.jl (#658): it needs no PormG, and it covers all of `src/`.

end
