@testitem "Precompilation" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro: text

# Load in the custom pacakge & trigger any precompilation
push!(LOAD_PATH, joinpath(@__DIR__, ".TestPackage"))
using TestPackage

port = get_free_port()
localhost = "http://$HOST:$port"

# call the start function from the TestPackage
start(;async=true, host=HOST, port=port, show_banner=false, access_log=nothing)

@testset "TestPackage" begin

    r = HTTP.get("$localhost")
    @test r.status == 200
    @test text(r) == "hello world"

    r = HTTP.get("$localhost/add?a=5&b=10")
    @test r.status == 200
    @test text(r) == "15"

    # test default value which should be 3
    r = HTTP.get("$localhost/add?a=3")
    @test r.status == 200
    @test text(r) == "6"


    r = HTTP.get("$localhost/add/extractor?a=5&b=10")
    @test r.status == 200
    @test text(r) == "15"

    # test default value which should be 3
    r = HTTP.get("$localhost/add/extractor?a=3")
    @test r.status == 200
    @test text(r) == "6"

end

# Call the stop() function from the TestPackage
stop()

end
@testitem "The precompile workload warms the listener a default serve builds (#450)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using Nitro

# src/precompile.jl compiles the transport layer for `_default_serve_listener`'s types. HTTP.jl
# specializes its connection loop on the listener's type and every closure in the chain is typed
# by what it captures, so the warmed code is only used if a default `serve` builds EXACTLY that
# type. A changed default (a new layer, a kwarg whose type moves) would otherwise leave the
# workload caching a shape no server runs, with nothing failing. Arguments that do not reach the
# chain (`host`, `port`, `async`, `show_banner`) are the only ones passed.
app = App()
urlpatterns(app, "", path("/x", req -> "x"))
server = serve(app; host = HOST, port = get_free_port(), async = true, show_banner = false)
try
    listener, request_handler = Nitro.Core._default_serve_listener(app)
    @test typeof(server.handler) == typeof(listener)
    # And the workload's `precompile` calls are not silently refused: `precompile` returns `false`
    # rather than throwing when a signature does not apply, e.g. if HTTP changes `Stream`'s
    # parameters, and the workload would then cache nothing.
    stream = Nitro.Stream{false, Nitro.Request{Nitro.Core.HTTP.EmptyBody}}
    @test precompile(listener, (stream,))
    @test precompile(request_handler, (stream,))
    @test precompile(Nitro.Core._handle_reporting, (typeof(request_handler), stream))
    @test precompile(Nitro.Core._write_response_body!, (stream, String))
finally
    terminate(app)
end
end
@testitem "The app-wide pipeline has one inferable type whatever the flags (#572)" tags=[:core, :middleware] begin
using Test
using Nitro
using Nitro.Core: setupmiddleware, internalrequest
import HTTP

# `juliac --trim` (docs/design/juliac-trim.md §3.2) needs the pipeline `setupmiddleware` builds to
# be a type the compiler can predict from the argument types alone. Two ways that used to fail:
# the layers were folded with `reduce(|>, [...])` over a heterogeneous vector, and each runtime
# flag chose between `[layer]` and `[]`, so five flags meant up to 32 shapes.
app = App()
urlpatterns(app, "", path("/x", req -> "x"))

@testset "the default shape infers" begin
    @test @inferred(setupmiddleware(app)) isa Function
    @test @inferred(setupmiddleware(app; middleware = ())) isa Function
end

@testset "the flags change behavior, not the type" begin
    ref = typeof(setupmiddleware(app))
    for serialize in (true, false), catch_errors in (true, false), show_errors in (true, false),
        access_log in (true, false), access_log_query in (true, false),
        security_headers in (nothing, SecurityHeaders()), prefix in (nothing, "/api")

        app.service.prefix[] = prefix
        p = setupmiddleware(app; serialize, catch_errors, show_errors, access_log,
                            access_log_query, security_headers)
        @test typeof(p) == ref
    end
    app.service.prefix[] = nothing
end

@testset "a Tuple of middleware is folded with its types, top-down (#312)" begin
    seen = String[]
    tag(name) = handler -> (req -> (push!(seen, name); handler(req)))
    a, b = tag("a"), tag("b")
    p = @inferred setupmiddleware(app; middleware = (a, b))
    @test p(HTTP.Request("GET", "/x")).status == 200
    @test seen == ["a", "b"]

    # The Vector form is still accepted, in the same order; it is folded from a dynamic Tuple.
    empty!(seen)
    @test internalrequest(app, HTTP.Request("GET", "/x"); middleware = [a, b]).status == 200
    @test seen == ["a", "b"]

    # A middleware that returns no function fails when the pipeline is built, not per request.
    broken = handler -> nothing
    @test_throws TypeError setupmiddleware(app; middleware = (broken,))
    @test_throws TypeError setupmiddleware(app; middleware = [broken])

    # A `LifecycleMiddleware` member runs its `.middleware`.
    empty!(seen)
    lm = Nitro.Core.LifecycleMiddleware(middleware = tag("lm"))
    @test internalrequest(app, HTTP.Request("GET", "/x"); middleware = (lm, a)).status == 200
    @test seen == ["lm", "a"]
end

@testset "a disabled layer adds nothing" begin
    # No security headers without `security_headers`, and the empty set adds none either.
    for sh in (nothing, SecurityHeaders(content_type_options = nothing, frame_options = nothing,
                                         referrer_policy = nothing))
        res = setupmiddleware(app; security_headers = sh)(HTTP.Request("GET", "/x"))
        @test res.status == 200
        @test !HTTP.hasheader(res, "X-Frame-Options")
        @test !HTTP.hasheader(res, "X-Content-Type-Options")
    end
    @test HTTP.hasheader(setupmiddleware(app; security_headers = SecurityHeaders())(
        HTTP.Request("GET", "/x")), "X-Frame-Options")

    # `serialize = false`: the handler's own return value comes back, unformatted.
    @test setupmiddleware(app; serialize = false)(HTTP.Request("GET", "/x")) == "x"

    # `catch_errors = false`: a throw propagates rather than becoming a 500.
    boom = handler -> (req -> error("boom"))
    @test_throws ErrorException setupmiddleware(app; middleware = (boom,), catch_errors = false)(
        HTTP.Request("GET", "/x"))
    @test setupmiddleware(app; middleware = (boom,), show_errors = false)(
        HTTP.Request("GET", "/x")).status == 500

    # No prefix: the target is not stripped.
    @test setupmiddleware(app)(HTTP.Request("GET", "/x")).status == 200
    app.service.prefix[] = "/api"
    try
        p = setupmiddleware(app)
        @test p(HTTP.Request("GET", "/api/x")).status == 200
        @test p(HTTP.Request("GET", "/x")).status == 404
    finally
        app.service.prefix[] = nothing
    end
end
end
