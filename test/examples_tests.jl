@testitem "examples/reusable_package -- both projects resolve, pass their tests and serve (#6)" tags=[:core, :slow, :network] setup=[NitroCommon, ExampleHarness] begin
using Test

example = copy_example("reusable_package", ("CatalogApp", "HostApp"))

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

@test run_child(joinpath(example, "HostApp"), script)
end

@testitem "examples/auth_package -- both projects resolve, pass their tests and serve (#674)" tags=[:core, :slow, :network] setup=[NitroCommon, ExampleHarness] begin
using Test

example = copy_example("auth_package", ("AuthKit", "AuthHost"))

script = """
    using Pkg
    Pkg.instantiate()

    using AuthKit, AuthHost, HTTP, Nitro, Sockets, Test
    include(joinpath(pkgdir(AuthKit), "test", "runtests.jl"))
    include(joinpath(pkgdir(AuthHost), "test", "runtests.jl"))

    # And `main()` boots on a real port: sign in, then call the admin-only route with the token.
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    ENV["PORT"] = string(port)
    ENV["AUTH_JWT_SECRET"] = "s"^32
    ENV["ADMIN_PASSWORD"] = "wonderland"
    ENV["MEMBER_PASSWORD"] = "builder"
    AuthHost.main(; host = "127.0.0.1", async = true, show_banner = false, access_log = nothing)
    try
        base = "http://127.0.0.1:\$port"
        r = HTTP.get("\$base/admin/report"; retry = false, status_exception = false)
        r.status == 401 || error("the report without a token answered \$(r.status)")
        r = HTTP.post("\$base/auth/login", ["Content-Type" => "application/json"],
                      "{\\"username\\": \\"alice\\", \\"password\\": \\"wonderland\\"}";
                      retry = false, status_exception = false)
        r.status == 200 || error("login answered \$(r.status)")
        auth = ["Authorization" => "Bearer " * Nitro.json(r)["token"]]
        r = HTTP.get("\$base/admin/report", auth; retry = false, status_exception = false)
        r.status == 200 || error("the report with alice's token answered \$(r.status)")
        Nitro.json(r)["requested_by"] == "alice" || error("unexpected body: \$(String(r.body))")
        r = HTTP.post("\$base/auth/logout", auth; retry = false, status_exception = false)
        r.status == 204 || error("logout answered \$(r.status)")
        r = HTTP.get("\$base/admin/report", auth; retry = false, status_exception = false)
        r.status == 401 || error("the report after logout answered \$(r.status)")
    finally
        terminate(AuthHost.app)
    end
    """

@test run_child(joinpath(example, "AuthHost"), script)
end
