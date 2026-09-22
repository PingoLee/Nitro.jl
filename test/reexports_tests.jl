@testitem "HTTP Reexports" tags=[:core] setup=[NitroCommon] begin
using Test
import HTTP
import Nitro

@testset "Testing HTTP Reexports" begin
    @test Nitro.Request        == HTTP.Request
    @test Nitro.Response       == HTTP.Response
    @test Nitro.Stream         == HTTP.Stream
    @test Nitro.WebSocket      == HTTP.WebSockets.WebSocket
    @test Nitro.queryparams    == HTTP.queryparams
end

@testset "Response builders are NOT re-exported at top level" begin
    # #28 collapsed two response namespaces into one. Nothing re-establishes a top-level
    # response builder: re-exporting any of these brings back the ambiguity where the same
    # bare name meant "parse a request" or "build a response" depending on the argument type.
    for name in (:html, :xml, :js, :css, :file, :redirect)
        @test !isdefined(Nitro, name)
    end

    # ... while the request-body parsers keep the bare names, and keep them ALONE: each must
    # resolve to BodyParsers, not to some reintroduced builder.
    for name in (:text, :json, :binary)
        @test isdefined(Nitro, name)
        @test getfield(Nitro, name) === getfield(Nitro.Core.Util.BodyParsers, name)
    end

    # The builders live in `Res`, reachable only qualified.
    for name in (:json, :html, :send, :status, :file, :redirect, :sse)
        @test isdefined(Nitro.Res, name)
    end
    @test !isdefined(Nitro.Res, :text)   # `Res.send` already is text/plain -- no synonym
    # `Res.sse` is a builder, so it obeys the same rule as the rest: qualified only (#160).
    @test !isdefined(Nitro, :sse)
end

@testset "SSE framing comes from HTTP, not from Nitro (#160)" begin
    # `format_sse_message` was Nitro's own SSE framer and it is GONE. It rejected LF in `event`
    # and `id` but not CR -- and a bare CR is a valid SSE line terminator, so attacker-influenced
    # data could forge fields or a dispatch boundary at every connected EventSource. `HTTP.SSEEvent`
    # rejects CR, LF and NUL, so the framing is upstream's now and there is exactly one of it.
    @test !isdefined(Nitro, :format_sse_message)
    @test !isdefined(Nitro.Core.Util, :format_sse_message)

    # `SSEEvent` is what a `Res.sse` producer writes, so it must be reachable from `using Nitro`
    # alone -- same contract as `Request`/`Response`/`Stream` above.
    @test isdefined(Nitro, :SSEEvent)
    @test Nitro.SSEEvent === HTTP.SSEEvent

    # `SSEStream`/`sse_stream` are deliberately NOT re-exported: the stream arrives as the
    # producer's argument, and building the response is `Res.sse`'s job.
    @test !isdefined(Nitro, :SSEStream)
    @test !isdefined(Nitro, :sse_stream)
end

end