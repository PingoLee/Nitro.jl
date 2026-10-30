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
    @test occursin("PormG.Configuration.load_many([\"db\"]; root = pkgdir(@__MODULE__), env)", main)
    @test occursin("#   PormG.Models.set_models(models, joinpath(pkgdir(@__MODULE__), \"db\"))", main)
    @test occursin("store = pormg_nitro_worker(db_key = \"db\")", main)
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

# The single source for the tutorial's boot (#417): `bigger_applications.md` carries this exact
# file between the markers. Regenerate it with `Nitro.newapp("MyApp")` (SQLite) and paste.
@testset "bigger_applications.md shows exactly what newapp writes" begin
    # A Windows checkout may give the page CRLF line endings; the generated file has LF.
    md = replace(read(joinpath(pkgdir(Nitro), "docs", "src", "tutorial", "bigger_applications.md"),
                      String), "\r\n" => "\n")
    m = match(r"<!-- newapp:src/MyApp\.jl -->\n```julia\n(.*?)```\n<!-- /newapp -->"s, md)
    @test m !== nothing
    m === nothing || @test m[1] == src
end
end

@testitem "newapp -- a PormG app with models precompiles, binds and serves (#790)" tags=[:extension, :pormg, :slow, :network] setup=[NitroCommon] begin
using Test
using Nitro

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
             "PormG.Models.set_models(models, joinpath(pkgdir(@__MODULE__), \"db\"))")
    @test occursin("#   " * line, src)
    src = replace(src, "#   " * line => line)
end
write(modfile, src)

checkout = pkgdir(Nitro)
logfile = joinpath(mktempdir(), "child.log")
# Both children fit inside the runner's 600 s per-item watchdog, so a slow leg fails here, with
# the child's log, instead of the watchdog killing the whole run.
function run_child(script; timeout = 280)
    cmd = addenv(Cmd(`$(Base.julia_cmd()) --project=$root -e $script`; dir = root),
                 "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ';' : ':'),
                 "JULIA_PROJECT" => nothing, "NITRO_ENV" => nothing, "GENIE_ENV" => nothing,
                 "PORMG_ENV" => nothing)
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

@test run_child("""
    using ShopApp, HTTP, Nitro, Sockets

    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    ENV["PORT"] = string(port)
    ENV["API_SECRET_KEY"] = "x"^32    # a placeholder: the boot requires 32 bytes
    ShopApp.main(; host = "127.0.0.1", async = true, show_banner = false, access_log = nothing)
    try
        ShopApp.appM.Item.connect_key == "db" ||
            error("the models are bound to \$(repr(ShopApp.appM.Item.connect_key)), not \\"db\\"")
        r = HTTP.get("http://127.0.0.1:\$port/health"; retry = false, status_exception = false)
        r.status == 200 || error("GET /health answered \$(r.status)")
    finally
        terminate(ShopApp.app)
    end
    println("bound and served")
    """)
@test occursin("bound and served", read(logfile, String))
end
