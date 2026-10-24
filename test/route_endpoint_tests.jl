@testitem "Route endpoints — one erasure point per route (#718)" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: RouteEndpoint, RouteNext, DeclaredMethodHandler, PipelineHandler,
                        ROUTE_RESOLUTION_KEY, snapshot
import Nitro: App, path, text, urlpatterns

# `RouteEndpoint` (src/routeendpoint.jl) is the one concrete type a route table hands back for a
# route's chain and for its handler, so a compiled image can call either without a dynamic call.
# What `juliac --trim` makes of it is measured by `bench/juliac/build.sh` (ENTRY=probe); this item
# pins what the JIT build sees: where the endpoints come from, that the call under the JIT is the
# direct one, and how the trimmed path fails when it cannot work.

const T = Nitro.Core.Types
# The leaf the router holds for `method` and `route`.
function leaf(app::App, method::String, route::String)
    handler, _, _ = Nitro.Core.RouterHOF._gethandler(app.service.router, HTTP.Request(method, route))
    return handler
end

tagged(tag) = handler -> (req::HTTP.Request -> Res.send(tag * "|" * text(handler(req))))

@testset "every leaf path() registers is an endpoint" begin
    app = App()
    urlpatterns(app, "",
        path("/get", req -> Res.send("get"); method = "GET"),
        path("/any", req -> Res.send("any"); method = "*"),
        path("/p/<int:id>", (req, id::Int) -> Res.send(string(id)); method = "GET"))
    @test leaf(app, "GET", "/get") isa RouteEndpoint
    @test leaf(app, "HEAD", "/get") isa DeclaredMethodHandler{RouteEndpoint}   # the auto-HEAD
    @test leaf(app, "PATCH", "/any") isa DeclaredMethodHandler{RouteEndpoint}
    @test leaf(app, "GET", "/p/7") isa RouteEndpoint
    @test Nitro.Core._nitro_leaf(leaf(app, "GET", "/get"))
    @test !Nitro.Core._nitro_leaf((req::HTTP.Request) -> "raw")
end

@testset "a route's chain is recorded beside the entry it was folded from" begin
    app = App()
    urlpatterns(app, "", path("/mw", req -> Res.send("h"); method = "GET", middleware = [tagged("a")]))
    entry = snapshot(app.service.custommiddleware)["GET|/mw"]
    rec = snapshot(app.service.route_chains)["GET|/mw"]
    @test rec.entry === entry
    @test rec.endpoint isa RouteEndpoint
    @test text(Nitro.Core.internalrequest(app, HTTP.Request("GET", "/mw"))) == "a|h"
end

@testset "under the JIT an endpoint is the direct call, and nothing is exported" begin
    @test T._trimmed() === false
    before = length(T.ENDPOINT_EXPORTS)
    e = RouteEndpoint((req::HTTP.Request) -> "direct")
    @test e.sym == ""
    @test length(T.ENDPOINT_EXPORTS) == before
    @test e(HTTP.Request("GET", "/")) == "direct"
    @test RouteEndpoint(e) === e                    # never wrapped twice
end

@testset "a matched request continues into its own pipeline's handler" begin
    app = App()
    urlpatterns(app, "", path("/mw", req -> Res.send("h"); method = "GET", middleware = [tagged("a")]))
    p = Nitro.Core.setupmiddleware(app)
    req = HTTP.Request("GET", "/mw")
    @test text(p(req)) == "a|h"
    res = req.context[ROUTE_RESOLUTION_KEY]
    @test res.pipeline.has_next
    @test res.pipeline.next isa PipelineHandler
    @test isconcretetype(PipelineHandler)
end

@testset "the trimmed path fails loudly where it cannot work" begin
    e = RouteEndpoint((req::HTTP.Request) -> "x", "nitro_route_endpoint_missing", nothing, C_NULL, C_NULL)
    # No exported code for it in this process: an error naming the fix, never a call through NULL.
    @test_throws ErrorException T._call_exported(e, HTTP.Request("GET", "/"))
    # A request body the transport never builds: refused, never a dynamic call.
    odd = HTTP.Request("POST", "/", [], "body")
    @test !(odd isa T.EmptyRequest) && !(odd isa T.BytesRequest)
    @test_throws ArgumentError T._call_exported(e, odd)
end

@testset "RouteNext outside a pipeline is an error, not a silent call" begin
    @test_throws ArgumentError RouteNext(Nitro.Types.nitro_router())(HTTP.Request("GET", "/"))
end

@testset "the trimmed call path, driven under the JIT" begin
    # `_ccall_endpoint` is what a trimmed image runs: a `ccall` into the exported thunk. Its pointer
    # here comes from `@cfunction` instead of the image's symbol table; the call is the same.
    ok = (req::HTTP.Request) -> Res.send("via ccall")
    function boom(req::HTTP.Request)
        throw(Nitro.Core.Errors.ValidationError("bad field"))
    end
    for (f, label) in ((ok, "ok"), (boom, "boom"))
        C = typeof(f)
        p = @cfunction($(T.EndpointThunk{C, T.EmptyRequest}()), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
        e = RouteEndpoint(f)
        GC.@preserve p begin
            ptr = Base.unsafe_convert(Ptr{Cvoid}, p)
            if label == "ok"
                @test text(T._ccall_endpoint(e, HTTP.Request("GET", "/"), ptr)) == "via ccall"
            else
                # The exception comes back as itself, not wrapped, so `handlerequest` still maps a
                # `ValidationError` to a 400; and it never unwound through the C frame.
                @test_throws Nitro.Core.Errors.ValidationError T._ccall_endpoint(e, HTTP.Request("GET", "/"), ptr)
            end
        end
    end
end

@testset "a nested internalrequest on the same request does not take over the chain" begin
    # A route middleware that sends its own request object to another route with
    # `internalrequest`, then carries on. The nested call writes its own stash over the chain's;
    # the chain must still continue into its own pipeline, to the route it was chosen for.
    side_ran = Ref(0)
    detour(target_app) = handler -> function (req::HTTP.Request)
        original = req.target
        req.target = "/side"
        Nitro.Core.internalrequest(target_app[], req)
        req.target = original
        return handler(req)
    end
    other = App()
    urlpatterns(other, "", path("/side", req -> (side_ran[] += 1; Res.send("other app")); method = "GET"))
    target = Ref{Any}(other)
    app = App()
    urlpatterns(app, "",
        path("/mw", req -> Res.send("this app"); method = "GET", middleware = [detour(target)]),
        path("/side", req -> (side_ran[] += 1; Res.send("side")); method = "GET"))
    p = Nitro.Core.setupmiddleware(app)
    # Another App: its `/side` ran for the nested call, and this route's leaf answered.
    @test text(p(HTTP.Request("GET", "/mw"))) == "this app"
    @test side_ran[] == 1
    # The same App: its own `/side` ran, and the chain still ended in `/mw`'s leaf.
    target[] = app
    @test text(p(HTTP.Request("GET", "/mw"))) == "this app"
    @test side_ran[] == 2
end

@testset "a chain continued under another app's stash is refused" begin
    # What `RouteNext`'s router check is for, without `internalrequest` restoring the stash: a
    # middleware that runs another app's pipeline on the same request object by hand.
    other = App()
    urlpatterns(other, "", path("/mw", req -> Res.send("other app"); method = "GET",
                                middleware = [h -> (r::HTTP.Request -> h(r))]))
    other_pipeline = Nitro.Core.setupmiddleware(other)
    hijack = handler -> function (req::HTTP.Request)
        other_pipeline(req)               # leaves `other`'s stash on `req`
        return handler(req)
    end
    app = App()
    urlpatterns(app, "", path("/mw", req -> Res.send("this app"); method = "GET", middleware = [hijack]))
    p = Nitro.Core.setupmiddleware(app; catch_errors = false)
    @test_throws ArgumentError p(HTTP.Request("GET", "/mw"))
end

@testset "a leaf not registered through Nitro" begin
    app = App()
    urlpatterns(app, "", path("/ok", req -> Res.send("ok"); method = "GET"))
    ran = Ref(false)
    HTTP.register!(app.service.router, "GET", "/raw", (req::HTTP.Request) -> (ran[] = true; HTTP.Response(200, "raw")))

    # `serve` refuses to start, before it changes anything, and says what to do instead.
    err = try
        serve(app; port = 0, async = true, show_banner = false, access_log = false); nothing
    catch e
        e
    finally
        isopen(app.service) && terminate(app)     # only if the refusal regressed
    end
    @test err isa ArgumentError
    @test occursin("GET /raw", err.msg) && occursin("path()", err.msg)
    @test !isopen(app.service)

    # Through `internalrequest` it is refused with a 500 and an error naming `path()`, and never run.
    logger = Test.TestLogger()
    r = Base.CoreLogging.with_logger(logger) do
        Nitro.Core.internalrequest(app, HTTP.Request("GET", "/raw"))
    end
    @test r.status == 500
    @test !ran[]
    @test any(rec -> rec.level == Base.CoreLogging.Error && occursin("path()", string(rec.message)),
              logger.logs)
    # The app's own routes are unaffected.
    @test text(Nitro.Core.internalrequest(app, HTTP.Request("GET", "/ok"))) == "ok"
end
end

@testitem "The serializer formats at the leaf, and its result is a response" tags=[:core, :middleware] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Nitro.Core.Types: RouteEndpoint, FormattedLeaf, RouterEntry, snapshot
import Nitro: App, path, urlpatterns

# A handler's endpoint carries the handler with `format_response` folded in (`FormattedLeaf`), and
# the serializer calls that one. `format_response` on the terminal's `Any` result was a runtime
# dispatch per request and a call `juliac --trim` rejects (docs/design/juliac-trim.md §3.2).
const T = Nitro.Core.Types
const Bytes = HTTP.Request{HTTP.BytesBody{Vector{UInt8}}}
function leaf(app::App, method::String, route::String)
    handler, _, _ = Nitro.Core.RouterHOF._gethandler(app.service.router, HTTP.Request(method, route))
    return handler
end

@testset "a handler's endpoint has a formatted half; a chain's has none" begin
    app = App()
    mw = handler -> (req -> handler(req))
    urlpatterns(app, "",
        path("/s", req -> "text"; method = "GET"),
        path("/mw", req -> Dict("a" => 1); method = "GET", middleware = [mw]))
    e = leaf(app, "GET", "/s")
    @test e isa RouteEndpoint && e.formatted isa RouteEndpoint
    @test e.formatted.obj isa FormattedLeaf
    @test e(HTTP.Request("GET", "/s")) == "text"                      # the raw call
    res = T.call_formatted(e, HTTP.Request("GET", "/s"))              # the formatted one
    @test res isa HTTP.Response && res.status == 200 && String(res.body) == "text"
    chain = snapshot(app.service.route_chains)["GET|/mw"].endpoint
    @test chain.formatted === nothing
end

@testset "inside the formatted half, `format_response` resolves" begin
    # A handler returning a `String` has a concrete return type, so the formatting is static there.
    h = (req::HTTP.Request) -> "x"
    @test isempty(dynamic_calls(FormattedLeaf(h), (Bytes,)))
    # The serializer's call into the terminal returns a response, whatever the route.
    rt = only(Base.return_types(Nitro.Core._formatted_response, (RouterEntry, Bytes)))
    @test rt <: HTTP.Response
end

@testset "what reaches middleware and the client is unchanged" begin
    app = App()
    seen = Ref{Any}(nothing)
    spy = handler -> (req -> (r = handler(req); seen[] = r; r))
    urlpatterns(app, "",
        path("/s", req -> "text"; method = "GET", middleware = [spy]),
        path("/d", req -> Dict("a" => 1); method = "GET"),
        path("/n", req -> 7; method = "GET"),
        path("/p/<int:id>", (req, id::Int) -> id + 1; method = "GET"))
    res = Nitro.internalrequest(app, HTTP.Request("GET", "/s"))
    @test seen[] isa HTTP.Response && String(seen[].body) == "text"   # route middleware: formatted, as before
    @test HTTP.header(res, "Content-Type") == "text/plain; charset=utf-8"
    res = Nitro.internalrequest(app, HTTP.Request("GET", "/d"))
    @test HTTP.header(res, "Content-Type") == "application/json; charset=utf-8" && String(res.body) == "{\"a\":1}"
    @test String(Nitro.internalrequest(app, HTTP.Request("GET", "/n")).body) == "7"
    @test String(Nitro.internalrequest(app, HTTP.Request("GET", "/p/4")).body) == "5"
    # `serialize = false`: the handler's own value, through the raw call, to the response
    # boundary, which refuses it (test/response_type_tests.jl).
    @test (@test_logs (:error, r"not an HTTP.Response") Nitro.Core.setupmiddleware(app; serialize = false)(
        HTTP.Request("GET", "/d"))).status == 500
    @test Nitro.internalrequest(app, HTTP.Request("GET", "/missing")).status == 404
end

@testset "a leaf built without the formatted half still formats under the JIT" begin
    e = RouteEndpoint((req::HTTP.Request) -> "bare")
    @test e.formatted === nothing
    @test String(T.call_formatted(e, HTTP.Request("GET", "/")).body) == "bare"
end

@testset "the caught exception's response is chosen by a closed set of types" begin
    U = Nitro.Core.Util
    E = Nitro.Core.Errors
    cases = (E.ValidationError("x") => 400, E.UnsupportedMediaTypeError("x") => 415,
             E.AuthorizationError("x") => 403, E.WorkerUnavailableError("x") => 503,
             E.WorkerCapacityError(:owner, "x") => 429, E.WorkerCapacityError(:queue, "x") => 503,
             ErrorException("x") => 500)
    for (e, status) in cases
        @test U._error_response(e).status == status
        @test String(U._error_response(e).body) == String(U.handle_error(e).body)
    end
    @test isempty(dynamic_calls(U._error_response, (Any,)))
    # One branch per `handle_error` method: a new method without a branch in `_error_response`
    # would answer 500 for its type. Count them so adding one fails here first.
    @test length(methods(U.handle_error)) == 6
end
end
