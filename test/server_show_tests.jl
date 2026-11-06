@testitem "Server show never leaks handler secrets" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# Regression test for the `NitroStreamHandler` secret-safe `show` (src/core/lifecycle.jl):
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

# Breadth-first over raw fields and array slots from `root`: `:found` when a `String` equal to
# `needle` is reachable, `:absent` when the graph ran out, `:budget` after `budget` nodes.
# Types, modules and methods are leaves: the secret lives in instance data, and those are the
# doors into the world's method and binding tables.
function reachable_string(root, needle::String; budget::Int = 2_000_000)
    seen = Base.IdSet{Any}()
    queue = Any[root]
    head = 1
    while head <= length(queue)
        head > budget && return :budget
        x = queue[head]
        head += 1
        if x isa String
            x == needle && return :found
            continue
        end
        x isa Union{Module, Type, Symbol, Method, Core.MethodInstance, Core.CodeInstance,
                    Core.SimpleVector} && continue
        x in seen && continue
        push!(seen, x)
        if x isa Union{Array, Base.GenericMemory}
            isbitstype(eltype(x)) && continue
            for i in eachindex(x)
                isassigned(x, i) && push!(queue, x[i])
            end
        else
            for i in 1:nfields(x)
                isdefined(x, i) || continue
                v = getfield(x, i)
                isbits(v) || push!(queue, v)
            end
        end
    end
    return :absent
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
        # Walking raw fields bypasses `show`, and it must find the captured secret, otherwise
        # the non-leak assertions below would pass vacuously. This used to be
        # `dump(server; maxdepth=60)`, which also prints every type it meets: on a Julia with
        # the task-cancellation work its output went from 73 KB to 396 MB at `maxdepth=10`, and
        # the item hung until the watchdog killed the run (#761). The walk below treats types
        # as leaves, so it covers the instance data alone (about 270 nodes on 1.13 and on the
        # 1.15 nightly). Its node budget turns a miss into a named failure instead of a hang.
        @test reachable_string(server, SECRET) === :found
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
