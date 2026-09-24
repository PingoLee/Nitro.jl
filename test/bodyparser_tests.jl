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

        req = Request("GET","/", [],"""{"title": "viscount", "power": NaN}""")
        myjson = json(req, rank, allownan = true)
        @test isnan(myjson.power)

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

        req = Request("GET","/", [],"""{"title": "viscount", "power": NaN}""")
        myjson = json(req, rank, allownan = true)
        @test isnan(myjson.power)

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
        req = Request("GET","/", [],"""{}""")
        @test_throws Union{TypeError, ArgumentError} json(req, rank)

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

# -- #254 -----------------------------------------------------------------------------------
#
# The unauthenticated half of #254, tested against a REAL `StackOverflowError` -- the only way
# to test this site honestly.
#
# A synthetic `throw(StackOverflowError())` works for the auth middleware because the thing it
# guards is a user callback, so the throw originates inside the guarded block. It does NOT work
# here: `_request_payload`/`text` run *outside* the `try`, and the guarded expression is
# `JSON.parse` itself. Anything faked from the outside throws before the catch and would pass
# identically against the unpatched code -- test theater. The real trigger is the only trigger.
#
# Which means the hazard the issue warns about is real: after a stack overflow Julia reports
# "program state may be corrupted", and a ReTestItems worker is reused by every item scheduled
# after this one. So every overflow runs in a **disposable subprocess**. The corruption is
# confined to a process that exits immediately, and the parent asserts on its output.
#
# ONE child per overflow, not one child for all of them (#273). The single child this used to
# be overflowed six times -- the first three back to back on its own root task -- and on
# Windows it intermittently died early with exit code 0xC00000FD (`STATUS_STACK_OVERFLOW`): an
# overflow the OS killed the process for, not a `StackOverflowError` Julia could hand to Nitro.
# That is consistent with Windows not recovering from repeated overflows on one thread stack,
# and it is not Nitro swallowing anything -- but it threw away every later step's verdict, and
# `read(cmd, String)` threw away the output that would have said which step died. Now no
# overflow runs on a stack an earlier one already used, and a crash that remains costs one step
# and names it. The price is six Nitro loads instead of one, far inside `testitem_timeout`.
#
# That did not stop it (#301), and what #279's diagnostics showed rules the hypothesis out: a
# failing job loses ALL six children, each overflowing once in a fresh process, and a passing
# job loses none. Something that holds for the whole job decides it -- and every child died
# with empty stdout, before its first result line, which is exactly what a crash while
# LOADING Nitro would also look like. So every child now prints a `LOADED` line, with its
# CPU, thread count, pkgimage state and load time, as the last act of the prelude and before
# any overflow; `child_failure` says which side of it the child died on. The CONTROL child
# runs the prelude and never overflows: if it dies too, the overflow is not the cause. The
# passing-job baseline for the same fields is the "Runner CPU (#301)" step in ci.yml, since
# ReTestItems shows an item's output only when it fails.
#
# The child scripts carry NO backslash-escaped quote on purpose. Julia's `raw"""` is raw about
# every backslash EXCEPT one before a quote, so an escaped-quote JSON literal written here
# arrives at the child with the backslashes gone and dies on a parse error that says nothing
# about this test. `[1]` is valid JSON needing no inner quote, so the question does not arise.
@testitem "Body parsers -- a deeply-nested body is not swallowed (#254)" tags=[:core, :network, :slow] setup=[NitroCommon] begin
using Nitro

prelude = raw"""
# Measured before `using` on purpose (#301): a job-wide cold pkgimage cache is one of the
# candidate causes, and after the load there is nothing left to ask.
t0 = time_ns()
nitro_cached = Base.isprecompiled(Base.identify_package("Nitro"))
using Nitro, HTTP, Sockets, Base64

# ~20 KB -- well inside any default body limit, and deep enough that JSON.parse exhausts the
# stack. This is the whole attack: no credentials, no unusual size, any route.
deep = repeat("[", 10_000) * repeat("]", 10_000)

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

# The marker (#301): the last thing the prelude does, before any step can overflow. Flushed,
# because a child the OS kills takes an unflushed pipe buffer with it. Not `NAME=` shaped, so
# `child_failure` never mistakes it for a result line.
println("LOADED cpu=", strip(Sys.cpu_info()[1].model), " target=", Sys.CPU_NAME,
        " threads=", Threads.nthreads(), " nitro_cached=", nitro_cached,
        " load_s=", round((time_ns() - t0) / 1e9; digits=1))
flush(stdout)
"""

# (step, child body, lines its stdout must contain). Each body overflows at most once.
steps = [
    # 0. The control (#301): the prelude and nothing else, no overflow.
    ("CONTROL", raw"""
println("CONTROL=OK")
""", ["CONTROL=OK"]),

    # 1. The parser itself.
    ("PARSER", raw"""
req = HTTP.Request("POST", "/j", ["Content-Type" => "application/json"], deep)
try
    r = json(req)
    println("PARSER=SWALLOWED:", r === nothing)
catch e
    println("PARSER=PROPAGATED:", typeof(e))
end
""", ["PARSER=PROPAGATED:StackOverflowError"]),

    # 2. The memoizing accessor handlers actually call.
    ("ACCESSOR", raw"""
req = HTTP.Request("POST", "/j", ["Content-Type" => "application/json"], deep)
try
    r = getjson(req)
    println("ACCESSOR=SWALLOWED:", r === nothing)
catch e
    println("ACCESSOR=PROPAGATED:", typeof(e))
end
""", ["ACCESSOR=PROPAGATED:StackOverflowError"]),

    # 2b. Scalar path/query parameters. `parseparam` tries `parse(T, str)` first and falls
    # through to `JSON.parse(str, T)`, so this fires for an ordinary `Int` parameter -- the
    # route shape `path("/p/<int:n>", …)` produces -- and used to answer 400. Called directly
    # rather than over a socket because a 20 KB URI is a transport question, not the one under
    # test.
    ("SCALAR", raw"""
try
    Nitro.parseparam_checked(Int, deep, "n", :query)
    println("SCALAR=SWALLOWED")
catch e
    println("SCALAR=PROPAGATED:", typeof(e))
end
""", ["SCALAR=PROPAGATED:StackOverflowError"]),

    # 3. End to end over a real socket: the defect was that the handler went on to serve a
    # normal 200 off a worker Julia had just declared possibly corrupt -- so not a 200. And the
    # server must still be answering afterwards: "louder" must not mean "dead", which is what
    # makes rethrowing the safe choice rather than merely the loud one. NEXT does not overflow,
    # and it has to share SERVED's process to mean anything.
    ("SERVED", raw"""
app, port = start_app(path("/j", req -> Res.json(Dict("parsed" => getjson(req) !== nothing)); method="POST"))
println("SERVED=", post_json(port, "/j", deep).status)
println("NEXT=", post_json(port, "/j", "[1]").status)
terminate(app)
""", ["SERVED=500", "NEXT=200"]),

    # 3b. #254 finding: an extractor route resolves through the same parser, but `safe_extract`
    # used to relabel the rethrow as a `ValidationError` -> 400. Same input must not produce two
    # different verdicts depending on how the handler reads the body: not 400, because a
    # corrupted worker is not a client mistake.
    ("EXTRACTOR", raw"""
app, port = start_app(path("/x", (req, body::Json{Dict{String,Any}}) -> Res.json(Dict("ok" => true)); method="POST"))
println("EXTRACTOR=", post_json(port, "/x", deep).status)
terminate(app)
""", ["EXTRACTOR=500"]),

    # 4. The AUTH half of #254, end to end -- the claim the issue, both docstrings, the tutorial
    # and the upgrade entry all rest on. The synthetic throws in the auth testitem prove the
    # catch block dispatches; only this proves a real bearer token gets there.
    ("AUTH", raw"""
hdr = replace(base64encode(deep), "+" => "-", "/" => "_", "=" => "")
token = hdr * ".ey.AAAA"
bearer = BearerAuth(t -> Nitro.Auth.decode_jwt(t, "secret"))(r -> Res.json(Dict("ok" => true)))
authreq = HTTP.Request("GET", "/")
HTTP.setheader(authreq, "Authorization" => "Bearer " * token)
try
    r = bearer(authreq)
    println("AUTH=SWALLOWED:", r.status)
catch e
    println("AUTH=PROPAGATED:", typeof(e))
end
""", ["AUTH=PROPAGATED:StackOverflowError"]),
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
        "died BEFORE LOADED -- while starting Julia or loading Nitro, not at this step's overflow" :
        "reached $(lines[loaded]) -- died in this step's own code"
    reached = filter(l -> occursin(r"^[A-Z]+=", l), lines)
    last_line = isempty(reached) ? "none -- died before its first result line" : last(reached)
    return "$step child: $code, termsignal $(r.termsignal); $stage; last result line: $last_line; " *
           "stdout: $(repr(r.out)); stderr tail: $(repr(last(r.err, 2000)))"
end

# The diagnoser is the deliverable of #301, and it runs for real only on a crash no other
# platform reproduces -- so pin its one distinction here rather than find it broken there.
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
