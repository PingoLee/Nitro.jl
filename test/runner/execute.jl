# Execution: run collected items sequentially in this process.
#
# Each item gets the module ReTestItems gave it -- a fresh module under `Main`, opening with
# `using Test` and `using Nitro`, then `using` + a `const` alias for each setup it names, then its
# body with every top-level statement in soft scope -- and runs in a `Threads.@spawn` task, which
# is where ReTestItems' worker ran items. Its stdout, stderr and global log stream go to a capture
# file that is printed only when the item does not pass.

# The real stdout, saved before anything is redirected. Progress lines go here, and so does
# anything an item must show on a PASSING run (`precompile_warmth_tests.jl`'s `warmth:` lines):
# an item's own `stdout` is its capture file, which a pass deletes unread.
const REPORT_IO = Ref{IO}()

"""
    report_io()

The stream that reaches the run's output even when the current item passes. Falls back to
`stdout` outside a run.
"""
report_io() = isassigned(REPORT_IO) ? REPORT_IO[] : stdout

# The running item's capture stream, for the watchdog's `flush` request (watchdog.jl).
const CURRENT_CAPTURE = Ref{Union{Nothing,IO}}(nothing)

# Copied from REPL's soft-scope rule, as ReTestItems did: each top-level statement of an item
# behaves as it would at the REPL, so a loop can assign a global the item defined earlier.
function softscope(@nospecialize ex)
    if ex isa Expr
        h = ex.head
        if h === :toplevel
            ex′ = Expr(h)
            map!(softscope, resize!(ex′.args, length(ex.args)), ex.args)
            return ex′
        elseif h in (:meta, :import, :using, :export, :module, :error, :incomplete, :thunk)
            return ex
        elseif h === :global && all(x -> isa(x, Symbol), ex.args)
            return ex
        else
            return Expr(:block, Expr(:softscope, true), ex)
        end
    end
    return ex
end

# `:(module $name end)` builds the `:module` expression in the shape THIS Julia's parser uses,
# so the runner never hard-codes its argument positions (#112). Only the body slot is replaced.
function _module_expr(name::Symbol, body::Expr)
    ex = :(module $name end)
    ex.args[end] = body
    return ex
end

function _imports(imports)
    Any[Expr(:using, Expr(:., m)) for m in imports]
end

mutable struct RunContext
    imports::Vector{Symbol}
    test_end::Union{Nothing,Expr}
    setups::Dict{Symbol,TestSetup}
    evaluated::Dict{Symbol,Module}
    # A setup that threw is not retried: its first failure is recorded on the item that hit it,
    # and every later item that names it errors with this message instead.
    failed::Dict{Symbol,String}
end

struct SetupError <: Exception
    msg::String
end
Base.showerror(io::IO, e::SetupError) = print(io, "SetupError: ", e.msg)

function ensure_setup!(ctx::RunContext, name::Symbol, it::TestItem)
    haskey(ctx.evaluated, name) && return ctx.evaluated[name]
    haskey(ctx.failed, name) && throw(SetupError(ctx.failed[name]))
    ts = get(ctx.setups, name, nothing)
    ts === nothing && throw(SetupError(
        "`@testsetup module $name`, named by `setup=[...]`, was not collected. Setups live in " *
        "test/setup_tests.jl, which test/runtests.jl adds to every run."))
    ex = deepcopy(ts.expr)
    ex.args[end-1] = gensym(name)   # a fresh name in `Main`, as ReTestItems used
    mod = try
        task_local_storage(() -> Core.eval(Main, ex), :SOURCE_PATH, ts.file)
    catch err
        ctx.failed[name] = "`@testsetup module $name` ($(basename(ts.file)):$(ts.line)) threw when " *
                           "test item \"$(it.name)\" first needed it: " * sprint(showerror, err)
        rethrow()
    end
    ctx.evaluated[name] = mod
    return mod
end

function _item_module(ctx::RunContext, it::TestItem, mods)
    body = Expr(:block, _imports(ctx.imports)...)
    for (name, mod) in mods
        push!(body.args, Expr(:using, Expr(:., :Main, nameof(mod))))
        push!(body.args, :(const $name = $mod))
    end
    append!(body.args, deepcopy(it.body).args)
    map!(softscope, body.args, body.args)
    return _module_expr(gensym(it.name), body)
end

# Swallow and report, never rethrow: an exception from the cleanup must not replace the item's
# own result, or the run says the cleanup broke and never which assertion did.
function run_test_end(ctx::RunContext, it::TestItem)
    ctx.test_end === nothing && return nothing
    try
        te = deepcopy(ctx.test_end)
        body = Expr(:block, _imports(ctx.imports)..., (te.head === :block ? te.args : Any[te])...)
        map!(softscope, body.args, body.args)
        Core.eval(Main, _module_expr(gensym(it.name * " test_end"), body))
    catch err
        @error "TEST_END failed after test item $(repr(it.name)); the item's own result stands" exception = (err, catch_backtrace())
    end
    return nothing
end

# Make `ts` the current test set the way `@testset` does, but WITHOUT `@testset`'s reset of the
# global RNG on entry. ReTestItems never reseeded per item either, so an item that draws from
# the default RNG gets a fresh draw rather than the same one as every other item.
function with_testset(f, ts::Test.AbstractTestSet)
    Base.ScopedValues.with(f, Test.CURRENT_TESTSET => ts,
                           Test.TESTSET_DEPTH => Test.get_testset_depth() + 1)
end

# Whether a finished test set, or any set nested in it, holds a `Fail` or an `Error`. Read
# through `get_test_counts`, the documented way to total a test set (the Test manual's "Creating
# Custom AbstractTestSet Types"), not through `DefaultTestSet`'s fields. The four field names
# are pinned in `test/runner_tests.jl`: the `TestCounts` docstring lists the cumulative ones
# under the wrong names.
function _failed(ts::Test.AbstractTestSet)
    tc = Test.get_test_counts(ts)
    return tc.fails + tc.errors + tc.cumulative_fails + tc.cumulative_errors > 0
end

# Redirect stdout and stderr into `io` for `f`, as ReTestItems' `logs = :issues` did. Julia's
# default global logger writes to whatever `stderr` is at the time, so a background task
# started by an earlier item logs into the capture of the item it interrupts. A `ConsoleLogger`
# installed with the original `stderr` would not follow the redirect, so one is swapped for the
# duration -- the same rule ReTestItems applied.
function with_capture(f, io::IO)
    cio = IOContext(io, :color => get(report_io(), :color, false), :displaysize => (10000, 10000))
    old = Base.CoreLogging.global_logger()
    swap = old isa Base.CoreLogging.ConsoleLogger && old.stream === stderr
    swap && Base.CoreLogging.global_logger(Base.CoreLogging.ConsoleLogger(cio, old.min_level))
    CURRENT_CAPTURE[] = io
    try
        redirect_stdio(f; stdout = cio, stderr = cio)
    finally
        CURRENT_CAPTURE[] = nothing
        swap && Base.CoreLogging.global_logger(old)
    end
end

function _progress(msg)
    io = report_io()
    println(io, msg)
    flush(io)
end

# Every item's test set starts the default RNG from this seed, through `@testset`'s `rng`
# option. Fixed rather than `Test`'s default: `@testset` would copy the task's seed, and a fresh
# task falls back to one `Random` draws from entropy once per process -- the same for every item
# of a run, but different in the next run. A red that depends on a draw must reproduce in the
# next process, under the same `--shuffle` seed. Any value would do; changing it changes every
# item's draws.
const ITEM_RNG_SEED = 763

# The item's test set: `@testset` with the item's own file and line as its source, so `Test`
# records an error outside any `@test` -- a throwing setup included -- at the item's `file:line`.
function _item_testset_expr(it::TestItem, body)
    src = LineNumberNode(it.line, Symbol(it.file))
    return Expr(:macrocall, Symbol("@testset"), src,
                Expr(:(=), :rng, Expr(:call, Random.Xoshiro, ITEM_RNG_SEED)),
                it.name, Expr(:block, src, Expr(:call, body)))
end

# Runs one item in its own task, inside its own `@testset`, and returns that test set. An item's
# failure never fails the task: `@testset` records it. What does is what `@testset` passes on --
# an `InterruptException` or a fail-fast stop -- and `fetch` throws it on, as a
# `TaskFailedException`, for `run_items` to end the run with.
function run_item(ctx::RunContext, it::TestItem)
    body = function ()
        # Setups run inside the test set so their errors are the item's, but must not move
        # the item's draws: the first item to need a setup would otherwise start its body
        # further along the stream than every later one.
        state = copy(Random.default_rng())
        mods = Pair{Symbol,Module}[s => ensure_setup!(ctx, s, it) for s in it.setups]
        copy!(Random.default_rng(), state)
        Core.eval(Main, _item_module(ctx, it, mods))
        return nothing
    end
    ex = _item_testset_expr(it, body)
    task = Threads.@spawn task_local_storage(:SOURCE_PATH, it.file) do
        try
            Core.eval(@__MODULE__, ex)
        finally
            # Outside the item's test set: the result is final before the cleanup runs. The
            # current test set here is the file's, so a `@test` in TEST_END would count there,
            # not against the item; `test/runtests.jl`'s has none.
            run_test_end(ctx, it)
        end
    end
    return fetch(task)::Test.AbstractTestSet
end

"""
    run_items(items, setups; imports, test_end, name) -> Int

Run `items` in order and print `Test`'s summary, under a root test set called `name`. Returns
`0` when every item passed, else `1`. Each item's output is captured under
`NITRO_TEST_CAPTURE_DIR` (a fresh temporary directory when unset), next to the events file the
watchdog follows.
"""
function run_items(items::Vector{TestItem}, setups::Dict{Symbol,TestSetup};
                   imports::Vector{Symbol} = [:Test], test_end::Union{Nothing,Expr} = nothing,
                   name::AbstractString = "Tests")
    REPORT_IO[] = stdout
    # Consumed, not just read: a julia that an item starts must not inherit them, or it would
    # take itself for a watched child -- and exit at once, when the orphan guard reads EOF from
    # a stdin nobody holds open.
    pop!(ENV, "NITRO_TEST_WATCHED", "0") == "1" && start_orphan_guard()
    capture_dir = something(pop!(ENV, "NITRO_TEST_CAPTURE_DIR", nothing), mktempdir())
    # An item that calls `exit` must not take its own buffered output with it: that output is
    # what the watchdog prints to say why the run ended early.
    atexit(() -> (io = CURRENT_CAPTURE[]; io === nothing || flush(io)))
    ctx = RunContext(imports, test_end, setups, Dict{Symbol,Module}(), Dict{Symbol,String}())
    n = length(items)
    failed = TestItem[]
    root = Test.DefaultTestSet(name)
    with_testset(root) do
        i = 0
        while i < n
            file = items[i+1].file
            fts = Test.DefaultTestSet(items[i+1].relfile)
            with_testset(fts) do
                while i < n && items[i+1].file == file
                    i += 1
                    it = items[i]
                    what = "test item $(repr(it.name)) at $(it.relfile):$(it.line)"
                    emit_event(capture_dir, "START $i $what")
                    _progress("START ($i/$n) $what")
                    logfile = joinpath(capture_dir, "$i.log")
                    t0 = time()
                    ts = open(io -> with_capture(() -> run_item(ctx, it), io), logfile, "w")
                    # `@testset` has already recorded the item into `fts`.
                    bad = ts === nothing || _failed(ts)
                    _progress("DONE  ($i/$n) test item $(repr(it.name)) " *
                              "$(round(time() - t0; digits = 2)) secs" * (bad ? " -- FAILED" : ""))
                    if bad
                        push!(failed, it)
                        io = report_io()
                        println(io, "\n── Captured output of test item $(repr(it.name)) at $(it.relfile):$(it.line) ──")
                        write(io, read(logfile))
                        println(io, "── End of captured output of $(repr(it.name)) ──\n")
                        flush(io)
                    end
                    rm(logfile; force = true)
                    emit_event(capture_dir, "DONE $i")
                end
            end
            Test.finish(fts)      # records into `root`
        end
    end
    if !isempty(failed)
        println(report_io(), "\n$(length(failed)) of $n test items did not pass:")
        foreach(it -> println(report_io(), "  $(repr(it.name)) at $(it.relfile):$(it.line)"), failed)
        println(report_io())
    end
    status = isempty(failed) ? 0 : 1
    try
        Test.finish(root)        # prints the summary table
    catch err
        err isa Test.TestSetException || rethrow()
        status = 1
    end
    # The end of the run, said explicitly. A child that exits WITHOUT this -- an item calling
    # `exit(0)`, a crash, a kill -- did not finish the run, whatever its exit code says.
    emit_event(capture_dir, "COMPLETE $status")
    return status
end
