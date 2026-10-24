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
