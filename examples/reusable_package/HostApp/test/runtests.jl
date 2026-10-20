using Test, HTTP, Nitro, HostApp

@testset "HostApp" begin
    # A fresh App, so the test never touches `HostApp.app`, the one `main()` serves.
    app = App(mod = HostApp)
    key = "k"^32
    urlpatterns(app, "", HostApp.urls(api_key = SecretString(key)))

    res = internalrequest(app, HTTP.Request("GET", "/health"))
    @test res.status == 200
    @test Nitro.json(res) == Dict("status" => "ok")

    create(headers) = internalrequest(app, HTTP.Request("POST", "/api/products",
        ["Content-Type" => "application/json", headers...], """{"name": "lamp"}"""))
    @test create([]).status == 401
    @test create(["X-Api-Key" => key]).status == 201

    res = internalrequest(app, HTTP.Request("GET", "/api/products/1"))
    @test res.status == 200
    @test Nitro.json(res)["name"] == "lamp"

    # The package's route names, under the prefix the host chose.
    @test url(app, "catalog.detail"; id = 1) == "/api/products/1"
end
