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
    @test precompile(Nitro.Core._write_response_body!, (stream, String))
finally
    terminate(app)
end
end
