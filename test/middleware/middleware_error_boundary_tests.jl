@testitem "Middleware error boundary (in-process)" tags=[:core, :middleware] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
using Nitro.Core.Errors: ValidationError

# `Base.CoreLogging`, not `using Logging` -- Logging is not a test dependency.
const ERROR_LEVEL = Base.CoreLogging.Error

# #256. An exception escaping MIDDLEWARE used to skip Nitro's error handling entirely: the
# serializer's catch wraps only the router, and every middleware layer is folded outside it. Under
# `serve` that was a bodyless 500 with no log line; under `internalrequest` it was raised to the
# caller. Every assertion marked (unpatched) fails against that code -- the call throws instead of
# returning a response.

const GENERIC_500 = "500: Internal Server Error"

throws_before(msg) = handler -> (req::HTTP.Request -> error(msg))
# Throws on the way OUT, after the handler has produced its response -- the other half of
# "middleware threw", and the one a boundary placed only in front of the handler would miss.
throws_after(msg) = handler -> (req::HTTP.Request -> (handler(req); error(msg)))

app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/ok", () -> "ok"),
    path("/handler-boom", () -> error("handler boom")),
    path("/route-mw", () -> "unreachable"; middleware = [throws_before("route mw boom")]),
)

get_(target) = HTTP.Request("GET", target)

@testset "global middleware throwing before the handler -> logged JSON 500 (unpatched)" begin
    r = @test_logs (:error, "ERROR: ") match_mode=:any begin
        internalrequest(app, get_("/ok"); middleware = [throws_before("global boom")])
    end
    @test r.status == 500
    @test json(r)["message"] == GENERIC_500
end

@testset "global middleware throwing after the handler -> logged JSON 500 (unpatched)" begin
    r = @test_logs (:error, "ERROR: ") match_mode=:any begin
        internalrequest(app, get_("/ok"); middleware = [throws_after("late boom")])
    end
    @test r.status == 500
    @test json(r)["message"] == GENERIC_500
end

@testset "route-level middleware throwing -> logged JSON 500 (unpatched)" begin
    r = @test_logs (:error, "ERROR: ") match_mode=:any internalrequest(app, get_("/route-mw"))
    @test r.status == 500
    @test json(r)["message"] == GENERIC_500
end

@testset "the #254 case: an unrecoverable error out of BearerAuth is a logged 500 (unpatched)" begin
    # #254 made BearerAuth re-raise StackOverflowError instead of answering 401. This is the
    # 500 that nothing on the server used to record.
    auth = BearerAuth(_ -> throw(StackOverflowError()))
    req = HTTP.Request("GET", "/ok", ["Authorization" => "Bearer anything"])
    r = @test_logs (:error, "ERROR: ") match_mode=:any internalrequest(app, req; middleware = [auth])
    @test r.status == 500
    @test json(r)["message"] == GENERIC_500
end

@testset "an InterruptException from middleware still propagates" begin
    # The boundary must not become the swallow #254 removed from the auth middleware: Ctrl-C
    # landing in middleware used to propagate and still does. Rethrown before `handlerequest`,
    # which would otherwise answer it with an unlogged 500.
    mw = handler -> (req::HTTP.Request -> throw(InterruptException()))
    @test_throws InterruptException internalrequest(app, get_("/ok"); middleware = [mw])
    auth = BearerAuth(_ -> throw(InterruptException()))
    req = HTTP.Request("GET", "/ok", ["Authorization" => "Bearer anything"])
    @test_throws InterruptException internalrequest(app, req; middleware = [auth])
end

@testset "the logged backtrace points into the middleware that threw" begin
    # The boundary hands the exception to `handlerequest` with a bare `rethrow()`, which must keep
    # the ORIGINAL backtrace -- a trace that starts at the boundary would tell an operator nothing.
    function distinctively_named_middleware_frame(req)
        error("traceable")
    end
    mw = handler -> distinctively_named_middleware_frame
    logger = Test.TestLogger(min_level = ERROR_LEVEL)
    r = Base.CoreLogging.with_logger(logger) do
        internalrequest(app, get_("/ok"); middleware = [mw])
    end
    @test r.status == 500
    @test length(logger.logs) == 1
    err, bt = logger.logs[1].kwargs[:exception]
    @test err isa ErrorException && err.msg == "traceable"
    frames = stacktrace(bt)
    @test any(f -> f.func === :distinctively_named_middleware_frame, frames)
end

@testset "a prefixed app: the boundary sits outside the prefix strip (unpatched)" begin
    papp = App(mod = @__MODULE__)
    urlpatterns(papp, "", path("/ok", () -> "ok"))
    papp.service.prefix[] = "/api"
    r = @test_logs (:error, "ERROR: ") match_mode=:any begin
        internalrequest(papp, get_("/api/ok"); middleware = [throws_before("prefixed boom")])
    end
    @test r.status == 500
    @test json(r)["message"] == GENERIC_500
    # ...and a miss on the prefix is still the prefix layer's own 404, untouched by the boundary.
    @test internalrequest(papp, get_("/elsewhere")).status == 404
end

@testset "a ValidationError from middleware is a 400, with no @error" begin
    mw = handler -> (req::HTTP.Request -> throw(ValidationError("bad header")))
    r = @test_logs min_level = ERROR_LEVEL internalrequest(app, get_("/ok"); middleware = [mw])
    @test r.status == 400
    @test json(r)["message"] == "400: Bad Request"
end

@testset "an UnsupportedMediaTypeError from middleware is a 415, with no @error (#327)" begin
    mw = handler -> (req::HTTP.Request -> throw(Nitro.Core.Errors.UnsupportedMediaTypeError("needs JSON")))
    r = @test_logs min_level = ERROR_LEVEL internalrequest(app, get_("/ok"); middleware = [mw])
    @test r.status == 415
    @test json(r)["message"] == "415: Unsupported Media Type"
end

@testset "a handler exception is logged exactly once, not once per layer" begin
    # The inner serializer catches it and the outer boundary sees a normal response. Exact
    # sequence at Error level: one entry, not two.
    r = @test_logs (:error, "ERROR: ") min_level = ERROR_LEVEL internalrequest(app, get_("/handler-boom"))
    @test r.status == 500
    @test json(r)["message"] == GENERIC_500
end

@testset "show_errors=false silences the log, not the response" begin
    pipeline = Nitro.Core.setupmiddleware(app; middleware = [throws_before("quiet boom")],
                                          show_errors = false)
    r = @test_logs min_level = ERROR_LEVEL pipeline(get_("/ok"))
    @test r.status == 500
    @test json(r)["message"] == GENERIC_500
end

@testset "the access log records the 500 (unpatched)" begin
    pipeline = Nitro.Core.setupmiddleware(app; middleware = [throws_before("logged boom")],
                                          access_log = true)
    r = @test_logs (:error, "ERROR: ") (:info, r"\"GET /ok\" 500$") match_mode=:any pipeline(get_("/ok"))
    @test r.status == 500
end

@testset "opt-outs still raise" begin
    @test_throws ErrorException internalrequest(app, get_("/ok");
                                                middleware = [throws_before("raised")],
                                                catch_errors = false)
    @test_throws ErrorException internalrequest(app, get_("/route-mw"); catch_errors = false)
    # `serialize=false` installs no error handling at all -- for handlers or middleware.
    @test_throws ErrorException internalrequest(app, get_("/ok");
                                                middleware = [throws_before("raw")],
                                                serialize = false)
end

@testset "a healthy request is untouched" begin
    r = @test_logs min_level = ERROR_LEVEL internalrequest(app, get_("/ok"))
    @test r.status == 200
    @test text(r) == "ok"
end

end

@testitem "Middleware error boundary (over a socket)" tags=[:core, :middleware, :network] setup=[NitroCommon] begin

using Test
using HTTP
using JSON
using Nitro

# The shape the issue reported: through the real `stream_handler`, a throwing middleware used to
# hand HTTP.jl the exception, which answered with a zero-length 500. Now the body is Nitro's.

app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/ok", () -> "ok"), path("/boom", () -> "unreachable"))

boom_on_path = handler -> function(req::HTTP.Request)
    req.target == "/boom" && error("middleware boom")
    return handler(req)
end

port = get_free_port()
serve(app; host = HOST, port = port, async = true, show_banner = false, show_errors = false,
      access_log = nothing, middleware = [boom_on_path])

try
    r = HTTP.get("http://$HOST:$port/boom"; status_exception = false, retry = false)
    @test r.status == 500
    @test !isempty(r.body)                                           # (unpatched: empty)
    @test JSON.parse(String(r.body))["message"] == "500: Internal Server Error"

    # And the server keeps serving on the same app.
    r = HTTP.get("http://$HOST:$port/ok"; status_exception = false, retry = false)
    @test r.status == 200
    @test String(r.body) == "ok"
finally
    terminate(app)
end

end
