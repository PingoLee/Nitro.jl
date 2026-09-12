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
    for name in (:json, :html, :send, :status, :file, :redirect)
        @test isdefined(Nitro.Res, name)
    end
    @test !isdefined(Nitro.Res, :text)   # `Res.send` already is text/plain -- no synonym
end

end