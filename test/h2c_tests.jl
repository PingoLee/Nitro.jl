@testitem "Cleartext HTTP/2 (h2c) is refused" tags=[:core, :network, :security] setup=[NitroCommon] begin

using Test
using HTTP
using Sockets
using Nitro
using Nitro: path

# #375. HTTP.jl sniffs the cleartext HTTP/2 preface on every plain listener and has no switch
# to turn it off; Nitro overrides that probe for its own servers (`src/core/lifecycle.jl`), so the
# preface reaches the HTTP/1.1 parser and no HTTP/2 frame is ever read or written.

const H2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

function _h2c_context()
    ctx = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/ok", req -> "ok"; method = "GET"),
        path("/echo", req -> String(req.body); method = "POST"),
    ])
    return ctx
end

_serve(ctx, port; kw...) = Nitro.Core.serve(ctx; port, host = HOST, async = true,
                                            show_banner = false, show_errors = false,
                                            access_log = nothing, kw...)

# Everything the server sends until it closes the connection, or a marker after `limit` seconds.
# An unpatched server answers the preface with nothing at all: it waits for the client's SETTINGS
# frame, so the marker — not a hang — is what the refusal assertions fail on.
function _raw_exchange(port, payload; limit = 10.0)
    sock = Sockets.connect(Sockets.localhost, port)
    try
        write(sock, payload)
        flush(sock)
        reader = @async try
            String(read(sock))
        catch
            ""
        end
        timedwait(() -> istaskdone(reader), limit; pollint = 0.05)
        return istaskdone(reader) ? fetch(reader) : "(no close within $(limit)s)"
    finally
        close(sock)
    end
end

@testset "the prior-knowledge preface gets an HTTP/1.1 400 and a closed connection" begin
    ctx = _h2c_context()
    port = get_free_port()
    _serve(ctx, port)
    try
        # A server speaking h2 would answer with a binary SETTINGS frame, never an HTTP/1.1
        # status line; `_raw_exchange` returning at all means the server closed the connection.
        reply = _raw_exchange(port, H2_PREFACE)
        @test startswith(reply, "HTTP/1.1 400")
        # The same preface followed by the client's SETTINGS frame, as a real h2c client sends it.
        settings = UInt8[0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]
        reply = _raw_exchange(port, vcat(Vector{UInt8}(codeunits(H2_PREFACE)), settings))
        @test startswith(reply, "HTTP/1.1 400")
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "HTTP.jl's own h2c client gets no response" begin
    ctx = _h2c_context()
    port = get_free_port()
    _serve(ctx, port)
    try
        client = HTTP.Client()
        try
            outcome = try
                HTTP.get("http://$HOST:$port/ok"; protocol = :h2, retry = false,
                         client, connect_timeout = 10, request_timeout = 10)
            catch err
                err
            end
            @test !(outcome isa HTTP.Response)
            # ...and fails on the wire, not because a keyword above stopped being accepted.
            @test !(outcome isa ArgumentError || outcome isa MethodError)
        finally
            close(client)
        end
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "HTTP/1.1 is unaffected, including a request that starts like the preface" begin
    ctx = _h2c_context()
    port = get_free_port()
    _serve(ctx, port)
    try
        @test HTTP.get("http://$HOST:$port/ok"; retry = false).status == 200
        # `POST` shares its first byte with `PRI`: HTTP.jl's probe used to read it and the next
        # byte before handing the connection to HTTP/1.1.
        reply = _raw_exchange(port, "POST /echo HTTP/1.1\r\nHost: $HOST\r\n" *
                                    "Content-Length: 5\r\nConnection: close\r\n\r\nhello")
        @test startswith(reply, "HTTP/1.1 200")
        @test endswith(reply, "hello")
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "a custom handler is refused too" begin
    ctx = _h2c_context()
    port = get_free_port()
    # `serve` wraps every handler in `NitroStreamHandler`, which is what the override keys on.
    _serve(ctx, port; handler = mw -> Nitro.Core.stream_handler(mw), max_body_bytes = nothing)
    try
        @test startswith(_raw_exchange(port, H2_PREFACE), "HTTP/1.1 400")
        @test HTTP.get("http://$HOST:$port/ok"; retry = false).status == 200
    finally
        Nitro.Core.terminate(ctx)
    end
end

end
