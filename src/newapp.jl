# newapp — the project scaffold, Django's `startproject` (#417)
#
# A generator is a second place that encodes the canonical boot, so two things keep it honest:
# `test/newapp_tests.jl` generates an app, develops this checkout into it and serves a request
# from it, and `test/extensions/newapp_pormg_tests.jl` asserts that the boot pasted into
# `docs/src/tutorial/bigger_applications.md` is byte-for-byte what this file writes. Change the
# template and the tutorial changes with it, or that test fails.
#
# PormG is a weak dependency, so the `pormg = true` half lives in `ext/NitroPormGExt.jl` behind
# the `_newapp_pormg` stub in `src/exts.jl`. It hands back a `_NewappDB`, and this file renders
# it; the template itself stays in one place.

import HTTP
import UUIDs

# The database half of the generated app — what differs between `pormg = true` and `false`.
Base.@kwdef struct _NewappDB
    usings::String                              # the module's `using` line
    module_note::Vector{String} = String[]      # module-body comment lines after the `App` const
    boot::Vector{String} = String[]             # `main()` lines before `worker_startup`
    store::String                               # the worker-store expression
    deps::Vector{Pair{String,String}} = Pair{String,String}[]      # name => uuid
    sources::Vector{Pair{String,String}} = Pair{String,String}[]   # name => inline table
    compat::Vector{Pair{String,String}} = Pair{String,String}[]    # name => compat
    gitignore::Vector{String} = String[]
end

const _NEWAPP_MEMORY =
    _NewappDB(usings = "using Nitro", store = "Nitro.Workers.InMemoryWorkerStore()")

# Kept equal to Nitro's own `julia` compat by `test/newapp_tests.jl`. HTTP's is derived from the
# loaded version instead, because Nitro pins it to one minor series (`~`) on purpose.
const _NEWAPP_JULIA_COMPAT = "^1.12"
const _NEWAPP_NITRO_URL = "https://github.com/PingoLee/Nitro.jl.git"
const _TEST_UUID = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

# A module named after a dependency (or `Main`) cannot coexist with it in the generated project.
# `SQLite` and `LibPQ` are the database drivers the PormG branch may add.
const _NEWAPP_TAKEN_NAMES =
    ("Nitro", "HTTP", "PormG", "SQLite", "LibPQ", "Test", "Base", "Core", "Main")

"""
    Nitro.newapp(name; path = ".", pormg = true) -> String

Write a new Nitro application named `name` into the directory `path`, laid out the way the
*Bigger Applications* tutorial recommends, and return that directory's absolute path. Public but
not exported: call it qualified, `Nitro.newapp("MyApp")`.

```
path/
├── Project.toml                 # Nitro and HTTP (and PormG) — installed by URL
├── .gitignore                   # pormg = true: excludes db/connection.yml (it holds the password)
├── db/                          # pormg = true only — written by PormG.setup
├── src/
│   ├── MyApp.jl                 # the module and its main() boot
│   ├── Routes.jl                # one path("/health", …)
│   └── Handlers/HealthHandlers.jl
└── test/runtests.jl             # one internalrequest test
```

The module body holds only `using`, `const app = App(mod = @__MODULE__)` and `include`s.
Everything that connects or starts runs in `main(; kwargs...)`, which reads `PORT` (default
`8000`) and `API_SECRET_KEY` (at least 32 bytes) from the environment and passes `kwargs` to
[`serve`](@ref). A module body runs at precompile time and never again, so a connection opened
there would be gone at runtime.

With `pormg = true` (the default) `using PormG` must come first. The boot then loads `db/` with
`PormG.Configuration.load_many` and stores worker tasks through
[`pormg_nitro_worker`](@ref), and once Nitro's files are written PormG's own interactive
`PormG.setup` asks for the database and writes `db/connection.yml`. Answer its questions in the
REPL. PormG's database drivers are weak dependencies, so the adapter you choose decides which one
the app installs and loads: `SQLite` for SQLite, `LibPQ` for PostgreSQL. If you leave the prompt,
the app is written without a driver; run `PormG.setup("db")` from the app directory and add the
driver yourself. With `pormg = false` the boot uses an in-memory worker store and there is no
`db/`.

`Project.toml` installs Nitro and PormG from their repositories, since neither is in Julia's
General registry. Each `rev` is the release tag of the version you generated with
(`v\$(pkgversion(Nitro))`). Generating from an unreleased checkout therefore pins its last release.
The first `Pkg.instantiate()` records the exact commit in `Manifest.toml`, which is the app's
real lock. To work on Nitro itself from the app, delete the `Nitro` line from `[sources]` before
`Pkg.develop`: Pkg refuses a `path` on top of a `url`. Next steps:

```julia
julia> using Nitro, PormG

julia> Nitro.newapp("MyApp"; path = "myapp")

shell> cd myapp

julia> using Pkg; Pkg.activate("."); Pkg.instantiate()

julia> using MyApp; MyApp.main()
```

Throws an `ArgumentError`, and writes nothing, when `name` is not a valid Julia module name (or
is the name of a dependency), when `path` exists and is not an empty directory, or when
`pormg = true` and PormG is not loaded. There is no `force`: delete the directory yourself.
"""
function newapp(name::AbstractString; path::AbstractString = ".", pormg::Bool = true)
    name = String(name)
    _valid_module_name(name) || throw(ArgumentError(
        "`$name` is not a valid Julia module name; use an identifier such as `MyApp`"))
    name in _NEWAPP_TAKEN_NAMES && throw(ArgumentError(
        "`$name` is the name of a module the generated app depends on; choose another"))
    root = abspath(path)
    if ispath(root) && !(isdir(root) && isempty(readdir(root)))
        throw(ArgumentError("`$root` already exists and is not empty; " *
                            "choose a new path or delete it first"))
    end
    if pormg && isempty(methods(_newapp_pormg))
        throw(ArgumentError("`pormg = true` needs PormG loaded: run `using PormG` first, " *
                            "or pass `pormg = false`"))
    end

    if pormg
        _newapp_pormg(db -> _write_newapp(root, _newapp_files(name, db)), root)
    else
        _write_newapp(root, _newapp_files(name, _NEWAPP_MEMORY))
    end
    return root
end

# `Base.isidentifier` accepts `end`, `struct` and the other keywords; parsing the name back
# rejects them, and `true`/`false`, which parse to a `Bool`.
_valid_module_name(name::String) =
    Base.isidentifier(name) && (try Meta.parse(name) === Symbol(name) catch; false end)

function _write_newapp(root::String, files::Vector{Pair{String,String}})
    for (rel, content) in files
        file = joinpath(root, rel)
        mkpath(dirname(file))
        write(file, content)
    end
    return nothing
end

# Every file of the generated app as `relative path => content`. Pure, so tests compare strings.
function _newapp_files(name::String, db::_NewappDB)::Vector{Pair{String,String}}
    files = [
        "Project.toml" => _newapp_project(name, db),
        "src/$name.jl" => _newapp_module(name, db),
        "src/Routes.jl" => _NEWAPP_ROUTES,
        "src/Handlers/HealthHandlers.jl" => _NEWAPP_HEALTH,
        "test/runtests.jl" => _newapp_test(name),
    ]
    isempty(db.gitignore) || push!(files, ".gitignore" => join(db.gitignore, "\n") * "\n")
    return files
end

function _newapp_project(name::String, db::_NewappDB)
    nitro = string(pkgversion(@__MODULE__))
    http = pkgversion(HTTP)
    deps = sort!(vcat(["HTTP" => string(Base.PkgId(HTTP).uuid),
                       "Nitro" => string(Base.PkgId(@__MODULE__).uuid)], db.deps); by = first)
    sources = vcat(["Nitro" => "{url = \"$_NEWAPP_NITRO_URL\", rev = \"v$nitro\"}"], db.sources)
    compat = sort!(vcat(["HTTP" => "~$(http.major).$(http.minor)", "Nitro" => nitro], db.compat);
                   by = first)
    push!(compat, "julia" => _NEWAPP_JULIA_COMPAT)
    entries(ps) = join(("$k = $v" for (k, v) in ps), "\n")
    quoted(ps) = entries(k => "\"$v\"" for (k, v) in ps)
    return """
        name = "$name"
        uuid = "$(UUIDs.uuid4())"
        version = "0.1.0"

        [deps]
        $(quoted(deps))

        [sources]
        $(entries(sources))

        [compat]
        $(quoted(compat))

        [extras]
        Test = "$_TEST_UUID"

        [targets]
        test = ["Test"]
        """
end

function _newapp_module(name::String, db::_NewappDB)
    lines = String[
        "module $name",
        "",
        db.usings,
        "",
        "const app = App(mod = @__MODULE__)",
        "",
    ]
    isempty(db.module_note) || append!(lines, db.module_note, [""])
    append!(lines, [
        "include(\"Handlers/HealthHandlers.jl\")",
        "include(\"Routes.jl\")",
        "",
        "\"\"\"",
        "    main(; kwargs...)",
        "",
        "Boot the app and serve it. Reads `PORT` (default 8000) and `API_SECRET_KEY` (at least",
        "32 bytes); keyword arguments go to `serve` (tests pass `async = true`).",
        "\"\"\"",
        "function main(; kwargs...)",
    ])
    append!(lines, ("    " * l for l in db.boot))
    append!(lines, [
        "    workers = worker_startup(app; queues = [\"reports\"], store = $(db.store))",
        "    urlpatterns(app, \"\", Routes.urlpatterns())",
        "    serve(app; port = parse(Int, get(ENV, \"PORT\", \"8000\")), middleware = [workers],",
        "          secret_key = SecretString(ENV[\"API_SECRET_KEY\"]), kwargs...)",
        "end",
        "",
        "end # module",
    ])
    return join(lines, "\n") * "\n"
end

# `using Nitro: path, …` rather than `using Nitro`: this module defines its own `urlpatterns`.
# Under a blanket `using Nitro` that silently shadows Nitro's, and is an error once anything in
# the module has called Nitro's first.
const _NEWAPP_ROUTES = """
    module Routes

    using Nitro: path, RouteDefinition
    import ..HealthHandlers

    urlpatterns() = RouteDefinition[
        path("/health", HealthHandlers.health, method = "GET"),
    ]

    end # module
    """

const _NEWAPP_HEALTH = """
    module HealthHandlers

    using HTTP
    using Nitro

    health(req::HTTP.Request) = Res.json(Dict("status" => "ok"))

    end # module
    """

function _newapp_test(name::String)
    return """
        using Test, HTTP, Nitro, $name

        @testset "$name" begin
            # A fresh App, so the test never touches `$name.app`, the one `main()` serves.
            app = App(mod = $name)
            urlpatterns(app, "", $name.Routes.urlpatterns())
            res = internalrequest(app, HTTP.Request("GET", "/health"))
            @test res.status == 200
        end
        """
end
