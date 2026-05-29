@testitem "Django-style routing" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using UUIDs
using Nitro: path, urlpatterns, include_routes, convert_django_path, RouteDefinition, GET, POST, PUT, DELETE, url

port = get_free_port()

# ─── Test: convert_django_path ────────────────────────────────────────

@testset "convert_django_path" begin
    # Basic integer converter
    nitro_path, hints = convert_django_path("/users/<int:id>")
    @test nitro_path == "/users/{id}"
    @test hints[:id] == Int

    # Multiple converters
    nitro_path, hints = convert_django_path("/posts/<str:slug>/comments/<int:comment_id>")
    @test nitro_path == "/posts/{slug}/comments/{comment_id}"
    @test hints[:slug] == String
    @test hints[:comment_id] == Int

    # Float converter
    nitro_path, hints = convert_django_path("/price/<float:amount>")
    @test nitro_path == "/price/{amount}"
    @test hints[:amount] == Float64

    # Bool converter
    nitro_path, hints = convert_django_path("/toggle/<bool:enabled>")
    @test nitro_path == "/toggle/{enabled}"
    @test hints[:enabled] == Bool

    # UUID converter
    nitro_path, hints = convert_django_path("/keys/<uuid:key>")
    @test nitro_path == "/keys/{key}"
    @test hints[:key] == UUID

    # No converters (plain path)
    nitro_path, hints = convert_django_path("/static/page")
    @test nitro_path == "/static/page"
    @test isempty(hints)

    # Invalid converter
    @test_throws ArgumentError convert_django_path("/bad/<unknown:x>")
end

# ─── Test: path() ─────────────────────────────────────────────────────

@testset "path() route definition" begin
    handler = (req) -> "hello"
    
    # Default method is GET
    rd = path("/test", handler)
    @test rd isa RouteDefinition
    @test rd.pattern == "/test"
    @test rd.methods == ["GET"]
    @test isnothing(rd.name)
    @test isnothing(rd.middleware)
    @test isempty(rd.type_hints)

    # Custom method
    rd = path("/test", handler, method="POST")
    @test rd.methods == ["POST"]

    # Multiple methods
    rd = path("/test", handler, methods=["GET", "POST"])
    @test rd.methods == ["GET", "POST"]

    # With converters
    rd = path("/users/<int:id>", handler)
    @test rd.pattern == "/users/{id}"
    @test rd.type_hints[:id] == Int

    rd = path("/keys/<uuid:key>", handler)
    @test rd.pattern == "/keys/{key}"
    @test rd.type_hints[:key] == UUID

    # With name
    rd = path("/users/<int:id>", handler, name="user-detail")
    @test rd.name == "user-detail"

    # With middleware
    mw = [(handler) -> (req) -> handler(req)]
    rd = path("/test", handler, middleware=mw)
    @test rd.middleware == mw
end

# ─── Test: include_routes() ───────────────────────────────────────────

@testset "include_routes" begin
    handler = (req) -> "hello"
    
    routes = [
        path("/users", handler, method="GET"),
        path("/users/<int:id>", handler, method="GET"),
    ]

    included = include_routes("/api/v1", routes)
    
    @test length(included) == 2
    @test included[1].pattern == "/api/v1/users"
    @test included[2].pattern == "/api/v1/users/{id}"
    @test included[2].type_hints[:id] == Int

    # Variadic form
    included2 = include_routes("/v2",
        path("/items", handler, method="GET"),
        path("/items/<int:id>", handler, method="GET"),
    )
    @test length(included2) == 2
    @test included2[1].pattern == "/v2/items"
end

# ─── Test: urlpatterns() with server ──────────────────────────────────

@testset "urlpatterns integration" begin
    # Register handlers using urlpatterns
    list_handler = (req) -> "list"
    detail_handler = (req, id) -> "detail: $id"
    inferred_handler = function(req::HTTP.Request, id)
        return Res.send(string(typeof(id)))
    end
    bool_handler = function(req::HTTP.Request, enabled)
        return Res.send("$(typeof(enabled)):$(enabled)")
    end
    uuid_handler = function(req::HTTP.Request, key)
        return Res.send("$(typeof(key)):$(key)")
    end
    create_handler = (req) -> "created"
    key_id = UUID("550e8400-e29b-41d4-a716-446655440000")
    
    urlpatterns("/api",
        path("/items", list_handler, method="GET"),
        path("/items/<int:id>", detail_handler, method="GET"),
        path("/typed/<int:id>", inferred_handler, method="GET"),
        path("/toggle/<bool:enabled>", bool_handler, method="GET"),
        path("/keys/<uuid:key>", uuid_handler, method="GET"),
        path("/items", create_handler, method="POST"),
    )

    # Test via internalrequest
    serve(port=port, async=true, show_banner=false)
    sleep(1)

    try
        # GET /api/items
        r = internalrequest(HTTP.Request("GET", "/api/items"))
        @test r.status == 200
        body = Nitro.text(r)
        @test body == "list" || body == "\"list\""

        # GET /api/items/42
        r = internalrequest(HTTP.Request("GET", "/api/items/42"))
        @test r.status == 200

        # GET /api/typed/42
        r = internalrequest(HTTP.Request("GET", "/api/typed/42"))
        @test r.status == 200
        @test Nitro.text(r) == string(Int)

        # GET /api/typed/not-an-int
        r = internalrequest(HTTP.Request("GET", "/api/typed/not-an-int"))
        @test r.status == 500

        # GET /api/toggle/true
        r = internalrequest(HTTP.Request("GET", "/api/toggle/true"))
        @test r.status == 200
        @test Nitro.text(r) == "Bool:true"

        # GET /api/toggle/not-a-bool
        r = internalrequest(HTTP.Request("GET", "/api/toggle/not-a-bool"))
        @test r.status == 500

        # GET /api/keys/<uuid>
        r = internalrequest(HTTP.Request("GET", "/api/keys/$key_id"))
        @test r.status == 200
        @test Nitro.text(r) == "Base.UUID:$key_id"

        # GET /api/keys/not-a-uuid
        r = internalrequest(HTTP.Request("GET", "/api/keys/not-a-uuid"))
        @test r.status == 500

        # POST /api/items
        r = internalrequest(HTTP.Request("POST", "/api/items"))
        @test r.status == 200
        body = Nitro.text(r)
        @test body == "created" || body == "\"created\""
    finally
        terminate()
        resetstate()
    end
end

@testset "named routes" begin
    user_handler = function(req::HTTP.Request, id::Int)
        return Res.send("ok")
    end
    flag_handler = function(req::HTTP.Request, enabled::Bool)
        return Res.send("ok")
    end
    key_handler = function(req::HTTP.Request, key::UUID)
        return Res.send("ok")
    end
    key_id = UUID("550e8400-e29b-41d4-a716-446655440000")

    try
        urlpatterns("/api",
            path("/users/<int:id>", user_handler, method="GET", name="user-detail"),
            path("/flags/<bool:enabled>", flag_handler, method="GET", name="flag-detail"),
            path("/keys/<uuid:key>", key_handler, method="GET", name="key-detail"),
        )

        @test url("user-detail"; id=42) == "/api/users/42"
        @test url("flag-detail"; enabled=true) == "/api/flags/true"
        @test url("key-detail"; key=key_id) == "/api/keys/$key_id"
        @test_throws ArgumentError url("user-detail")
        @test_throws ArgumentError url("user-detail"; id=42, extra=1)
        @test_throws ArgumentError url("missing-route"; id=42)
    finally
        resetstate()
    end
end

@testset "duplicate route names" begin
    handler = function(req::HTTP.Request)
        return Res.send("ok")
    end

    try
        @test_throws ArgumentError urlpatterns("",
            path("/users", handler, method="GET", name="dup-route"),
            path("/admins", handler, method="GET", name="dup-route"),
        )
    finally
        resetstate()
    end
end

@testset "converter type conflicts" begin
    bad_handler = function(req::HTTP.Request, id::String)
        return Res.send(id)
    end
    bad_bool_handler = function(req::HTTP.Request, id::Bool)
        return Res.send(string(id))
    end

    try
        @test_throws ArgumentError urlpatterns("",
            path("/conflict/<int:id>", bad_handler, method="GET"),
        )
        @test_throws ArgumentError urlpatterns("",
            path("/bool-conflict/<int:id>", bad_bool_handler, method="GET"),
        )
    finally
        resetstate()
    end
end

# ─── Test: include_routes() integration ───────────────────────────────

@testset "include_routes integration" begin
    get_profile = (req) -> "profile"
    get_settings = (req) -> "settings"
    
    user_routes = [
        path("/profile", get_profile, method="GET"),
        path("/settings", get_settings, method="GET"),
    ]

    urlpatterns("",
        include_routes("/user", user_routes)...,
    )

    serve(port=port, async=true, show_banner=false)
    sleep(1)

    try
        r = internalrequest(HTTP.Request("GET", "/user/profile"))
        @test r.status == 200
        body = Nitro.text(r)
        @test body == "profile" || body == "\"profile\""
        
        r = internalrequest(HTTP.Request("GET", "/user/settings"))
        @test r.status == 200
        body = Nitro.text(r)
        @test body == "settings" || body == "\"settings\""
    finally
        terminate()
        resetstate()
    end
end

end
