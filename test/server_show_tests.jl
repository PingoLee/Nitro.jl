@testitem "Server show never leaks handler secrets" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# Regression test for the `NitroStreamHandler` secret-safe `show` (src/core.jl):
# displaying the server handle returned by `serve(async=true)` must never print
# secrets captured in middleware/handler closures.

const SECRET = "NITRO-TEST-SECRET-2f7c91"

# The secret must be a captured LOCAL: closures over module globals do not store the
# value as a closure field, so a global would make the leak assertions vacuous.
function secret_middleware(secret_key::String)
    return function (handle)
        return function (req::HTTP.Request)
            # An auth-style check, so `secret_key` is genuinely captured and used.
            HTTP.header(req, "X-Api-Key", "") == secret_key || nothing
            return handle(req)
        end
    end
end

port = get_free_port()
localhost = "http://$HOST:$port"

urlpatterns("",
    path("/ping", function(req) return "pong" end, method="GET"),
)

server = serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false,
               access_log=nothing, middleware=[secret_middleware(SECRET)])

try
    @testset "handle is a real HTTP.Server and the server works" begin
        @test server isa HTTP.Server
        response = HTTP.get("$localhost/ping")
        @test response.status == 200
    end

    @testset "sanity: the secret IS reachable in the object graph" begin
        # `dump` bypasses `show` and walks raw fields; it must find the captured secret,
        # otherwise the non-leak assertions below would pass vacuously.
        @test occursin(SECRET, sprint(io -> dump(io, server; maxdepth=60)))
    end

    @testset "show / display / interpolation print only the address" begin
        shown   = sprint(show, server)
        display = sprint((io, x) -> show(io, MIME("text/plain"), x), server)
        interp  = "$server"
        for s in (shown, display, interp)
            @test !occursin(SECRET, s)
            @test occursin(string(port), s)   # the address, the one thing it should print
        end
    end
finally
    terminate()
end

end # @testitem
