@testitem "The middleware chain returns a response (ResponseBoundary)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App, path, urlpatterns

# `compose` wraps the global middleware chain in `RouterHOF.ResponseBoundary`, so what comes out
# of user code is held to the contract (`handle -> req -> resp`) once, and every framework layer
# outside it reads an `HTTP.Response` rather than `Any` (docs/design/juliac-trim.md §3.7). A value
# that breaks the contract is answered with a 500 here. Before, the access log or `SecurityHeaders`
# threw on it (a bodyless 500), with neither installed it went out as an empty 200, and
# `internalrequest` threw a `MethodError`.

returning(v) = handler -> (req -> (handler(req); v))
const SENTINEL = "s3cret-value"

function served_app(; route_mw = Function[])
    app = App()
    urlpatterns(app, "", path("/x", req -> Res.send("ok"); method = "GET", middleware = route_mw))
    return app
end

# What one in-process request returns, with the error records it logged.
function logged(f)
    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
    r = Base.CoreLogging.with_logger(f, logger)
    return r, logger.logs
end

@testset "the whole pipeline is typed HTTP.Response" begin
    app = served_app()
    for serialize in (true, false)
        p = Nitro.Core.setupmiddleware(app; serialize)
        @test only(Base.return_types(p, (HTTP.Request,))) <: HTTP.Response
    end
    boundary = Nitro.Core.RouterHOF.compose(app.service, ())(req -> Res.send("x"))
    @test boundary isa Nitro.Core.RouterHOF.ResponseBoundary
    @test only(Base.return_types(boundary, (HTTP.Request,))) <: HTTP.Response
end

@testset "a response passes through untouched" begin
    shared = Res.send("shared")
    app = served_app()
    r = Nitro.internalrequest(app, HTTP.Request("GET", "/x"); middleware = [handler -> (req -> shared)])
    @test r === shared
end

@testset "anything else is a 500, logged by type and route, never by value" begin
    for (where, v) in Iterators.product((:global, :route), ("$SENTINEL", Dict("k" => SENTINEL), nothing, 42))
        app = where === :route ? served_app(route_mw = [returning(v)]) : served_app()
        mw = where === :global ? [returning(v)] : Function[]
        r, logs = logged() do
            Nitro.internalrequest(app, HTTP.Request("GET", "/x?token=$SENTINEL"); middleware = mw)
        end
        @test r.status == 500
        @test String(r.body) == "{\"message\":\"500: Internal Server Error\"}"
        entry = only(logs)
        @test entry.level == Base.CoreLogging.Error
        @test occursin("not an HTTP.Response", entry.message)
        @test entry.kwargs[:type] == typeof(v)
        @test entry.kwargs[:route] == "/x"
        @test !occursin(SENTINEL, sprint(show, entry.kwargs))
        @test !occursin(SENTINEL, entry.message)
    end
    # No route matched: the record says so rather than naming the request's target.
    app = served_app()
    r, logs = logged() do
        Nitro.internalrequest(app, HTTP.Request("GET", "/$SENTINEL"); middleware = [handler -> (req -> 1)])
    end
    @test r.status == 500
    @test only(logs).kwargs[:route] === nothing
    @test !occursin(SENTINEL, sprint(show, only(logs).kwargs))
end

@testset "serialize = false: middleware still sees the handler's raw value" begin
    app = App()
    urlpatterns(app, "", path("/d", req -> Dict("a" => 1); method = "GET"))
    seen = Ref{Any}(nothing)
    # The Oxygen-era pattern: no serializer, a global middleware that formats.
    formatter = handler -> (req -> (v = handler(req); seen[] = v; Res.json(v)))
    r = Nitro.internalrequest(app, HTTP.Request("GET", "/d"); serialize = false, middleware = [formatter])
    @test seen[] == Dict("a" => 1)
    @test r.status == 200 && String(r.body) == "{\"a\":1}"
    # Without one, the raw value reaches the boundary.
    r, logs = logged() do
        Nitro.Core.setupmiddleware(app; serialize = false)(HTTP.Request("GET", "/d"))
    end
    @test r.status == 500
    @test only(logs).kwargs[:type] == Dict{String, Int}
end
end

@testitem "The middleware chain returns a response — over a socket" tags=[:core, :middleware, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App, path, urlpatterns

function serving(f, app; kw...)
    port = get_free_port()
    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
    Base.CoreLogging.with_logger(logger) do
        serve(app; host = HOST, port = port, async = true, show_banner = false, kw...)
    end
    @test timedwait(() -> Base.isopen(app.service), 10.0) === :ok
    try
        r = HTTP.get("http://$HOST:$port/x"; status_exception = false, retry = false, readtimeout = 10)
        f(r, logger.logs)
    finally
        terminate(app)
    end
end

@testset "a global middleware's String is a 500 with a body, whatever the outer layers" begin
    for access_log in (true, false), security_headers in (nothing, SecurityHeaders())
        app = App()
        urlpatterns(app, "", path("/x", req -> Res.send("ok"); method = "GET"))
        serving(app; middleware = [handler -> (req -> "text")], access_log, security_headers) do r, logs
            @test r.status == 500
            @test String(r.body) == "{\"message\":\"500: Internal Server Error\"}"
            security_headers === nothing || @test HTTP.hasheader(r, "X-Frame-Options")
            @test count(l -> occursin("not an HTTP.Response", l.message), logs) == 1
            @test !any(l -> occursin("outside the error handler", l.message), logs)
        end
    end
end

@testset "serialize = false: what a STREAM handler returns after writing is not an error" begin
    # The handler writes its own response and returns `nothing`, or what its last `write`
    # returned. Under the access log (on by default) that value used to reach `response.status`:
    # the client lost the connection mid-response and the server logged an error.
    raw(ret) = function (stream::HTTP.Stream)
        HTTP.setheader(stream, "Content-Type" => "text/plain")
        HTTP.startwrite(stream)
        n = write(stream, "chunk")
        return ret ? n : nothing
    end
    for access_log in (true, false), ret in (false, true)
        app = App()
        urlpatterns(app, "", path("/x", raw(ret); method = "STREAM"))
        serving(app; serialize = false, access_log) do r, logs
            @test r.status == 200
            @test String(r.body) == "chunk"
            @test isempty(logs)
        end
    end
end
end

@testitem "Types.with_response — every body Nitro builds takes a static branch" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# `with_response` (src/routeendpoint.jl) is the closed dispatch on a response's body type that
# lets `SecurityHeaders` and the transport call `HTTP.Response{B}` code statically. A body outside
# its list still works under the JIT, through one dynamic call in `_with_unlisted_body`, but a
# trimmed image refuses it. So every body a Nitro builder produces must be listed: this fails
# when a builder gains one the dispatch lacks.

const T = Nitro.Core.Types
const LISTED = (String, Vector{UInt8}, HTTP.EmptyBody, HTTP.BytesBody{Vector{UInt8}},
                HTTP.BytesBody{T.RangeBytes}, T.StreamedFileBody, HTTP.SSEStream)

# Whether `with_response(f, ::HTTP.Response{B})` compiles to the fallback's call.
function reaches_fallback(f, B)
    for (ci, _) in code_typed(T.with_response, (typeof(f), HTTP.Response{B}); optimize = true), st in ci.code
        st isa Expr && st.head === :invoke || continue
        x = st.args[1]
        mi = x isa Core.CodeInstance ? x.def : x
        mi isa Core.MethodInstance || (mi = getproperty(mi, :def))
        mi.def.name === :_with_unlisted_body && return true
    end
    return false
end
status_of(r::HTTP.Response) = r.status

@testset "each listed body is a branch, and only those" begin
    for B in LISTED
        @test !reaches_fallback(status_of, B)
    end
    # The control: an unlisted body (a strided view) takes the fallback, and still works under the JIT.
    unlisted = HTTP.Response(200, HTTP.BytesBody(view(UInt8[1, 2, 3, 4], 1:2:3)))
    @test reaches_fallback(status_of, typeof(unlisted).parameters[1])
    @test T.with_response(status_of, unlisted) == 200
end

@testset "every Nitro builder's body is listed" begin
    dir = mktempdir()
    file = joinpath(dir, "a.txt")
    write(file, "hello world")
    req = HTTP.Request("GET", "/a.txt")
    ranged = HTTP.Request("GET", "/a.txt", ["Range" => "bytes=0-3"])
    built = Any[
        Res.send("x"), Res.json(Dict("a" => 1)), Res.json(UInt8[0x7b, 0x7d]), Res.html("<p>"),
        Res.status(204), Res.redirect("/"), Res.file(file), Res.file(req, file), Res.file(ranged, file),
        Res.file(req, file; stream = true), Res.file(ranged, file; stream = true), Res.sse(),
        Nitro.Core.format_response("x"), Nitro.Core.format_response(Dict("a" => 1)),
        HTTP.Response(404), HTTP.Response(200, "x"),
    ]
    try
        for r in built
            @test typeof(r).parameters[1] in LISTED
        end
    finally
        for r in built
            r.body isa Union{T.StreamedFileBody, HTTP.SSEStream} && HTTP.body_close!(r.body)
        end
    end
end

@testset "the transport's body methods are the ones the list was checked against" begin
    # A new `_write_response_body!` or `_release_response_body!` method is a new body type the
    # transport writes: add it to `with_response` (and to LISTED above) in the same change.
    @test length(methods(Nitro.Core._write_response_body!)) == 5
    @test length(methods(Nitro.Core._release_response_body!)) == 4
end

@testset "SecurityHeaders: static per body, a new response of the same type" begin
    SH = Nitro.Core.SecurityHeadersMiddleware
    for B in LISTED
        @test isempty(dynamic_calls(SH._with_security_headers, (HTTP.Response{B}, Vector{Pair{String, String}})))
    end
    @test isempty(dynamic_calls(SecurityHeaders()(req -> Res.send("x")), (HTTP.Request{HTTP.EmptyBody},)))
    for inner in (Res.send("x"), Res.json(UInt8[0x7b, 0x7d]), HTTP.Response(204))
        before = copy(inner.headers)
        out = SecurityHeaders()(req -> inner)(HTTP.Request("GET", "/"))
        @test typeof(out) === typeof(inner)
        @test out !== inner && inner.headers == before
        @test HTTP.hasheader(out, "X-Frame-Options")
    end
    # Anything that is not a response passes through: a router's own `SecurityHeaders()` can see a
    # handler's raw value under `serialize = false`, before the boundary does.
    @test SecurityHeaders()(req -> "raw")(HTTP.Request("GET", "/")) == "raw"
end
end

@testitem "The transport writes each listed body without a dynamic call" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# `stream_handler` hands the pipeline's response to `_send_response!` through
# `Types.with_response`, so each body type gets its own compiled write path: the HEAD length, the
# hand-off copy, the early slot release, the write and the release, all static (#453, #298, #654).
const T = Nitro.Core.Types
const S = HTTP.Stream{false, HTTP.Request{HTTP.EmptyBody}}
const A = T.Nullable{Nitro.Core._Admission}
for B in (String, Vector{UInt8}, HTTP.EmptyBody, HTTP.BytesBody{Vector{UInt8}},
          HTTP.BytesBody{T.RangeBytes}, T.StreamedFileBody, HTTP.SSEStream)
    @test isempty(dynamic_calls(Nitro.Core._send_response!, (HTTP.Response{B}, S, HTTP.Request{HTTP.EmptyBody}, A)))
end
# A pipeline value that is not a response (the transport answers it with an empty `200`).
@test isempty(dynamic_calls(Nitro.Core._send_response!, (Nothing, S, HTTP.Request{HTTP.EmptyBody}, A)))
end
