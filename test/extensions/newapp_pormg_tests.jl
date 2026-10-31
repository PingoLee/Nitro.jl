@testitem "newapp -- the PormG branch (#417)" tags=[:extension, :pormg] setup=[NitroCommon] begin
using Test
using Nitro
using Pkg: TOML

@eval using PormG

@testset "the extension fills the exts.jl stub" begin
    @test !isempty(methods(Nitro._newapp_pormg))
end

# The real `PormG.setup`, driven through stdin so it can never wait on a prompt: SQLite, the
# default file name, UTC, the default models file, and "n" to PormG's AI-skill install.
function generate(name, root)
    answers = joinpath(mktempdir(), "answers.txt")
    write(answers, "2\n\n\n\nn\n")
    open(answers) do io
        redirect_stdin(io) do
            redirect_stdout(devnull) do
                Nitro.newapp(name; path = root)
            end
        end
    end
end

root = generate("MyApp", joinpath(mktempdir(), "myapp"))

@testset "PormG.setup wrote db/, and only db/" begin
    @test isfile(joinpath(root, "db", "connection.yml"))
    @test isfile(joinpath(root, "db", "models.jl"))
    @test occursin("adapter: SQLite", read(joinpath(root, "db", "connection.yml"), String))
    @test !ispath(joinpath(root, ".github"))     # the AI-skill question was answered "n"
    @test readlines(joinpath(root, ".gitignore")) == ["db/connection.yml"]
end

src = read(joinpath(root, "src", "MyApp.jl"), String)

@testset "the boot loads and binds in main(), never in the module body" begin
    body, main = split(src, "\"\"\"\n    main"; limit = 2)
    @test occursin("using Nitro, PormG, SQLite", body)
    # PormG refuses `@import_models` against a folder no `load` has loaded, outside a REPL
    # (PormG #1226), and a precompile is never one: the models are included, and bound in main.
    @test !occursin("load_many", body)
    @test !occursin("@import_models", src)
    @test occursin("#   include(\"../db/models.jl\")", body)
    # The environment is named, because PormG refuses a `load` with none outside a REPL (#790):
    # a set `PORMG_ENV` first, as PormG 0.8 read it, then Nitro's.
    @test occursin("env = something(sync_pormg_env!(), current_env())", main)
    # `db/` is found from `root` (#798), which defaults to `pkgdir` only when nothing passes one:
    # a JuliaC executable's `pkgdir` is the temporary copy it was built from.
    @test occursin("function main(; root::AbstractString = pkgdir(@__MODULE__), kwargs...)", main)
    @test occursin("PormG.Configuration.load_many([\"db\"]; root, env)", main)
    @test occursin("#   PormG.Models.set_models(models, joinpath(root, \"db\"))", main)
    # The default in the signature (written twice: docstring and definition) and the docstring's
    # note on JuliaC. Nothing in the body: `load_many` and `set_models` take `root`.
    @test count("pkgdir", main) == 3
    @test occursin("store = pormg_nitro_worker(db_key = \"db\")", main)
end

entry = read(joinpath(root, "main.jl"), String)

@testset "main.jl passes APP_ROOT, else the working directory, inside the value-free catch (#798)" begin
    @test occursin("using MyApp, Nitro", entry)
    @test occursin("        MyApp.main(; root = get(ENV, \"APP_ROOT\", pwd()))\n    catch e\n", entry)
    @test occursin("e isa InterruptException && rethrow()", entry)
    @test occursin("println(Core.stderr, \"start-up failed: \", Nitro.startup_failure_text(e))",
                   entry)
    @test !occursin("pkgdir(", entry) && !occursin("@__DIR__", entry)
    @test !occursin(r"^\s*@error"m, entry) && !occursin("showerror", entry)
    @test Meta.parseall(entry) isa Expr
end

@testset "Project.toml installs PormG by URL and the driver the adapter needs" begin
    project = TOML.parsefile(joinpath(root, "Project.toml"))
    nitro_project = TOML.parsefile(joinpath(pkgdir(Nitro), "Project.toml"))
    pormg_project = TOML.parsefile(joinpath(pkgdir(PormG), "Project.toml"))
    @test sort!(collect(keys(project["deps"]))) == ["HTTP", "Nitro", "PormG", "SQLite"]
    @test project["deps"]["PormG"] == nitro_project["weakdeps"]["PormG"]
    # Nitro's own pins, both of them, so the generated app and Nitro cannot drift apart.
    @test project["sources"]["PormG"] == nitro_project["sources"]["PormG"]
    @test occursin(r"^[0-9a-f]{40}$", project["sources"]["PormG"]["rev"])
    @test project["compat"]["PormG"] == nitro_project["compat"]["PormG"]
    # The drivers the extension knows are PormG's own weak dependencies, at PormG's compat.
    @test project["deps"]["SQLite"] == pormg_project["weakdeps"]["SQLite"]
    @test project["compat"]["SQLite"] == pormg_project["compat"]["SQLite"]
    @test haskey(pormg_project["weakdeps"], "LibPQ")
    @test pormg_project["compat"]["LibPQ"] == "1"
end

@testset "PostgreSQL brings LibPQ" begin
    pg = joinpath(mktempdir(), "pg")
    answers = joinpath(mktempdir(), "answers.txt")
    # PostgreSQL, then name, host, user, password, port, time zone, models file, AI skills.
    write(answers, "1\nshop\n\nshop\nplaceholder\n\n\n\nn\n")
    open(answers) do io
        redirect_stdin(io) do
            redirect_stdout(devnull) do
                Nitro.newapp("PgApp"; path = pg)
            end
        end
    end
    @test occursin("using Nitro, PormG, LibPQ", read(joinpath(pg, "src", "PgApp.jl"), String))
    project = TOML.parsefile(joinpath(pg, "Project.toml"))
    pormg_project = TOML.parsefile(joinpath(pkgdir(PormG), "Project.toml"))
    @test project["deps"]["LibPQ"] == pormg_project["weakdeps"]["LibPQ"]
end

# The single source for the tutorial's boot (#417) and entry (#798): `bigger_applications.md`
# carries these exact files between the markers. Regenerate them with `Nitro.newapp("MyApp")`
# (SQLite) and paste.
@testset "bigger_applications.md shows exactly what newapp writes" begin
    # A Windows checkout may give the page CRLF line endings; the generated file has LF.
    md = replace(read(joinpath(pkgdir(Nitro), "docs", "src", "tutorial", "bigger_applications.md"),
                      String), "\r\n" => "\n")
    for (file, content) in ("src/MyApp.jl" => src, "main.jl" => entry)
        # `String * Regex` quotes the string, so the file name's `.` is literal.
        m = match("<!-- newapp:$file -->\n```julia\n" * r"(.*?)```\n<!-- /newapp -->"s, md)
        @test m !== nothing
        m === nothing || @test m[1] == content
    end
end
end

@testitem "newapp -- a PormG app with models precompiles, binds and serves (#790)" tags=[:extension, :pormg, :slow, :network] setup=[NitroCommon] begin
# Every child below takes its time from this one clock (#817). The runner stops the whole run at
# 600 s per item, from before this line: a filtered or shuffled run evaluates `NitroCommon` cold
# first. So the children share 500 s, a child shutdown adds at most 45 s (`stop!`), and a
# `health()` poll in flight at the deadline at most 7 s. A slow leg then fails in a child, with
# that child's log, never by the watchdog.
T0 = time()
DEADLINE = T0 + 500
left_for(cap) = min(cap, DEADLINE - time())
elapsed() = round(time() - T0; digits = 1)

using Test
using Nitro
using HTTP, Sockets

@eval using PormG

# The rot guard for the PormG half, as `test/newapp_tests.jl` is for the in-memory one. It runs
# what a user does next: define a model, uncomment the lines the template says to, and load the
# package -- which precompiles it in a worker that is never a REPL. That is where PormG 0.9
# refuses `@import_models` against a folder no `load` has loaded (PormG #1226), and where a `load`
# with no environment is refused (PormG #1228). `NITRO_ENV` and `PORMG_ENV` are unset in the
# child, so the environment is `current_env()`'s "dev", the one block a SQLite `PormG.setup` writes.
root = joinpath(mktempdir(), "shop")
answers = joinpath(mktempdir(), "answers.txt")
write(answers, "2\n\n\n\nn\n")
open(answers) do io
    redirect_stdin(io) do
        redirect_stdout(devnull) do
            Nitro.newapp("ShopApp"; path = root)
        end
    end
end

# The model goes INTO the file `PormG.setup` wrote, before its closing `end`, rather than over
# it: whatever PormG's generator puts there (a registration line, a module name) is loaded too.
models_file = joinpath(root, "db", "models.jl")
models_src = read(models_file, String)
@test occursin(r"^module models$"m, models_src)
ends = collect(eachmatch(r"^end\b"m, models_src))
@test !isempty(ends)
close_at = last(ends).offset
models_src = models_src[1:prevind(models_src, close_at)] *
    "Item = Models.Model(\"item\", id = Models.IDField(), " *
    "name = Models.CharField(max_length = 50))\n\n" * models_src[close_at:end]
write(models_file, models_src)
modfile = joinpath(root, "src", "ShopApp.jl")
src = read(modfile, String)
for line in ("include(\"../db/models.jl\")", "const appM = models",
             "PormG.Models.set_models(models, joinpath(root, \"db\"))")
    @test occursin("#   " * line, src)
    src = replace(src, "#   " * line => line)
end
write(modfile, src)

checkout = pkgdir(Nitro)
logfile = joinpath(mktempdir(), "child.log")

# SIGTERM, then a bounded wait, never a bare `wait(proc)` (#816): a served child once ignored the
# SIGTERM, and the unbounded wait parked the item until the runner stopped the run. A child that
# outlives `grace` gets a SIGQUIT, which makes Julia print every task's backtrace into its log,
# then a SIGKILL. Returns whether the SIGTERM alone ended it. On Windows `kill` is
# `TerminateProcess`, so there it always does.
#
# A SIGTERM never reaches `terminate()` or its drains: a script ends through its `atexit` hooks
# only (`serve`'s docstring, src/methods.jl), and the one this app has is PormG's, which closes the
# pools with no drain. A healthy exit takes seconds, so a child alive after `grace` is stuck.
function stop!(proc; grace = 30, dump_grace = 15)
    kill(proc)
    timedwait(() -> process_exited(proc), grace) === :ok && return true
    println("── the child outlived its SIGTERM by $grace s (#816); on Linux, its task dump is in the log")
    if !Sys.iswindows()
        kill(proc, Base.SIGQUIT)
        timedwait(() -> process_exited(proc), dump_grace)
    end
    process_exited(proc) || kill(proc, Base.SIGKILL)
    wait(proc)
    return false
end

# The escalation runs only when #816 fires, so it is exercised here against a child that ignores
# SIGTERM and SIGQUIT both, and that only the SIGKILL can end. POSIX only: see above.
if !Sys.iswindows()
    deaf = run(`sh -c 'trap "" TERM QUIT; exec sleep 300'`; wait = false)
    @test stop!(deaf; grace = 1, dump_grace = 1) == false
    @test process_exited(deaf) && deaf.termsignal == Base.SIGKILL
end

# `--code-coverage=none`, as every other child in the suite runs: on the coverage leg an inherited
# flag would precompile and run the generated app, and everything it loads, instrumented (#817),
# and no child's coverage is collected anyway.
child_cmd(args...; env...) =
    addenv(Cmd(`$(Base.julia_cmd()) --code-coverage=none --project=$root $args`; dir = root),
           "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ';' : ':'),
           "JULIA_PROJECT" => nothing, "NITRO_ENV" => nothing, "GENIE_ENV" => nothing,
           "PORMG_ENV" => nothing, (string(k) => v for (k, v) in env)...)

# Each child gets `timeout`, or what is left of the item's clock if that is less. The legs after
# the first only load what it precompiled, so their caps are shorter.
function run_child(script; timeout = 280)
    t = left_for(timeout)
    if t <= 0
        println("── no time left on the item's clock at $(elapsed()) s; the child was not started")
        return false
    end
    proc = open(logfile, "a") do log
        run(pipeline(child_cmd("-e", script); stdout = log, stderr = log); wait = false)
    end
    if timedwait(() -> process_exited(proc), t) === :timed_out
        println("── the child ran past its $(round(t; digits = 1)) s")
        stop!(proc)
    end
    ok = success(proc)
    println("── child done at $(elapsed()) s, ok = $ok")
    ok || println(read(logfile, String))
    return ok
end

# As in `test/newapp_tests.jl`: Pkg refuses to `develop` over a `url` source, so drop Nitro's.
# PormG stays on the `[sources]` commit the template copied from Nitro's own Project.toml.
@test run_child("""
    using Pkg
    p = Pkg.TOML.parsefile("Project.toml")
    delete!(p["sources"], "Nitro")
    open(io -> Pkg.TOML.print(io, p), "Project.toml", "w")
    Pkg.develop(path = $(repr(checkout)))
    Pkg.instantiate()
    """)

# `root` (#798): `db/` moves to another folder and the package's own loses its connection.yml,
# as a JuliaC executable's `pkgdir` names a folder that no longer holds one. Only a boot that
# takes `db/` from `root` connects. (models.jl stays: the package includes it as it precompiles.)
alt = mktempdir()
cp(joinpath(root, "db"), joinpath(alt, "db"))
mv(joinpath(root, "db", "connection.yml"), joinpath(root, "db", "connection.yml.moved"))

@test run_child("""
    using ShopApp, HTTP, Nitro, Sockets

    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    ENV["PORT"] = string(port)
    ENV["API_SECRET_KEY"] = "x"^32    # a placeholder: the boot requires 32 bytes
    ShopApp.main(; root = $(repr(alt)), host = "127.0.0.1", async = true, show_banner = false,
                 access_log = nothing)
    try
        ShopApp.appM.Item.connect_key == "db" ||
            error("the models are bound to \$(repr(ShopApp.appM.Item.connect_key)), not \\"db\\"")
        r = HTTP.get("http://127.0.0.1:\$port/health"; retry = false, status_exception = false)
        r.status == 200 || error("GET /health answered \$(r.status)")
    finally
        terminate(ShopApp.app)
    end
    println("bound and served")
    """; timeout = 180)
@test occursin("bound and served", read(logfile, String))

# The program itself, run the way an executable runs it: `main.jl` from the app's directory,
# whose db/ no longer has a connection.yml, with `APP_ROOT` naming the folder that does.
server = Sockets.listen(Sockets.localhost, 0)
port = Int(Sockets.getsockname(server)[2])
close(server)
health() = try
    HTTP.get("http://127.0.0.1:$port/health"; retry = false, status_exception = false,
             connect_timeout = 2, readtimeout = 5).status == 200
catch
    false
end
# Returns (served, stopped): whether `/health` answered, and whether the SIGTERM alone ended it.
function run_entry(; timeout = 120)
    t = left_for(timeout)
    if t <= 0
        println("── no time left on the item's clock at $(elapsed()) s; main.jl was not started")
        return (false, true)
    end
    entry = child_cmd("main.jl"; APP_ROOT = alt, PORT = string(port), API_SECRET_KEY = "x"^32)
    proc = open(logfile, "a") do log
        run(pipeline(entry; stdout = log, stderr = log); wait = false)
    end
    # The poll records its own answer: a second `health()` after it could add another 7 s.
    up = Ref(false)
    stopped = false
    try
        timedwait(() -> process_exited(proc) || (up[] = health()), t; pollint = 1)
    finally
        stopped = stop!(proc)
    end
    served = up[]
    println("── main.jl done at $(elapsed()) s, served = $served, stopped = $stopped")
    return (served, stopped)
end
served, stopped = run_entry()
served && stopped || println(read(logfile, String))
@test served
# A served program ends on SIGTERM. #816 is the case where it did not.
@test stopped
end
