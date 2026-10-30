@testitem "newapp -- refusals and the in-memory template (#417)" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro
using Pkg: TOML

@testset "public, not exported" begin
    @test Base.ispublic(Nitro, :newapp)
    @test !Base.isexported(Nitro, :newapp)
end

@testset "refuses a name that is not a module identifier" begin
    dir = mktempdir()
    target = joinpath(dir, "app")
    # `end` and `struct` pass `Base.isidentifier`; `true` parses to a Bool. Dependency names
    # would shadow the package the generated app loads.
    for name in ("1x", "my-app", "Foo.jl", "", "end", "struct", "true")
        @test_throws "not a valid Julia module name" Nitro.newapp(name; path = target, pormg = false)
    end
    for name in ("Nitro", "HTTP", "SQLite", "Main")
        @test_throws "depends on" Nitro.newapp(name; path = target, pormg = false)
    end
    # A module's own name is bound inside it: `App` would make `App(mod = …)` call the module,
    # `app`/`main` collide with what it defines, and the other two with what it includes.
    for name in ("App", "app", "main", "Routes", "HealthHandlers", "serve")
        @test_throws "uses itself" Nitro.newapp(name; path = target, pormg = false)
    end
    @test !ispath(target)
end

@testset "refuses an existing path unless it is an empty directory" begin
    dir = mktempdir()
    full = joinpath(dir, "full")
    mkpath(full)
    write(joinpath(full, "keep.txt"), "mine")
    @test_throws "not empty" Nitro.newapp("MyApp"; path = full, pormg = false)
    @test readdir(full) == ["keep.txt"]
    @test read(joinpath(full, "keep.txt"), String) == "mine"

    file = joinpath(dir, "a_file")
    write(file, "x")
    @test_throws "not empty" Nitro.newapp("MyApp"; path = file, pormg = false)
    @test read(file, String) == "x"

    empty = joinpath(dir, "empty")
    mkpath(empty)
    @test Nitro.newapp("MyApp"; path = empty, pormg = false) == abspath(empty)
    @test isfile(joinpath(empty, "src", "MyApp.jl"))
end

@testset "writes the layout and the in-memory boot" begin
    root = Nitro.newapp("DemoApp"; path = joinpath(mktempdir(), "demo"), pormg = false)
    files = sort!([replace(relpath(joinpath(d, f), root), '\\' => '/')
                   for (d, _, fs) in walkdir(root) for f in fs])
    @test files == sort!(["Project.toml", "main.jl", "src/DemoApp.jl", "src/Routes.jl",
                          "src/Handlers/HealthHandlers.jl", "test/runtests.jl"])
    @test !isdir(joinpath(root, "db"))

    src = read(joinpath(root, "src", "DemoApp.jl"), String)
    @test !occursin("PormG", src)
    @test occursin("store = Nitro.Workers.InMemoryWorkerStore()", src)
    # The module body holds only `using`, the App const and `include`s: nothing that connects
    # or starts, because a module body runs at precompile time and never again.
    body = first(split(src, "\"\"\"\n    main"))
    @test occursin("const app = App(mod = @__MODULE__)", body)
    for call in ("serve(", "worker_startup(", "urlpatterns(", "load_many")
        @test !occursin(call, body)
    end
    @test occursin("serve(app; port = parse(Int, get(ENV, \"PORT\", \"8000\"))", src)
    @test occursin("function main(; kwargs...)", src)   # no `root`: there is no db/ to find
    @test Meta.parseall(src) isa Expr   # it is Julia

    # The program (#798): the boot runs inside a `try` whose `catch` prints a value-free line,
    # because a compiled executable prints an escaping exception field by field.
    entry = read(joinpath(root, "main.jl"), String)
    @test occursin("using DemoApp, Nitro", entry)
    @test occursin("function (@main)(args::Vector{String})::Cint", entry)
    @test occursin("        DemoApp.main()\n    catch e\n", entry)
    @test occursin("e isa InterruptException && rethrow()", entry)
    @test occursin("println(Core.stderr, \"start-up failed: \", Nitro.startup_failure_text(e))",
                   entry)
    @test occursin("return Cint(1)", entry)
    @test !occursin("APP_ROOT", entry)
    @test !occursin(r"^\s*@error"m, entry) && !occursin("showerror", entry)
    @test Meta.parseall(entry) isa Expr

    project = TOML.parsefile(joinpath(root, "Project.toml"))
    nitro_project = TOML.parsefile(joinpath(pkgdir(Nitro), "Project.toml"))
    @test project["name"] == "DemoApp"
    @test sort!(collect(keys(project["deps"]))) == ["HTTP", "Nitro"]
    @test project["deps"]["Nitro"] == nitro_project["uuid"]
    @test project["deps"]["HTTP"] == nitro_project["deps"]["HTTP"]
    # Installed by URL, pinned to the commit of the Nitro doing the generating: this suite runs
    # from a git checkout, so that is its HEAD.
    @test project["sources"]["Nitro"]["url"] == nitro_project["repo"]
    @test project["sources"]["Nitro"]["rev"] ==
          readchomp(Cmd(`git rev-parse HEAD`; dir = pkgdir(Nitro)))
    @test project["compat"]["Nitro"] == string(pkgversion(Nitro))
    # Derived (HTTP) or hard-coded (julia), these must say what Nitro's own compat says.
    @test project["compat"]["HTTP"] == nitro_project["compat"]["HTTP"]
    @test project["compat"]["julia"] == nitro_project["compat"]["julia"]
    @test project["targets"]["test"] == ["Test"]
end

@testset "outside a checkout, Nitro's rev comes from the manifest that provides it" begin
    uuid = string(Base.PkgId(Nitro).uuid)
    function env(entry)
        dir = mktempdir()
        write(joinpath(dir, "Project.toml"), "[deps]\nNitro = \"$uuid\"\n")
        open(io -> TOML.print(io, Dict("manifest_format" => "2.0",
                                       "deps" => Dict("Nitro" => [entry]))),
             joinpath(dir, "Manifest.toml"), "w")
        return joinpath(dir, "Project.toml")
    end
    sha = "0123456789abcdef0123456789abcdef01234567"
    pinned = env(Dict("uuid" => uuid, "repo-rev" => sha))
    tagged = env(Dict("uuid" => uuid, "repo-rev" => "v0.5.0"))
    developed = env(Dict("uuid" => uuid, "path" => "../Nitro.jl"))
    other = env(Dict("uuid" => string(Base.UUID(0)), "repo-rev" => "v9.9.9"))
    stdlib = Sys.STDLIB
    @test Nitro._manifest_nitro_rev([stdlib, pinned, tagged]) == sha
    @test Nitro._manifest_nitro_rev([tagged, pinned]) == "v0.5.0"   # the first provider wins
    @test Nitro._manifest_nitro_rev([developed, pinned]) === nothing
    @test Nitro._manifest_nitro_rev([other, pinned]) == sha          # matched by uuid, not name
    @test Nitro._manifest_nitro_rev([stdlib, joinpath(mktempdir(), "Project.toml")]) === nothing
    @test Nitro._is_commit(sha)
    @test !Nitro._is_commit("v0.5.0") && !Nitro._is_commit(uppercase(sha))
end
end

@testitem "newapp -- the generated app instantiates, boots and serves (#417)" tags=[:core, :slow, :network] setup=[NitroCommon] begin
using Test
using Nitro

# The rot guard: a template only stays right if something runs what it writes. Both halves run
# in child processes, in the generated project. The child's `JULIA_LOAD_PATH` is pinned so this
# test environment cannot leak into what the generated app resolves.
root = Nitro.newapp("DemoApp"; path = joinpath(mktempdir(), "demo"), pormg = false)
checkout = pkgdir(Nitro)
logfile = joinpath(mktempdir(), "child.log")

function run_child(script; timeout = 900)
    cmd = addenv(Cmd(`$(Base.julia_cmd()) --project=$root -e $script`; dir = root),
                 "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ';' : ':'),
                 "JULIA_PROJECT" => nothing)
    proc = open(logfile, "a") do log
        run(pipeline(cmd; stdout = log, stderr = log); wait = false)
    end
    if timedwait(() -> process_exited(proc), timeout) === :timed_out
        kill(proc)
        wait(proc)
    end
    ok = success(proc)
    ok || println(read(logfile, String))
    return ok
end

# Pkg refuses to `develop` a package whose `[sources]` entry has a `url` ("`path` and `url` are
# conflicting specifications"), so the child drops it first.
@test run_child("""
    using Pkg
    p = Pkg.TOML.parsefile("Project.toml")
    delete!(p["sources"], "Nitro")
    isempty(p["sources"]) && delete!(p, "sources")
    open(io -> Pkg.TOML.print(io, p), "Project.toml", "w")
    Pkg.develop(path = $(repr(checkout)))
    Pkg.instantiate()
    """)

@test run_child("""
    using DemoApp, HTTP, Nitro, Sockets, Test

    # The generated test suite passes.
    include(joinpath(pkgdir(DemoApp), "test", "runtests.jl"))

    # Without PormG loaded, the default `pormg = true` is refused before anything is written.
    target = joinpath(mktempdir(), "x")
    try
        Nitro.newapp("Other"; path = target)
        error("newapp did not refuse pormg = true without PormG")
    catch err
        err isa ArgumentError && occursin("using PormG", err.msg) || rethrow()
    end
    ispath(target) && error("the refused newapp wrote \$target")

    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    ENV["PORT"] = string(port)
    ENV["API_SECRET_KEY"] = "x"^32    # a placeholder: the boot requires 32 bytes
    DemoApp.main(; host = "127.0.0.1", async = true, show_banner = false, access_log = nothing)
    try
        r = HTTP.get("http://127.0.0.1:\$port/health"; retry = false, status_exception = false)
        r.status == 200 || error("GET /health answered \$(r.status)")
        String(r.body) == "{\\"status\\":\\"ok\\"}" || error("unexpected body: \$(String(r.body))")
    finally
        terminate(DemoApp.app)
    end
    println("served")
    """)
@test occursin("served", read(logfile, String))

# The program (#798). With `API_SECRET_KEY` unset, `main` fails before `serve` is called. The entry
# prints one value-free line and exits with 1: no fatal dump, no backtrace, and not the
# `KeyError`'s key, which is what a compiled executable's fatal printer would have written.
errfile = joinpath(mktempdir(), "entry.err")
entry = addenv(Cmd(`$(Base.julia_cmd()) --project=$root main.jl`; dir = root),
               "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ';' : ':'),
               "JULIA_PROJECT" => nothing, "API_SECRET_KEY" => nothing)
proc = open(errfile, "w") do err
    run(pipeline(entry; stdout = devnull, stderr = err); wait = false)
end
if timedwait(() -> process_exited(proc), 300) === :timed_out
    kill(proc)
    wait(proc)
end
err = read(errfile, String)
proc.exitcode == 1 || println(err)
@test proc.exitcode == 1
@test occursin(r"^start-up failed: KeyError \(its contents are withheld"m, err)
@test !occursin("API_SECRET_KEY", err)
@test !occursin("Stacktrace", err) && !occursin("fatal:", err)
end
