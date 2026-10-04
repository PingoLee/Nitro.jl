@testitem "Streamed bodies go to the wire as they are read (#377)" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Sockets
using Random
using Nitro
import Nitro: App

# A response with a declared length is framed FIXED, and on HTTP/1.1 HTTP.jl 2.7 buffers every
# write to a FIXED stream response in `stream.request_buffer`, putting the head and body on the
# wire only at `closewrite`. #41's streamed `Res.file` read its cursor into that buffer in full,
# so peak memory was the file, not a chunk. `_write_response_body!` now commits the head and
# writes each chunk live (see `_write_fixed_body_live!` in `src/core/transport.jl`).
#
# Every assertion here goes over a raw socket: the defect is WHEN bytes reach the wire, which no
# in-process check and no pooling client can observe. Random bytes come from `RandomDevice`,
# because `@testset` reseeds the default RNG.

"""
One raw HTTP/1.1 connection with a background reader appending everything the server sends.
A raw socket rather than HTTP.jl's client: no pool, no retry, exactly one connection.
"""
mutable struct RawConn
    sock::TCPSocket
    buf::Vector{UInt8}
    lock::ReentrantLock
    eof::Bool
    reader::Task
    function RawConn(port)
        c = new(Sockets.connect(Sockets.localhost, port), UInt8[], ReentrantLock(), false)
        c.reader = @async begin
            try
                while !eof(c.sock)
                    bytes = readavailable(c.sock)
                    lock(() -> append!(c.buf, bytes), c.lock)
                end
            catch
            end
            c.eof = true
        end
        return c
    end
end

send!(c::RawConn, s::AbstractString) = (write(c.sock, s); flush(c.sock); nothing)
received(c::RawConn) = lock(() -> copy(c.buf), c.lock)
Base.close(c::RawConn) = close(c.sock)

"Index just past the head's blank line in `bytes` from `from`, or `nothing`."
function head_end(bytes::Vector{UInt8}, from::Int = 1)
    r = findnext(b"\r\n\r\n", bytes, from)
    return r === nothing ? nothing : last(r) + 1
end

function content_length(head::AbstractString)
    m = match(r"(?i)\r\ncontent-length:\s*(\d+)", head)
    return m === nothing ? nothing : parse(Int, m[1])
end

"""
Read the next full response on `c` starting at byte `from`: the head, and `Content-Length`
body bytes unless `bodyless`. Returns `(head, body, next_from)`, or throws on timeout.
"""
function next_response(c::RawConn, from::Int; bodyless::Bool = false, limit = 20.0)
    local head, body, stop
    ok = timedwait(limit; pollint = 0.01) do
        bytes = received(c)
        hend = head_end(bytes, from)
        hend === nothing && return false
        head = String(bytes[from:hend-1])
        n = bodyless ? 0 : something(content_length(head), 0)
        length(bytes) - hend + 1 >= n || return false
        body = bytes[hend:hend+n-1]
        stop = hend + n
        return true
    end
    ok === :ok || error("no complete response within $(limit)s; received $(length(received(c)) - from + 1) bytes")
    return head, body, stop
end

# Two chunks of a body with a declared length, the second held back until `release` fires. Built
# per request: a streaming body is single-use.
const FIRST  = fill(UInt8('a'), 1000)
const SECOND = fill(UInt8('b'), 1000)

function gated_response(release::Base.Event, fail_second::Bool)
    calls = Ref(0)
    body = HTTP.CallbackBody(function (dst)
        calls[] += 1
        if calls[] == 1
            copyto!(dst, FIRST)
            return length(FIRST)
        elseif calls[] == 2
            wait(release)
            fail_second && error("producer failed mid-body")
            copyto!(dst, SECOND)
            return length(SECOND)
        end
        return 0
    end, () -> nothing)
    return HTTP.Response(200, ["Content-Type" => "application/octet-stream",
                               "Content-Length" => string(length(FIRST) + length(SECOND))], body)
end

# A body that lies about its length: `FIRST` then `SECOND` against a declared `declared` bytes.
# Short (2000 declared, 1000 sent) and long (1500 declared, 2000 produced) both have to end the
# response by closing the connection, or the next response on it is read out of step.
function lying_response(declared::Int, chunks::Vector{Vector{UInt8}})
    next = Ref(1)
    body = HTTP.CallbackBody(function (dst)
        next[] > length(chunks) && return 0
        chunk = chunks[next[]]
        next[] += 1
        copyto!(dst, chunk)
        return length(chunk)
    end, () -> nothing)
    return HTTP.Response(200, ["Content-Length" => string(declared)], body)
end

const FILE_BYTES = rand(Random.RandomDevice(), UInt8, 3 * 1024 * 1024 + 17)   # 49 chunks, a short last one
const FILE_PATH  = joinpath(mktempdir(), "download.bin")
write(FILE_PATH, FILE_BYTES)

function streaming_app(release::Base.Event)
    ctx = App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/gated",  (req::HTTP.Request) -> gated_response(release, false)),
        path("/broken", (req::HTTP.Request) -> gated_response(release, true)),
        path("/short",  (req::HTTP.Request) -> lying_response(2000, [FIRST])),
        path("/long",   (req::HTTP.Request) -> lying_response(1500, [FIRST, SECOND])),
        # Wrong before a byte is sent: known from the first read, so refused before the head.
        path("/overrun-first",  (req::HTTP.Request) -> lying_response(500, [FIRST])),
        path("/empty-declared", (req::HTTP.Request) -> lying_response(100, Vector{UInt8}[])),
        path("/firstfail", (req::HTTP.Request) -> HTTP.Response(200, ["Content-Length" => "10"],
             HTTP.CallbackBody(dst -> error("cannot read the source"), () -> nothing))),
        path("/file",   (req::HTTP.Request) -> Res.file(req, FILE_PATH; stream = true);
             methods = ["GET", "HEAD"]),
    ])
    return ctx
end

"The `Warn` records `logger` has captured so far — read under its lock, since the server logs from its own tasks."
warnings(logger) = lock(() -> filter(r -> r.level == Base.CoreLogging.Warn, copy(logger.logs)), logger.lock)

"Send one request on a fresh connection and return everything the server sends before it closes."
function one_shot(port, target)
    c = RawConn(port)
    try
        send!(c, "GET $target HTTP/1.1\r\nHost: $HOST\r\nConnection: keep-alive\r\n\r\n")
        timedwait(() -> c.eof, 10.0) === :ok || return nothing
        return received(c)
    finally
        close(c)
    end
end

# Uncapped, and under `max_concurrent_requests`: the capped path calls `closewrite` itself while
# the slot is held (#298), so both have to agree that a live-written body is already closed.
for cap in (nothing, 4)
    release = Base.Event()
    ctx = streaming_app(release)
    port = get_free_port()
    # Served under a capturing logger: the request tasks inherit it, so the warning a failed body
    # logs can be asserted -- and does not clutter the suite's output.
    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
    Base.CoreLogging.with_logger(logger) do
        Nitro.Core.serve(ctx; host = HOST, port = port, async = true, show_banner = false,
                         show_errors = false, access_log = nothing, max_concurrent_requests = cap)
    end
    @test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
    try
        @testset "cap=$cap: the head and first chunk arrive while the body is still being read" begin
            # The core pin. Against the buffered writer NOTHING reaches the client until the body
            # is exhausted, so waiting for the first chunk before `release` times out. The window
            # is generous because this is the first request to a fresh server, and pays the
            # compile latency of the write path; the buffered writer never delivers, so a long
            # window costs no discrimination.
            c = RawConn(port)
            try
                send!(c, "GET /gated HTTP/1.1\r\nHost: $HOST\r\n\r\n")
                early = timedwait(30.0; pollint = 0.01) do
                    bytes = received(c)
                    hend = head_end(bytes)
                    hend !== nothing && length(bytes) - hend + 1 >= length(FIRST)
                end
                @test early === :ok
                notify(release)
                head, body, _ = next_response(c, 1)
                @test startswith(head, "HTTP/1.1 200")
                @test content_length(head) == 2000
                @test body == vcat(FIRST, SECOND)
            finally
                notify(release)
                close(c)
            end
        end

        @testset "cap=$cap: a streamed Res.file is byte-exact and the connection stays reusable" begin
            # Four responses on ONE keep-alive connection. Any bookkeeping the live writer left
            # wrong -- a second head, an unflushed buffer, a miscounted length -- desynchronises
            # the framing of the next response on the same socket.
            c = RawConn(port)
            try
                req(target; method = "GET", extra = "") =
                    send!(c, "$method $target HTTP/1.1\r\nHost: $HOST\r\n$extra\r\n")

                req("/file")
                head, body, at = next_response(c, 1)
                @test startswith(head, "HTTP/1.1 200")
                @test content_length(head) == length(FILE_BYTES)
                @test body == FILE_BYTES

                req("/file"; method = "HEAD")
                head, body, at = next_response(c, at; bodyless = true)
                @test startswith(head, "HTTP/1.1 200")
                @test content_length(head) == length(FILE_BYTES)

                req("/file"; extra = "Range: bytes=70000-70099\r\n")
                head, body, at = next_response(c, at)
                @test startswith(head, "HTTP/1.1 206")
                @test occursin("bytes 70000-70099/$(length(FILE_BYTES))", head)
                @test body == FILE_BYTES[70001:70100]

                req("/file")
                head, body, at = next_response(c, at)
                @test startswith(head, "HTTP/1.1 200")
                @test body == FILE_BYTES

                sleep(0.2)
                @test length(received(c)) == at - 1     # nothing trailing: no second head, no leftovers
            finally
                close(c)
            end
        end

        @testset "cap=$cap: a body that fails after its head closes the connection, with no second status" begin
            # Once the head is on the wire the status cannot change, so a failing producer
            # truncates the body and closes the connection -- Go's `net/http` semantics. What must
            # never happen is a `500` appended after the partial body.
            c = RawConn(port)
            try
                send!(c, "GET /broken HTTP/1.1\r\nHost: $HOST\r\n\r\n")
                notify(release)
                @test timedwait(() -> c.eof, 10.0) === :ok
                bytes = received(c)
                text = String(copy(bytes))
                @test startswith(text, "HTTP/1.1 200")
                @test count("HTTP/1.1 ", text) == 1
                hend = head_end(bytes)
                @test hend !== nothing
                @test bytes[hend:end] == FIRST
            finally
                close(c)
            end
        end

        @testset "cap=$cap: a body that does not match its Content-Length ends the connection" begin
            # The length is enforced on the live path too. A short body must not leave the
            # connection reusable -- the client would wait forever for the missing bytes -- and a
            # long one must not put the surplus on the wire, where it would be read as the start
            # of the next response. Keep-alive is requested on purpose, so only the check closes it.
            for (route, declared) in (("/short", 2000), ("/long", 1500))
                # Cleared first: `/broken` above already logged `declared = 2000, written = 1000`,
                # which would satisfy `/short`'s check whether or not `/short` itself warned.
                lock(() -> empty!(logger.logs), logger.lock)
                bytes = one_shot(port, route)
                @test bytes !== nothing
                bytes === nothing && continue
                text = String(copy(bytes))
                @test startswith(text, "HTTP/1.1 200")
                @test count("HTTP/1.1 ", text) == 1
                hend = head_end(bytes)
                @test hend !== nothing
                @test bytes[hend:end] == FIRST
                # The client only sees a cut connection, so the server log is where the defect
                # surfaces: one warning, with how far the body got and what it promised.
                logged = timedwait(10.0; pollint = 0.05) do
                    any(r -> get(r.kwargs, :declared, nothing) == declared &&
                             get(r.kwargs, :written, nothing) == 1000, warnings(logger))
                end
                @test logged === :ok
            end
        end

        @testset "cap=$cap: a body known to be wrong before its head gets a clean 500" begin
            # Refused before a byte is sent, so the status can still say so: a source that fails on
            # its first read, a first chunk already past the length, a body with none of the bytes
            # it declared. A 500, not HTTP's 400 for a `ProtocolError` -- the wrong length is the
            # server's defect, not the client's. The first route pins that the head waits for the
            # first read; the other two pin the pre-head length check.
            for route in ("/firstfail", "/overrun-first", "/empty-declared")
                bytes = one_shot(port, route)
                @test bytes !== nothing
                bytes === nothing && continue
                text = String(copy(bytes))
                @test startswith(text, "HTTP/1.1 500")
                @test count("HTTP/1.1 ", text) == 1
            end
        end
    finally
        notify(release)
        Nitro.Core.terminate(ctx)
    end
end

end

@testitem "stream_handler puts the response on the wire itself, on every path (#453)" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Nitro
import Nitro: App

# HTTP.jl's connection loop calls `closewrite` only after the stream handler returns, on the
# connection task -- and HTTP.jl 2.x runs every connection task on the single `:interactive`
# thread. On HTTP/1.1 a buffered fixed-length response reaches the socket only at `closewrite`, so
# leaving that call to the loop put every response the server wrote on one thread: ~30k rps
# against ~60k for bare HTTP.jl on the same box (bench/socket/). `stream_handler` now closes the
# write side itself, on the request's own task, whether or not a `max_concurrent_requests` slot is
# held. This pins it where it is observable: the moment `stream_handler`'s closure returns.
#
# Uncapped is the case that matters: the capped path already closed writes itself (#298), so an
# assertion only under a cap would pass against the unpatched code.

ctx = App()
Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/text", (req::HTTP.Request) -> Res.send("hello"); methods = ["GET", "HEAD"]),
    path("/json", (req::HTTP.Request) -> Res.json(Dict("a" => 1))),
    path("/boom", (req::HTTP.Request) -> error("handler failed")),
])

closed_on_return = Bool[]
connections = UInt[]            # objectid of the server-side connection each request arrived on
seen_lock = ReentrantLock()
# The wrapper is `stream_handler` itself plus one observation after it returns. A custom `handler`
# is refused alongside a body cap, which only Nitro's own handler can enforce -- hence
# `max_body_bytes = nothing`.
recording = function (mw)
    inner = Nitro.Core.stream_handler(mw)
    return function (stream::HTTP.Stream)
        inner(stream)
        closed = @atomic :acquire stream.write_closed
        conn = objectid(getfield(stream, :tracked))
        lock(seen_lock) do
            push!(closed_on_return, closed)
            push!(connections, conn)
        end
        return nothing
    end
end

port = get_free_port()
Nitro.Core.serve(ctx; host = HOST, port = port, async = true, show_banner = false,
                 show_errors = false, access_log = nothing, max_body_bytes = nothing,
                 handler = recording)
@test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok
try
    # Keep-alive reuse is part of the claim: closing writes early must not cost the connection.
    responses = [
        HTTP.get("http://$HOST:$port/text"; status_exception = false, retry = false),
        HTTP.get("http://$HOST:$port/json"; status_exception = false, retry = false),
        HTTP.head("http://$HOST:$port/text"; status_exception = false, retry = false),
        HTTP.get("http://$HOST:$port/missing"; status_exception = false, retry = false),
        HTTP.get("http://$HOST:$port/boom"; status_exception = false, retry = false),
        HTTP.get("http://$HOST:$port/text"; status_exception = false, retry = false),
    ]
    @test [r.status for r in responses] == [200, 200, 200, 404, 500, 200]
    @test String(responses[1].body) == "hello"
    @test String(responses[2].body) == "{\"a\":1}"
    @test isempty(responses[3].body)
    @test HTTP.header(responses[3], "Content-Length") == "5"
    @test String(responses[6].body) == "hello"

    snapshot = lock(() -> copy(closed_on_return), seen_lock)
    @test length(snapshot) == length(responses)
    @test all(snapshot)
    # All six on ONE connection. Closing writes early must not make HTTP's `startwrite` decide
    # the connection is done; if it did, the client would quietly reconnect and every status
    # above would still pass.
    @test length(unique(lock(() -> copy(connections), seen_lock))) == 1
    @test !any(r -> HTTP.hasheader(r, "Connection", "close"), responses)
finally
    terminate(ctx)
end

end
