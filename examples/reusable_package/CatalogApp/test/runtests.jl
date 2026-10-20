using Test, HTTP, Nitro, CatalogApp

const JSON_HEADERS = ["Content-Type" => "application/json"]

body(res) = Nitro.json(res)

@testset "CatalogApp" begin

@testset "routes() is a value: building it registers nothing" begin
    defs = routes(Catalog(); prefix = "/items", namespace = "items")
    @test defs isa Vector{RouteDefinition}
    @test [(d.pattern, d.methods, d.name) for d in defs] == [
        ("/items", ["GET"], "items.list"),
        ("/items/{id}", ["GET"], "items.detail"),
        ("/items", ["POST"], "items.create"),
    ]
    # Nothing reached the process-wide app either, the only one a package could reach unasked.
    @test internalrequest(HTTP.Request("GET", "/items")).status == 404
end

@testset "RequireApiKey refuses an empty key" begin
    @test_throws "must not be empty" RequireApiKey(key = SecretString(""))
end

@testset "list, create, detail" begin
    app = App(mod = CatalogApp)
    urlpatterns(app, "", routes(Catalog()))

    @test body(internalrequest(app, HTTP.Request("GET", "/products"))) == []

    res = internalrequest(app, HTTP.Request("POST", "/products", JSON_HEADERS,
                                            """{"name": "lamp", "price_cents": 1500}"""))
    @test res.status == 201
    @test body(res) == Dict("id" => 1, "name" => "lamp", "price_cents" => 1500)

    res = internalrequest(app, HTTP.Request("GET", "/products/1"))
    @test res.status == 200
    @test body(res)["name"] == "lamp"

    @test internalrequest(app, HTTP.Request("GET", "/products/99")).status == 404
    # The `<int:id>` converter refuses a non-integer before the handler runs.
    @test internalrequest(app, HTTP.Request("GET", "/products/lamp")).status == 400
    # `Json{NewProduct}` refuses a body without its required `name`.
    @test internalrequest(app, HTTP.Request("POST", "/products", JSON_HEADERS,
                                            """{"price_cents": 1}""")).status == 400
end

@testset "write_middleware guards POST only" begin
    app = App(mod = CatalogApp)
    guard = RequireApiKey(key = SecretString("k"^32))
    urlpatterns(app, "", routes(Catalog(); write_middleware = [guard]))

    post(headers) = internalrequest(app, HTTP.Request("POST", "/products",
                                                      vcat(JSON_HEADERS, headers),
                                                      """{"name": "lamp"}"""))
    @test post([]).status == 401
    @test post(["X-Api-Key" => "wrong"]).status == 401
    @test post(["X-Api-Key" => "k"^32]).status == 201
    @test internalrequest(app, HTTP.Request("GET", "/products")).status == 200
end

@testset "one app mounts the package twice, each with its own state and names" begin
    app = App(mod = CatalogApp)
    urlpatterns(app, "/shop", vcat(
        routes(Catalog(); prefix = "/products", namespace = "products"),
        routes(Catalog(); prefix = "/services", namespace = "services"),
    ))

    res = internalrequest(app, HTTP.Request("POST", "/shop/products", JSON_HEADERS,
                                            """{"name": "lamp"}"""))
    @test res.status == 201
    @test length(body(internalrequest(app, HTTP.Request("GET", "/shop/products")))) == 1
    @test isempty(body(internalrequest(app, HTTP.Request("GET", "/shop/services"))))

    @test url(app, "products.detail"; id = 1) == "/shop/products/1"
    @test url(app, "services.list") == "/shop/services"
    # Without distinct namespaces, the second mount's names collide with the first's.
    @test_throws r"Duplicate route name: 'products\.list'" urlpatterns(
        app, "/other", routes(Catalog(); namespace = "products"))
end

end
