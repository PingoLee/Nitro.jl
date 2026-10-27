@testitem "Test runner: collection refuses what it would not run faithfully (#754)" tags=[:core] begin

# The runner in `test/runner/` implements two `@testitem` keywords, `tags` and `setup`. A third
# one accepted and ignored would run the item differently from what its header says -- a
# `timeout=` that never fires, a `skip=` that does not skip -- so collection refuses it, with the
# file and line. The same goes for code outside any item, which would run with no result to
# report it.

include(joinpath(pkgdir(Nitro), "test", "runner", "NitroTestRunner.jl"))
using .NitroTestRunner: collect_file, CollectionError, setup_name_and_body

dir = mktempdir()
function refusal(src)
    path = joinpath(dir, "probe_tests.jl")
    write(path, src)
    try
        collect_file(path, "probe_tests.jl")
        return nothing
    catch err
        err isa CollectionError || rethrow()
        return err.msg
    end
end

@testset "a well-formed file collects, in source order" begin
    path = joinpath(dir, "ok_tests.jl")
    write(path, """
        @testsetup module S
        export X
        const X = 1
        end

        @testitem "first" tags=[:core, :slow] setup=[S] begin
            @test X == 1
        end

        @testitem "second" begin
            @test true
        end
        """)
    items, setups = collect_file(path, "ok_tests.jl")
    @test [it.name for it in items] == ["first", "second"]
    @test items[1].tags == [:core, :slow]
    @test items[1].setups == [:S]
    @test items[2].tags == Symbol[] && items[2].setups == Symbol[]
    @test [it.line for it in items] == [6, 10]
    @test only(setups).name === :S
    # The body keeps the file's own line numbers, which is what `@__DIR__`, a relative
    # `include` and a failure's location all read.
    lnn = first(x for x in items[1].body.args if x isa LineNumberNode)
    @test String(lnn.file) == path && lnn.line == 7
end

@testset "every refusal names the file, the line and the reason" begin
    msg = refusal("@testitem \"a\" retries=2 begin\n@test true\nend\n")
    @test msg !== nothing && occursin("probe_tests.jl:1", msg) && occursin("`retries`", msg)
    msg = refusal("@testitem \"a\" tags=[:core] timeout=60 begin\nend\n")
    @test msg !== nothing && occursin("`timeout`", msg)
    # Multi-line headers are one macrocall; the line is the macro's.
    msg = refusal("\n\n@testitem \"a\" tags=[:core] skip=true setup=[\n    S,\n] begin\nend\n")
    @test msg !== nothing && occursin("probe_tests.jl:3", msg) && occursin("`skip`", msg)

    msg = refusal("x = 1\n@testitem \"a\" begin\nend\n")
    @test msg !== nothing && occursin("probe_tests.jl:1", msg) && occursin("top level", msg)
    msg = refusal("name = \"a\"\n")
    @test msg !== nothing
    msg = refusal("@testitem \"a \$(1)\" begin\nend\n")
    @test msg !== nothing && occursin("string literal", msg)
    msg = refusal("@testitem \"a\" begin\nend\n@testitem \"a\" begin\nend\n")
    @test msg !== nothing && occursin("probe_tests.jl:3", msg) && occursin("second", msg)
    msg = refusal("@testitem \"a\" tags=[core] begin\nend\n")
    @test msg !== nothing && occursin("quoted symbols", msg)
    msg = refusal("@testitem \"a\" tags=[:core] tags=[:slow] begin\nend\n")
    @test msg !== nothing && occursin("repeats", msg)
    msg = refusal("@testitem \"a\" 42\n")
    @test msg !== nothing && occursin("body", msg)
    msg = refusal("@testsetup begin\nend\n")
    @test msg !== nothing && occursin("module", msg)
    msg = refusal("@testitem \"a\" begin\n")
    @test msg !== nothing && occursin("parse", msg)
end

@testset "a setup module's name is read from the end, so 1.14's versioned form parses (#112)" begin
    body = Expr(:block)
    @test setup_name_and_body(Expr(:module, true, :Foo, body)) == (:Foo, body)
    # Julia 1.14 prepends the syntax version (JuliaLang/julia#60018). Reading positionally from
    # the front is the exact break that kept ReTestItems from collecting on 1.14.
    @test setup_name_and_body(Expr(:module, v"1.14.0", true, :Foo, body)) == (:Foo, body)
    # Whatever this Julia's parser produces, the name and body come back.
    parsed = Meta.parse("module Bar\nx = 1\nend")
    name, b = setup_name_and_body(parsed)
    @test name === :Bar && b isa Expr && b.head === :block
end

end

@testitem "Test runner: the collected suite agrees with the harness, in ReTestItems' order (#754)" tags=[:core] begin

# `harness_manifest.jl`'s `testitems` reads item names and tags with its own AST walk, and
# `harness_tests.jl` checks the tag vocabulary through it. The runner's collection is a second
# reader of the same files, so the two must agree on every file -- else a guard checks one
# suite and the run executes another.

include(joinpath(pkgdir(Nitro), "test", "runner", "NitroTestRunner.jl"))
using .NitroTestRunner: collect_file, collect_suite, sort_files, resolve_paths
using .NitroTestRunner.NitroTestHarness: TEST_FILES, testitems

const ROOT = pkgdir(Nitro)
const TEST_ROOT = joinpath(ROOT, "test")

@testset "every listed file collects, and agrees with `testitems`" begin
    total = 0
    for f in TEST_FILES
        path = joinpath(TEST_ROOT, f)
        items, _ = collect_file(path, "test/" * f)
        @test [(it.name, it.tags) for it in items] == testitems(path)
        total += length(items)
    end
    @test total > 250   # vacuity floor
end

@testset "the setups the suite names all exist" begin
    items, setups = collect_suite([joinpath(TEST_ROOT, f) for f in TEST_FILES]; root = ROOT)
    named = Set(s for it in items for s in it.setups)
    @test issubset(named, keys(setups))
    @test :NitroCommon in keys(setups)
end

@testset "files run in lexical path order, compared by component" begin
    # The order ReTestItems ran: each directory's children sorted by path. It is the order the
    # suite has always passed in, and `test/app_tests.jl` documents one item that relies on it.
    files = sort_files([joinpath(TEST_ROOT, f) for f in TEST_FILES], ROOT)
    rel = [replace(relpath(f, ROOT), '\\' => '/') for f in files]
    @test first(rel) == "test/app_tests.jl"
    before(a, b) = findfirst(==(a), rel) < findfirst(==(b), rel)
    # A directory sorts where its NAME sorts, among its siblings...
    @test before("test/examples_tests.jl", "test/extensions/crypto_tests.jl")
    @test before("test/extensions/timezone_tests.jl", "test/extractor_tests.jl")
    # ...which puts `middleware/` ahead of `middleware_cache_tests.jl` (`/` sorts first).
    @test before("test/middleware/access_log_tests.jl", "test/middleware_cache_tests.jl")
    @test before("test/middleware/websocket_origins_tests.jl", "test/middleware_tests.jl")
    @test before("test/extensions/protobuf/protobuf_tests.jl", "test/extensions/templating_tests.jl")
end

@testset "a path is a file, a directory, or an error" begin
    @test_throws "No such test path" resolve_paths([joinpath(TEST_ROOT, "middlware")])
    @test_throws "Not a test file" resolve_paths([joinpath(TEST_ROOT, "runtests.jl")])
    # A directory selects the files under it, not every path that shares its prefix: the
    # string-prefix match ReTestItems used made `test/middleware` select
    # `test/middleware_tests.jl` too.
    mw = resolve_paths([joinpath(TEST_ROOT, "middleware")])
    @test !isempty(mw)
    @test all(f -> occursin(joinpath("test", "middleware") * Base.Filesystem.path_separator, f), mw)
    # Naming the same file twice runs it once.
    one = joinpath(TEST_ROOT, "setup_tests.jl")
    @test resolve_paths([one, one]) == [normpath(one)]
end

end

@testitem "Test runner: selection and --shuffle (#754)" tags=[:core] begin

include(joinpath(pkgdir(Nitro), "test", "runner", "NitroTestRunner.jl"))
using .NitroTestRunner: TestItem, select_items, shuffle_items, collect_suite
using .NitroTestRunner.NitroTestHarness: TEST_FILES

mk(name, tags, file) = TestItem(name, tags, Symbol[], file, file, 1, Expr(:block))

@testset "select_items is the shared rule, exclusion included" begin
    items = [mk("a", [:core], "f"), mk("b", [:core, :network], "f"), mk("c", [:middleware], "g")]
    names(xs) = [it.name for it in xs]
    @test names(select_items(items)) == ["a", "b", "c"]
    @test names(select_items(items; tags = [:core])) == ["a", "b"]
    # `--skip-tags` reaches the selection: dropping it would run the `:network` item.
    @test names(select_items(items; skip_tags = [:network])) == ["a", "c"]
    @test names(select_items(items; tags = [:core], skip_tags = [:network])) == ["a"]
    @test names(select_items(items; name = "c")) == ["c"]
    @test isempty(select_items(items; name = "Session"))
end

@testset "--shuffle is a deterministic permutation that keeps a file's items together" begin
    items, _ = collect_suite([joinpath(pkgdir(Nitro), "test", f) for f in TEST_FILES];
                             root = pkgdir(Nitro))
    key(xs) = [(it.file, it.line) for it in xs]
    a = shuffle_items(items, 1234)
    @test key(a) == key(shuffle_items(items, 1234))      # same seed, same order
    @test key(a) != key(shuffle_items(items, 1235))      # another seed, another order
    @test key(a) != key(items)                            # it does shuffle
    @test sort(key(a)) == sort(key(items))                # nothing lost or duplicated
    # A file's items stay contiguous, so a file is still one block of the run.
    runs = [it.file for (i, it) in enumerate(a) if i == 1 || a[i-1].file != it.file]
    @test allunique(runs)
    # The stream is the runner's own SplitMix64, not `Random`'s, so a printed seed
    # reproduces its order on every Julia version. Pinned on a fixed input.
    six = [mk(string(i), Symbol[], "f$(cld(i, 2))") for i in 1:6]
    @test [it.name for it in shuffle_items(six, 7)] == [it.name for it in shuffle_items(six, 7)]
    @test length(unique([[it.name for it in shuffle_items(six, s)] for s in 1:20])) > 1
end

end

@testitem "Test runner: a hung item is killed and named; a failing setup or TEST_END hides nothing (#754)" tags=[:core, :slow] begin

# The runner's guards, provoked for real. Each scenario is a synthetic test tree run by
# `test/.helpers/runner_probe.jl` in a child julia that loads only `Test`: running the runner
# inside this item would nest its test sets into this item's own.

const PROBE = joinpath(pkgdir(Nitro), "test", ".helpers", "runner_probe.jl")

function tree(files::Pair...)
    dir = mktempdir()
    for (name, src) in files
        write(joinpath(dir, name), src)
    end
    return dir
end

function probe(args...; limit = 180)
    cmd = `$(Base.julia_cmd()) --code-coverage=none --startup-file=no --project=$(Base.active_project()) $PROBE $args`
    out = IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out); wait = false)
    killer = Timer(_ -> process_running(p) && kill(p, Base.SIGKILL), limit)
    t = @elapsed wait(p)
    close(killer)
    return (; code = p.exitcode, out = String(take!(out)), seconds = t)
end

@testset "a hung item is killed at the timeout, named, and the run fails" begin
    dir = tree("hang_tests.jl" => """
        @testitem "quick" begin
            @test true
        end

        @testitem "sleeper" begin
            println("about to hang")
            sleep(600)
        end

        @testitem "never reached" begin
            @test true
        end
        """)
    r = probe(dir, "--watch", "5")
    @test r.code == 1
    @test occursin("TIMEOUT", r.out)
    @test occursin("test item \"sleeper\" at hang_tests.jl:5", r.out)
    # The killed item's captured output is printed, not lost with the process.
    @test occursin("about to hang", r.out)
    @test !occursin("START (3/3)", r.out)
    @test r.seconds < 120
    r.code == 1 || println(r.out)
end

@testset "a watched run that passes exits 0, and one that fails exits 1" begin
    ok = probe(tree("ok_tests.jl" => "@testitem \"fine\" begin\n@test true\nend\n"), "--watch", "60")
    @test ok.code == 0
    bad = probe(tree("bad_tests.jl" => "@testitem \"red\" begin\n@test 1 == 2\nend\n"), "--watch", "60")
    @test bad.code == 1
    @test occursin("\"red\" at bad_tests.jl:1", bad.out)
end

@testset "a child that ends mid-run fails the run and names the item, whatever its exit code" begin
    # `exit(0)` inside an item: the child's exit code says success, but the run did not end.
    quits = probe(tree("a_tests.jl" => """
        @testitem "fine" begin
            @test true
        end

        @testitem "quits" begin
            println("quitting early")
            exit(0)
        end

        @testitem "red, never reached" begin
            @test false
        end
        """), "--watch", "60")
    @test quits.code == 1
    @test occursin("ended before the run did", quits.out)
    @test occursin("test item \"quits\" at a_tests.jl:5", quits.out)
    @test occursin("quitting early", quits.out)        # its capture is printed
    # A crash: the process dies under the item, and the item is still named.
    crash = probe(tree("b_tests.jl" => """
        @testitem "dies" begin
            println("last words")
            flush(stdout)
            ccall(:abort, Cvoid, ())
        end
        """), "--watch", "60")
    @test crash.code == 1
    @test occursin("test item \"dies\" at b_tests.jl:1", crash.out)
    @test occursin("last words", crash.out)
end

@testset "an item's stdin is at EOF, not the watchdog's pipe" begin
    # ReTestItems gave its worker `devnull`; a process an item starts with `run` inherits stdin,
    # and one that reads it must not block until the timeout.
    r = probe(tree("a_tests.jl" => """
        @testitem "reads stdin" begin
            @test read(stdin, String) == ""
            @test success(`\$(Base.julia_cmd()) --startup-file=no -e 'read(stdin)'`)
        end
        """), "--watch", "60")
    @test r.code == 0
    @test r.seconds < 50
    r.code == 0 || println(r.out)
end

@testset "a setup that throws errors every item that names it" begin
    dir = tree("a_tests.jl" => """
        @testsetup module Broken
        error("setup probe failure")
        end

        @testitem "first user" setup=[Broken] begin
            @test true
        end

        @testitem "second user" setup=[Broken] begin
            @test true
        end

        @testitem "bystander" begin
            @test true
        end
        """)
    r = probe(dir)
    @test r.code == 1
    @test occursin("setup probe failure", r.out)
    @test occursin("SetupError", r.out)   # the second user names the first failure
    # Both users are listed as not passing, and the bystander is not.
    @test occursin("2 of 3 test items did not pass:\n  \"first user\" at a_tests.jl:5\n" *
                   "  \"second user\" at a_tests.jl:9\n\n", r.out)
end

@testset "a TEST_END that throws does not replace the item's own failure" begin
    dir = tree("a_tests.jl" => "@testitem \"red\" begin\n@test 1 == 2\nend\n")
    r = probe(dir, "--test-end-throws")
    @test r.code == 1
    @test occursin("TEST_END failed", r.out)
    @test occursin("Test Failed", r.out)
    @test occursin("Expression: 1 == 2", r.out)
    # ...and a TEST_END that throws after a PASSING item does not turn it red.
    g = probe(tree("b_tests.jl" => "@testitem \"green\" begin\n@test true\nend\n"), "--test-end-throws")
    @test g.code == 0
end

@testset "an errormonitor'd task left running fails the watched run, named by item and site (#772)" begin
    leak = """
        @testitem "tidy" begin
            @test true
        end

        @testitem "leaks" begin
            ev = Base.Event()
            start(ev) = errormonitor(Threads.@spawn wait(ev))
            start(ev)
            @test true
        end

        @testitem "leaks a loop that starts another task late" begin
            errormonitor(Threads.@spawn begin
                sleep(2)
                errormonitor(Threads.@spawn wait(Base.Event()))
                wait(Base.Event())
            end)
            @test true
        end
        """
    r = probe(tree("a_tests.jl" => leak), "--watch", "60")
    @test r.code == 1
    # The loop's late task is started during the grace wait, and still counted.
    @test occursin("3 background tasks were still running at the end of the run.", r.out)
    # The item that started it, then the call site as the first frame: not Base's
    # `errormonitor`, the runner's replacement of it, or `Threads.@spawn`'s expansion.
    @test occursin(r"started during test item \"leaks\" at a_tests\.jl:5:\n    start at \S*a_tests\.jl:7\n", r.out)
    @test !occursin("started during test item \"tidy\"", r.out)
    r.code == 1 || println(r.out)
    # The same item unwatched: the record is never installed, so nothing is checked.
    @test probe(tree("b_tests.jl" => leak)).code == 0

    # Stopped by its item, or still on its way out when the run ends: both pass.
    ok = probe(tree("c_tests.jl" => """
        @testitem "stops its task" begin
            ev = Base.Event()
            t = errormonitor(Threads.@spawn wait(ev))
            notify(ev)
            wait(t)
            @test istaskdone(t)
        end

        @testitem "its task ends just after it" begin
            errormonitor(Threads.@spawn sleep(2))
            @test true
        end
        """), "--watch", "60")
    @test ok.code == 0
    ok.code == 0 || println(ok.out)
end

@testset "a failed errormonitor'd task prints as Base prints it, with the item's own methods" begin
    # The replacement calls Base's method in the current world, so a `showerror` the item
    # defined after the record was installed is the one that prints.
    r = probe(tree("a_tests.jl" => """
        @testitem "prints" begin
            struct ProbeError <: Exception end
            Base.showerror(io::IO, ::ProbeError) = print(io, "probe error, shown by the item's method")
            path, io = mktemp()
            redirect_stderr(io) do
                t = errormonitor(Threads.@spawn throw(ProbeError()))
                @test_throws TaskFailedException wait(t)
                # The monitor writes without flushing, so flush for it.
                timedwait(() -> (flush(io); occursin("probe error", read(path, String))), 30.0)
            end
            close(io)
            out = read(path, String)
            # Base upper-cases the banner when the stream has no color.
            @test occursin(r"unhandled task error: probe error, shown by the item's method"i, out)
        end
        """), "--watch", "60")
    @test r.code == 0
    r.code == 0 || println(r.out)
end

end

@testitem "Test runner: each item runs in its own @testset (#763)" tags=[:core] begin

# Each item runs inside a real `@testset` whose source is the item's own `file:line`. That is
# where two guarantees come from: every item starts the default RNG from the same fixed seed, so
# no item's draws depend on what ran before it (or on the process), and `Test` itself records a
# failure at the item's location. Probed in child runs, as the guard item above does, so the
# probes' test sets do not nest into this item's own.

include(joinpath(pkgdir(Nitro), "test", "runner", "NitroTestRunner.jl"))
using Random

const PROBE = joinpath(pkgdir(Nitro), "test", ".helpers", "runner_probe.jl")

function tree(files::Pair...)
    dir = mktempdir()
    for (name, src) in files
        write(joinpath(dir, name), src)
    end
    return dir
end

function probe(args...; limit = 180, env = ())
    cmd = addenv(`$(Base.julia_cmd()) --code-coverage=none --startup-file=no --project=$(Base.active_project()) $PROBE $args`, env...)
    out = IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out); wait = false)
    killer = Timer(_ -> process_running(p) && kill(p, Base.SIGKILL), limit)
    wait(p)
    close(killer)
    return (; code = p.exitcode, out = String(take!(out)))
end

# A passing item's output is discarded with its capture, so each item writes its first draw to a
# file next to it: one `name value` line per item, in the order the items ran.
draw_item(name; setup = "", after = "") = """
    @testitem "$name"$(isempty(setup) ? "" : " setup=[$setup]") begin
        open(io -> println(io, "$name ", rand()), joinpath(@__DIR__, "draws.txt"), "a")
        $after
    end
    """

# A setup that draws when it loads, so its first user is the item that evaluates it.
const DRAWING_SETUP = "@testsetup module Draws\nconst D = rand()\nend\n"

function draws(dir, args...)
    rm(joinpath(dir, "draws.txt"); force = true)
    r = probe(dir, args...)
    r.code == 0 || println(r.out)
    lines = split(strip(read(joinpath(dir, "draws.txt"), String)), '\n')
    return (; code = r.code, order = [String(first(split(l))) for l in lines],
            value = Dict(String(first(split(l))) => String(last(split(l))) for l in lines))
end

@testset "every item starts from the same fixed draw, whatever ran before it" begin
    # `between` draws 1000 values; `b` is the first user of a setup that draws; `c` the second.
    with_between = tree("a_tests.jl" => DRAWING_SETUP * draw_item("a") *
                        draw_item("between"; after = "rand(1000)") *
                        draw_item("b"; setup = "Draws") * draw_item("c"; setup = "Draws"))
    without = tree("a_tests.jl" => DRAWING_SETUP * draw_item("a") *
                   draw_item("b"; setup = "Draws") * draw_item("c"; setup = "Draws"))
    d1 = draws(with_between)
    d2 = draws(without)
    @test d1.code == 0 && d2.code == 0
    @test d1.order == ["a", "between", "b", "c"]
    expected = string(rand(Random.Xoshiro(NitroTestRunner.ITEM_RNG_SEED)))
    @test all(==(expected), values(d1.value))
    # Not just the same within a run: the same in another process, with an item fewer.
    @test d2.value == Dict(k => d1.value[k] for k in ("a", "b", "c"))

    # A shuffled order, in a third process, gives every item the same draw again. Seed 6 runs
    # `between` first and makes `c` the setup's first user.
    ds = draws(with_between, "--shuffle", "6")
    @test ds.code == 0
    @test ds.order == ["between", "c", "b", "a"]
    @test ds.value == d1.value
end

@testset "a failure points at the item, and a failing @test at its own line" begin
    dir = tree("loc_tests.jl" => """
        @testitem "throws outside a test" begin
            x = 1
            error("outside any test")
        end

        @testitem "fails a test" begin
            @test 1 == 2
        end

        @testitem "only broken" begin
            @test_broken 1 == 2
        end
        """)
    path = joinpath(dir, "loc_tests.jl")
    r = probe(dir)
    # The child inherits the parent's `--color` through `Base.julia_cmd()`, and CI runs with
    # colour on, so `Test` wraps "Error During Test", " at " and the path in separate ANSI runs.
    # Strip them before matching: the location is what is under test, not the colouring.
    out = replace(r.out, r"\e\[[0-9;]*m" => "")
    @test r.code == 1
    @test occursin("Error During Test at $path:1", out)
    @test occursin("Test Failed at $path:7", out)
    # A Broken result is not a failure: the third item is not listed.
    @test occursin("2 of 3 test items did not pass:\n  \"throws outside a test\" at loc_tests.jl:1\n" *
                   "  \"fails a test\" at loc_tests.jl:6\n\n", out)
    r.code == 1 || println(r.out)
end

@testset "a stop that gets past an item's test set ends the run, and names the item" begin
    # `@testset` passes on an `InterruptException` and a fail-fast stop instead of recording
    # them. Either must end the run where it happened, with no COMPLETE event, as a crash would --
    # not be recorded by the file's test set and run past. Fail-fast is the one a probe can
    # provoke deterministically.
    dir = tree("ff_tests.jl" => """
        @testitem "first red" begin
            @test 1 == 2
        end

        @testitem "never reached" begin
            @test true
        end
        """)
    r = probe(dir, "--watch", "60"; env = ("JULIA_TEST_FAILFAST" => "true",))
    @test r.code == 1
    @test occursin("ended before the run did", r.out)
    @test occursin("during test item \"first red\" at ff_tests.jl:1", r.out)
    @test !occursin("START (2/2)", r.out)
    r.code == 1 || println(r.out)
end

end

@testitem "Test runner: no Test internals in test/runner, except what is pinned (#763)" tags=[:core] begin

# The runner uses `Test`'s documented surface only: `@testset` (with its `rng` option), the
# result types for `isa`, `TestSetException`, and `get_test_counts`/`TestCounts`.
# ReTestItems broke on 1.13 exactly where it reached past that surface (#112), so anything
# internal the runner needs must be named here, as a contract a Julia bump fails by name, the
# way `test/http_internals_contract_tests.jl` pins HTTP.jl. Nothing internal is needed today.

const RUNNER = joinpath(pkgdir(Nitro), "test", "runner")

# What the runner may name from `Test`, qualified (`Test.x`) or imported (`using Test: x`): the
# documented surface. The result types are here for `isa`; constructing one is refused below.
const PUBLIC = Set([Symbol("@testset"), :AbstractTestSet, :TestSetException, :get_test_counts,
                    :TestCounts, :record, :finish, :Result, :Pass, :Fail, :Error, :Broken])
# Never, under any spelling: the test set stack the runner used to set by hand, and the switch
# that broke ReTestItems on 1.13 (#112).
const STACK = Set([:CURRENT_TESTSET, :TESTSET_DEPTH, :TESTSET_PRINT_ENABLE, :get_testset,
                   :get_testset_depth, :push_testset, :pop_testset, Symbol("@with_testset")])
const CONSTRUCTED = Set([:Pass, :Fail, :Error, :Broken, :DefaultTestSet])
const FIELDS = Set([:results, :results_lock, :n_passed, :anynonpass, :time_end])

# Internals that must stay, as `(name, file) => why`. Empty: if one is ever added, its contract
# goes in the testset below.
const PINNED = Dict{Tuple{Symbol,String},String}()

_test_name(x) = Meta.isexpr(x, :., 2) && x.args[1] === :Test && x.args[2] isa QuoteNode ?
                x.args[2].value : nothing

# Every use of `Test` beyond its public surface in `ex`, as `(line, name, what)`. The walk is
# over the parsed AST, so a comment or a string can neither hide a use nor fake one.
function test_internals(ex)
    found = Tuple{Int,Symbol,String}[]
    line = 0
    function walk(x)
        if x isa LineNumberNode
            line = x.line
        elseif x isa QuoteNode
            walk(x.value)   # `:CURRENT_TESTSET`, as in `getfield(Test, :CURRENT_TESTSET)`
        elseif x isa Symbol
            x in STACK && push!(found, (line, x, "the test set stack, `$x`"))
        elseif x isa Expr
            n = _test_name(x)
            if n !== nothing
                n in PUBLIC || push!(found, (line, n, "`Test.$n`, which is not public"))
                return
            end
            if Meta.isexpr(x, :., 2) && x.args[2] isa QuoteNode && x.args[2].value in FIELDS
                push!(found, (line, x.args[2].value, "the DefaultTestSet field `.$(x.args[2].value)`"))
            elseif x.head === :call
                c = x.args[1] isa Symbol ? x.args[1] : _test_name(x.args[1])
                c in CONSTRUCTED && push!(found, (line, c, "the constructor `$c(…)`"))
                if c in (:getfield, :getproperty, :setfield!, :setproperty!) && length(x.args) >= 3 &&
                   x.args[3] isa QuoteNode
                    f = x.args[3].value
                    f in FIELDS && push!(found, (line, f, "the DefaultTestSet field `$f`, through `$c`"))
                    x.args[2] === :Test && !(f in PUBLIC) &&
                        push!(found, (line, f, "`Test.$f` through `$c`, which is not public"))
                end
            elseif Meta.isexpr(x, :(=), 2) && x.args[2] === :Test
                # `const T = Test`: every `T.x` after it would go unchecked.
                push!(found, (line, :Test, "an alias of `Test`"))
            elseif x.head in (:using, :import)
                for a in x.args
                    if Meta.isexpr(a, :as) && a.args[1] == Expr(:., :Test)
                        push!(found, (line, :Test, "an alias of `Test`"))   # `import Test as T`
                    elseif Meta.isexpr(a, :.) && length(a.args) >= 2 && a.args[1] === :Test
                        m = a.args[end]                                   # `import Test.x`
                        m in PUBLIC || push!(found, (line, m, "`import Test.$m`, which is not public"))
                    elseif Meta.isexpr(a, :(:)) && a.args[1] == Expr(:., :Test)
                        for b in a.args[2:end]
                            # An alias would hide a constructor call: `using Test: Error as E`.
                            Meta.isexpr(b, :as) &&
                                push!(found, (line, b.args[1].args[end], "an alias of a `Test` name"))
                            m = (Meta.isexpr(b, :as) ? b.args[1] : b).args[end]
                            m in PUBLIC || push!(found, (line, m, "`using Test: $m`, which is not public"))
                        end
                    end
                end
            end
            foreach(walk, x.args)
        end
    end
    walk(ex)
    return found
end

@testset "the runner reaches no further into Test than its public surface" begin
    files = String[]
    for (dir, _, fs) in walkdir(RUNNER), f in fs
        endswith(f, ".jl") && push!(files, joinpath(dir, f))
    end
    @test joinpath(RUNNER, "execute.jl") in files && joinpath(RUNNER, "NitroTestRunner.jl") in files
    hits = String[]
    for path in files
        rel = relpath(path, RUNNER)
        for (line, name, what) in test_internals(Meta.parseall(read(path, String); filename = path))
            haskey(PINNED, (name, rel)) || push!(hits, "test/runner/$rel:$line uses $what")
        end
    end
    @test isempty(hits)
    isempty(hits) || foreach(println, hits)

    # The walk catches each shape it is for, so an empty `hits` is not a dead check...
    caught = ["Base.ScopedValues.with(f, Test.CURRENT_TESTSET => ts)",
              "using Test: DefaultTestSet, get_testset_depth",
              "Test.TESTSET_PRINT_ENABLE[]",
              "Test.record(ts, Test.Error(:nontest_error, Expr(:tuple), err, bt, src))",
              "ts = DefaultTestSet(\"x\")",
              "any(r -> r isa Test.Fail, ts.results)",
              "getfield(ts, :n_passed)",
              "Test.filter_errors(ts)",
              # Spellings that route around a plain `Test.x`:
              "import Test as T; T.CURRENT_TESTSET",
              "const T = Test",
              "getproperty(Test, :TESTSET_DEPTH)",
              "getproperty(Test, :filter_errors)",
              "using Test: Error as E",
              "import Test.filter_errors",
              "setfield!(ts, :results, [])"]
    @test all(s -> !isempty(test_internals(Meta.parseall(s))), caught)
    # ...and passes what the runner is allowed, including names that only appear in text.
    allowed = ["r isa Test.Error || r isa Test.Fail",
               "tc = Test.get_test_counts(ts); tc.cumulative_fails",
               "err isa TestSetException || rethrow()",
               "import Test; using Test: @testset, TestSetException",
               "Test.@testset \"x\" begin end",
               "# Test.CURRENT_TESTSET, in a comment\nx = 1",
               "s = \"Test.Error( in a string\""]
    @test all(s -> isempty(test_internals(Meta.parseall(s))), allowed)
end

@testset "what the runner reads from get_test_counts is still there" begin
    # The runner totals an item through `Test.get_test_counts`, which the Test manual documents
    # ("Creating Custom AbstractTestSet Types"). The `TestCounts` docstring lists the cumulative
    # fields under the plain names (`passes`, `fails`, ... twice), so the four the runner reads
    # are pinned by name.
    @test hasmethod(Test.get_test_counts, Tuple{Test.DefaultTestSet})
    @test issubset((:fails, :errors, :cumulative_fails, :cumulative_errors), fieldnames(Test.TestCounts))
    # That the totals actually report a failure is checked end to end by the location probe in
    # "Test runner: each item runs in its own @testset (#763)": exit 1, and both items listed.
end

end
