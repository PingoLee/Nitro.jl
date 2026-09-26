@testitem "WebSocket" tags=[:handler, :network, :slow] setup=[NitroCommon] begin
using Test
using HTTP
using HTTP.WebSockets
using HTTP.WebSockets: send, receive
using Nitro

port = get_free_port()

urlpatterns("",
    path("/ws", function(ws::HTTP.WebSockets.WebSocket)
        try
            for msg in ws
                send(ws, "Received message: $msg")
            end
        catch e
            if !isa(e, HTTP.WebSockets.WebSocketError)
                rethrow(e)
            end
        end
    end, method="WEBSOCKET"),
    path("/router/ws", function(ws::HTTP.WebSockets.WebSocket)
        try
            for msg in ws
                send(ws, "Received message: $msg")
            end
        catch e
            if !isa(e, HTTP.WebSockets.WebSocketError)
                rethrow(e)
            end
        end
    end, method="WEBSOCKET"),
    path("/ws/{x}", function(ws, x::Int)
        try
            for msg in ws
                send(ws, "Received message from $x: $msg")
            end
        catch e
            if !isa(e, HTTP.WebSockets.WebSocketError)
                rethrow(e)
            end
        end
    end, method="WEBSOCKET"),
    # WebSocket handler registered via GET method (detected by first arg type)
    path("/ws/get", function(ws::HTTP.WebSockets.WebSocket)
        try
            for msg in ws
                send(ws, "Received message: $msg")
            end
        catch e
            if !isa(e, HTTP.WebSockets.WebSocketError)
                rethrow(e)
            end
        end
    end, method="GET"),
)

serve(port=port, host=HOST, async=true,  show_errors=false, show_banner=false, access_log=nothing)

@testset "Websocket Tests" begin

    @testset "/ws route" begin
        WebSockets.open("ws://$HOST:$port/ws") do ws
            send(ws, "Test message")
            response = receive(ws)
            @test response == "Received message: Test message"
        end
    end

    @testset "/router/ws route" begin
        WebSockets.open("ws://$HOST:$port/router/ws") do ws
            send(ws, "Test message")
            response = receive(ws)
            @test response == "Received message: Test message"
        end
    end

    @testset "/ws with arg route" begin
        WebSockets.open("ws://$HOST:$port/ws/9") do ws
            send(ws, "Test message")
            response = receive(ws)
            @test response == "Received message from 9: Test message"
        end
    end

    @testset "/ws with route(GET)" begin
        WebSockets.open("ws://$HOST:$port/ws/get") do ws
            send(ws, "Test message")
            response = receive(ws)
            @test response == "Received message: Test message"
        end
    end

end

terminate()
println()
end

@testitem "WebSocket Origin behind a TLS-terminating proxy (#374)" tags=[:handler, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Sockets
using Base.CoreLogging: with_logger
const Logging = Base.CoreLogging   # `Logging` is not a test dependency; the levels live here
using Nitro
using Nitro: path, ExtractIP

# Every server here runs on a private `App`, so none of them touches the global router the
# item above serves; each is terminated in its own `finally`.

# A browser behind a proxy that terminates TLS: the page is https, the proxy reaches Nitro over
# plain TCP from loopback, and it forwards `Host`, `Origin` and the scheme it saw.
const PUBLIC_HOST = "app.example.com"
const WS_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

function _ws_context()
    ctx = Nitro.Core.App()
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/ws", function(ws::HTTP.WebSockets.WebSocket)
            try
                for _ in ws end            # until the client goes away
            catch e
                e isa HTTP.WebSockets.WebSocketError || rethrow()
            end
        end, method = "WEBSOCKET"),
        path("/ok", req -> "ok"),
    ])
    return ctx
end

_serve(ctx, port; kw...) = Nitro.Core.serve(ctx; port, host = HOST, async = true,
                                            show_banner = false, show_errors = false,
                                            access_log = nothing, kw...)

# A raw handshake rather than `WebSockets.open`: the client has to send a `Host` that is not the
# address it connects to, which is exactly what a proxy does. Returns the status line.
function _handshake(port; origin = nothing, proto = nothing)
    lines = ["GET /ws HTTP/1.1", "Host: $PUBLIC_HOST", "Upgrade: websocket",
             "Connection: Upgrade", "Sec-WebSocket-Key: $WS_KEY", "Sec-WebSocket-Version: 13"]
    origin === nothing || push!(lines, "Origin: $origin")
    proto  === nothing || push!(lines, "X-Forwarded-Proto: $proto")
    sock = Sockets.connect(Sockets.localhost, port)
    try
        write(sock, join(lines, "\r\n") * "\r\n\r\n")
        flush(sock)
        reader = @async try readline(sock) catch; "" end
        timedwait(() -> istaskdone(reader), 15.0; pollint = 0.05)
        return istaskdone(reader) ? fetch(reader) : "(no reply within 15s)"
    finally
        close(sock)
    end
end

upgraded(line) = startswith(line, "HTTP/1.1 101")
forbidden(line) = startswith(line, "HTTP/1.1 403")

const TRUSTED   = ExtractIP(forwarded_proto = :x_forwarded_proto, trusted_proxies = [ip"127.0.0.1"])
const UNTRUSTED = ExtractIP(forwarded_proto = :x_forwarded_proto, trusted_proxies = ["10.0.0.0/8"])

@testset "a trusted proxy's scheme decides the same-origin check" begin
    ctx, port = _ws_context(), get_free_port()
    _serve(ctx, port; middleware = [TRUSTED])
    try
        # THE BUG: this was a 403 for every browser behind a TLS-terminating proxy.
        @test upgraded(_handshake(port; origin = "https://$PUBLIC_HOST", proto = "https"))
        # Traefik's spelling on an upgrade.
        @test upgraded(_handshake(port; origin = "https://$PUBLIC_HOST", proto = "wss"))
        # The scheme still has to match once it is known — the reason the fix is not "ignore it".
        @test forbidden(_handshake(port; origin = "http://$PUBLIC_HOST", proto = "https"))
        # And it never admits another site: it only chooses which scheme of OUR host counts.
        @test forbidden(_handshake(port; origin = "https://evil.example", proto = "https"))
        # No report from the proxy: the transport decides, as before.
        @test forbidden(_handshake(port; origin = "https://$PUBLIC_HOST"))
        @test upgraded(_handshake(port; origin = "http://$PUBLIC_HOST"))
        # Scheme-only trust must not break ordinary requests either.
        @test HTTP.get("http://$HOST:$port/ok"; retry = false).status == 200
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "a scheme from an untrusted peer is ignored" begin
    ctx, port = _ws_context(), get_free_port()
    _serve(ctx, port; middleware = [UNTRUSTED])
    try
        @test forbidden(_handshake(port; origin = "https://$PUBLIC_HOST", proto = "https"))
        @test upgraded(_handshake(port; origin = "http://$PUBLIC_HOST", proto = "https"))
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "without ExtractIP, HTTP.jl's transport rule is unchanged" begin
    ctx, port = _ws_context(), get_free_port()
    _serve(ctx, port)
    try
        @test forbidden(_handshake(port; origin = "https://$PUBLIC_HOST", proto = "https"))
        @test upgraded(_handshake(port; origin = "http://$PUBLIC_HOST"))
        @test upgraded(_handshake(port))                  # no Origin: not a browser
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "a refusal is one warning and the real status, never an error with a backtrace" begin
    statuses = Channel{Int}(16)
    record = handle -> req -> begin
        resp = handle(req)
        resp isa HTTP.Response && put!(statuses, resp.status)
        resp
    end
    logger = Test.TestLogger(min_level = Logging.Debug)
    ctx, port = _ws_context(), get_free_port()
    # `show_errors = true`: the setting under which the refusal used to reach `@error`. The server's
    # tasks are spawned inside `with_logger`, so they inherit this logger.
    with_logger(logger) do
        _serve(ctx, port; show_errors = true, middleware = [record])
    end
    refused(r) = r.level == Logging.Debug && r.message == "WebSocket upgrade refused"
    # The server's tasks append under the logger's own lock; read under it too.
    records() = @lock logger.lock copy(logger.logs)
    try
        @test forbidden(_handshake(port; origin = "https://evil.example"))
        @test forbidden(_handshake(port; origin = "https://evil.example"))
        # What a middleware on the way out sees is what the client got — the access log used to
        # record a 500 that was never sent.
        @test timedwait(() -> Base.n_avail(statuses) >= 2, 10.0; pollint = 0.05) === :ok
        @test [take!(statuses) for _ in 1:Base.n_avail(statuses)] == [403, 403]
        # HTTP writes the 403 before it throws, so the client can read it before the log lands.
        @test timedwait(() -> count(refused, records()) >= 2, 10.0; pollint = 0.05) === :ok
        logs = records()
        warns = filter(r -> r.level == Logging.Warn && occursin("WebSocket", string(r.message)), logs)
        @test length(warns) == 1
        @test all(r -> occursin("forwarded_proto", string(r.message)), warns)
        @test !any(r -> r.level >= Logging.Error, logs)
        @test !any(r -> haskey(r.kwargs, :exception), logs)
        details = filter(refused, logs)
        @test !isempty(details) && details[1].kwargs[:status] == 403
        @test !isempty(details) && details[1].kwargs[:origin] == "https://evil.example"
    finally
        Nitro.Core.terminate(ctx)
    end
end

end
