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
using Nitro.Core.Util.BodyParsers: interns_client_strings, interns_client_strings_cached
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
        @test interns_client_strings_cached(T)  # the memo `json(req, T)` reads (#498)
    end
    for T in (Any, Int, Float64, String, Shade, Nullable{Shade}, Vector{Shade}, Dict{String,Shade},
              Dict{String,Any}, Tuple{Vararg{Int}}, Safe, Node, Vector)
        @test !interns_client_strings(T)
        @test !interns_client_strings_cached(T)
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
@test_throws ValidationError Nitro.parseparam(Union{Float32, Float64}, "nan")

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
segment = Nitro.Crypto.base64url_encode(Vector{UInt8}(claims))
@test length(Nitro.Auth._jwt_segment_json(segment)) == 1500
end

@testitem "review follow-ups: NamedTuple targets and the cached type walk (#306)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App, Query, Form
using Nitro.Core.Util.BodyParsers: interns_client_strings, interns_client_strings_cached,
                                   INTERNS_CLIENT_STRINGS

memoized_for(T) = haskey((@atomic :acquire INTERNS_CLIENT_STRINGS.snapshot).known, T)

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
@test memoized_for(Walked)
@test interns_client_strings_cached(Walked) === false
# A hit reads one atomic snapshot and takes no lock (#498): it used to queue on a process-wide
# `ReentrantLock`, and allocate for the closures around it. Min of 5 runs (#511).
@testset let lookup = allocs(() -> interns_client_strings_cached(Walked))
    @test lookup.bytes == 0
end
# ...and `json(req, T)` is what consults it.
struct ViaJson
    a::Int
end
@test !memoized_for(ViaJson)
@test json(HTTP.Request("POST", "/", ["Content-Type" => "application/json"], """{"a":1}"""), ViaJson).a == 1
@test memoized_for(ViaJson)

# The walk asks `eltype`, which a type may define as a method of its own: the memo is keyed on the
# world counter, so a method defined after the first answer is seen, as the uncached walk sees it.
struct Bag <: AbstractVector{Int}; end
@test !interns_client_strings_cached(Bag)
Core.eval(@__MODULE__, :(Base.eltype(::Type{Bag}) = Symbol))
@test interns_client_strings(Bag)
@test interns_client_strings_cached(Bag)

# Many tasks missing on fresh types at once, each publishing its own copy of the snapshot. Whether
# a publication is actually lost is up to the scheduler; this pins that every answer is right
# however they interleave.
@testset "concurrent first answers agree with the uncached walk" begin
    types = [Core.eval(@__MODULE__, isodd(i) ?
                 :(struct $(Symbol("Walk", i)); tag::Vector{Symbol}; end; $(Symbol("Walk", i))) :
                 :(struct $(Symbol("Walk", i)); tag::Vector{String}; end; $(Symbol("Walk", i))))
             for i in 1:32]
    expected = interns_client_strings.(types)
    @test count(expected) == 16
    for _ in 1:4
        answers = fetch.([Threads.@spawn(interns_client_strings_cached(T)) for T in types for _ in 1:4])
        @test answers == repeat(expected; inner = 4)
    end
end
end

@testitem "Body{T} binds only raw text; a struct T is refused at registration (#345)" tags=[:core, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Dates
using UUIDs
using Nitro
using Nitro: App, Nullable, Body, Json
using Nitro.Core.Util.BodyParsers: binds_from_text

# `Body{T}` for a struct went through `parseparam`'s JSON fallback, which reads the body as JSON
# whatever its Content-Type -- a `text/plain` body a cross-site page can send without a CORS
# preflight bound exactly like the app's own JSON client. #327 closed that path for `Json{T}`.
struct Transfer345
    to::String
    amount::Int
end
@enum Tier345 bronze = 1 gold = 2
# An app type opts in by defining `Base.parse`.
struct Cents345
    n::Int
end
Base.parse(::Type{Cents345}, s::String) = Cents345(parse(Int, s))

@testset "binds_from_text" begin
    for T in (Any, String, Char, Regex, Int, Float64, Bool, BigInt, Tier345, Date, DateTime, UUID,
              Cents345, Nullable{Int}, Union{Float32, Float64}, Union{Missing, String})
        @test binds_from_text(T)
    end
    for T in (Transfer345, Vector{Int}, Vector{Any}, Dict{String, Any}, Tuple{Int},
              NamedTuple{(:a,), Tuple{Int}}, Nullable{Transfer345}, Union{Int, Vector{Int}},
              Nothing, Union{Nothing, Missing},
              # Base declares `parse` for these abstract types, but it throws on each of them.
              Integer, Real, AbstractFloat, Signed)
        @test !binds_from_text(T)
    end
end

@testset "a struct or container Body{T} is refused when the route is declared" begin
    refused(route) = (app = App(mod = @__MODULE__);
                      @test_throws ArgumentError urlpatterns(app, "", route))
    refused(path("/t", (req, t::Body{Transfer345}) -> "x"; method = "POST"))
    refused(path("/v", (req, v::Body{Vector{Any}}) -> "x"; method = "POST"))
    refused(path("/d", (req, d::Body{Dict{String, Any}}) -> "x"; method = "POST"))
    refused(path("/n", (req, n::Body{Nullable{Transfer345}}) -> "x"; method = "POST"))

    app = App(mod = @__MODULE__)
    err = try
        urlpatterns(app, "", path("/t", (req, transfer::Body{Transfer345}) -> "x"; method = "POST"))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("'transfer'", err.msg)
    @test occursin("Json{", err.msg)
end

@testset "raw scalars still register and bind from any Content-Type" begin
    app = App(mod = @__MODULE__)
    urlpatterns(app, "",
        path("/s", (req, b::Body{String}) -> b.payload; method = "POST"),
        path("/a", (req, b::Body{Any}) -> string(b.payload); method = "POST"),
        path("/f", (req, b::Body{Float64}) -> string(b.payload); method = "POST"),
        path("/u", (req, b::Body{Union{Float32, Float64}}) -> string(b.payload); method = "POST"),
        path("/b", (req, b::Body{Bool}) -> string(b.payload); method = "POST"),
        path("/e", (req, b::Body{Tier345}) -> string(b.payload); method = "POST"),
        path("/date", (req, b::Body{Date}) -> string(b.payload); method = "POST"),
        path("/c", (req, b::Body{Cents345}) -> string(b.payload.n); method = "POST"),
        path("/nc", (req, b::Body{Nullable{Cents345}}) -> string(b.payload.n); method = "POST"),
        # The replacement for a struct body: same value, and it demands a JSON Content-Type.
        path("/j", (req, t::Json{Transfer345}) -> t.payload.to; method = "POST"),
    )
    send(route, body; ct = "text/plain") =
        internalrequest(app, HTTP.Request("POST", route, ["Content-Type" => ct], body))
    @test Nitro.text(send("/s", "hello")) == "hello"
    @test Nitro.text(send("/a", "hello")) == "hello"
    @test Nitro.text(send("/f", "2.5")) == "2.5"
    @test Nitro.text(send("/u", "2.5")) == "2.5"
    @test Nitro.text(send("/b", "true")) == "true"
    @test Nitro.text(send("/e", "gold")) == "gold"
    @test Nitro.text(send("/date", "2026-09-24")) == "2026-09-24"
    @test Nitro.text(send("/c", "150")) == "150"

    # No JSON fall-through behind an admitted type (#345 review): `parseparam` retried a failed
    # `parse` as JSON, so a type admitted for its own `Base.parse` bound field by field from a JSON
    # body sent as `text/plain` -- skipping whatever that `parse` checks.
    @test send("/c", """{"n":150}""").status == 400
    @test Nitro.text(send("/nc", "7")) == "7"
    @test send("/nc", """{"n":150}""").status == 400
    @test send("/f", "[2.5]").status == 400
    @test send("/f", "Infinity").status == 400

    body = """{"to":"mallory","amount":1000}"""
    @test send("/j", body).status == 415
    @test Nitro.text(send("/j", body; ct = "application/json")) == "mallory"
end
end

@testitem "the generated binder binds exactly what the reflective walk did (#537)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using JSON
using Nitro
using Nitro: App, Nullable, ValidationError
using Nitro: Query, Form, Header, Path, JsonFragment
using Nitro.Core.Reflection: struct_builder, bind_value, kw_construct, kw_constructible, dict_builder

# `struct_builder` as it was before #537, verbatim: the reference every result below must equal.
function reference_builder(::Type{T}, source::AbstractDict) :: T where {T}
    T <: AbstractDict && return dict_builder(T, source)
    if kw_constructible(T)
        kwargs = Pair{Symbol, Any}[]
        for name in fieldnames(T)
            key = String(name)
            haskey(source, key) || continue
            push!(kwargs, name => bind_value(fieldtype(T, name), source[key]))
        end
        return kw_construct(T, kwargs)
    end
    args = Any[]
    for name in fieldnames(T)
        key = String(name)
        ftype = fieldtype(T, name)
        if haskey(source, key)
            push!(args, bind_value(ftype, source[key]))
        elseif Nothing <: ftype
            push!(args, nothing)
        elseif Missing <: ftype
            push!(args, missing)
        else
            throw(ValidationError("Missing required field '$name'"))
        end
    end
    T <: NamedTuple && return T(Tuple(args))
    return T(args...)
end

# Declared defaults (one of them a non-`nothing` default on a `Nullable` field, which a static
# null-fill would get wrong), required fields, fields only a null can fill, and the positional
# shapes.
Base.@kwdef struct KwDefaults
    a::Int = 0
    b::String = "d"
    c::Nullable{Int} = 1
end
Base.@kwdef struct KwRequired
    a::Int
    b::Union{Nothing, String}
    c::Union{Missing, Int}
end
Base.@kwdef struct KwMixed
    a::Int
    b::String = "d"
    c::Nullable{Int} = nothing
end
struct PlainABC
    a::Int
    b::Union{Nothing, String}
    c::Union{Missing, Int}
end
struct PlainRequired
    a::Int
    b::String
    c::Nullable{Int}
end
const NTABC = @NamedTuple{a::Int, b::String, c::Nullable{Int}}
Base.@kwdef struct KwEmpty end
Base.@kwdef struct Leaf
    x::Int = 5
end
Base.@kwdef struct Nested
    a::Int = 0
    leaf::Leaf = Leaf()
end

# A parametric struct, an `Any` field, an inner constructor that validates (`a = -1` is refused
# by it, not by binding), and defaults that read another field (`b` and `c` from a required `a`).
Base.@kwdef struct KwParam{X}
    a::X = zero(X)
    b::Any = "any"
    c::Nullable{Int} = nothing
end
struct PlainValidated
    a::Int
    b::String
    c::Nullable{Int}
    PlainValidated(a, b, c) = a >= 0 ? new(a, b, c) : throw(ArgumentError("a must be >= 0"))
end
Base.@kwdef struct KwDependent
    a::Int
    b::String = string(a)
    c::Int = a + 1
end

const TYPES = (KwDefaults, KwRequired, KwMixed, PlainABC, PlainRequired, NTABC,
               KwParam{Int}, PlainValidated, KwDependent)
const VALUES = Dict("a" => "1", "b" => "s", "c" => "3")
subsets(keys) = [[k for (i, k) in enumerate(keys) if (m >> (i - 1)) & 1 == 1] for m in 0:(2^length(keys) - 1)]
# Every presence pattern, plus an unknown key, plus a value that does not bind.
sources() = vcat([Dict{String, String}(k => VALUES[k] for k in ks) for ks in subsets(["a", "b", "c"])],
                 [Dict("a" => "1", "b" => "s", "c" => "3", "zzz" => "1"), Dict("a" => "x", "b" => "s", "c" => "3"),
                  Dict("a" => "-1", "b" => "s", "c" => "3")])

outcome(f) = try
    (:ok, f())
catch e
    (:err, typeof(e), e isa ValidationError ? e.msg : sprint(showerror, e))
end

@testset "unit: every type, every presence pattern" begin
    for T in TYPES, source in sources()
        @test (T, source, outcome(() -> struct_builder(T, source))) ==
              (T, source, outcome(() -> reference_builder(T, source)))
    end
    @test struct_builder(KwEmpty, Dict("a" => "1")) === reference_builder(KwEmpty, Dict("a" => "1"))
    # A JSON object for a struct field still recurses, defaults applying at every level.
    for source in (Dict{String, Any}("a" => 2, "leaf" => Dict{String, Any}("x" => 9)),
                   Dict{String, Any}("leaf" => Dict{String, Any}()), Dict{String, Any}())
        @test (source, struct_builder(Nested, source)) == (source, reference_builder(Nested, source))
    end
    # A target the generated binders do not take fails as it always did.
    @test outcome(() -> struct_builder(Tuple{Int, String}, Dict("1" => "1"))) ==
          outcome(() -> reference_builder(Tuple{Int, String}, Dict("1" => "1")))
end

# Through each extractor that binds with `struct_builder`, from a real request.
seen = Ref{Any}(nothing)
routename(T) = T === NTABC ? "NTABC" : string(nameof(T))
app = App(mod = @__MODULE__)
for T in TYPES
    n = routename(T)
    @eval urlpatterns(app, "",
        path($("/q/$n"), (req, x::Query{$T}) -> (seen[] = x.payload; "ok")),
        path($("/f/$n"), (req, x::Form{$T}) -> (seen[] = x.payload; "ok"); method = "POST"),
        path($("/h/$n"), (req, x::Header{$T}) -> (seen[] = x.payload; "ok")),
        path($("/j/$n"), (req, frag::JsonFragment{$T}) -> (seen[] = frag.payload; "ok"); method = "POST"),
        path($("/p/$n/{a}/{b}/{c}"), (req, x::Path{$T}) -> (seen[] = x.payload; "ok")))
end
form(source) = join(("$k=$v" for (k, v) in source), "&")
function via(T, kind, source)
    n = routename(T)
    seen[] = nothing
    res = if kind === :query
        internalrequest(app, HTTP.Request("GET", "/q/$n?" * form(source)))
    elseif kind === :form
        internalrequest(app, HTTP.Request("POST", "/f/$n", ["Content-Type" => "application/x-www-form-urlencoded"], form(source)))
    elseif kind === :header
        internalrequest(app, HTTP.Request("GET", "/h/$n", collect(source)))
    elseif kind === :json
        internalrequest(app, HTTP.Request("POST", "/j/$n", ["Content-Type" => "application/json"],
                                          JSON.json(Dict("frag" => source))))
    else
        internalrequest(app, HTTP.Request("GET", "/p/$n/$(source["a"])/$(source["b"])/$(source["c"])"))
    end
    return res.status == 200 ? (:ok, seen[]) : (:refused, res.status)
end
expected(T, source) = (o = outcome(() -> reference_builder(T, source)); first(o) === :ok ? o : (:refused, 400))

@testset "routes: Query, Form, Header, JsonFragment and Path bind what the reference does" begin
    for T in TYPES, source in sources(), kind in (:query, :form, :header, :json)
        @test (T, kind, source, via(T, kind, source)) == (T, kind, source, expected(T, source))
    end
    for T in TYPES, source in (VALUES, Dict("a" => "x", "b" => "s", "c" => "3"))
        @test (T, :path, source, via(T, :path, source)) == (T, :path, source, expected(T, source))
    end
end

# The reflective walk paid a `String` per field, a boxed `Pair` per value and a keyword call built
# from a runtime vector. With every field present the generated binder makes a static call:
# under the suite's flags 5 allocations here against the walk's 22. The bound sits between them;
# `reference_builder` is the positive control.
@testset let full = Dict("a" => "1", "b" => "s", "c" => "3"),
             generated = allocs(() -> struct_builder(KwDefaults, full)),
             reflective = allocs(() -> reference_builder(KwDefaults, full))
    @test reflective.count >= 15
    @test generated.count <= 10
end
# The positional binder too, so a plain struct cannot fall back to the walk unnoticed: 3
# allocations against the walk's 8 under the suite's flags.
@testset let full = Dict("a" => "1", "b" => "s", "c" => "3"),
             generated = allocs(() -> struct_builder(PlainRequired, full)),
             reflective = allocs(() -> reference_builder(PlainRequired, full))
    @test reflective.count >= 6
    @test generated.count <= 5
end
end

@testitem "a float parameter parses with no runtime method lookup (#631)" tags=[:core] setup=[NitroCommon] begin
using Test
using Nitro

# The float method reached the generic fallback through `invoke` with a `UnionAll` signature,
# which is resolved at run time on every call: 19 allocations for `parseparam(Float64, "1.5")`
# against none for `Int`. It now calls the fallback's body by name. The old `invoke` is the
# positive control, so a bound of 0 cannot pass by measuring nothing.
fallback_by_invoke(T, s) = invoke(Nitro.parseparam, Tuple{Type{T}, String} where {T}, T, s)
@test allocs(() -> fallback_by_invoke(Float64, "1.5")).count >= 10
@test allocs(() -> Nitro.parseparam(Float64, "1.5")).count == 0
@test allocs(() -> Nitro.parseparam(Float32, "1.5")).count == 0

# What the float method is for stays exactly as it was: the value, the finite-only rule (#327),
# a float union handed to the union method, and the JSON fall-through for text `parse` refuses.
@test Nitro.parseparam(Float64, "1.5") === 1.5
@test Nitro.parseparam(Float32, "-2.25") === -2.25f0
@test_throws ArgumentError Nitro.parseparam(Float64, "NaN")
@test_throws ArgumentError Nitro.parseparam(Float64, "1e999")
@test Nitro.parseparam(Union{Float32, Float64}, "1.5") === 1.5f0
@test_throws ValidationError Nitro.parseparam(Union{Float32, Float64}, "inf")
@test_throws ArgumentError Nitro.parseparam(Float64, "abc")   # the bounded JSON parse refuses it
end
