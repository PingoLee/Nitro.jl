@testitem "Streaming" tags=[:handler, :network, :slow] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

function explicit_stream(stream::HTTP.Stream)
    # Set headers
    HTTP.setheader(stream, "Content-Type" => "text/plain")
    HTTP.setheader(stream, "Transfer-Encoding" => "chunked")

    # Start writing (if you need to send headers before the body)
    startwrite(stream)

    data = ["a", "b", "c"]
    for chunk in data
        write(stream, chunk)
    end

    # Close the stream to end the HTTP response properly
    closewrite(stream)
end

function implicit_stream(stream)
    explicit_stream(stream)
end

urlpatterns("",
    path("/api/chunked/text", implicit_stream, method="STREAM"),
    path("/stream/api/func/chunked/text", implicit_stream, method="STREAM"),
    path("/api/post/chunked/text", explicit_stream, method="STREAM"),
    path("/api/error", implicit_stream, method="GET"),
)

serve(port=port, host=HOST, async=true,  show_errors=false, show_banner=false, access_log=nothing)

@testset "StreamingChunksDemo Tests" begin

    @testset "route stream handler" begin
        response = HTTP.get("$localhost/api/chunked/text", headers=Dict("Connection" => "close"))
        @test response.status == 200
        @test text(response) == "abc"
    end

    @testset "function stream handler" begin
        response = HTTP.get("$localhost/stream/api/func/chunked/text",  headers=Dict("Connection" => "close"))
        @test response.status == 200
        @test text(response) == "abc"
    end

    @testset "/api/post/chunked/text" begin
        response = HTTP.post("$localhost/api/post/chunked/text",  headers=Dict("Connection" => "close"))
        @test response.status == 200
        @test text(response) == "abc"
    end

    @testset "Can't setup implicit stream handler on regular routing functions" begin
        try 
            response = HTTP.get("$localhost/api/error",  headers=Dict("Connection" => "close"))
            @test false
        catch e
            @test true
        end
    end

end


terminate()
println()
end

@testitem "Streaming — route middleware runs on a STREAM route (#282)" tags=[:handler, :middleware, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro

# Route middleware on a STREAM route used to be skipped entirely (#282). Now it runs, so on the
# wire: a middleware that passes through must leave the handler's stream intact, and a guard
# that refuses must still get its 403 written, since the handler never started the response.
# In-process coverage of the keying is in test/custommiddleware_tests.jl.

function chunks(stream::HTTP.Stream)
    HTTP.setheader(stream, "Content-Type" => "text/plain")
    startwrite(stream)
    for chunk in ("a", "b", "c")
        write(stream, chunk)
    end
    closewrite(stream)
end

hits = Threads.Atomic{Int}(0)
counting = handle -> (req -> (Threads.atomic_add!(hits, 1); handle(req)))
deny = handle -> (req -> HTTP.Response(403))

app = App()
urlpatterns(app, "",
    path("/counted", chunks; method = "STREAM", middleware = [counting]),
    path("/denied", chunks; method = "STREAM", middleware = [deny]),
)

port = get_free_port()
localhost = "http://$HOST:$port"
serve(app; port = port, host = HOST, async = true, show_errors = false, show_banner = false,
      access_log = nothing)

try
    @testset "a passing middleware runs once and the stream is intact" begin
        r = HTTP.get("$localhost/counted"; headers = Dict("Connection" => "close"))
        @test r.status == 200
        @test text(r) == "abc"
        @test hits[] == 1
        r = HTTP.post("$localhost/counted"; headers = Dict("Connection" => "close"))
        @test text(r) == "abc"
        @test hits[] == 2
    end

    @testset "a refusing guard is answered with its own status" begin
        r = HTTP.get("$localhost/denied"; headers = Dict("Connection" => "close"), status_exception = false)
        @test r.status == 403
        @test isempty(text(r))
    end
finally
    terminate(app)
end
end
