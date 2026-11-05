@testitem "Handler request injection" tags=[:handler, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

urlpatterns("",
    path("/noarg", function(;request)
        @test isa(request, HTTP.Request)
        return Res.send("Hello World")
    end, method="GET"),
    path("/params/double/{a}", function(req, a::Float64; request::HTTP.Request)
        @test isa(request, HTTP.Request)
        return Res.send("$(a*2)")
    end, method="GET"),
    path("/singlearg", function(req; request)
        @test isa(req, HTTP.Request)
        @test isa(request, HTTP.Request)
        return Res.send("Hello World")
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
using Nitro.Core: App, create_param_parser, parse_func_params

ctx = App()

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

@testitem "Param strategies take their type and their request statically (#460)" tags=[:core, :handler] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core: App, create_param_parser, parse_func_params, parseparam_checked
using Nitro.Types: LazyRequest, pathparams, queryvars, headers

# The #37 item above pins what the parser infers. These pin the two shapes that answer depends
# on, which Julia 1.13 masks: it folds `param.type` to a constant and inlines the strategies into
# the parser, so its inference is concrete either way. Julia 1.14 does neither, and the parser
# inferred `Tuple{Any, String, Any}` there, and a trimmed `GET /users/7` answered 500.
h(req, id::Int, name::String, page::Int = 1) = "x"
parser = create_param_parser(App(), parse_func_params("/x/{id}", h))
strats = only(filter(f -> f isa Tuple, [getfield(parser, i) for i in 1:nfields(parser)]))
req = HTTP.Request("GET", "/x/7?name=bob&page=3")
req.context[:params] = Dict("id" => "7")
L = typeof(LazyRequest(req))

# The argument each strategy's source passes as `parseparam_checked`'s type, read from its
# LOWERED code: what the source says, before inference can fold it.
function type_argument(s)
    ci = only(code_lowered(s, (L,)))
    val(x) = x isa Core.SSAValue ? val(ci.code[x.id]) : x isa GlobalRef ? getglobal(x.mod, x.name) : x
    for st in ci.code
        st isa Expr && st.head === :call && val(st.args[1]) === parseparam_checked || continue
        return val(st.args[2])
    end
    return nothing
end

@testset "each scalar strategy passes its own type parameter, not `param.type`" begin
    # The readings below index the strategies by position.
    @test typeof.(strats) == (Nitro.Core.PathParamStrategy{Int},
                              Nitro.Core.RequiredQueryParamStrategy{String},
                              Nitro.Core.QueryParamStrategy{Int})
    @test parser(req) === (7, "bob", 3)
    for s in strats
        # `T` lowers to the method's static parameter; `s.param.type` to a `getproperty` call.
        @test type_argument(s) == Expr(:static_parameter, 1)
    end
    # The behaviour reading, each strategy on its own (the #37 item reads them inlined into the
    # parser). 1.13 infers these for the field read too, since it folds it; 1.14 inferred `Any`.
    @test Base.infer_return_type(strats[1], Tuple{L}) === Int
    @test Base.infer_return_type(strats[2], Tuple{L}) === String
    @test Base.infer_return_type(strats[3], Tuple{L}) === Union{Nothing, Int}
    # Where the conversion is not inlined (`Int`, not `String`), the call is a static invoke.
    @test invokes(strats[1], (L,), parseparam_checked)
    @test invokes(strats[3], (L,), parseparam_checked)
end

@testset "a LazyRequest carries its request's concrete type" begin
    @test isconcretetype(fieldtype(L, :req))
    @test LazyRequest(request = req) isa L          # the keyword form is unchanged
    # `HTTP.Request` alone is a `UnionAll`: the accessors on it then dispatched at run time.
    for f in (pathparams, queryvars, headers)
        @test invokes(f, (L,), f)
    end
    # The parser builds it positionally: a keyword call is static only where the compiler
    # resolves it (#856).
    @test isempty(kwcalls(parser, (typeof(req),); optimize = false, to = LazyRequest))
end
end
