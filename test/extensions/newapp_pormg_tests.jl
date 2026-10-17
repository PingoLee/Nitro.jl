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

@testset "the boot connects in main(), never in the module body" begin
    body, main = split(src, "\"\"\"\n    main"; limit = 2)
    @test occursin("using Nitro, PormG, SQLite", body)
    @test !occursin("load_many", body)
    @test occursin("PormG.Configuration.load_many([\"db\"]; root = pkgdir(@__MODULE__))", main)
    @test occursin("store = pormg_nitro_worker(db_key = \"db\")", main)
    @test occursin("sync_pormg_env!()", main)
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
