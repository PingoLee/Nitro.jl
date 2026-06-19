@testitem "App context" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

struct Person
    name::String
    age::Int
end

urlpatterns("",
    path("/test", function(req) return "Hello World" end, method="GET"),
    path("/injected", function(req, ctx::Context{Person}) return json(ctx.payload) end, method="GET"),
    path("/getcontext", function(req) return json(getcontext(req)) end, method="GET"),
    path("/getcontext-typed", function(req) return json(getcontext(req, Person)) end, method="GET"),
    path("/kwarg-only", function(req; context) return json(context) end, method="GET"),
    path("/both-kwargs", function(; request::Request, context::Person) return json(context) end, method="GET"),
    path("/method-only", function() return json(context()) end, method="GET"),
)

serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false, access_log=nothing)

@testset "null context tests" begin 
    try
        response = HTTP.get("$localhost/injected")
    catch e
        @test e isa HTTP.Exception
        @test e.status == 500
    end

    try
        response = HTTP.get("$localhost/method-only")
    catch e
        @test e isa HTTP.Exception
        @test e.status == 500
    end

    try
        response = HTTP.get("$localhost/kwarg-only")
    catch e
        @test e isa HTTP.Exception
        @test e.status == 500
    end

    @test context() isa Missing
end

@testset "getcontext null context" begin
    # No context configured: getcontext(req) is nothing ...
    response = HTTP.get("$localhost/getcontext")
    @test response.status == 200
    @test text(response) == "null"

    # ... and the typed accessor raises (→ 500)
    try
        HTTP.get("$localhost/getcontext-typed")
        @test false
    catch e
        @test e isa HTTP.Exception
        @test e.status == 500
    end
end

terminate()

person = Person("John", 25)

serve(port=port, host=HOST, async=true, show_errors=true, show_banner=false, access_log=nothing, context=person)

@testset "context() tests" begin
    @test context() isa Person
    @test context() == person
end

@testset "standard get requests" begin 
    response = HTTP.get("$localhost/test")
    @test response.status == 200
    @test text(response) == "Hello World"
end

@testset "accessing injected context from a function handler" begin
    response = HTTP.get("$localhost/injected")
    @test response.status == 200
    @test json(response, Person) == person
end

@testset "getcontext(req) reaches the typed config without a Context param" begin
    response = HTTP.get("$localhost/getcontext")
    @test response.status == 200
    @test json(response, Person) == person

    response = HTTP.get("$localhost/getcontext-typed")
    @test response.status == 200
    @test json(response, Person) == person
end

@testset "accessing injected context from kwargs" begin 
    response = HTTP.get("$localhost/kwarg-only")
    @test response.status == 200
    @test json(response, Person) == person
end

@testset "accessing injected context from kwargs (both request and context)" begin 
    response = HTTP.get("$localhost/both-kwargs")
    @test response.status == 200
    @test json(response, Person) == person
end

@testset "context() method only" begin
    response = HTTP.get("$localhost/method-only")
    @test response.status == 200
    @test json(response, Person) == person
end

terminate()

# The app context is seeded before the middleware pipeline, so getcontext(req)
# is available inside global/custom middleware — not only at handler dispatch.
function _ctx_probe(handler)
    return function(req::HTTP.Request)
        resp = handler(req)
        cfg = getcontext(req)
        HTTP.setheader(resp, "X-Ctx-Name" => cfg === nothing ? "none" : cfg.name)
        return resp
    end
end

serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false,
      access_log=nothing, context=person, middleware=[_ctx_probe])

@testset "getcontext available inside middleware" begin
    response = HTTP.get("$localhost/test")
    @test response.status == 200
    @test HTTP.header(response, "X-Ctx-Name") == "John"
end

terminate()

end