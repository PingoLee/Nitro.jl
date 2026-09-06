@testitem "Handler request injection" tags=[:handler, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

urlpatterns("",
    path("/noarg", function(;request)
        @test isa(request, HTTP.Request)
        return text("Hello World")
    end, method="GET"),
    path("/params/double/{a}", function(req, a::Float64; request::HTTP.Request)
        @test isa(request, HTTP.Request)
        return text("$(a*2)")
    end, method="GET"),
    path("/singlearg", function(req; request)
        @test isa(req, HTTP.Request)
        @test isa(request, HTTP.Request)
        return text("Hello World")
    end, method="GET"),
)

serve(port=port, host=HOST, async=true,  show_errors=false, show_banner=false, access_log=nothing)

@testset "Handler request Injection Tests" begin

    @testset "Inject request into no arg function" begin
        response = HTTP.get("$localhost/noarg")
        @test response.status == 200
        @test text(response) == "Hello World"
    end

    @testset "Inject request into function with path params" begin
        response = HTTP.get("$localhost/params/double/5")
        @test response.status == 200
        @test text(response) == "10.0"
    end

    @testset "Inject request into function with single arg" begin
        response = HTTP.get("$localhost/singlearg")
        @test response.status == 200
        @test text(response) == "Hello World"
    end
end


terminate()
end

@testitem "Param parser is type-stable (#37)" tags=[:core, :handler] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: ServerContext, create_param_parser, parse_func_params

ctx = ServerContext()

# One of every scalar strategy at once: a path param, a required query param and a
# defaulted query param.
h(req, id::Int, name::String, page::Int = 1) = "x"
parser = create_param_parser(ctx, parse_func_params("/x/{id}", h))

req = HTTP.Request("GET", "/x/7?name=bob&page=3")
req.context[:params] = Dict("id" => "7")

@testset "parsed params land in a concrete Tuple, not a Vector{Any}" begin
    params = parser(req)
    @test params isa Tuple
    @test !(params isa Vector)
    @test params == (7, "bob", 3)
    @test typeof(params) === Tuple{Int, String, Int}
end

@testset "the parser's return type is inferred concretely" begin
    # This is the subject of #37. The old parser filled a `Vector{Any}`, so every
    # parsed value was boxed and the downstream `func(arg, parameters...)` splat was a
    # dynamic call. `Union{Nothing,Int}` on the third slot is the *declared*
    # optionality of a defaulted query param — a small union Julia splits, not an
    # inference failure. A regression here shows up as `Vector{Any}` or `Any`.
    inferred = Base.infer_return_type(parser, Tuple{HTTP.Request})
    @test inferred === Tuple{Int, String, Union{Nothing, Int}}
end

@testset "strategies are stored concretely, never behind an abstract eltype" begin
    # The strategy container must be a concrete `Tuple`; as a `Vector{Function}` every
    # call was a dynamic dispatch, which is the other half of #37.
    strats = only(filter(f -> f isa Tuple, [getfield(parser, i) for i in 1:nfields(parser)]))
    @test strats isa Tuple
    @test isconcretetype(typeof(strats))
    @test all(isconcretetype, map(typeof, strats))
end

@testset "a handler with no bindable params parses to an empty tuple" begin
    g(req) = "y"
    p0 = create_param_parser(ctx, parse_func_params("/y", g))
    @test p0(HTTP.Request("GET", "/y")) === ()
end
end
