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
