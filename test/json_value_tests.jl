@testitem "JSON values: the walks give Base's answers" tags=[:core] setup=[NitroCommon] begin
using Test
using JSON
using Nitro

# `Types._json_equal`, `_json_copy` and `_json_dicts` replace `==`/`isequal`, `deepcopy` and a
# `dicttype` parse on the paths a trimmed image takes (docs/design/juliac-trim.md §3.11), so they
# must give exactly what those give. Base is the third source here: every expected value below is
# computed by Base on the same inputs, never written down.
T = Nitro.Types

docs = [
    "{}", "[]", "1", "1.0", "-0.0", "\"a\"", "true", "false", "null",
    "{\"a\":1,\"b\":[1,2.5,true,null,\"s\"],\"c\":{\"d\":{\"e\":[{}]}}}",
    "[[], {}, [[1]], {\"x\":[{\"y\":null}]}]",
    "{\"a\":1,\"a\":2}",                       # a later duplicate key wins
    "{\"n\":12345678901234567890123}",          # a BigInt: outside the list, the JIT's call
]
default = [JSON.parse(d) for d in docs]
dicts = [JSON.parse(d; dicttype = Dict{String, Any}) for d in docs]

@testset "_json_dicts is the dicttype parse" begin
    for (d, parsed, expected) in zip(docs, default, dicts)
        converted = T._json_dicts(parsed)
        @test isequal(converted, expected)
        # Every object is a `Dict{String, Any}`, at every depth, as under `dicttype`.
        walk(v) = v isa AbstractDict ? (v isa Dict{String, Any} && all(walk, values(v))) :
                  v isa AbstractVector ? all(walk, v) : true
        @test walk(converted)
    end
    # And the typed-NamedTuple keyword call is that same parse.
    for d in docs
        @test isequal(Nitro.Core.Util.BodyParsers._parse_json_dict_bounded(Vector{UInt8}(d); max_fields = 0),
                      JSON.parse(d; dicttype = Dict{String, Any}))
    end
end

@testset "_json_equal is == and isequal" begin
    values_ = Any[default; dicts; Any[1, 1.0, true, 0.0, -0.0, NaN, "1", nothing, Any[1.0], Any[true],
                                      Dict{String, Any}("a" => 1.0), Dict{String, Any}("a" => true),
                                      Dict{String, Any}("a" => NaN), Any[NaN], :sym, Int32(1), Any[:sym]]]
    # Collected rather than one `@test` per pair: a tuple holding a NaN never `==` itself.
    wrong = [(cmp, a, b) for a in values_, b in values_, cmp in (==, isequal)
             if T._json_equal(cmp, a, b) !== cmp(a, b)]
    @test isempty(wrong)
    @test length(values_)^2 * 2 > 1000
end

@testset "_json_copy is a deep copy" begin
    for v in [default; dicts]
        c = T._json_copy(v)
        @test isequal(c, v)
        @test typeof(c) === typeof(v)
        if v isa Dict{String, Any} && haskey(v, "c")
            @test c["c"] !== v["c"]
            @test c["b"] !== v["b"]
        end
    end
    # A value outside the list is `deepcopy`d under the JIT.
    outside = Dict{String, Any}("v" => [1, 2], "s" => :sym)
    c = T._json_copy(outside)
    @test c == outside
    @test c["v"] !== outside["v"]
end

@testset "with_json_value hands each type to a static branch" begin
    seen = Any[]
    for v in Any["s", 1, 1.5, true, nothing, Any[], Dict{String, Any}(), JSON.Object{String, Any}(), :sym, big(1)]
        T.with_json_value((x, out) -> push!(out, typeof(x)), v, seen)
    end
    @test seen == Any[String, Int64, Float64, Bool, Nothing, Vector{Any}, Dict{String, Any},
                      JSON.Object{String, Any}, Symbol, BigInt]
end
end

@testitem "JSON values: the walks and the claim reads make no dynamic call" tags=[:core, :auth] setup=[NitroCommon] begin
using Test
using HTTP
using JSON
using Nitro

# What `juliac --trim` would report as an unresolved call, pinned under the JIT
# (`dynamic_calls`, test/setup_tests.jl): every walk, and every Auth read of a claim value, is
# static on its own body. A value outside the list reaches an `@noinline` fallback, which is a
# static call too; the dynamic call is inside it, and a trimmed image folds it away.
T = Nitro.Types
A = Nitro.Auth
G = Nitro.Core.Middleware.GuardsMiddleware
for cmp in (==, isequal)
    @test isempty(dynamic_calls(T._json_equal, (typeof(cmp), Any, Any)))
end
@test isempty(dynamic_calls(T._json_copy, (Any,)))
@test isempty(dynamic_calls(T._json_dicts, (Any,)))
@test isempty(dynamic_calls(T._is_identity, (Any,)))
@test isempty(dynamic_calls(A._claim_int, (Any, String)))
@test isempty(dynamic_calls(A._claim_string, (Any,)))
@test isempty(dynamic_calls(A._warn_iss, (Any,)))
@test isempty(dynamic_calls(A._principal, (Dict{String, Any}, Union{Nothing, String}, Symbol, String)))
for C in (Nitro.Principal, Dict{String, Any}, JSON.Object{String, Any})
    @test isempty(dynamic_calls(G._claim_equals, (C, String, String)))
    @test isempty(dynamic_calls(G._claim_contains, (C, String, String)))
end
@test isempty(dynamic_calls(G._with_claims, (typeof(G._claim_equals), AbstractDict, String, String)))
end

@testitem "JWT claims: every spelling reads as before" tags=[:core, :auth] setup=[NitroCommon] begin
using Test
using HTTP
using JSON
using Nitro

# The claim reads moved to closed dispatches (#747). Each spelling an issuer may use reads as it
# did, through the branch for its JSON type or the fallback for anything else.
A = Nitro.Auth
@testset "_claim_int" begin
    for (v, expected) in ((7, 7), (7.9, 7), (-7.9, -7), ("12", 12), (true, 1), (Int32(5), 5),
                          (big(9), 9), (Float32(2.5), 2), (SubString("x13", 2), 13))
        @test A._claim_int(v, "exp") === expected
    end
    for bad in ("x", nothing, Any[1], Dict{String, Any}(), SubString("x", 1))
        @test_throws A.AuthError A._claim_int(bad, "exp")
    end
end
@testset "_claim_string" begin
    for v in ("u-1", 42, 4.5, true, Any[1, "a"], Dict{String, Any}("k" => 1), :sym)
        @test A._claim_string(v) == string(v)
    end
end
@testset "_is_identity" begin
    I = Nitro.Types._is_identity
    for (v, expected) in (("", false), ("u", true), (SubString("ab", 1, 0), false), (SubString("ab", 1), true),
                          (Dict{String, Any}(), false), (Dict{String, Any}("a" => 1), true),
                          (JSON.Object{String, Any}(), false), (JSON.parse("{\"a\":1}"), true),
                          (Dict{Symbol, Any}(), false), (Dict(:a => 1), true),
                          (nothing, false), (missing, false), (true, false), (false, false), (0, true))
        @test isequal((v, I(v)), (v, expected))
    end
end

secret = jwtkey("json-value-secret")
now_ts = trunc(Int, time())
token(claims) = A.encode_jwt(merge(Dict{String, Any}("exp" => now_ts + 600), claims), secret)

@testset "nested claims are Dict{String, Any} all the way down" begin
    claims = A.decode_jwt(token(Dict{String, Any}("sub" => "u", "addr" => Dict("city" => "x", "geo" => [Dict("a" => 1)]))), secret)
    @test claims isa Dict{String, Any}
    @test claims["addr"] isa Dict{String, Any}
    @test claims["addr"]["geo"][1] isa Dict{String, Any}
end

@testset "the principal's id, from each JSON spelling" begin
    for (sub, id) in (("u-1", "u-1"), (42, "42"), (true, "true"), (1.5, "1.5"))
        p = A.jwt_validator(secret)(token(Dict{String, Any}("sub" => sub)))
        @test p.id == id
    end
end

@testset "claim_required over each claims source" begin
    G = Nitro.Core.Middleware.GuardsMiddleware
    guard = G.claim_required("role", "admin")
    scopes = G.claim_required("scope", "write"; kind = :contains)
    sources = Any[
        Nitro.Principal(Dict{String, Any}("role" => "admin", "scope" => Any["read", "write"]); id = "u"),
        Dict{String, Any}("role" => "admin", "scope" => Any["read", "write"]),
        JSON.parse("{\"role\":\"admin\",\"scope\":[\"read\",\"write\"]}"),
        Dict{String, String}("role" => "admin"),              # an app's own claims type
        Dict{String, Any}("role" => "admin", "scope" => ["read", "write"]),   # a Vector{String}
    ]
    for (i, user) in enumerate(sources)
        req = HTTP.Request("GET", "/")
        req.context[:user] = user
        @test (i, guard(req)) == (i, nothing)
        @test (i, scopes(req) === nothing) == (i, i != 4)
    end
    for user in (Dict{String, Any}("role" => "user"), Dict{String, Any}("role" => Any["admin"]),
                 Dict{String, Any}("scope" => "write"), Dict{String, Any}("scope" => Any["read"]))
        req = HTTP.Request("GET", "/")
        req.context[:user] = user
        @test guard(req) isa HTTP.Response
        @test scopes(req) isa HTTP.Response
    end
end
end

@testitem "missing claim values answer as the guards did" tags=[:core, :middleware, :auth] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# JSON holds no `missing`, but an app's own claims dict can, and Base's `==` and `in` are
# three-valued over it. The reference for each outcome is the expression the change replaced, run
# on the same input: admit, deny, or throw.
G = Nitro.Core.Middleware.GuardsMiddleware
outcome(f) = try
    r = f()
    r === nothing ? :admit : r isa HTTP.Response ? :deny : :other
catch
    :error
end

equals = G.claim_required("role", "admin")
contains = G.claim_required("scope", "write"; kind = :contains)
old_equals(c) = (get(c, "role", nothing) != "admin") ? HTTP.Response(403) : nothing
old_contains(c) = (container = get(c, "scope", nothing);
                   (!(container isa AbstractVector) || !("write" in container)) ? HTTP.Response(403) : nothing)
for claims in (Dict{String, Any}("role" => missing), Dict{String, Any}("scope" => Any[missing, "write"]),
               Dict{String, Any}("scope" => Any[missing, "read"]), Dict{String, Any}("scope" => Any["write", missing]),
               Dict{String, Any}("scope" => Union{Missing, String}[missing, "write"]))
    req = HTTP.Request("GET", "/")
    req.context[:user] = claims
    @test isequal((claims, outcome(() -> equals(req))), (claims, outcome(() -> old_equals(claims))))
    @test isequal((claims, outcome(() -> contains(req))), (claims, outcome(() -> old_contains(claims))))
end
# A compare that answers `missing` on an element that is not itself `missing`: a container value.
nested = G.claim_required("x", Any[missing]; kind = :contains)
old_nested(c) = (container = get(c, "x", nothing);
                 (!(container isa AbstractVector) || !(Any[missing] in container)) ? HTTP.Response(403) : nothing)
for claims in (Dict{String, Any}("x" => Any[Any[missing], Any[missing]]), Dict{String, Any}("x" => Any[Any[missing], Any[1]]),
               Dict{String, Any}("x" => Any[Any[1], Any[2]]))
    req = HTTP.Request("GET", "/")
    req.context[:user] = claims
    @test isequal((claims, outcome(() -> nested(req))), (claims, outcome(() -> old_nested(claims))))
end
# A `missing` before the match admits, as `in` did.
req = HTTP.Request("GET", "/")
req.context[:user] = Dict{String, Any}("scope" => Any[missing, "write"])
@test contains(req) === nothing
end
