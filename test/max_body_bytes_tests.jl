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
