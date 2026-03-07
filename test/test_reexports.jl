module TestReexports
using Test
import HTTP
import Nitro

@testset "Testing HTTP Reexports" begin
    @test Nitro.Request        == HTTP.Request
    @test Nitro.Response       == HTTP.Response
    @test Nitro.Stream         == HTTP.Stream
    @test Nitro.WebSocket      == HTTP.WebSocket
    @test Nitro.queryparams    == HTTP.queryparams
end

end