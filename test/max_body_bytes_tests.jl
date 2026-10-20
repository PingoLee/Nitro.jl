@testitem "Request body size limit" tags=[:core, :network, :security] setup=[NitroCommon] begin
using Test
using HTTP
using Sockets
using Nitro

# The ceiling under test. Small on purpose: every assertion here is about the *boundary*, and
# driving 64 MiB through a loopback socket to prove an integer comparison would make this the
# slowest item in the suite for no extra coverage. `DEFAULT_MAX_BODY_BYTES` itself is asserted
# once, by value, at the bottom.
const LIMIT = 1024

urlpatterns("",
    path("/echo", function(req::HTTP.Request)
        return Dict("n" => length(Nitro.binary(req)))
    end, methods=["POST"]),
)

port = get_free_port()
localhost = "http://$HOST:$port"
serve(port=port, host=HOST, async=true, show_errors=false, show_banner=false,
      access_log=nothing, max_body_bytes=LIMIT)

const CRLF = "\r\n"

# Raw socket driver. HTTP.jl's client normalizes away exactly what this item cares about --
# whether a `100 Continue` interim was emitted, and whether the server closed the connection -- so
# the boundary cases speak HTTP/1.1 directly.
#
# The response is read by FRAMING it (blocking byte reads up to the header terminator, then
# exactly `Content-Length` bytes) rather than by polling. Two things make the obvious approaches
# wrong here: Julia's `TCPSocket` only fills its internal buffer once a read has been initiated,
# so a `bytesavailable` poll reads zero forever; and `eof(sock)` blocks indefinitely on a
# connection the server is deliberately keeping alive. Framing is deterministic under both.
function read_http_response(sock)
    terminator = Vector{UInt8}(CRLF * CRLF)
    head = UInt8[]
    while !(length(head) >= 4 && head[end-3:end] == terminator)
        push!(head, read(sock, UInt8))
    end
    headtext = String(head)
    m = match(r"(?im)^content-length:[ \t]*(\d+)", headtext)
    body = m === nothing ? "" : String(read(sock, parse(Int, m.captures[1])))
    return headtext * body
end

function raw_exchange(payload::String)
    sock = Sockets.connect(HOST, port)
    try
        write(sock, payload)
        return read_http_response(sock)
    finally
        close(sock)
    end
end

function chunked_request(n::Int, c::String)
    return string("POST /echo HTTP/1.1", CRLF, "Host: ", HOST, ":", port, CRLF,
                  "Transfer-Encoding: chunked", CRLF, "Content-Type: text/plain", CRLF, CRLF,
                  string(n, base=16), CRLF, repeat(c, n), CRLF, "0", CRLF, CRLF)
end

@testset "Under the limit is untouched" begin
    r = HTTP.post("$localhost/echo", [], repeat("a", LIMIT - 1))
    @test r.status == 200
    # The byte count, not just the status: a cap that truncated instead of rejecting would still
    # answer 200 here, and that is the failure mode worth naming.
    @test occursin("\"n\":$(LIMIT - 1)", String(r.body))
end

@testset "Exactly at the limit is accepted" begin
    r = HTTP.post("$localhost/echo", [], repeat("a", LIMIT))
    @test r.status == 200
    @test occursin("\"n\":$LIMIT", String(r.body))
end

@testset "Declared Content-Length over the limit is 413" begin
    r = HTTP.post("$localhost/echo", [], repeat("a", LIMIT + 1); status_exception=false)
    @test r.status == 413
    @test lowercase(HTTP.header(r, "Connection", "")) == "close"
    # That this assertion can run at all is the point of the bounded swallow in
    # `_reject_oversized_body!`. Closing the socket with the client's bytes still unread sends an
    # RST, and an RST discards the 413 that was already in the send buffer -- the client then sees
    # a connection reset and cannot tell "too large" from "server crashed".
end

@testset "Chunked over the limit is 413 -- the pre-check cannot see it" begin
    # A chunked request declares `content_length == -1`, so the Content-Length fast path is
    # structurally unable to fire. This is the case that proves the incremental counter, rather
    # than the header check, is what actually enforces the ceiling.
    reply = raw_exchange(chunked_request(LIMIT + 512, "b"))
    @test startswith(reply, "HTTP/1.1 413")
    @test occursin(r"(?i)connection:\s*close", reply)
end

@testset "Chunked under the limit arrives whole" begin
    n = LIMIT - 64
    reply = raw_exchange(chunked_request(n, "c"))
    @test startswith(reply, "HTTP/1.1 200")
    @test occursin("\"n\":$n", reply)
end

@testset "Expect: 100-continue is refused before the body is sent" begin
    # The cheap rejection path: the declared-length check runs before any read, and `100 Continue`
    # is emitted by the first read -- so a client that asks permission never gets it and never
    # spends the bytes. Regression guard against reordering that check after the read, and against
    # letting the swallow run on a client that has not sent anything yet (which would invite the
    # very body just refused).
    payload = string("POST /echo HTTP/1.1", CRLF, "Host: ", HOST, ":", port, CRLF,
                     "Content-Length: ", LIMIT + 1, CRLF, "Expect: 100-continue", CRLF, CRLF)
    reply = raw_exchange(payload)
    @test startswith(reply, "HTTP/1.1 413")
    @test !occursin("100 Continue", reply)
end

@testset "Keep-alive survives an under-limit request" begin
    # The `EmptyBody` and fixed-length fast paths both skip a read that HTTP otherwise relies on to
    # mark the body consumed. If either got that wrong, `startwrite` would force
    # `Connection: close` on every ordinary request and this connection could not carry a second.
    sock = Sockets.connect(HOST, port)
    try
        payload = string("POST /echo HTTP/1.1", CRLF, "Host: ", HOST, ":", port, CRLF,
                         "Content-Length: 4", CRLF, "Content-Type: text/plain", CRLF, CRLF, "abcd")
        # A bodyless GET drives the `EmptyBody` branch, which skips the read ENTIRELY. That is only
        # safe because `EmptyBody` reports itself fully consumed; if it did not, `startwrite` would
        # force `Connection: close` here and the socket could not carry the POST that follows.
        bodyless = string("GET /echo HTTP/1.1", CRLF, "Host: ", HOST, ":", port, CRLF, CRLF)
        for _ in 1:2
            write(sock, bodyless)
            reply = read_http_response(sock)
            # Assert the response ARRIVED, not just that a header is absent. `read_http_response`
            # frames on Content-Length, so a malformed reply here would desync the socket and
            # surface as a failure in the POST below instead of at its real cause.
            @test startswith(reply, "HTTP/1.1")
            @test !occursin(r"(?i)connection:\s*close", reply)

            write(sock, payload)
            reply = read_http_response(sock)
            @test startswith(reply, "HTTP/1.1 200")
            @test occursin("\"n\":4", reply)
            @test !occursin(r"(?i)connection:\s*close", reply)
        end
    finally
        close(sock)
    end
end

terminate()

@testset "max_body_bytes=nothing buffers without a ceiling" begin
    port2 = get_free_port()
    serve(port=port2, host=HOST, async=true, show_errors=false, show_banner=false,
          access_log=nothing, max_body_bytes=nothing)
    try
        # Comfortably past the ceiling the previous server enforced -- the point is that no ceiling
        # applies at all, not that this particular size is special.
        n = LIMIT * 64
        r = HTTP.post("http://$HOST:$port2/echo", [], repeat("d", n))
        @test r.status == 200
        @test occursin("\"n\":$n", String(r.body))
    finally
        terminate()
    end
end

@testset "Invalid configuration is refused at serve()" begin
    # Matched on MESSAGE, not on `ArgumentError` alone. `serve` raises that type for at least four
    # unrelated causes -- already serving, bad `revise`, bad `shutdown_timeout`, and these -- so a
    # bare type check discriminates nothing. Worse, these assertions would be coupled: if the first
    # regressed, `serve` would not throw but would START and leak a server on the singleton
    # `CONTEXT[]`, and the second call would then trip `serve`'s own "already serving" guard and
    # pass as an `ArgumentError` for entirely the wrong reason, hiding half the regression.
    @test_throws "max_body_bytes" serve(port=get_free_port(), host=HOST, async=true,
                                        show_banner=false, max_body_bytes=-1)

    # A custom handler reads the body itself, so Nitro cannot cap it. Silently ignoring the kwarg
    # would hand back a server the caller believes is protected.
    @test_throws "max_body_bytes" serve(port=get_free_port(), host=HOST, async=true,
                                        show_banner=false, max_body_bytes=4096,
                                        handler=mw -> (stream -> nothing))

    # The caller asking for the DEFAULT value explicitly must be refused just the same. This is the
    # case an `!= DEFAULT_MAX_BODY_BYTES` guard silently let through, dropping the ceiling on a
    # server the caller believed was protected.
    @test_throws "max_body_bytes" serve(port=get_free_port(), host=HOST, async=true,
                                        show_banner=false,
                                        max_body_bytes=Nitro.DEFAULT_MAX_BODY_BYTES,
                                        handler=mw -> (stream -> nothing))
end

@testset "The default is the fork's own ceiling" begin
    # 64 MiB is not a Nitro invention -- it is `HTTP._SERVER_DEFAULT_MAX_BODY_BYTES`, the cap the
    # bundled fork enforces on the `serve!` path that Nitro's stream handler bypasses. If the fork
    # ever moves its number, this is the line that says whether to follow it.
    @test Nitro.DEFAULT_MAX_BODY_BYTES == 64 * 1024 * 1024
    @test Nitro.DEFAULT_MAX_BODY_BYTES == HTTP._SERVER_DEFAULT_MAX_BODY_BYTES
end

end

@testitem "The body read keeps every byte and allocates by the body, not by the chunk (#535)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Random
using Sockets
using Nitro

# `_http_stream_request` driven directly, under a raw HTTP.jl stream server, so what is measured is
# the body read alone -- no router, no middleware, no response building.
const Core_ = Nitro.Core
const CRLF = "\r\n"
const LIMIT = Int64(5000)
const SEEN = Channel{Any}(Inf)

function reader(limit::Int64)
    return function (stream::HTTP.Stream)
        req = nothing
        err = nothing
        # A throw is REPORTED, not left to HTTP's loop: the test would otherwise wait on `SEEN`
        # forever instead of failing.
        bytes = @allocated try
            req = Core_._http_stream_request(stream, limit)
        catch e
            err = e
        end
        rejected = req isa Core_._BodyRejected
        body = req isa HTTP.Request ? (req.body isa HTTP.EmptyBody ? UInt8[] : copy(req.body.data)) : nothing
        put!(SEEN, (; body, rejected, bytes, err))
        err === nothing || return nothing
        HTTP.setstatus(stream, rejected ? 413 : 200)
        HTTP.setheader(stream, "Content-Length" => "0")
        rejected && HTTP.setheader(stream, "Connection" => "close")
        HTTP.startwrite(stream)
        return nothing
    end
end

head(framing) = string("POST /b HTTP/1.1", CRLF, "Host: x", CRLF, framing, CRLF, CRLF)
fixed(body) = vcat(Vector{UInt8}(head("Content-Length: $(length(body))")), body)
function chunked(chunks)
    io = IOBuffer()
    write(io, head("Transfer-Encoding: chunked"))
    for c in chunks
        write(io, string(length(c), base = 16), CRLF, c, CRLF)
    end
    write(io, "0", CRLF, CRLF)
    return take!(io)
end

function await_seen()
    timedwait(() -> isready(SEEN), 30.0; pollint = 0.01) === :ok || error("the handler reported nothing in 30 s")
    return take!(SEEN)
end

function send(port, payload)
    sock = Sockets.connect(HOST, port)
    try
        write(sock, payload)
        return await_seen()
    finally
        close(sock)
    end
end

port = get_free_port()
server = HTTP.listen!(reader(Int64(64 << 20)), HOST, port)
try
    @testset "fixed length, every size around the read boundaries" begin
        for n in (1, 200, 1023, 1024, 1025, 65535, 65536, 65537, 200_000)
            body = rand(Random.RandomDevice(), UInt8, n)
            seen = send(port, fixed(body))
            @test !seen.rejected
            @test seen.body == body
        end
    end

    @testset "chunked, chunks smaller than, equal to and larger than a read" begin
        for sizes in ([200], [1], [1024], [1025], [1024, 1024], [1, 1023, 1025, 4096],
                      [65536], [70_000], [16384 for _ in 1:20], [1000, 70_000, 3, 65536, 2])
            chunks = [rand(Random.RandomDevice(), UInt8, s) for s in sizes]
            seen = send(port, chunked(chunks))
            @test !seen.rejected
            @test seen.body == reduce(vcat, chunks)
        end
    end

    @testset "a small chunked body allocates less than one transfer chunk" begin
        # Before #535 every chunked body cost at least two `_STREAM_CHUNK_BYTES` allocations --
        # a 64 KiB scratch, and 64 KiB inside HTTP.jl per read -- however few bytes it carried.
        # The bound is that shape, not a byte count: the read is now sized by the body.
        payload = chunked([rand(Random.RandomDevice(), UInt8, 200)])
        bytes = minimum(send(port, payload).bytes for _ in 1:5)
        @test bytes < Core_._STREAM_CHUNK_BYTES
    end
finally
    close(server)
end

port = get_free_port()
server = HTTP.listen!(reader(LIMIT), HOST, port)
try
    @testset "the ceiling, exactly, under every framing" begin
        at = rand(Random.RandomDevice(), UInt8, LIMIT)
        @test send(port, fixed(at)).body == at
        @test send(port, chunked([at[1:1], at[2:end]])).body == at
        @test send(port, chunked([at])).body == at
        @test send(port, chunked([at, UInt8[0x01]])).rejected
        @test send(port, chunked([at[1:2500], vcat(at[2501:end], 0x01)])).rejected
        @test send(port, chunked([UInt8[0x01] for _ in 1:(LIMIT + 1)])).rejected
    end
finally
    close(server)
end

port = get_free_port()
server = HTTP.listen!(reader(Int64(0)), HOST, port)   # `max_body_bytes = nothing`: no ceiling
try
    @testset "a Content-Length claim reserves nothing before its bytes arrive" begin
        # 256 MiB claimed, 300 bytes sent, then the client hangs up. With no ceiling nothing
        # refuses the claim up front, so the only defence is that the buffer grows with bytes
        # RECEIVED. Sizing the first read, or the body's growth, from `declared` would allocate
        # the claim here.
        # The minimum of three, as above: `@allocated` counts the whole process, and a first run
        # that compiled the read would count the JIT too.
        claimed = 256 << 20
        runs = map(1:3) do _
            sock = Sockets.connect(HOST, port)
            write(sock, head("Content-Length: $claimed"), rand(Random.RandomDevice(), UInt8, 300))
            close(sock)
            return await_seen()
        end
        @test all(s -> s.err isa HTTP.ParseError, runs)   # truncated, and the read says so
        @test minimum(s -> s.bytes, runs) < 4 * Core_._STREAM_CHUNK_BYTES
    end
finally
    close(server)
end
end
