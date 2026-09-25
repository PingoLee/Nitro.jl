@testitem "Body parser" tags=[:core] setup=[NitroCommon] begin

struct rank
    title   :: String 
    power   :: Float64
end

req = Request("GET", "/json", [], """{"message":["hello",1.0]}""")
json(req)

@testset "queryparams" begin
    no_params = Request("GET", "http://google.com")
    with_params = Request("GET", "http://google.com?q=123&l=345")

    @test queryparams(no_params) == Dict{String, String}()
    @test queryparams(with_params) == Dict("q" => "123", "l" => "345")

    @test queryparams(Response(200; body="", request=with_params)) == Dict("q" => "123", "l" => "345")
    @test isnothing(queryparams(Response(200; body="")))
end

@testset "formdata() Request struct keyword tests" begin 
    req = Request("POST", "/", [], "message=hello world&value=3")
    data = formdata(req)
    @test data["message"] == "hello world"
    @test data["value"] == "3"
end

@testset "formdata() Response struct keyword tests" begin 
    req = Response("message=hello world&value=3")
    data = formdata(req)
    @test data["message"] == "hello world"
    @test data["value"] == "3"
end


@testset "json() Request struct keyword tests" begin


    @testset "json() Request struct keyword tests" begin 

        req = Request("GET", "/json", [], "{\"message\":[NaN,1.0]}")
        @test isnan(json(req, allownan = true)["message"][1])
        @test !isnan(json(req, allownan = true)["message"][2])

        req = Request("GET", "/json", [], "{\"message\":[Inf,1.0]}")
        @test isinf(json(req, allownan = true)["message"][1])

        req = Request("GET", "/json", [], "{\"message\":[null,1.0]}")
        @test isnothing(json(req, allownan = false)["message"][1])

    end


    @testset "json() Request stuct keyword with class_type" begin

        # #327: `json(req, T)` never binds NaN or Infinity from a REQUEST, so `allownan` is
        # refused outright. It used to bind `power = NaN`. (The untyped form above and the
        # Response forms below keep the keyword: they build no typed value from client input.)
        req = Request("GET","/", [],"""{"title": "viscount", "power": NaN}""")
        @test_throws ArgumentError json(req, rank, allownan = true)

        req = Request("GET","/", [],"""{"title": "viscount", "power": 9000.1}""")
        myjson = json(req, rank, allownan = false)
        @test myjson.power == 9000.1

    end


    @testset "regular Request json() tests" begin 

        req = Request("GET", "/json", [], "{\"message\":[null,1.0]}")
        @test isnothing(json(req)["message"][1])
        @test json(req)["message"][2] == 1

        req = Request("GET", "/json", [], """{"message":["hello",1.0]}""")
        @test json(req)["message"][1] == "hello"
        @test json(req)["message"][2] == 1

        req = Request("GET", "/json", [], "{\"message\":[3.4,4.0]}")
        @test json(req)["message"][1] == 3.4
        @test json(req)["message"][2] == 4

        req = Request("GET", "/json", [], "{\"message\":[null,1.0]}")
        @test isnothing(json(req)["message"][1])
    end


    @testset "json() Request with class_type" begin

        # #327: refused, as above (a usage error, so still an ArgumentError); and without the
        # keyword NaN is not JSON at all -- client input, so a ValidationError (#326).
        req = Request("GET","/", [],"""{"title": "viscount", "power": NaN}""")
        @test_throws ArgumentError json(req, rank, allownan = true)
        @test_throws ValidationError json(req, rank)
        # A number too large for a Float64 is not smuggled in as Inf.
        req = Request("GET","/", [],"""{"title": "viscount", "power": 1e999}""")
        @test_throws ValidationError json(req, rank)

        req = Request("GET","/", [],"""{"title": "viscount", "power": 9000.1}""")
        myjson = json(req, rank)
        @test myjson.power == 9000.1

        # A body that omits a required field must FAIL rather than hand back a
        # partially-initialised struct. That is the contract; the exception TYPE is not,
        # and pinning it is what made this assertion red on every CI job (#218).
        #
        # StructUtils owns that type and changed it deliberately:
        #   <= 2.8  `fielddefault(style, T, i)::fieldtype(T, i)` -- with no default,
        #           `fielddefault` returns `nothing`, so `nothing::String` fails the type
        #           ASSERT. The `TypeError` was incidental, and named the type, not the field.
        #   >= 2.9  an explicit `_absentfield_error(name)` throwing `ArgumentError` that
        #           names the missing FIELD. Its source comment says the message deliberately
        #           carries no type, "so it is safe under `juliac --trim`".
        #
        # So this is an upstream improvement, not a regression -- do not narrow `[compat]`
        # to dodge it. The union accepts both spellings, since `[compat] JSON = "^1.3"`
        # admits resolves on either side of the change.
        #
        # The contract that actually reaches an app is asserted elsewhere and is already
        # type-agnostic: `test/extractor_tests.jl` ("user_id has no default and is absent")
        # pins missing-required-field -> `ValidationError` -> 400, because `safe_extract`
        # wraps ANY non-`InterruptException` throw. That is why this dependency change
        # altered no HTTP behaviour, only this line's expectation.
        #
        # #326 then gave `json(req, T)` the same wrap `safe_extract` has: whatever StructUtils
        # throws, the REQUEST form now raises a value-free `ValidationError` carrying it as
        # `.cause` -- a 400 in a handler, where the raw error was a 500 whose log line quoted
        # the body. The Response form below keeps the raw union: a response is not client input.
        req = Request("GET","/", [],"""{}""")
        err = try json(req, rank); nothing catch e; e end
        @test err isa ValidationError
        @test err.cause isa Union{TypeError, ArgumentError}

        # The message never quotes the body, even when the parse error does -- and it does for
        # bytes just before the error, which is where the issue's repro put its password.
        req = Request("GET","/", [],"""{"title": "viscount", "password":"S3CR3T" oops}""")
        err = try json(req, rank); nothing catch e; e end
        @test err isa ValidationError
        @test !occursin("S3CR3T", err.msg)
        @test !occursin("S3CR3T", sprint(showerror, err))
        @test occursin("S3CR3T", sprint(showerror, err.cause))   # the cause really carries it

        # test extra key
        req = Request("GET","/", [],"""{"title": "viscount", "power": 9000.1, "extra": "hi"}""")
        myjson = json(req, rank)
        @test myjson.power == 9000.1

    end


    @testset "json() Response" begin 

        res = Response("""{"title": "viscount", "power": 9000.1}""")
        myjson = json(res)
        @test myjson["power"] == 9000.1

        res = Response("""{"title": "viscount", "power": 9000.1}""")
        myjson = json(res, rank)
        @test myjson.power == 9000.1

    end

    @testset "json() Response struct keyword tests" begin 

        req = Response("{\"message\":[NaN,1.0]}")
        @test isnan(json(req, allownan = true)["message"][1])
        @test !isnan(json(req, allownan = true)["message"][2])

        req = Response("{\"message\":[Inf,1.0]}")
        @test isinf(json(req, allownan = true)["message"][1])

        req = Response("{\"message\":[null,1.0]}")
        @test isnothing(json(req, allownan = false)["message"][1])

    end


    @testset "json() Response stuct keyword with class_type" begin 

        req = Response("""{"title": "viscount", "power": NaN}""")
        myjson = json(req, rank, allownan = true)
        @test isnan(myjson.power)

        req = Response("""{"title": "viscount", "power": 9000.1}""")
        myjson = json(req, rank, allownan = false)
        @test myjson.power == 9000.1

    end


    @testset "regular json() Response tests" begin 

        req = Response("{\"message\":[null,1.0]}")
        @test isnothing(json(req)["message"][1])
        @test json(req)["message"][2] == 1

        req = Response("""{"message":["hello",1.0]}""")
        @test json(req)["message"][1] == "hello"
        @test json(req)["message"][2] == 1

        req = Response("{\"message\":[3.4,4.0]}")
        @test json(req)["message"][1] == 3.4
        @test json(req)["message"][2] == 4

        req = Response("{\"message\":[null,1.0]}")
        @test isnothing(json(req)["message"][1])
    end


    @testset "json() Response with class_type" begin 

        req = Response("""{"title": "viscount", "power": NaN}""")
        myjson = json(req, rank; allownan=true)
        @test isnan(myjson.power)

        req = Response("""{"title": "viscount", "power": 9000.1}""")
        myjson = json(req, rank)
        @test myjson.power == 9000.1

        # Same contract on the Response side, same reasoning -- see the Request testset
        # above for why the exception type is a union and not `TypeError` (#218).
        req = Response("""{}""")
        @test_throws Union{TypeError, ArgumentError} json(req, rank)

        # test extra key
        req = Response("""{"title": "viscount", "power": 9000.1, "extra": "hi"}""")
        myjson = json(req, rank)
        @test myjson.power == 9000.1

    end


    @testset "payload merges JSON, Form, and Query params" begin
        # Test Query only
        req = Request("GET", "/?a=1&b=2")
        data = payload(req)
        @test data["a"] == "1"
        @test data["b"] == "2"

        # Test Form only
        req = Request("POST", "/", [], "a=1&b=2")
        data = payload(req)
        @test data["a"] == "1"
        @test data["b"] == "2"

        # Test JSON only
        req = Request("POST", "/", ["Content-Type" => "application/json"], """{"a": 1, "b": 2}""")
        data = payload(req)
        @test data["a"] == 1
        @test data["b"] == 2

        # Test Precedence (JSON > Form > Query)
        # Using HTTP Request directly to combine query and body
        req = Request("POST", "/?a=query_a&b=query_b&c=query_c", ["Content-Type" => "application/json"], """{"a": "json_a"}""")
        # One body cannot be both JSON and a form: `payload` reads JSON only under a JSON
        # Content-Type (#327) and a form only when the body parses as one, so Query + JSON here,
        # and Query + Form below.
        data = payload(req)
        @test data["a"] == "json_a" # JSON wins
        @test data["b"] == "query_b" # Fallback to Query
        @test data["c"] == "query_c"

        # Test Query + Form Data
        req_form = Request("POST", "/?a=query_a&b=query_b", ["Content-Type" => "application/x-www-form-urlencoded"], "a=form_a&c=form_c")
        data_form = payload(req_form)
        @test data_form["a"] == "form_a" # Form wins over Query
        @test data_form["b"] == "query_b" # Fallback to Query
        @test data_form["c"] == "form_c" # Only in Form
    end

end

# ─── Helper to build raw multipart/form-data bytes for testing ────────

"""Build a raw multipart/form-data body and Content-Type header for testing."""
function build_multipart(; boundary::String="----TestBoundary7MA4YWxkTrZu0gW", parts::Vector)
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

@testset "multipart() - single file upload" begin
    body, ct = build_multipart(parts=[
        Dict(:name => "document", :filename => "report.xlsx", :content_type => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", :data => "fake xlsx content")
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)

    @test haskey(result, "document")
    f = result["document"]
    @test f isa FormFile
    @test f.name == "document"
    @test f.filename == "report.xlsx"
    @test f.content_type == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    @test String(f.data) == "fake xlsx content"
end

@testset "multipart() - multiple files under different field names" begin
    body, ct = build_multipart(parts=[
        Dict(:name => "file1", :filename => "data.dbf", :content_type => "application/octet-stream", :data => "dbf bytes"),
        Dict(:name => "file2", :filename => "sheet.xlsx", :content_type => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", :data => "xlsx bytes")
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)

    @test length(result) == 2
    @test result["file1"] isa FormFile
    @test result["file2"] isa FormFile
    @test result["file1"].filename == "data.dbf"
    @test result["file2"].filename == "sheet.xlsx"
    @test String(result["file1"].data) == "dbf bytes"
    @test String(result["file2"].data) == "xlsx bytes"
end

@testset "multipart() - multiple files under same field name" begin
    body, ct = build_multipart(parts=[
        Dict(:name => "attachments", :filename => "file1.dbf", :data => "content1"),
        Dict(:name => "attachments", :filename => "file2.dbf", :data => "content2"),
        Dict(:name => "attachments", :filename => "file3.xlsx", :data => "content3")
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)

    @test haskey(result, "attachments")
    files = result["attachments"]
    @test files isa Vector
    @test length(files) == 3
    @test files[1].filename == "file1.dbf"
    @test files[2].filename == "file2.dbf"
    @test files[3].filename == "file3.xlsx"
end

@testset "multipart() - mixed files and text fields" begin
    body, ct = build_multipart(parts=[
        Dict(:name => "description", :data => "My upload"),
        Dict(:name => "file", :filename => "data.csv", :content_type => "text/csv", :data => "a,b,c\n1,2,3")
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)

    @test result["description"] isa String
    @test result["description"] == "My upload"
    @test result["file"] isa FormFile
    @test result["file"].filename == "data.csv"
end

@testset "multipart() - same field name as both file and text does not crash" begin
    # Pathological input: one field name carries both a file part and a text
    # part. This must not throw (it used to raise a MethodError building a
    # Vector{Any}). The file wins the slot; the conflicting text is dropped.
    body, ct = build_multipart(parts=[
        Dict(:name => "field", :filename => "f.txt", :data => "file bytes"),
        Dict(:name => "field", :data => "text value"),
    ])
    req = Request("POST", "/upload", ["Content-Type" => ct], body)
    result = multipart(req)
    @test result["field"] isa FormFile
    @test result["field"].filename == "f.txt"
    @test String(result["field"].data) == "file bytes"
end

@testset "multipart() - non-multipart request returns empty dict" begin
    req = Request("POST", "/upload", ["Content-Type" => "application/json"], """{"key": "value"}""")
    result = multipart(req)
    @test isempty(result)
end

@testset "multipart() - empty body returns empty dict" begin
    req = Request("POST", "/upload", ["Content-Type" => "multipart/form-data; boundary=xyz"], UInt8[])
    result = multipart(req)
    @test isempty(result)
end

end

# -- #314, #254 -------------------------------------------------------------------------------
#
# Every request path that parses JSON, fed a document deep enough to overflow an unbounded
# `JSON.parse` -- 10,000 levels, where the stack of a request task gives out at ~3,100 -- and
# asserting each answers its ordinary "malformed JSON" verdict instead (#314). Before #314 these
# same children asserted the overflow PROPAGATED rather than being swallowed (#254); the input
# is unchanged, only the verdict is.
#
# Why the deep input, and not the 513-level one the in-process item below uses: that one proves
# the bound's edge, this one proves the bound is what stands between a request and the
# overflow. Drop the bound from any path and its child overflows -- which is also why they run
# in **disposable subprocesses**. After a stack overflow Julia reports "program state may be
# corrupted", and on some Windows hosts the process dies outright (#301); a regression must cost
# one step of one test item, not the ReTestItems worker every later item runs on.
#
# Why Windows CI kept losing these children (#273, #301) -- the record, because the answer is
# what made #314 the fix rather than a better catch.
#
# While these children still overflowed, Windows runners intermittently killed them with
# 0xC00000FD (`STATUS_STACK_OVERFLOW`) or 0xC0000005 (`STATUS_ACCESS_VIOLATION`) instead of
# letting Julia raise a `StackOverflowError`. #273 split one six-overflow child into one child
# per overflow; it kept happening, all-or-nothing per job (#301). #302 then had every child
# print a `LOADED` line -- CPU, LLVM target, threads, pkgimage state -- before its step, plus a
# CONTROL child that never overflowed. The failing jobs settled it: main run 36027018987 (job
# 107726024787, Windows, 2 threads) and 35999186292 (18f320b) both ran on an `INTEL(R) XEON(R)
# PLATINUM 8573C` (`sapphirerapids`), CONTROL passed, and every overflowing child reached
# `LOADED` and died in its own step. Every passing job on record was AMD or Apple. So it was
# never a load crash or a flake: on those hosts the overflow itself kills the process. A server
# on one would die on a single deep-JSON request, and no `catch` can be made reliable there --
# hence bounding the input (#314), after which no child overflows at all.
#
# What stays, and why. One child per step, and `LOADED` with `child_failure`'s verdict on which
# side of it a child died: if the bound ever regresses on one path, its child dies (on such a
# host) or prints `=PROPAGATED:StackOverflowError` (elsewhere -- which relies on #254's rethrow
# still standing behind the bound; the in-process item below pins that rethrow synthetically),
# and the failure names the step and the CPU. The AT_LIMIT step parses the deepest document the
# bound admits on a request-sized stack, so every CI host checks that the limit itself is safe
# there.
#
# The child scripts carry NO backslash-escaped quote on purpose. Julia's `raw"""` is raw about
# every backslash EXCEPT one before a quote, so an escaped-quote JSON literal written here
# arrives at the child with the backslashes gone and dies on a parse error that says nothing
# about this test. `[1]` is valid JSON needing no inner quote, so the question does not arise.
@testitem "Body parsers -- a deeply-nested request is rejected without overflowing (#314, #254)" tags=[:core, :network, :slow] setup=[NitroCommon] begin
using Nitro

prelude = raw"""
# Measured before `using` on purpose (#301): a failure should say whether the child hit a cold
# pkgimage cache, and after the load there is nothing left to ask.
t0 = time_ns()
nitro_cached = Base.isprecompiled(Base.identify_package("Nitro"))
using Nitro, HTTP, Sockets, Base64

# ~20 KB -- well inside any default body limit, and deep enough that an unbounded JSON.parse
# exhausts the stack. This was the whole attack: no credentials, no unusual size, any route.
deep = repeat("[", 10_000) * repeat("]", 10_000)
b64url(s) = replace(base64encode(s), "+" => "-", "/" => "_", "=" => "")

# Pick a free port rather than a literal: :network items in this suite never pin one, because
# a fixed port turns a parallel run into a flake.
function start_app(routes...)
    probe = Sockets.listen(Sockets.InetAddr(Sockets.ip"127.0.0.1", 0))
    port = Sockets.getsockname(probe)[2]
    close(probe)
    app = App(mod = @__MODULE__)
    urlpatterns(app, "", routes...)
    serve(app; port=port, async=true, show_banner=false)
    sleep(2)
    return app, port
end

post_json(port, route, body) =
    HTTP.post("http://127.0.0.1:$port$route", ["Content-Type" => "application/json"], body;
              status_exception=false, request_timeout=20, retry=false)

# The marker (#301): the last thing the prelude does, before any step runs. Flushed, because a
# child the OS kills takes an unflushed pipe buffer with it. Not `NAME=` shaped, so
# `child_failure` never mistakes it for a result line.
println("LOADED cpu=", strip(Sys.cpu_info()[1].model), " target=", Sys.CPU_NAME,
        " threads=", Threads.nthreads(), " nitro_cached=", nitro_cached,
        " load_s=", round((time_ns() - t0) / 1e9; digits=1))
flush(stdout)
"""

# (step, child body, lines its stdout must contain). Every body feeds a path input deep enough
# to overflow an unbounded parser; each keeps its `catch` so a regression still names itself on
# a platform that survives the overflow (`=PROPAGATED:StackOverflowError`).
steps = [
    # 0. The limit itself, on a request-sized stack (#301). 512 levels -- the deepest document
    # the bound admits -- through the untyped parse (the shallowest to overflow, at ~3,100), a
    # typed one and an object one, on a `Threads.@spawn` task like a real request. The bound is
    # only a fix if what it lets through is safe on every host, and this runs on every CI host.
    ("AT_LIMIT", raw"""
arrays = repeat("[", 512) * repeat("]", 512)
q = string(Char(34))   # a double quote, spelled without one -- see the raw-string note above
objects = repeat("{" * q * "a" * q * ":", 512) * "1" * repeat("}", 512)
jreq(s) = HTTP.Request("POST", "/j", ["Content-Type" => "application/json"], s)
try
    ok = fetch(Threads.@spawn (json(jreq(arrays)) !== nothing &&
                               json(jreq(arrays), Vector{Any}) isa Vector{Any} &&
                               json(jreq(objects)) !== nothing &&
                               json(jreq(objects), Dict{String, Any}) isa Dict{String, Any}))
    println("AT_LIMIT=", ok ? "PARSED" : "REJECTED")
catch e
    println("AT_LIMIT=PROPAGATED:", typeof(e))
end
""", ["AT_LIMIT=PARSED"]),

    # 1. The parser itself: too deep is malformed, and malformed is `nothing`.
    ("PARSER", raw"""
req = HTTP.Request("POST", "/j", ["Content-Type" => "application/json"], deep)
try
    println("PARSER=", json(req) === nothing ? "REJECTED" : "PARSED")
catch e
    println("PARSER=PROPAGATED:", typeof(e))
end
""", ["PARSER=REJECTED"]),

    # 1b. Unclosed -- the shape that overflows in half the bytes, and the one #314 measured.
    ("PARSER_UNCLOSED", raw"""
req = HTTP.Request("POST", "/j", ["Content-Type" => "application/json"], repeat("[", 10_000))
try
    println("PARSER_UNCLOSED=", json(req) === nothing ? "REJECTED" : "PARSED")
catch e
    println("PARSER_UNCLOSED=PROPAGATED:", typeof(e))
end
""", ["PARSER_UNCLOSED=REJECTED"]),

    # 1c. The typed parser: malformed -- too deep included -- is a `ValidationError` wrapping the
    # parser's `ArgumentError` (#326; it was the raw `ArgumentError`), not an overflow.
    ("TYPED", raw"""
req = HTTP.Request("POST", "/j", ["Content-Type" => "application/json"], deep)
try
    json(req, Vector{Any})
    println("TYPED=PARSED")
catch e
    println("TYPED=THREW:", typeof(e), " CAUSE:", typeof(e.cause))
end
""", ["TYPED=THREW:ValidationError CAUSE:ArgumentError"]),

    # 2. The memoizing accessor handlers actually call.
    ("ACCESSOR", raw"""
req = HTTP.Request("POST", "/j", ["Content-Type" => "application/json"], deep)
try
    println("ACCESSOR=", getjson(req) === nothing ? "REJECTED" : "PARSED")
catch e
    println("ACCESSOR=PROPAGATED:", typeof(e))
end
""", ["ACCESSOR=REJECTED"]),

    # 2b. Scalar path/query parameters. `parseparam` tries `parse(T, str)` first and falls
    # through to a JSON parse, so this reaches the parser through an ordinary `Int` parameter --
    # the route shape `path("/p/<int:n>", …)` produces. A bad value is a `ValidationError` (400).
    # Called directly rather than over a socket because a 20 KB URI is a transport question,
    # not the one under test.
    ("SCALAR", raw"""
try
    Nitro.parseparam_checked(Int, deep, "n", :query)
    println("SCALAR=PARSED")
catch e
    println("SCALAR=THREW:", typeof(e))
end
""", ["SCALAR=THREW:ValidationError"]),

    # 3. End to end over a real socket: the handler runs and sees "no JSON" -- the same answer
    # a malformed body gets -- and the server is still answering afterwards. NEXT has to share
    # SERVED's process to mean anything.
    ("SERVED", raw"""
app, port = start_app(path("/j", req -> Res.json(Dict("parsed" => getjson(req) !== nothing)); method="POST"))
r = post_json(port, "/j", deep)
println("SERVED=", r.status, ":", json(r)["parsed"])
println("NEXT=", post_json(port, "/j", "[1]").status)
terminate(app)
""", ["SERVED=200:false", "NEXT=200"]),

    # 3b. An extractor route resolves through the same bound: a malformed body is a 400, and
    # too deep is malformed. One input, one verdict, however the handler reads the body.
    ("EXTRACTOR", raw"""
app, port = start_app(path("/x", (req, body::Json{Dict{String,Any}}) -> Res.json(Dict("ok" => true)); method="POST"))
println("EXTRACTOR=", post_json(port, "/x", deep).status)
terminate(app)
""", ["EXTRACTOR=400"]),

    # 4. The AUTH path, end to end. A 26 KB header segment: over the 1 KB header cap, so it is
    # refused before either decoder runs.
    ("AUTH", raw"""
token = b64url(deep) * ".ey.AAAA"
bearer = BearerAuth(t -> Nitro.Auth.decode_jwt(t, "k"^32))(r -> Res.json(Dict("ok" => true)))
authreq = HTTP.Request("GET", "/")
HTTP.setheader(authreq, "Authorization" => "Bearer " * token)
try
    println("AUTH=", bearer(authreq).status)
catch e
    println("AUTH=PROPAGATED:", typeof(e))
end
""", ["AUTH=401"]),

    # 4b. #314's reproduction, verbatim: 4,149 bytes of `Authorization` -- inside nginx's and
    # Apache's default header limits -- through `jwt_validator`, on a `Threads.@spawn` task
    # like a real request. It was a 500 after a stack-overflow warning.
    ("AUTH_REPRO", raw"""
app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/me", req -> "me"; middleware = [BearerAuth(Nitro.Auth.jwt_validator("k"^32))]))
hdr = "Bearer " * b64url("["^3100) * ".e30.sig"
try
    r = fetch(Threads.@spawn internalrequest(app, HTTP.Request("GET", "/me", ["Authorization" => hdr])))
    println("AUTH_REPRO=", ncodeunits(hdr), ":", r.status)
catch e
    println("AUTH_REPRO=PROPAGATED:", typeof(e))
end
""", ["AUTH_REPRO=4149:401"]),

    # 4c. The same token as a cookie. A browser caps what it STORES at 4 KB; a hand-built
    # request is not a browser, so "a cookie cannot carry it" was never a defence.
    ("AUTH_COOKIE", raw"""
token = b64url("["^3100) * ".e30.sig"
cookieauth = CookieAuthMiddleware(Nitro.Auth.jwt_validator("k"^32))(r -> Res.json(Dict("ok" => true)))
try
    println("AUTH_COOKIE=", cookieauth(HTTP.Request("GET", "/", ["Cookie" => "auth_token=" * token])).status)
catch e
    println("AUTH_COOKIE=PROPAGATED:", typeof(e))
end
""", ["AUTH_COOKIE=401"]),

    # 4d. The claims parser. With `verify=true` an unsigned token never reaches it (claims are
    # decoded only after the signature verifies); `verify=false` decodes them straight away,
    # so that is the path that must bound them.
    ("CLAIMS", raw"""
token = b64url("{}") * "." * b64url(deep) * ".AAAA"
try
    Nitro.Auth.decode_jwt(token, "k"^32; verify=false)
    println("CLAIMS=PARSED")
catch e
    println("CLAIMS=THREW:", nameof(typeof(e)), ":", e isa Nitro.Auth.AuthError ? e.msg : "")
end
""", ["CLAIMS=THREW:AuthError:Invalid JWT encoding"]),
]

# `--code-coverage=none` explicitly, matching test/extensions/pormg_env_tests.jl: CI runs the
# suite under coverage in the job that uploads it (#244), and `Base.julia_cmd()` propagates
# that flag. Inheriting it costs the child its pkgimages, so it reloads all of
# Nitro from source -- and `test/runtests.jl` sets `nworkers = 0` under coverage, which is
# the one configuration where `testitem_timeout` does not apply, so a slow or wedged child
# would have no ceiling at all (#84). Everything else must come FROM `julia_cmd()`, notably
# `--check-bounds=yes`, or the child lands in a different cache and recompiles anyway.
#
# `ignorestatus` + captured streams rather than `read(cmd, String)` (#273): on a non-zero exit
# `read` throws `ProcessFailedException` and discards the child's stdout, so a crash reported
# neither which step it reached nor what the child printed on the way down.
function run_child(script)
    cmd = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) --startup-file=no -e $script`
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    return (; exitcode=p.exitcode, termsignal=p.termsignal,
              out=String(take!(out)), err=String(take!(err)))
end

# `nothing` for a clean exit; otherwise the whole diagnosis as one string. Asserted with `===`
# because `Test` prints "Evaluated:" only for a comparison -- `@test isnothing(...)` fails with
# the expression alone, and a bare `@test r.exitcode == 0` with just `3221225725 == 0`.
function child_failure(step, r)
    r.exitcode == 0 && r.termsignal == 0 && return nothing
    code = "exit code $(r.exitcode) (0x$(string(r.exitcode % UInt32; base=16, pad=8)))"
    # Named, not explained: WHERE the OS raised it is what the LOADED stage below answers.
    r.exitcode == 0xC00000FD && (code *= " = Windows STATUS_STACK_OVERFLOW")
    r.exitcode == 0xC0000005 && (code *= " = Windows STATUS_ACCESS_VIOLATION")
    lines = split(r.out, '\n')
    loaded = findfirst(startswith("LOADED "), lines)
    stage = loaded === nothing ?
        "died BEFORE LOADED -- while starting Julia or loading Nitro, not in this step's code" :
        "reached $(lines[loaded]) -- died in this step's own code"
    reached = filter(l -> occursin(r"^[A-Z_]+=", l), lines)
    last_line = isempty(reached) ? "none -- died before its first result line" : last(reached)
    return "$step child: $code, termsignal $(r.termsignal); $stage; last result line: $last_line; " *
           "stdout: $(repr(r.out)); stderr tail: $(repr(last(r.err, 2000)))"
end

# The diagnoser answered #301, and from now on it runs for real only if the bound regresses on
# a host where the overflow kills the process -- so pin its one distinction here rather than
# find it broken there.
@testset "child_failure names which side of LOADED a child died on" begin
    crashed(out) = (; exitcode=0xC00000FD, termsignal=0, out, err="")
    @test contains(child_failure("X", crashed("")), "died BEFORE LOADED")
    after = child_failure("X", crashed("LOADED cpu=Test target=generic threads=1 nitro_cached=true load_s=1.0\n"))
    @test contains(after, "reached LOADED cpu=Test")
    @test !contains(after, "BEFORE LOADED")
end

for (step, body, expected) in steps
    r = run_child(prelude * body)
    @testset "$step" begin
        @test child_failure(step, r) === nothing
        @test contains(r.out, "LOADED ")
        for line in expected
            @test contains(r.out, line)
        end
    end
end
end

# -- #314, in-process -------------------------------------------------------------------------
#
# The bound's edge, on every path that parses request JSON: 512 levels bind, 513 are malformed.
# Nothing here nests deeper than ~1,000, far under the ~3,100 where an unbounded parse
# overflows a request task, so a missing bound fails an assertion instead of taking the worker
# down -- the overflow-depth inputs live in the subprocess item above. Every 513 case parses
# happily against the unbounded code, so none of these can pass without the bound.
@testitem "Body parsers -- JSON nesting depth is bounded before JSON.parse (#314)" tags=[:core, :security] setup=[NitroCommon] begin
using HTTP, JSON
using Nitro

const BP = Nitro.Core.Util.BodyParsers

nest(d) = repeat("[", d) * repeat("]", d)
nestobj(d) = repeat("{\"a\":", d) * "1" * repeat("}", d)
# Alternating arrays and objects, `d` levels in all.
mixed(d) = join(isodd(i) ? "[" : "{\"k\":" for i in 1:d) * "0" *
           join(isodd(i) ? "]" : "}" for i in d:-1:1)
verdict(s) = try
    BP._check_json_depth(s)
    :ok
catch e
    e isa ArgumentError || rethrow()
    :rejected
end

@testset "the scanner" begin
    @test BP.MAX_JSON_DEPTH == 512
    for shape in (nest, nestobj, mixed)
        @test verdict(shape(512)) === :ok
        @test verdict(shape(513)) === :rejected
    end
    @test JSON.parse(mixed(4)) == Any[Dict("k" => Any[Dict("k" => 0)])]

    # Unclosed: the shape that overflowed in half the bytes. The scanner judges depth only;
    # a shallow unclosed document is the parser's to reject.
    @test verdict(repeat("[", 513)) === :rejected
    @test verdict(repeat("[", 512)) === :ok

    # Brackets inside a string literal are not nesting ...
    @test verdict("\"" * repeat("[", 1000) * "\"") === :ok
    @test verdict("[\"" * repeat("{", 1000) * "\"]") === :ok
    # ... an escaped quote does not close the string ...
    @test verdict("[\"\\\"" * repeat("[", 1000) * "\"]") === :ok
    # ... and an escaped BACKSLASH before a quote does, so what follows counts again.
    @test verdict("[\"\\\\\"," * repeat("[", 513)) === :rejected

    # Stray closers cannot bank depth for a later run of openers.
    @test verdict(repeat("]", 1000) * repeat("[", 513)) === :rejected
    @test verdict(repeat("}", 1000) * nest(512)) === :ok

    # Multi-byte UTF-8 never matches a delimiter; bytes and String agree.
    u = repeat("[\"é漢🙂\",", 512) * "1" * repeat("]", 512)
    @test verdict(u) === :ok
    @test verdict(Vector{UInt8}(u)) === :ok
    @test verdict(codeunits(u)) === :ok
    @test verdict(Vector{UInt8}(nest(513))) === :rejected

    # The message names the limit, never the input -- it becomes a `ValidationError.cause`.
    err = try
        BP._check_json_depth("[\"secret-token\"," * repeat("[", 600))
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("512", err.msg)
    @test !occursin("secret-token", err.msg)

    # The wrapper passes parser options through.
    @test BP._parse_json_bounded("[1]\n[2]\n"; jsonlines = true) == Any[Any[1], Any[2]]
    @test BP._parse_json_bounded(nest(3), Vector{Any}) == Any[Any[Any[]]]
end

# `{"a": nest(d)}` nests `d + 1` deep: 511 binds, 512 is one past the limit.
body(d) = "{\"a\":" * nest(d) * "}"
jreq(s) = HTTP.Request("POST", "/j", ["Content-Type" => "application/json"], s)

@testset "the bare parsers" begin
    @test json(jreq(body(512))) === nothing
    @test json(jreq(body(511))) isa AbstractDict
    @test getjson(jreq(body(512))) === nothing
    @test getjson(jreq(body(511))) isa AbstractDict
    # A ValidationError since #326, carrying the bound's ArgumentError as its cause.
    @test_throws ValidationError json(jreq(body(512)), Dict{String, Any})
    @test (try json(jreq(body(512)), Dict{String, Any}); catch e; e.cause; end) isa ArgumentError
    @test json(jreq(body(511)), Dict{String, Any}) isa Dict{String, Any}
    @test json(HTTP.Response(200; body = body(512))) === nothing
    @test json(HTTP.Response(200; body = body(511))) isa AbstractDict
end

Base.@kwdef struct DeepWrap
    a::Any = nothing
end

@testset "the extractors -- too deep is a 400, like any malformed body" begin
    app = App(mod = @__MODULE__)
    ok(req, _) = Res.json(Dict("ok" => true))
    urlpatterns(app, "",
        path("/dict", (req, b::Json{Dict{String, Any}}) -> ok(req, b); method = "POST"),
        path("/kwdef", (req, b::Json{DeepWrap}) -> ok(req, b); method = "POST"),
        path("/body", (req, b::Body{Vector{Any}}) -> ok(req, b); method = "POST"))
    status(route, s) = internalrequest(app, HTTP.Request("POST", route,
        ["Content-Type" => "application/json"], s)).status

    @test status("/dict", body(512)) == 400
    @test status("/dict", body(511)) == 200
    # The `@kwdef` path parses the body into raw field texts first -- the JSONText branch.
    @test status("/kwdef", body(512)) == 400
    @test status("/kwdef", body(511)) == 200
    @test status("/body", nest(513)) == 400
    @test status("/body", nest(512)) == 200
end

@testset "scalar parameters -- the JSON fall-through is bounded" begin
    err = try
        Nitro.parseparam_checked(Vector{Any}, nest(513), "n", :query)
    catch e
        e
    end
    @test err isa Nitro.ValidationError
    @test err.cause isa ArgumentError
    @test Nitro.parseparam_checked(Vector{Any}, nest(512), "n", :query) isa Vector{Any}
end

# The bound means request input no longer raises one of `is_unrecoverable`'s three, so the
# deep-input children stopped exercising #254's rethrows -- and deleting one would leave the
# suite green. Pin them from INSIDE each guarded block with a synthetic trigger instead: a
# `dicttype` whose constructor throws runs within the parse the `try` wraps, and so does a
# `Base.parse` method for a type of our own.
struct DepthBoomDict <: AbstractDict{String, Any} end
DepthBoomDict() = throw(OutOfMemoryError())
struct DepthBoom end
Base.parse(::Type{DepthBoom}, ::String) = throw(OutOfMemoryError())

@testset "#254's rethrow still stands behind the bound" begin
    @test_throws OutOfMemoryError json(jreq("{\"a\":1}"); dicttype = DepthBoomDict)
    @test_throws OutOfMemoryError json(HTTP.Response(200; body = "{\"a\":1}"); dicttype = DepthBoomDict)
    # `parseparam`'s own rethrow (before its JSON fall-through), then `parseparam_checked`'s
    # (before it wraps everything else in a `ValidationError`) -- both must hold for this.
    @test_throws OutOfMemoryError Nitro.parseparam_checked(DepthBoom, "x", "n", :query)
    # ... and the `Union` method's own rethrow, which tries each member type in turn.
    @test_throws OutOfMemoryError Nitro.parseparam_checked(Union{Nothing, DepthBoom}, "x", "n", :query)
    # Ordinary failures on the same paths are still absorbed.
    @test json(jreq("not json")) === nothing
    @test_throws Nitro.ValidationError Nitro.parseparam_checked(Int, "x", "n", :query)
end
end

# Every JSON parse of request data has to go through the bound, and the easiest way to lose
# that is a new call site written as plain `JSON.parse`. So count them, by AST rather than by
# regex -- a regex matches docstring prose and misses a file that starts with a BOM.
@testitem "Body parsers -- JSON.parse is reached only through the depth guard (#314)" tags=[:core, :security] setup=[NitroCommon] begin
using Nitro

const PARSERS = (:parse, :parse!, :parsefile, :parsefile!, :lazy, :lazyfile)

# `JSON.<parser>` anywhere -- a call, a bare reference, qualified (`Util.JSON.parse`), or an
# `import JSON.<parser>` path -- and `import`/`using JSON: <parser>`, renamed (`as`) or not.
is_json(x) = x === :JSON || (x isa Expr && x.head === :. && x.args[end] == QuoteNode(:JSON))
imported(a) = a isa Expr && (a.head === :as ? imported(a.args[1]) : a.args[end] in PARSERS)
function json_parse_sites(path)
    n = Ref(0)
    function walk(e)
        e isa Expr || return
        if e.head === :. && length(e.args) == 2 && is_json(e.args[1]) &&
           (e.args[2] isa QuoteNode ? e.args[2].value : e.args[2]) in PARSERS
            n[] += 1
        elseif e.head in (:import, :using) && length(e.args) == 1 && e.args[1] isa Expr &&
               e.args[1].head === :(:) && e.args[1].args[1] == Expr(:., :JSON)
            n[] += count(imported, e.args[1].args[2:end])
        end
        foreach(walk, e.args)
    end
    walk(Meta.parseall(read(path, String)))
    return n[]
end

# A plain recursive `readdir`, not `walkdir` (#297).
function julia_files(dir)
    out = String[]
    for name in readdir(dir)
        p = joinpath(dir, name)
        if !islink(p) && isdir(p)
            append!(out, julia_files(p))
        elseif endswith(name, ".jl")
            push!(out, p)
        end
    end
    return out
end

root = pkgdir(Nitro)
found = Dict{String, Int}()
for dir in ("src", "ext"), p in julia_files(joinpath(root, dir))
    k = json_parse_sites(p)
    k > 0 && (found[replace(relpath(p, root), '\\' => '/')] = k)
end

# The wrapper's own call, and the PormG extension's two. Those read JSON the application wrote
# to its own database (session payloads, worker results), not request data -- bounding them is
# a separate question. Any NEW site must go through `_parse_json_bounded` instead.
@test found == Dict(
    "src/utilities/bodyparsers.jl" => 1,
    "ext/NitroPormGExt.jl" => 2,
)

# The detector itself, so a silent miss cannot pass for a clean tree.
mktempdir() do d
    f = joinpath(d, "probe.jl")
    write(f, "\"docstring naming JSON.parse\"\nf(x) = JSON.parse(x)\ng = JSON.lazy\n" *
             "import JSON: parse, json\nimport JSON.parsefile\n# JSON.parse in a comment\n" *
             "h(x) = Util.JSON.parse(x)\nusing JSON: lazy as l, json as j\n")
    @test json_parse_sites(f) == 6
end
end

# `formdata` and `multipart` take the same narrowing, and deliberately ship WITHOUT a dedicated
# test: neither `HTTP.queryparams` nor `HTTP.parse_multipart_form` parses recursively, so no
# request input reaches their guarded block with any of the three types, and the only test that
# could be written would pass against the unpatched code too. They are covered by
# `is_unrecoverable`'s own contract and by the regression testitem below, which pins the half
# that CAN break -- that ordinary malformed input still yields the empty default.
@testitem "Body parsers -- malformed input still yields the empty default (#254)" tags=[:core] setup=[NitroCommon] begin
using HTTP
using Nitro

@test json(HTTP.Request("POST", "/j", [], "not json at all")) === nothing
@test json(HTTP.Request("POST", "/j", [], "{\"a\": ")) === nothing
@test json(HTTP.Request("POST", "/j", [], "{\"a\":1}")) == Dict("a" => 1)

@test formdata(HTTP.Request("POST", "/f", [], "no-equals-sign")) == Dict{String,String}()
@test formdata(HTTP.Request("POST", "/f", [], "a=1&b=2")) == Dict("a" => "1", "b" => "2")

@test isempty(multipart(HTTP.Request("POST", "/m",
    ["Content-Type" => "multipart/form-data; boundary=xyz"], "garbage")))
end

@testitem "json(req, T) in a handler: a bad body is a 400, not a logged 500 (#326)" tags=[:core, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro: App

struct Login326
    user::String
    password::String
end
app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/login", req -> (json(req, Login326); "ok"); method = "POST"))
send(body) = internalrequest(app,
    HTTP.Request("POST", "/login", ["Content-Type" => "application/json"], body))

logger = Test.TestLogger(min_level = Base.CoreLogging.Debug)
r = Base.CoreLogging.with_logger(logger) do
    send("""{"user":"u","password":"S3CR3T" oops}""")
end
@test r.status == 400
@test !any(l -> l.level >= Base.CoreLogging.Error, logger.logs)
@test !any(l -> occursin("S3CR3T", string(l.message, l.kwargs)), logger.logs)
@test send("""{"user":"u"}""").status == 400                       # wrong shape
@test send("""{"user":"u","password":"p"}""").status == 200
end

@testitem "Body parsers -- the body is read in place and never emptied (#327)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# Every reader used to start from its own copy of the body, and `text` made a second:
# `payload(req)` -- or CSRF reading the form and then the JSON -- made ~4 transient copies of a
# 64 MiB body. They now read a view in place. The danger that creates is `String(::Vector)`,
# which takes over the vector and leaves it EMPTY: one such call and every later reader of the
# request would see no body. Both storage shapes are covered -- a `String` body (tests, clients)
# and a `Vector{UInt8}` body (what the server's stream reader builds).
body = """{"a":1,"b":"x=y"}"""
for (shape, make) in (("String", () -> HTTP.Request("POST", "/", ["Content-Type" => "application/json"], body)),
                      ("Vector", () -> HTTP.Request("POST", "/", ["Content-Type" => "application/json"], Vector{UInt8}(body))))
    @testset "$shape body" begin
        req = make()
        n = length(req.body.data)
        @test text(req) == body
        @test text(req) == body
        @test json(req)["a"] == 1
        @test getjson(req)["b"] == "x=y"
        @test formdata(req) isa Dict
        bytes = binary(req)
        bytes[1] = UInt8('X')                     # the caller owns what `binary` returns
        @test length(req.body.data) == n
        @test text(req) == body
        @test payload(req)["a"] == 1
    end
end

@testset "a Response body is not emptied either" begin
    res = HTTP.Response(200, Vector{UInt8}("hello=world"))
    @test text(res) == "hello=world"
    @test text(res) == "hello=world"
    @test formdata(res) == Dict("hello" => "world")
    @test binary(res) == Vector{UInt8}("hello=world")
    @test text(res) == "hello=world"
end

@testset "text() makes one copy of a byte body, not two" begin
    big = Vector{UInt8}(repeat("a", 1 << 20))
    req = HTTP.Request("POST", "/", [], big)
    text(req)                                    # compile
    @test (@allocated text(req)) < 1.5 * (1 << 20)
    # A String body needs no copy at all.
    sreq = HTTP.Request("POST", "/", [], repeat("a", 1 << 20))
    text(sreq)
    @test (@allocated text(sreq)) < 1024
end
end
