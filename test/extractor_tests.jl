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

# Payload types for the MultipartForm{T} extractor tests
struct ImportUpload
    user_id     :: String
    ibge_id     :: Int
    dry_run     :: Union{Nothing, Bool}
    files       :: Vector{FormFile}
end

@kwdef struct SingleFileUpload
    category :: String
    file     :: FormFile
end

@kwdef struct DefaultsUpload
    user_id :: String
    label   :: String = "unlabeled"   # non-nothing default, honored when absent
    retries :: Int    = 3             # non-nothing default, honored when absent
    file    :: FormFile
end

validate(u::ImportUpload) = u.ibge_id > 0 && !isempty(u.user_id)

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

@testset "MultipartForm - mixed text fields and files" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "user_id", :data => "alice"),
        Dict(:name => "ibge_id", :data => "355030"),
        Dict(:name => "dry_run", :data => "true"),
        Dict(:name => "files", :filename => "a.csv", :data => "row1"),
        Dict(:name => "files", :filename => "b.csv", :data => "row2"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    result = extract(param, LazyRequest(request=req))

    @test result isa MultipartForm{ImportUpload}
    data = result.payload
    @test data.user_id == "alice"
    @test data.ibge_id == 355030          # parsed Int
    @test data.dry_run === true           # parsed Bool
    @test length(data.files) == 2         # Vector{FormFile}
    @test data.files[1].filename == "a.csv"
    @test data.files[2].filename == "b.csv"
end

@testset "MultipartForm - optional field absent binds to nothing" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "user_id", :data => "bob"),
        Dict(:name => "ibge_id", :data => "1"),
        Dict(:name => "files", :filename => "x.csv", :data => "data"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    result = extract(param, LazyRequest(request=req))
    @test result.payload.dry_run === nothing
end

@testset "MultipartForm - single FormFile field" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "category", :data => "reports"),
        Dict(:name => "file", :filename => "doc.pdf", :data => "pdf bytes"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{SingleFileUpload}, missing, false)
    result = extract(param, LazyRequest(request=req))
    @test result.payload.category == "reports"
    @test result.payload.file isa FormFile
    @test result.payload.file.filename == "doc.pdf"
end

@testset "MultipartForm - @kwdef defaults honored when fields absent" begin
    # Only user_id + file sent; label/retries absent → declared defaults apply.
    body, ct = _build_multipart(parts=[
        Dict(:name => "user_id", :data => "erin"),
        Dict(:name => "file", :filename => "x.csv", :data => "data"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{DefaultsUpload}, missing, false)
    result = extract(param, LazyRequest(request=req)).payload
    @test result.user_id == "erin"
    @test result.label == "unlabeled"   # default, not an error
    @test result.retries == 3           # default, not an error

    # When present, the body value overrides the default.
    body, ct = _build_multipart(parts=[
        Dict(:name => "user_id", :data => "erin"),
        Dict(:name => "label", :data => "q3"),
        Dict(:name => "retries", :data => "7"),
        Dict(:name => "file", :filename => "x.csv", :data => "data"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    result = extract(param, LazyRequest(request=req)).payload
    @test result.label == "q3"
    @test result.retries == 7
end

@testset "MultipartForm - @kwdef missing required (no default) throws" begin
    # user_id has no default and is absent → ValidationError, not UndefKeywordError.
    body, ct = _build_multipart(parts=[
        Dict(:name => "file", :filename => "x.csv", :data => "data"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{DefaultsUpload}, missing, false)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))
end

@testset "MultipartForm - missing required text field throws" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "ibge_id", :data => "1"),
        Dict(:name => "files", :filename => "x.csv", :data => "data"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))
end

@testset "MultipartForm - unparseable number throws" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "user_id", :data => "x"),
        Dict(:name => "ibge_id", :data => "not-a-number"),
        Dict(:name => "files", :filename => "x.csv", :data => "data"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))
end

@testset "MultipartForm - validate(::T) failure throws" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "user_id", :data => "carol"),
        Dict(:name => "ibge_id", :data => "0"),   # fails validate: ibge_id > 0
        Dict(:name => "files", :filename => "x.csv", :data => "data"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))
end

@testset "MultipartForm - validation error message stays bounded (no file-byte dump)" begin
    # A large uploaded file that fails validation must NOT dump its bytes into
    # the error message (which would otherwise bloat logs by ~the file size).
    big = repeat("A", 200_000)
    body, ct = _build_multipart(parts=[
        Dict(:name => "user_id", :data => "carol"),
        Dict(:name => "ibge_id", :data => "0"),          # fails validate: ibge_id > 0
        Dict(:name => "files", :filename => "big.csv", :data => big),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    err = try
        extract(param, LazyRequest(request=req)); nothing
    catch e
        e
    end
    @test err isa Nitro.Core.Errors.ValidationError
    @test length(err.msg) < 2_000          # bounded, not ~200 KB
    @test !occursin(big, err.msg)          # the file bytes are not embedded
    @test occursin("ImportUpload", err.msg)  # still names the failing type
end

@testset "MultipartForm - non-multipart body throws" begin
    req = HTTP.Request("POST", "/", ["Content-Type" => "application/json"], """{}""")
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))
end

@testset "MultipartForm - empty multipart body reports the missing field, not Content-Type" begin
    # A well-formed multipart/form-data body with no parts must NOT be reported
    # as a Content-Type error — the message should name the missing field.
    boundary = "----TestBoundaryEmpty"
    req = HTTP.Request("POST", "/",
        ["Content-Type" => "multipart/form-data; boundary=$boundary"],
        "--$boundary--\r\n")
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    err = try
        extract(param, LazyRequest(request=req))
        nothing
    catch e
        e
    end
    @test err isa Nitro.Core.Errors.ValidationError
    @test occursin("user_id", err.msg)
    @test !occursin("Content-Type", err.msg)
end

@testset "MultipartForm - file given where text expected throws" begin
    body, ct = _build_multipart(parts=[
        Dict(:name => "user_id", :filename => "oops.txt", :data => "uploaded"),  # file, but user_id is text
        Dict(:name => "ibge_id", :data => "1"),
        Dict(:name => "files", :filename => "x.csv", :data => "data"),
    ])
    req = HTTP.Request("POST", "/", ["Content-Type" => ct], body)
    param = Param(:payload, MultipartForm{ImportUpload}, missing, false)
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=req))
end

end

@testitem "MultipartForm end-to-end dispatch" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Nitro: path, FormFile, MultipartForm

# Uses a *local* ServerContext + internalrequest, so this item mutates no global
# router/server state and is safe to run in parallel with other test items.

struct E2EUpload
    user_id :: String
    count   :: Int
    files   :: Vector{FormFile}
end

function upload_handler(req, payload::MultipartForm{E2EUpload})
    data = payload.payload
    return Res.json(Dict(
        "user_id"   => data.user_id,
        "count"     => data.count,
        "num_files" => length(data.files),
        "first"     => isempty(data.files) ? "" : data.files[1].filename,
    ))
end

function _multipart_request(target)
    boundary = "----E2EBoundary"
    io = IOBuffer()
    for part in [
        (name="user_id", data="dave"),
        (name="count", data="3"),
        (name="files", filename="a.csv", data="r1"),
        (name="files", filename="b.csv", data="r2"),
    ]
        write(io, "--$boundary\r\n")
        if haskey(part, :filename)
            write(io, "Content-Disposition: form-data; name=\"$(part.name)\"; filename=\"$(part.filename)\"\r\n")
            write(io, "Content-Type: application/octet-stream\r\n")
        else
            write(io, "Content-Disposition: form-data; name=\"$(part.name)\"\r\n")
        end
        write(io, "\r\n$(part.data)\r\n")
    end
    write(io, "--$boundary--\r\n")
    return HTTP.Request("POST", target, ["Content-Type" => "multipart/form-data; boundary=$boundary"], take!(io))
end

ctx = Nitro.Core.ServerContext()
Nitro.Core.Routing.urlpatterns(ctx, "/api", Nitro.RouteDefinition[
    path("/upload", upload_handler, method="POST"),
])

r = Nitro.Core.internalrequest(ctx, _multipart_request("/api/upload"))
@test r.status == 200
body = Nitro.json(r)
@test body["user_id"] == "dave"
@test body["count"] == 3
@test body["num_files"] == 2
@test body["first"] == "a.csv"

# Bad payload (count not a number) → 400 ValidationError
bad = HTTP.Request("POST", "/api/upload",
    ["Content-Type" => "multipart/form-data; boundary=b"],
    "--b\r\nContent-Disposition: form-data; name=\"user_id\"\r\n\r\nx\r\n--b\r\nContent-Disposition: form-data; name=\"count\"\r\n\r\nNaN\r\n--b--\r\n")
r = Nitro.Core.internalrequest(ctx, bad)
@test r.status == 400

end
