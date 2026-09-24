@testitem "Extractors" tags=[:core] setup=[NitroCommon] begin

using Base: @kwdef
using Test
using HTTP
using Suppressor
using ProtoBuf
using Nitro
using Nitro: extract, Param, LazyRequest, Extractor, ProtoBuffer, isbodyparam, FormFile, Files
# HTTP.jl v2 exports `Form`/`Cookie` at the top level, which collide with Nitro's
# extractors under `using HTTP`. Import the Nitro ones explicitly to disambiguate.
using Nitro: Form, Cookie

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

# #72: the credential-carrying shape from the issue — a body-bound extractor whose
# deserialized instance holds a submitted password.
struct Login
    username::String
    password::String
end
validate(l::Login) = length(l.password) >= 12

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

    # The fragment lookup itself is client input: a body missing the key, and a body that
    # is not a JSON object at all, must be ValidationErrors (400) like every sibling
    # extractor -- they used to escape as a KeyError / MethodError and surface as 500s.
    missing_key = HTTP.Request("GET", "/", [], """{ "other": {"name": "joe", "age": 25} }""")
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=missing_key))

    not_an_object = HTTP.Request("GET", "/", [], "not json at all")
    @test_throws Nitro.Core.Errors.ValidationError extract(param, LazyRequest(request=not_an_object))
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
        path("/", function() Res.send("home") end, method="GET"),
        path("/headers", function(req, headers = Header(Sample, s -> s.limit > 5))
            return headers.payload
        end, method="GET"),
        path("/form", function(req, form::Form{Sample})
            return form.payload |> Res.json
        end, method="POST"),
        path("/query", function(req, query::Query{Sample})
            return query.payload |> Res.json
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
            return Res.json((p1=p1.payload, p2=p2.payload))
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

# #72: for a body-bound extractor the validated instance *is* the client's
# deserialized payload, so interpolating it put submitted credentials into `.msg` —
# which is app-reachable through `showerror` and any `catch ValidationError`. Both
# `try_validate` branches had the same interpolation, so both are covered here.
@testset "validation errors never echo the submitted payload (#72)" begin
    extract_err(param, body) = try
        extract(param, LazyRequest(request = HTTP.Request("POST", "/", [], body)))
        nothing
    catch e
        e
    end

    # Case 1 — the global `validate(::Login)` rejects: password shorter than 12.
    err1 = extract_err(Param(:credentials, Json{Login}, missing, false),
                       """{"username":"u-c1-sentinel","password":"pw-c1"}""")
    # Case 2 — the global validator passes; an extractor-local validator rejects.
    err2 = extract_err(Param(:credentials, Json{Login}, Json{Login}(l -> false), true),
                       """{"username":"u-c2-sentinel","password":"pw-c2-long-enough"}""")

    for (err, secret, user) in ((err1, "pw-c1", "u-c1-sentinel"),
                                (err2, "pw-c2-long-enough", "u-c2-sentinel"))
        @test err isa Nitro.Core.Errors.ValidationError
        @test !occursin(secret, err.msg)                 # the submitted password
        @test !occursin(user, err.msg)                   # any other submitted value
        @test !occursin(secret, sprint(showerror, err))  # showerror is app-reachable too
        # Still diagnosable: the parameter and its type.
        @test occursin("credentials", err.msg)
        @test occursin("Login", err.msg)
    end

    # ...and the validator that rejected it, however it identifies itself: a named
    # global `validate` method by name, an anonymous extractor-local one by source
    # location. Neither identification carries a submitted value. The source-location
    # assertion deliberately pins "the message identifies which validator rejected" —
    # an anonymous function has no other identity, so hardening `impl` later must
    # supply a replacement rather than simply dropping it.
    @test occursin("validate", err1.msg)
    @test occursin("extractor_tests.jl", err2.msg)

    # The other branch: `safe_extract` wraps a deserialization failure and attaches the
    # underlying exception as `.cause`. Its `.msg` is value-free too, which is what makes
    # the `@debug message=error.msg` line in `handlerequest` safe — and as of #130 the
    # rendered forms are value-free as well, so the payload cannot come back that way
    # either. The cause is still ATTACHED and still carries the submitted bytes; only an
    # explicit opt-in reaches it.
    bs = Char(0x5c)   # one real backslash → an invalid JSON escape inside the password
    parse_err = extract_err(Param(:credentials, Json{Login}, missing, false),
                            string("{\"username\":\"u-c3\",\"password\":\"pw-c3", bs, "qX\"}"))
    @test parse_err isa Nitro.Core.Errors.ValidationError
    @test !occursin("pw-c3", parse_err.msg)
    @test !occursin("u-c3", parse_err.msg)
    @test occursin("credentials", parse_err.msg)

    # #130 — the assertion this testset was written to be able to make. Both rendered
    # forms, because a logger that treats `exception=` as a plain value reaches `show`
    # rather than `showerror`, and the default struct `show` printed every field.
    @test !occursin("pw-c3", sprint(showerror, parse_err))
    @test !occursin("Caused by", sprint(showerror, parse_err))
    @test !occursin("pw-c3", sprint(show, parse_err))
    @test occursin("ArgumentError", sprint(show, parse_err))   # the type survives, not the value

    # ...and these are real guards, not vacuous ones: the cause IS attached and DOES carry
    # the submitted password, so all four assertions above fail against the unpatched
    # renderers. If this pair ever goes red, the sentinel stopped being present and those
    # four silently stopped proving anything — they do not quietly become theater.
    @test parse_err.cause isa Exception
    @test occursin("pw-c3", sprint(showerror, parse_err.cause))

    # The opt-in still renders the chain, which is what makes keeping `.cause` worthwhile.
    @test occursin("Caused by", sprint(io -> showerror(io, parse_err; cause = true)))
    @test occursin("pw-c3", sprint(io -> showerror(io, parse_err; cause = true)))
    # One formatter, not two: the helper must never drift from the kwarg it wraps.
    @test Nitro.Core.Errors.cause_report(parse_err) ==
          sprint(io -> showerror(io, parse_err; cause = true))
end

# #141: `safe_extract` is a wrap site, and a wrap site must not launder control flow. An
# interrupt arriving while a body-bound extractor deserializes is not client input -- turning
# it into a `ValidationError` means `handlerequest` never excludes it from the `@error` branch
# and `serve` never shuts down on it. `test/util_tests.jl` covers the same rule for the sibling
# site `parseparam_checked`.
@testset "safe_extract rethrows InterruptException instead of wrapping it (#141)" begin
    param = Param(:credentials, Json{Login}, missing, false)

    # The defect. Against the unpatched code this raised ValidationError, so the assertion
    # fails there rather than passing for the wrong reason.
    @test_throws InterruptException Nitro.Extractors.safe_extract(param) do
        throw(InterruptException())
    end

    # The guard must be narrow: every OTHER exception still becomes a 400 with the original
    # attached as `.cause`. Without this half, `catch e; rethrow(); end` would pass the test above.
    wrapped = try
        Nitro.Extractors.safe_extract(param) do
            throw(ArgumentError("DESERIALIZER-SENTINEL"))
        end
        nothing
    catch e
        e
    end
    @test wrapped isa Nitro.Core.Errors.ValidationError
    @test wrapped.cause isa ArgumentError
    # ...and a ValidationError raised inside still passes through unwrapped, not double-wrapped.
    inner = Nitro.Core.Errors.ValidationError("inner")
    rethrown = try
        Nitro.Extractors.safe_extract(param) do
            throw(inner)
        end
        nothing
    catch e
        e
    end
    @test rethrown === inner
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

# Uses a *local* App + internalrequest, so this item mutates no global
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

ctx = Nitro.Core.App()
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

@testitem "Extractors decode percent-encoding exactly once (#70)" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Nitro: path

# The scalar binding path (`parseparam`) and the extractor binding path
# (`struct_builder`/`parsetype`) used to disagree, each correct for one source and wrong for
# the other: scalars decoded query values twice, while `Path{T}` never decoded at all -- a
# `/files/a%2Fb` request reached the struct field as the literal "a%2Fb". Both now read the
# single decode performed by the `Types.*` accessor, so the two must agree on every URL.

struct PathBox;  v::String; end
struct QueryBox; q::String; end

ctx = Nitro.Core.App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/ext/{v}", (req, p::Nitro.Path{PathBox}, q::Nitro.Query{QueryBox}) ->
             Res.send("$(p.payload.v)|$(q.payload.q)"), method="GET"),
    path("/scalar/{v}", (req, v::String, q::String) -> Res.send("$v|$q"), method="GET"),
])
get_(t) = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", t))

@testset "Path{T} decodes -- the half that never did" begin
    @test Nitro.text(get_("/ext/a%2Fb?q=x"))   == "a/b|x"
    @test Nitro.text(get_("/ext/a%20b?q=x"))   == "a b|x"
    # One decode only: `%252B` must land as `%2B`, not as `+`.
    @test Nitro.text(get_("/ext/a%252Bb?q=x")) == "a%2Bb|x"
end

@testset "Query{T} is unchanged -- it was already correct" begin
    @test Nitro.text(get_("/ext/v?q=100%25%20off")) == "v|100% off"
    @test Nitro.text(get_("/ext/v?q=a%252Bb"))      == "v|a%2Bb"
end

@testset "the two binding paths agree" begin
    # This agreement is the point of the change: same URL, same values, whichever way the
    # handler declares its parameters.
    for target in ("/%s/a%%2Fb?q=100%%25%%20off", "/%s/a%%20b?q=a%%252Bb", "/%s/plain?q=50%%25")
        ext    = Nitro.text(get_(Base.replace(target, "%s" => "ext")))
        scalar = Nitro.text(get_(Base.replace(target, "%s" => "scalar")))
        @test ext == scalar
    end
end

end


# -- #293 -----------------------------------------------------------------------------------
#
# A `Cookie(name, T)` default is how a `Cookie{T}` parameter reads a cookie under a name other
# than its own. `try_validate` read `.validate` off every extractor default, and `Cookie` had
# no such field, so the route answered 500 whenever the cookie was *present*. The absent case
# returns before `try_validate`, which is why the direct-call test in cookies_tests.jl never
# saw it -- these go through a real route.
@testitem "Cookie{T} with a Cookie(name, T) default (#293)" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Nitro: path, Cookie

ctx = Nitro.Core.App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/renamed", (req, theme::Cookie{String} = Cookie("ui-theme", String)) ->
        Res.send(something(theme.value, "absent"))),
    path("/validated", (req, theme::Cookie{String} = Cookie("ui-theme", String, t -> t in ("light", "dark"))) ->
        Res.send(something(theme.value, "absent"))),
    path("/typed", (req, n::Cookie{Int} = Cookie("count", Int)) ->
        Res.send(string(something(n.value, -1)))),
])
get_(t, cookie=nothing) = Nitro.Core.internalrequest(ctx,
    HTTP.Request("GET", t, isnothing(cookie) ? Pair{String,String}[] : ["Cookie" => cookie]))

@testset "reads the named cookie, present or absent" begin
    r = get_("/renamed", "ui-theme=blue")
    @test r.status == 200
    @test Nitro.text(r) == "blue"
    @test Nitro.text(get_("/renamed")) == "absent"
    # The default's name replaces the parameter's -- a cookie called `theme` is not read.
    @test Nitro.text(get_("/renamed", "theme=blue")) == "absent"
end

@testset "the default's validator runs on a present cookie" begin
    @test Nitro.text(get_("/validated", "ui-theme=dark")) == "dark"
    @test get_("/validated", "ui-theme=blue").status == 400
    @test Nitro.text(get_("/validated")) == "absent"
end

@testset "the value parses as T" begin
    @test Nitro.text(get_("/typed", "count=7")) == "7"
    @test get_("/typed", "count=seven").status == 400
end

@testset "constructors carry the validator" begin
    f = t -> true
    @test Cookie("a", String).validate === nothing
    @test Cookie("a", String, f).validate === f
    @test Cookie("a", "v", f).value == "v"
    @test Cookie{Int}("a", 3, f).validate === f
    @test Cookie{Int}("a").value === nothing
end

# The class, not just `Cookie`: an extractor type with no `validate` field (`ProtoBuffer{T}`
# is one) must not turn its own default into a 500.
struct NoValidatorExtractor{T} <: Nitro.Types.Extractor{T}
    payload::T
end
@testset "try_validate tolerates an extractor with no validate field" begin
    param = Nitro.Types.Param(name=:x, type=NoValidatorExtractor{Int},
                              default=NoValidatorExtractor(1), hasdefault=true)
    @test Nitro.Core.Extractors.try_validate(param, 5) == 5
end

end


# -- #294 -----------------------------------------------------------------------------------
#
# JSON.jl 1.x knows StructUtils-style defaults, not `Base.@kwdef`'s, so `Json{T}` answered a body
# that omitted a defaulted field with a 400 -- including the Request Body tutorial's own
# `ProductSearch` example. `Query{T}`/`Form{T}`/`JsonFragment{T}` go through `struct_builder` and
# always honored the defaults.
@testitem "Json{T} honors @kwdef field defaults (#294)" tags=[:core] setup=[NitroCommon] begin

using Test
using HTTP
using JSON
using Nitro
using Nitro: path

# The tutorial's struct, verbatim.
@kwdef struct ProductSearch
    name     :: String = ""
    category :: String = ""
    limit    :: Int    = 20
end
@kwdef struct Paging
    page :: Int = 1
    size :: Int = 10
end
@kwdef struct Mixed
    id     :: Int                              # required
    note   :: Union{String, Nothing}           # no default, but admits `nothing`
    label  :: Union{String, Nothing} = "none"  # a default beats the null
    paging :: Paging = Paging()
    tags   :: Vector{String} = String[]
    scale  :: Float64 = id * 2.0               # a default computed from another field
end
struct Plain; q::String; limit::Int; end

ctx = Nitro.Core.App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/search", (req, s::Json{ProductSearch}) -> Res.json(s.payload); method = "POST"),
    path("/validated", (req, s = Json(ProductSearch, q -> !isempty(q.name) || !isempty(q.category))) ->
        Res.json(s.payload); method = "POST"),
    path("/mixed", (req, m::Json{Mixed}) -> Res.json(m.payload); method = "POST"),
    path("/plain", (req, p::Json{Plain}) -> Res.json(p.payload); method = "POST"),
])
post(t, body) = Nitro.Core.internalrequest(ctx, HTTP.Request("POST", t, [], body))
bound(r) = JSON.parse(Nitro.text(r))

@testset "a partial body binds, absent fields take their defaults" begin
    r = post("/search", """{"name":"lamp"}""")
    @test r.status == 200
    @test bound(r) == Dict("name" => "lamp", "category" => "", "limit" => 20)
    @test bound(post("/search", "{}")) == Dict("name" => "", "category" => "", "limit" => 20)
    # A full body is unchanged, and an unknown key is still ignored.
    @test bound(post("/search", """{"name":"a","category":"b","limit":5,"extra":1}""")) ==
          Dict("name" => "a", "category" => "b", "limit" => 5)
end

@testset "the tutorial's inline validator sees the partial body" begin
    @test post("/validated", """{"category":"tools"}""").status == 200
    @test post("/validated", """{"limit":3}""").status == 400
end

@testset "a missing required field is still a 400" begin
    @test post("/mixed", """{"note":"x"}""").status == 400
end

@testset "absent fields follow JSON.jl's rule: default, else null" begin
    m = bound(post("/mixed", """{"id":2}"""))
    @test m["id"] == 2
    @test m["note"] === nothing
    @test m["label"] == "none"
    @test m["paging"] == Dict("page" => 1, "size" => 10)
    @test m["tags"] == String[]
    @test m["scale"] == 4.0
end

@testset "a directly nested @kwdef struct binds partially too" begin
    m = bound(post("/mixed", """{"id":1,"paging":{"size":50},"tags":["a"],"label":null}"""))
    @test m["paging"] == Dict("page" => 1, "size" => 50)
    @test m["tags"] == ["a"]
    @test m["label"] === nothing   # a present `null` is a value, not an absence
end

@testset "malformed and mistyped bodies are still 400s" begin
    @test post("/search", """{"name":"a"} trailing""").status == 400
    @test post("/search", """{"name":""").status == 400
    @test post("/search", "[1,2]").status == 400
    @test post("/search", "").status == 400
    @test post("/search", """{"limit":"many"}""").status == 400
    @test post("/mixed", """{"id":1,"paging":{"size":"big"}}""").status == 400
end

@testset "a plain struct is unchanged -- every field is required" begin
    @test bound(post("/plain", """{"q":"x","limit":1}""")) == Dict("q" => "x", "limit" => 1)
    @test post("/plain", """{"q":"x"}""").status == 400
end

@kwdef struct WithMissing; id::Int; m::Union{Int, Missing}; end
@testset "absent-field fill reaches `missing` too" begin
    w = Nitro.Core.Extractors.json_bind(WithMissing, """{"id":1}""")
    @test w.id == 1
    @test w.m === missing
end

# A struct that already speaks StructUtils is JSON.jl's to bind: its field tags must survive.
# Taking the per-field path dropped them, so `{"bee":"y"}` bound the default "x" with a 200.
JSON.StructUtils.@kwarg struct Tagged
    a :: Int    = 3
    b :: String = "x" &(json=(name="bee",),)
end
@testset "StructUtils field tags are honored, not dropped" begin
    @test Nitro.Core.Extractors.json_bind(Tagged, """{"bee":"y"}""") == JSON.parse("""{"bee":"y"}""", Tagged)
    @test Nitro.Core.Extractors.json_bind(Tagged, """{"bee":"y"}""").b == "y"
    @test Nitro.Core.Extractors.json_bind(Tagged, "{}") == Tagged(3, "x")
end

@testset "the missing-field error names the field, never a value" begin
    err = try
        Nitro.Core.Extractors.json_bind(Mixed, """{"note":"secret-value"}""")
    catch e
        e
    end
    @test err isa Nitro.Core.Errors.ValidationError
    @test occursin("'id'", sprint(showerror, err))
    @test !occursin("secret-value", sprint(showerror, err))
end

end


# -- #254 -----------------------------------------------------------------------------------
#
# The `Session` extractor looks a session id up in an application-supplied store through a
# `Base.get` the store owns. "It threw" therefore means "no session for this id", and the
# extractor falls back to an empty `Session` -- right for a store that is down or picky, wrong
# for the three conditions the runtime raises about itself.
#
# Synthetic throws are honest here, unlike in the body parsers: the guarded expression IS the
# user callback, so `throw(StackOverflowError())` from the store originates inside the `try`
# exactly where a real one would.
@testitem "Session extractor -- unrecoverable errors are not swallowed (#254)" tags=[:core] setup=[NitroCommon] begin
using HTTP
using Nitro
using Nitro: LazyRequest, Param, Session, extract

# A real `AbstractSessionStore` since #327: the extractor reads no other kind of context, so a
# store that is not one would never be called and these assertions would pass vacuously.
struct ThrowingStore <: Nitro.Types.AbstractSessionStore{String, Dict{String,Any}}
    ex::Exception
end
Base.get(s::ThrowingStore, ::String, ::Any) = throw(s.ex)

struct FakeContext
    payload::Any
end

function session_param()
    return Param{Session{Dict{String,Any}}}(:s, Session{Dict{String,Any}}, Session("session", Dict{String,Any}), true)
end

function request_with_session_cookie()
    req = HTTP.Request("GET", "/")
    HTTP.setheader(req, "Cookie" => "session=abc123")
    return LazyRequest(request=req)
end

@testset "propagates $(typeof(ex))" for ex in (InterruptException(), StackOverflowError(), OutOfMemoryError())
    ctx = FakeContext(ThrowingStore(ex))
    @test_throws typeof(ex) extract(session_param(), request_with_session_cookie(), nothing, ctx)
end

# The contract that must not regress: an ordinary store failure is still an empty session, not
# an exception reaching the handler.
@testset "an ordinary store failure still yields an empty session" begin
    for ex in (ErrorException("db down"), KeyError(:nope), ArgumentError("bad id"))
        ctx = FakeContext(ThrowingStore(ex))
        result = extract(session_param(), request_with_session_cookie(), nothing, ctx)
        @test result.payload === nothing
        @test result.name == "session"
    end
end
end

@testitem "Extractors declared with an abstract T bind (#327)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App, Json, Body, Cookie, Session

# `try_validate` dispatched `instance::T` on the value's RUNTIME type, and `extract` returned
# `X(value)` -- an `X{typeof(value)}` -- so a parameter declared with an abstract `T` matched no
# method, or could not be converted to its declared type. Either way a 500 with a backtrace for
# a perfectly good request (#327, the #293 family).
struct Person
    name::String
end

store = MemoryStore{String, Person}()
Nitro.Types.set_session!(store, "sid", Person("Ann"); ttl = 60)

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/body", (req, b::Body{Any}) -> string(typeof(b.payload)); method = "POST"),
    path("/json", (req, j::Json{Any}) -> string(j.payload["a"]); method = "POST"),
    path("/cookie", (req, c::Cookie{Any}) -> string(c.value)),
    path("/session", (req, s::Session{Any}) -> s.payload.name),
)
send(r) = internalrequest(app, r; context = store)

r = send(HTTP.Request("POST", "/body", ["Content-Type" => "text/plain"], "hello"))
@test r.status == 200
@test Nitro.text(r) == "String"

r = send(HTTP.Request("POST", "/json", ["Content-Type" => "application/json"], """{"a":1}"""))
@test r.status == 200
@test Nitro.text(r) == "1"

r = send(HTTP.Request("GET", "/cookie", ["Cookie" => "c=v"]))
@test r.status == 200
@test Nitro.text(r) == "v"

r = send(HTTP.Request("GET", "/session", ["Cookie" => "session=sid"]))
@test r.status == 200
@test Nitro.text(r) == "Ann"
end
