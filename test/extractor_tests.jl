@testitem "Extractors" tags=[:core] setup=[NitroCommon] begin

using Base: @kwdef
using Test
using HTTP
using Suppressor
using ProtoBuf
using Nitro
using Nitro: extract, Param, LazyRequest, Extractor, ProtoBuffer, isbodyparam, FormFile, Files

# extend the built-in validate function
import Nitro: validate

include("extensions/protobuf/.messages/test_pb.jl")
using .test_pb: MyMessage 

struct Person
    name::String
    age::Int
end

@kwdef struct Home
    address::String
    owner::Person
end

# Add a lower bound to age with a global validator
validate(p::Person) = p.age >= 0

@testset "Extactor builder sytnax" begin 

    @test Json{Person}(x -> x.age >= 25) isa Extractor

    @test Json(Person) isa Extractor
    @test Json(Person, x -> x.age >= 25) isa Extractor

    p = Person("joe", 25)

    @test Json(p) isa Extractor
    @test Json(p, x -> x.age >= 25) isa Extractor
end

@testset "JSON extract" begin 
    req = HTTP.Request("GET", "/", [], """{"name": "joe", "age": 25}""")
    param = Param(:person, Json{Person}, missing, false)
    p = extract(param, LazyRequest(request=req)).payload
    @test p.name == "joe"
    @test p.age == 25
end

@testset "kwarg_struct_builder Nested test" begin 
    req = HTTP.Request("GET", "/", [], """
    {
        "address": "123 main street",
        "owner": {
            "name": "joe",
            "age": 25
        }
    }
    """)
    param = Param(:person, Json{Home}, missing, false)
    p = extract(param, LazyRequest(request=req)).payload
    @test p isa Home
    @test p.owner isa Person
    @test p.address == "123 main street"
    @test p.owner.name == "joe"
    @test p.owner.age == 25
end

@testset "isbodyparam tests" begin 
    param = Param(:person, Json{Home}, missing, false)
    @test isbodyparam(param) == true
end

@testset "Partial JSON extract" begin 
    req = HTTP.Request("GET", "/", [], """{ "person": {"name": "joe", "age": 25} }""")
    param = Param(:person, JsonFragment{Person}, missing, false)
    p = extract(param, LazyRequest(request=req)).payload
    @test p.name == "joe"
    @test p.age == 25
end


@testset "Form extract" begin 
    req = HTTP.Request("GET", "/", [], """name=joe&age=25""")
    param = Param(:form, Form{Person}, missing, false)
    p = extract(param, LazyRequest(request=req)).payload
    @test p.name == "joe"
    @test p.age == 25


    # Test that negative age trips the global validator
    req = HTTP.Request("GET", "/", [], """name=joe&age=-4""")
    param = Param(:form, Form{Person}, missing, false)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))


    # Test that age < 25 trips the local validator
    req = HTTP.Request("GET", "/", [], """name=joe&age=10""")
    default_value = Form{Person}(x -> x.age > 25)
    param = Param(:form, Form{Person}, default_value, true)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))
end


@testset "Path extract" begin 
    req = HTTP.Request("GET", "/person/john/20", [])
    req.context[:params] = Dict("name" => "john", "age" => "20") # simulate path params

    param = Param(:path, Path{Person}, missing, false)
    p = extract(param, LazyRequest(request=req)).payload
    @test p.name == "john"
    @test p.age == 20
end


@testset "Query extract" begin 
    req = HTTP.Request("GET", "/person?name=joe&age=30", [])
    param = Param(:query, Query{Person}, missing, false)
    p = extract(param, LazyRequest(request=req)).payload
    @test p.name == "joe"
    @test p.age == 30

    # test custom instance validator
    req = HTTP.Request("GET", "/person?name=joe&age=30", [])
    default_value = Query{Person}(x -> x.age > 25)
    param = Param(:query, Query{Person}, default_value, true)
    p = extract(param, LazyRequest(request=req)).payload
    @test p.name == "joe"
    @test p.age == 30
end

@testset "Header extract" begin 
    req = HTTP.Request("GET", "/person", ["name" => "joe", "age" => "19"])
    param = Param(:header, Header{Person}, missing, false)
    p = extract(param, LazyRequest(request=req)).payload
    @test p.name == "joe"
    @test p.age == 19
end


@testset "Body extract" begin 

    # Parse Float64 from body
    req = HTTP.Request("GET", "/", [], "3.14")
    param = Param(:form, Body{Float64}, missing, false)
    value = extract(param, LazyRequest(request=req)).payload
    @test value == 3.14

    # Parse String from body
    req = HTTP.Request("GET", "/", [], "Here's a regular string")
    param = Param(:form, Body{String}, missing, false)
    value = extract(param, LazyRequest(request=req)).payload
    @test value == "Here's a regular string"
end


@kwdef struct Sample
    limit::Int
    skip::Int = 33
end

@kwdef struct PersonWithDefault
    name::String
    age::Int
    value::Float64 = 1.5
end

struct Parameters
    b::Int
end

@testset "Api tests" begin

    urlpatterns("",
        path("/", function() text("home") end, method="GET"),
        path("/headers", function(req, headers = Header(Sample, s -> s.limit > 5))
            return headers.payload
        end, method="GET"),
        path("/form", function(req, form::Form{Sample})
            return form.payload |> json
        end, method="POST"),
        path("/query", function(req, query::Query{Sample})
            return query.payload |> json
        end, method="GET"),
        path("/body/string", function(req, body::Body{String})
            return body.payload
        end, method="POST"),
        path("/body/float", function(req, body::Body{Float64})
            return body.payload
        end, method="POST"),
        path("/json", function(req, data = Json{PersonWithDefault}(s -> s.value < 10))
            return data.payload
        end, method="POST"),
        path("/protobuf", function(req, data::ProtoBuffer{MyMessage})
            return protobuf(data.payload)
        end, method="POST"),
        path("/json/partial", function(req, p1::JsonFragment{PersonWithDefault}, p2::JsonFragment{PersonWithDefault})
            return json((p1=p1.payload, p2=p2.payload))
        end, method="POST"),
        path("/path/add/{a}/{b}", function(req, a::Int, path::Path{Parameters}, qparams::Query{Sample}, c::Nullable{Int}=23)
            return a + path.payload.b
        end, method="GET"),
    )

    r = internalrequest(HTTP.Request("GET", "/"))
    @test r.status == 200
    @test text(r) == "home"

    r = internalrequest(HTTP.Request("GET", "/path/add/3/7?limit=10"))
    @test r.status == 200
    @test text(r) == "10"

    r = internalrequest(HTTP.Request("POST", "/form", [], """limit=10&skip=25"""))
    @test r.status == 200
    data = json(r)
    @test data["limit"] == 10
    @test data["skip"] == 25

    r = internalrequest(HTTP.Request("GET", "/query?limit=10&skip=25"))
    @test r.status == 200
    data = json(r)
    @test data["limit"] == 10
    @test data["skip"] == 25
    
    r = internalrequest(HTTP.Request("POST", "/body/string", [], """Hello World!"""))
    @test r.status == 200
    @test text(r) == "Hello World!"

    r = internalrequest(HTTP.Request("POST", "/body/float", [], """3.14"""))
    @test r.status == 200
    @test parse(Float64, text(r)) == 3.14

    @suppress_err begin 
        # should fail since we are missing query params
        r = internalrequest(HTTP.Request("GET", "/path/add/3/7"))
        @test r.status == 400
    end

    r = internalrequest(HTTP.Request("GET", "/headers", ["limit" => "10"], ""))
    @test r.status == 200
    data = json(r)
    @test data["limit"] == 10
    @test data["skip"] == 33

    @suppress_err begin 
        # should fail since we are missing query params
        r = internalrequest(HTTP.Request("GET", "/headers", ["limit" => "3"], ""))
        @test r.status == 400
    end

    @suppress_err begin 
        # value is higher than the limit set in the validator
        r = internalrequest(HTTP.Request("POST", "/json", [], """
        {
            "name": "joe",
            "age": 24,
            "value": 12.0
        }
        """))
        @test r.status == 400
    end

    r = internalrequest(HTTP.Request("POST", "/json", [], """
    {
        "name": "joe",
        "age": 24,
        "value": 4.8
    }
    """))
    data = json(r)
    @test data["name"] == "joe"
    @test data["age"] == 24
    @test data["value"] == 4.8

    r = internalrequest(HTTP.Request("POST", "/json/partial", [], """
    {
        "p1": {
            "name": "joe",
            "age": "24"
        },
        "p2": {
            "name": "kim",
            "age": "25",
            "value": 100.0
        }
    }
    """))

    @test r.status == 200
    data = json(r)
    p1 = data["p1"]
    p2 = data["p2"]

    @test p1["name"] == "joe"
    @test p1["age"] == 24
    @test p1["value"] == 1.5

    @test p2["name"] == "kim"
    @test p2["age"] == 25
    @test p2["value"] == 100

    message = MyMessage(-1, ["a", "b"])
    r = internalrequest(protobuf(message, "/protobuf"))
    decoded_msg = protobuf(r, MyMessage)

    @test decoded_msg isa MyMessage
    @test decoded_msg.a == -1
    @test decoded_msg.b == ["a", "b"]

end

# ─── Helper to build raw multipart/form-data bytes for testing ────────

function _build_multipart(; boundary::String="----TestBoundary7MA4YWxkTrZu0gW", parts::Vector)
    io = IOBuffer()
    for part in parts
        write(io, "--$boundary\r\n")
        if haskey(part, :filename)
            write(io, "Content-Disposition: form-data; name=\"$(part[:name])\"; filename=\"$(part[:filename])\"\r\n")
            ct = get(part, :content_type, "application/octet-stream")
            write(io, "Content-Type: $ct\r\n")
        else
            write(io, "Content-Disposition: form-data; name=\"$(part[:name])\"\r\n")
        end
        write(io, "\r\n")
        write(io, part[:data])
        write(io, "\r\n")
    end
    write(io, "--$boundary--\r\n")
    body = take!(io)
    content_type = "multipart/form-data; boundary=$boundary"
    return body, content_type
end

@testset "Files extractor - single file by name" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "document", :filename => "report.xlsx", :data => "fake xlsx content")
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:document, Files{FormFile}, missing, false)
    result = extract(param, LazyRequest(request=req))
    @test result isa Files{FormFile}
    @test result.payload.filename == "report.xlsx"
    @test String(result.payload.data) == "fake xlsx content"
end

@testset "Files extractor - all files" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "file1", :filename => "data.dbf", :data => "dbf bytes"),
        Dict(:name => "file2", :filename => "sheet.xlsx", :data => "xlsx bytes")
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:files, Files{Vector{FormFile}}, missing, false)
    result = extract(param, LazyRequest(request=req))
    @test result isa Files{Vector{FormFile}}
    @test length(result.payload) == 2
    @test result.payload[1].filename == "data.dbf"
    @test result.payload[2].filename == "sheet.xlsx"
end

@testset "Files extractor - missing field throws ValidationError" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "other", :filename => "file.txt", :data => "content")
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:document, Files{FormFile}, missing, false)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))
end

@testset "Files extractor - empty multipart returns empty vector" begin
    req = HTTP.Request("POST", "/", ["Content-Type" => "application/json"], """{}""")
    param = Param(:files, Files{Vector{FormFile}}, missing, false)
    result = extract(param, LazyRequest(request=req))
    @test result isa Files{Vector{FormFile}}
    @test isempty(result.payload)
end

end
