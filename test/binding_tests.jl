# Struct binding for `Query{T}`, `Form{T}`, `Header{T}`, `Path{T}` and `JsonFragment{T}`
# (`Reflection.struct_builder`), and the rule that no request string ever becomes a `Symbol`.
#
# #306: `struct_builder` began with `Dict(Symbol(k) => v for (k, v) in params)` over the whole
# client map, so every key a client sent -- including keys `T` does not have -- was interned
# before binding ran. Julia never frees an interned `Symbol`: a million unique junk keys grew
# the process by ~47 MB for good, on an unauthenticated route. The binder now walks `T`'s
# fields, and every typed JSON parse of client input uses Nitro's read style, which matches an
# enum by name without interning the string.

@testitem "struct_builder binds by field name (#306)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using JSON
using UUIDs
using Dates
using Nitro
using Nitro: App, Nullable, ValidationError
# HTTP.jl v2 exports its own `Form` (and friends); take the extractors from Nitro explicitly.
using Nitro: Query, Form, Header, JsonFragment
using Nitro.Core.Reflection: struct_builder

@enum Tier bronze = 1 silver = 2 gold = 3

struct Plain
    name::String
    count::Int
end
struct PlainOptional
    name::String
    note::Nullable{String}
end
@kwdef struct Opts
    page::Int = 1
    limit::Nullable{Int} = nothing
    id::Nullable{UUID} = nothing
    since::Nullable{Date} = nothing
    tier::Tier = bronze
end
@kwdef struct Inner
    city::String = "nowhere"
    zip::Int = 0
end
@kwdef struct Outer
    name::String
    inner::Inner = Inner()
    tags::Vector{String} = String[]
end
struct Hdr
    accept::String
end

const UID = "5e0bd8b6-4a3b-4f8b-9a55-6a1f2c3d4e5f"

@testset "unit: fields are looked up by name, unknown keys ignored" begin
    @test struct_builder(Plain, Dict("name" => "a", "count" => "3", "junk" => "z")) == Plain("a", 3)
    @test struct_builder(PlainOptional, Dict("name" => "a")) == PlainOptional("a", nothing)
    @test_throws ValidationError struct_builder(Plain, Dict("name" => "a"))
end

@testset "unit: @kwdef fields bind Nullable, UUID, Date and enums (by name or integer)" begin
    # Each of these was a 400 on the `@kwdef` path before #306: `parse(Union{Nothing,Int}, "5")`
    # has no method, and `isstructtype(UUID)`/`isstructtype(Date)` sent them into a recursive
    # `struct_builder` call on a `String`.
    o = struct_builder(Opts, Dict("limit" => "5", "id" => UID, "since" => "2024-01-02", "tier" => "gold"))
    @test o.page == 1
    @test o.limit == 5
    @test o.id == UUID(UID)
    @test o.since == Date(2024, 1, 2)
    @test o.tier == gold
    @test struct_builder(Opts, Dict("tier" => "2")).tier == silver
    @test struct_builder(Opts, Dict{String,String}()) == Opts()
    @test_throws ArgumentError struct_builder(Opts, Dict("tier" => "platinum"))
end

@testset "unit: a JSON object nests, and nested @kwdef defaults apply" begin
    frag = JSON.parse("""{"name":"n","inner":{"zip":"12"},"tags":["a","b"]}""")
    o = struct_builder(Outer, frag)
    @test o.name == "n"
    @test o.inner == Inner("nowhere", 12)
    @test o.tags == ["a", "b"]
end

@testset "unit: a dictionary target is built directly" begin
    @test struct_builder(Dict{String,Int}, Dict("a" => "1", "b" => "2")) == Dict("a" => 1, "b" => 2)
end

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/q", (req, q::Query{Opts}) -> Res.json(q.payload)),
    path("/f", (req, f::Form{Plain}) -> Res.json(f.payload); method = "POST"),
    path("/h", (req, h::Header{Hdr}) -> h.payload.accept),
    path("/frag", (req, outer::JsonFragment{Outer}) -> Res.json(outer.payload); method = "POST"),
)
getreq(t, headers = Pair{String,String}[]) = internalrequest(app, HTTP.Request("GET", t, headers))
post(t, body, ct) = internalrequest(app, HTTP.Request("POST", t, ["Content-Type" => ct], body))

@testset "routes: each extractor binds by field" begin
    r = getreq("/q?limit=7&tier=silver&id=$UID&unknown=1")
    @test r.status == 200
    b = JSON.parse(Nitro.text(r))
    @test b["limit"] == 7
    @test b["tier"] == "silver"
    @test b["id"] == UID

    r = post("/f", "name=x&count=4&extra=1", "application/x-www-form-urlencoded")
    @test r.status == 200
    @test JSON.parse(Nitro.text(r)) == Dict("name" => "x", "count" => 4)

    r = getreq("/h", ["Accept" => "text/csv"])
    @test r.status == 200
    @test Nitro.text(r) == "text/csv"

    r = post("/frag", """{"outer":{"name":"n","inner":{"city":"c"}}}""", "application/json")
    @test r.status == 200
    b = JSON.parse(Nitro.text(r))
    @test b["inner"] == Dict("city" => "c", "zip" => 0)

    @test getreq("/q?tier=platinum").status == 400
    @test post("/f", "name=x", "application/x-www-form-urlencoded").status == 400
end
end

@testitem "client strings are never interned (#306)" tags=[:core, :security] setup=[NitroCommon] begin
using Test
using HTTP
using JSON
using Nitro
using Nitro: App, Query, Form, Header, Json, JsonFragment
using Random

# `jl_symbol_lookup` is an exported C entry point of libjulia, not public Julia API: it
# answers "is this string already an interned Symbol?" without interning it. There is no
# public way to ask, and it is exactly the question #306 is about. A fresh random hex string
# (no NUL, so `Cstring` is safe) cannot have been interned by anything else.
interned(s::String) = ccall(:jl_symbol_lookup, Ptr{Cvoid}, (Cstring,), s) != C_NULL
# `RandomDevice`, not the default RNG: `@testset` reseeds the default RNG to the same seed on
# entry, so the first `rand` of every testset repeats -- and the positive control below interns
# exactly that string.
fresh() = "nitro306_" * bytes2hex(rand(Random.RandomDevice(), UInt8, 12))

@testset "positive control: the probe sees an interned string" begin
    k = fresh()
    @test !interned(k)
    Symbol(k)
    @test interned(k)
end

@enum Shade light = 1 dark = 2
@kwdef struct QueryTarget
    q::String = ""
    shade::Shade = light
end
struct FormTarget
    name::String
end
struct HeaderTarget
    accept::String
end
@kwdef struct FragTarget
    name::String = ""
end
struct JsonTarget
    shade::Shade
end
@kwdef struct JsonKw
    shade::Shade = light
end

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/q", (req, x::Query{QueryTarget}) -> "ok"),
    path("/f", (req, x::Form{FormTarget}) -> "ok"; method = "POST"),
    path("/h", (req, x::Header{HeaderTarget}) -> "ok"),
    path("/frag", (req, fragment::JsonFragment{FragTarget}) -> "ok"; method = "POST"),
    path("/json", (req, x::Json{JsonTarget}) -> "ok"; method = "POST"),
    path("/jsonkw", (req, x::Json{JsonKw}) -> "ok"; method = "POST"),
    path("/scalar/{shade}", (req, shade::Shade) -> "ok"),
    path("/bare", function (req)
        try
            json(req, JsonTarget)
            return "bound"
        catch
            return "refused"
        end
    end; method = "POST"),
)
send(method, t; headers = Pair{String,String}[], body = "") =
    internalrequest(app, HTTP.Request(method, t, headers, body))
const JSON_CT = ["Content-Type" => "application/json"]

@testset "unknown keys" begin
    k = fresh()
    @test send("GET", "/q?q=a&$k=1").status == 200
    @test !interned(k)

    k = fresh()
    @test send("POST", "/f"; body = "name=a&$k=1",
               headers = ["Content-Type" => "application/x-www-form-urlencoded"]).status == 200
    @test !interned(k)

    k = fresh()
    @test send("GET", "/h"; headers = ["Accept" => "x", uppercase(k) => "1", k * "_b" => "2"]).status == 200
    @test !interned(k)
    @test !interned(uppercase(k))
    @test !interned(k * "_b")

    k = fresh()
    @test send("POST", "/frag"; headers = JSON_CT,
               body = """{"fragment":{"name":"a","$k":1},"$(k)_top":2}""").status == 200
    @test !interned(k)
    @test !interned(k * "_top")

    k = fresh()
    @test send("POST", "/json"; headers = JSON_CT, body = """{"shade":"dark","$k":1}""").status == 200
    @test !interned(k)
end

@testset "enum values" begin
    k = fresh()
    @test send("GET", "/q?shade=$k").status == 400
    @test !interned(k)

    k = fresh()
    @test send("GET", "/scalar/$k").status == 400
    @test !interned(k)

    k = fresh()
    @test send("POST", "/json"; headers = JSON_CT, body = """{"shade":"$k"}""").status == 400
    @test !interned(k)

    k = fresh()
    @test send("POST", "/jsonkw"; headers = JSON_CT, body = """{"shade":"$k"}""").status == 400
    @test !interned(k)

    k = fresh()
    r = send("POST", "/bare"; headers = JSON_CT, body = """{"shade":"$k"}""")
    @test Nitro.text(r) == "refused"
    @test !interned(k)

    # And a valid name still binds on every path.
    @test send("GET", "/q?shade=dark").status == 200
    @test send("GET", "/scalar/dark").status == 200
    @test send("GET", "/scalar/2").status == 200
    @test send("POST", "/json"; headers = JSON_CT, body = """{"shade":"dark"}""").status == 200
    @test send("POST", "/jsonkw"; headers = JSON_CT, body = """{"shade":"dark"}""").status == 200
    @test Nitro.text(send("POST", "/bare"; headers = JSON_CT, body = """{"shade":"dark"}""")) == "bound"
end
end

@testitem "Symbol is refused at registration (#306)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App, Nullable, Query, Form, Json, Body, Cookie, Session, Context
using Nitro.Core.Types: Extractor
using Nitro.Core.Util.BodyParsers: interns_client_strings
using Random

@enum Shade light = 1 dark = 2
struct WithSymbol
    tag::Symbol
end
struct WithSymbolDict
    counts::Dict{Symbol,Int}
end
struct WithEnumDict
    counts::Dict{Shade,Int}
end
struct Safe
    name::String
    shade::Shade
    tags::Vector{String}
    counts::Dict{String,Shade}
end
mutable struct Node
    value::Int
    next::Union{Nothing,Node}
end
# A third-party-style extractor: Nitro does not bind it, so its payload type is not checked.
struct Opaque{T} <: Extractor{T}
    payload::Union{T,Nothing}
end

interned(s::String) = ccall(:jl_symbol_lookup, Ptr{Cvoid}, (Cstring,), s) != C_NULL

@testset "interns_client_strings" begin
    for T in (Symbol, Nullable{Symbol}, Vector{Symbol}, Set{Symbol}, Dict{Symbol,Int},
              Dict{String,Symbol}, Tuple{Int,Symbol}, Tuple{Vararg{Symbol}},
              NamedTuple{(:a,),Tuple{Symbol}}, WithSymbol, WithSymbolDict, WithEnumDict,
              Vector{WithSymbol})
        @test interns_client_strings(T)
    end
    for T in (Any, Int, Float64, String, Shade, Nullable{Shade}, Vector{Shade}, Dict{String,Shade},
              Dict{String,Any}, Tuple{Vararg{Int}}, Safe, Node, Vector)
        @test !interns_client_strings(T)
    end
end

@testset "a Symbol-binding parameter is refused when the route is declared" begin
    refused(route) = (app = App(mod = @__MODULE__);
                      @test_throws ArgumentError urlpatterns(app, "", route))
    refused(path("/p/{x}", (req, x::Symbol) -> "x"))
    refused(path("/q", (req, x::Nullable{Symbol} = nothing) -> "x"))
    refused(path("/b", (req, b::Body{Symbol}) -> "x"; method = "POST"))
    refused(path("/c", (req, c::Cookie{Symbol}) -> "x"))
    refused(path("/qs", (req, q::Query{WithSymbol}) -> "x"))
    refused(path("/j", (req, j::Json{Vector{Symbol}}) -> "x"; method = "POST"))
    refused(path("/f", (req, f::Form{WithSymbolDict}) -> "x"; method = "POST"))
    refused(path("/je", (req, j::Json{WithEnumDict}) -> "x"; method = "POST"))

    app = App(mod = @__MODULE__)
    err = try
        urlpatterns(app, "", path("/p/{x}", (req, x::Symbol) -> "x"))
        nothing
    catch e
        e
    end
    @test occursin("'x'", err.msg)
    @test occursin("@enum", err.msg)
end

@testset "everything that does not bind a Symbol from input still registers" begin
    app = App(mod = @__MODULE__)
    urlpatterns(app, "",
        path("/ok/{shade}", (req, shade::Shade) -> string(shade)),
        path("/safe", (req, s::Json{Safe}) -> "x"; method = "POST"),
        path("/session", (req, s::Session{WithSymbol}) -> "x"),
        path("/opaque", (req, o::Opaque{WithSymbol}) -> "x"; method = "POST"),
    )
    @test internalrequest(app, HTTP.Request("GET", "/ok/dark")).status == 200
end

@testset "json(req, T) refuses a Symbol-binding T without interning" begin
    k = "nitro306_" * bytes2hex(rand(Random.RandomDevice(), UInt8, 12))
    req = HTTP.Request("POST", "/", ["Content-Type" => "application/json"], """{"tag":"$k"}""")
    @test_throws ArgumentError json(req, WithSymbol)
    @test_throws ArgumentError json(req, Dict{Symbol,String})
    @test !interned(k)
end
end

@testitem "non-finite floats are rejected (#327)" tags=[:core, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App, Query, Form, Json, JsonFragment, Body, Cookie, MultipartForm, Nullable

# `parse(Float64, s)` accepts "NaN", "nan", "inf" and "-Infinity" and reads "1e999" as Inf; JSON
# has no NaN but reads an oversized number as a BigFloat/BigInt, which converts to Inf. `NaN >
# balance` and `NaN <= balance` are both false, so a "reject if amount > balance" check lets it
# through. Every path a client float takes is covered here.
@kwdef struct Amount
    amount::Float64 = 0.0
end
struct JAmount
    amount::Float64
end
struct J32
    amount::Float32
end
struct JOpt
    amount::Nullable{Float64}
end
struct MAmount
    amount::Float64
end

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/conv/<float:amount>", (req, amount::Float64) -> string(amount)),
    path("/scalar", (req, amount::Float64) -> string(amount)),
    path("/query", (req, q::Query{Amount}) -> string(q.payload.amount)),
    path("/form", (req, f::Form{Amount}) -> string(f.payload.amount); method = "POST"),
    path("/json", (req, j::Json{JAmount}) -> string(j.payload.amount); method = "POST"),
    path("/json32", (req, j::Json{J32}) -> string(j.payload.amount); method = "POST"),
    path("/jsonopt", (req, j::Json{JOpt}) -> string(j.payload.amount); method = "POST"),
    path("/jsonkw", (req, j::Json{Amount}) -> string(j.payload.amount); method = "POST"),
    path("/fragment", (req, amount::JsonFragment{Amount}) -> string(amount.payload.amount); method = "POST"),
    path("/body", (req, b::Body{Float64}) -> string(b.payload); method = "POST"),
    path("/cookie", (req, amount::Cookie{Float64}) -> string(amount.value)),
    path("/multipart", (req, m::MultipartForm{MAmount}) -> string(m.payload.amount); method = "POST"),
)
send(r) = internalrequest(app, r)
get_(t; headers = Pair{String,String}[]) = send(HTTP.Request("GET", t, headers))
post(t, ct, body) = send(HTTP.Request("POST", t, ["Content-Type" => ct], body))
const JSON_T = "application/json"
const FORM = "application/x-www-form-urlencoded"

@testset "scalar, converter, query and form: $bad" for bad in ("NaN", "nan", "inf", "-Infinity", "1e999")
    @test get_("/conv/$bad").status == 400
    @test get_("/scalar?amount=$bad").status == 400
    @test get_("/query?amount=$bad").status == 400
    @test post("/form", FORM, "amount=$bad").status == 400
    @test post("/body", "text/plain", bad).status == 400
    @test post("/fragment", JSON_T, """{"amount":{"amount":"$bad"}}""").status == 400
    # `Cookie{Float64}` answers a non-finite value like any other it cannot parse: a 400.
    @test get_("/cookie"; headers = ["Cookie" => "amount=$bad"]).status == 400
    # `get_cookie` with a numeric default reads it as absent, as it does an unparsable one.
    req = HTTP.Request("GET", "/", ["Cookie" => "amount=$bad"])
    @test Nitro.get_cookie(req, "amount", 1.0) === 1.0
end

@testset "typed JSON: an oversized number is not Inf" begin
    for path in ("/json", "/jsonopt", "/jsonkw")
        @test post(path, JSON_T, """{"amount":1e999}""").status == 400
        @test post(path, JSON_T, """{"amount":-1e999}""").status == 400
        @test post(path, JSON_T, """{"amount":$("9"^400)}""").status == 400
    end
    @test post("/json32", JSON_T, """{"amount":1e39}""").status == 400
    # JsonFragment: the untyped parse keeps 1e999 a BigFloat; the field binder must not lower it to Inf.
    @test post("/fragment", JSON_T, """{"amount":{"amount":1e999}}""").status == 400
end

@testset "multipart" begin
    boundary = "----nitro327"
    body(v) = "--$boundary\r\nContent-Disposition: form-data; name=\"amount\"\r\n\r\n$v\r\n--$boundary--\r\n"
    ct = "multipart/form-data; boundary=$boundary"
    @test post("/multipart", ct, body("inf")).status == 400
    @test post("/multipart", ct, body("nan")).status == 400
    @test post("/multipart", ct, body("2.5")).status == 200
end

@testset "finite values still bind everywhere" begin
    @test Nitro.text(get_("/conv/3.14")) == "3.14"
    @test Nitro.text(get_("/scalar?amount=-2.5")) == "-2.5"
    @test Nitro.text(get_("/query?amount=1e10")) == "1.0e10"
    @test Nitro.text(post("/form", FORM, "amount=0.5")) == "0.5"
    @test Nitro.text(post("/json", JSON_T, """{"amount":1.5}""")) == "1.5"
    @test Nitro.text(post("/json32", JSON_T, """{"amount":1.5}""")) == "1.5"
    @test Nitro.text(post("/jsonopt", JSON_T, """{"amount":null}""")) == "nothing"
    @test Nitro.text(post("/jsonkw", JSON_T, "{}")) == "0.0"
    @test Nitro.text(post("/fragment", JSON_T, """{"amount":{"amount":7}}""")) == "7.0"
    @test Nitro.text(post("/body", "text/plain", "4.25")) == "4.25"
    @test Nitro.text(get_("/cookie"; headers = ["Cookie" => "amount=1.25"])) == "1.25"
end
end

@testitem "review follow-ups: float unions, NaN keywords, and the JWT claim segment (#327)" tags=[:core, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App, Query, Body, MultipartForm, Nullable

# A union of float types is `<: AbstractFloat` (and `<: Number`), so it landed on the float-only
# parse method -- whose `parse` on a union recurses in Base's `tryparse` until the stack
# overflows: a 500 flagged "program state may be corrupted", on every request.
@test Nitro.parseparam(Union{Float32, Float64}, "1.5") === 1.5f0
@test_throws Exception Nitro.parseparam(Union{Float32, Float64}, "nan")

@kwdef struct UnionAmount
    amount::Union{Float32, Float64} = 0.0
end
struct MUnion
    amount::Union{Float32, Float64}
end
app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/scalar", (req, amount::Union{Float32, Float64}) -> string(amount)),
    path("/query", (req, q::Query{UnionAmount}) -> string(q.payload.amount)),
    path("/body", (req, b::Body{Union{Float32, Float64}}) -> string(b.payload); method = "POST"),
    path("/multipart", (req, m::MultipartForm{MUnion}) -> string(m.payload.amount); method = "POST"),
    path("/conv/<float:amount>", (req, amount::Float64) -> string(amount)),
)
send(r) = internalrequest(app, r)
@test send(HTTP.Request("GET", "/scalar?amount=2.5")).status == 200
@test send(HTTP.Request("GET", "/scalar?amount=inf")).status == 400
@test send(HTTP.Request("GET", "/query?amount=2.5")).status == 200
@test send(HTTP.Request("POST", "/body", ["Content-Type" => "text/plain"], "2.5")).status == 200
boundary = "----nitro327union"
mp = "--$boundary\r\nContent-Disposition: form-data; name=\"amount\"\r\n\r\n2.5\r\n--$boundary--\r\n"
@test send(HTTP.Request("POST", "/multipart", ["Content-Type" => "multipart/form-data; boundary=$boundary"], mp)).status == 200
# The `<float:>` route always matches, so a non-finite value is exactly a 400.
@test send(HTTP.Request("GET", "/conv/nan")).status == 400

# `json(req, T)` refuses every truthy `allownan`, and a caller `style`.
struct Reading
    value::Float64
end
req = HTTP.Request("POST", "/", ["Content-Type" => "application/json"], """{"value":NaN}""")
@test_throws ArgumentError json(req, Reading; allownan = true)
@test_throws ArgumentError json(req, Reading; allownan = 1)
@test_throws ArgumentError json(req, Reading; style = Nitro.Core.Util.BodyParsers.NITRO_READ_STYLE)

# A JWT claim segment is size-bounded already; the field cap would turn a valid token with many
# claims into a `ValidationError` where `decode_jwt` promises an `AuthError`. Not capped.
claims = "{" * join(("\"c$i\":$i" for i in 1:1500), ",") * "}"
segment = Nitro.Auth._base64url_encode(Vector{UInt8}(claims))
@test length(Nitro.Auth._jwt_segment_json(segment)) == 1500
end

@testitem "review follow-ups: NamedTuple targets and the cached type walk (#306)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App, Query, Form
using Nitro.Core.Util.BodyParsers: interns_client_strings_cached, _INTERNS_CACHE

# StructTypes built a NamedTuple target; the field-driven binder's positional `T(args...)` has
# no method for one, so `Query{@NamedTuple{...}}` answered 400 until this.
const NT = @NamedTuple{a::Int, b::String}
app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/q", (req, q::Query{NT}) -> string(q.payload)),
    path("/f", (req, f::Form{NT}) -> string(f.payload); method = "POST"),
)
r = internalrequest(app, HTTP.Request("GET", "/q?a=1&b=x"))
@test r.status == 200
@test Nitro.text(r) == string((a = 1, b = "x"))
r = internalrequest(app, HTTP.Request("POST", "/f", ["Content-Type" => "application/x-www-form-urlencoded"], "a=2&b=y"))
@test r.status == 200
@test Nitro.text(r) == string((a = 2, b = "y"))

# `json(req, T)` walks `T` once, not on every call.
struct Walked
    a::Vector{Dict{String, Int}}
end
@test interns_client_strings_cached(Walked) === false
@test haskey(_INTERNS_CACHE, Walked)
@test interns_client_strings_cached(Walked) === false
@test (@allocated interns_client_strings_cached(Walked)) < 256
end
