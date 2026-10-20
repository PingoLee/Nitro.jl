@testitem "examples/reusable_package -- both projects resolve, pass their tests and serve (#6)" tags=[:core, :slow, :network] setup=[NitroCommon] begin
using Test
using Nitro
using Pkg: TOML

# The rot guard for the example tree: an example only stays right if something runs it. It runs
# in a copy of the example, so instantiating writes no Manifest.toml into the checkout. The
# copy's `[sources]` point Nitro at this checkout by an absolute path; `HostApp`'s relative path
# to `CatalogApp` holds inside the copy.
#
# One child, in HostApp's environment, which resolves CatalogApp and Nitro through those
# sources: one resolve and one precompile, and both projects' tests `include`d rather than run
# through `Pkg.test`, whose sandboxes would each resolve and precompile again and could outrun
# the suite's per-item ceiling. The trade: CatalogApp's own `[targets]` are not resolved
# standalone, as the README's per-project `Pkg.test()` does. The child's `JULIA_LOAD_PATH` is
# pinned so this test environment cannot leak into what it resolves; `@stdlib` is what supplies
# `Test`.
checkout = pkgdir(Nitro)
example = joinpath(mktempdir(), "reusable_package")
cp(joinpath(checkout, "examples", "reusable_package"), example)
for project in ("CatalogApp", "HostApp")
    dir = joinpath(example, project)
    rm(joinpath(dir, "Manifest.toml"); force = true)   # one left by a local run of the example
    file = joinpath(dir, "Project.toml")
    p = TOML.parsefile(file)
    @test p["sources"]["Nitro"] == Dict("path" => "../../..")   # the example tracks its checkout
    p["sources"]["Nitro"] = Dict("path" => checkout)
    open(io -> TOML.print(io, p), file, "w")
end
root = joinpath(example, "HostApp")
logfile = joinpath(mktempdir(), "child.log")

script = """
    using Pkg
    Pkg.instantiate()

    using CatalogApp, HostApp, HTTP, Nitro, Sockets, Test
    include(joinpath(pkgdir(CatalogApp), "test", "runtests.jl"))
    include(joinpath(pkgdir(HostApp), "test", "runtests.jl"))

    # And `main()` boots: it reads the environment, registers and serves on a real port.
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    ENV["PORT"] = string(port)
    ENV["CATALOG_API_KEY"] = "change-me"
    HostApp.main(; host = "127.0.0.1", async = true, show_banner = false, access_log = nothing)
    try
        base = "http://127.0.0.1:\$port"
        post(headers) = HTTP.post("\$base/api/products",
                                  ["Content-Type" => "application/json", headers...],
                                  "{\\"name\\": \\"lamp\\"}"; retry = false, status_exception = false)
        r = post([])
        r.status == 401 || error("POST without a key answered \$(r.status)")
        r = post(["X-Api-Key" => "change-me"])
        r.status == 201 || error("POST with the key answered \$(r.status)")
        r = HTTP.get("\$base/api/products/1"; retry = false, status_exception = false)
        r.status == 200 || error("GET /api/products/1 answered \$(r.status)")
        Nitro.json(r)["name"] == "lamp" || error("unexpected body: \$(String(r.body))")
    finally
        terminate(HostApp.app)
    end
    """

# Below the suite's 600 s per-item ceiling, so a hung child is killed and its log printed here
# rather than the whole item being cut off with nothing to read.
cmd = addenv(Cmd(`$(Base.julia_cmd()) --project=$root -e $script`; dir = root),
             "JULIA_LOAD_PATH" => join(["@", "@stdlib"], Sys.iswindows() ? ';' : ':'),
             "JULIA_PROJECT" => nothing)
proc = open(logfile, "w") do log
    run(pipeline(cmd; stdout = log, stderr = log); wait = false)
end
if timedwait(() -> process_exited(proc), 540) === :timed_out
    kill(proc)
    wait(proc)
end
ok = success(proc)
ok || println(read(logfile, String))
@test ok
end
