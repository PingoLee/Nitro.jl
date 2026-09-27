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

@testitem "A request to a WebSocket route that is not an upgrade is 426 or 400, never 200 (#384)" tags=[:handler, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Sockets
using Base.CoreLogging: with_logger
const Logging = Base.CoreLogging   # `Logging` is not a test dependency; the levels live here
using Nitro
using Nitro: path

const WS_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

function _ws_context()
    ctx = Nitro.Core.App()
    handler = function (ws::HTTP.WebSockets.WebSocket)
        try
            for _ in ws end
        catch e
            e isa HTTP.WebSockets.WebSocketError || rethrow()
        end
    end
    Nitro.Core.Routing.urlpatterns(ctx, "", Nitro.RouteDefinition[
        path("/ws", handler, method = "WEBSOCKET"),
        # Detected by the handler's first argument, not by the declared method.
        path("/ws/get", handler, method = "GET"),
        # A `"*"` route whose handler takes a `WebSocket` receives every method.
        path("/ws/any", handler, method = "*"),
    ])
    return ctx
end

# A raw request, so each handshake header can be left out on purpose. Returns the status and the
# response headers (lowercased names), read up to the blank line that ends the head.
function _raw(port; target = "/ws", method = "GET", upgrade = "websocket", connection = "Upgrade",
              key = WS_KEY, version = "13")
    lines = ["$method $target HTTP/1.1", "Host: $HOST:$port"]
    upgrade    === nothing || push!(lines, "Upgrade: $upgrade")
    connection === nothing || push!(lines, "Connection: $connection")
    key        === nothing || push!(lines, "Sec-WebSocket-Key: $key")
    version    === nothing || push!(lines, "Sec-WebSocket-Version: $version")
    sock = Sockets.connect(Sockets.localhost, port)
    try
        write(sock, join(lines, "\r\n") * "\r\n\r\n")
        flush(sock)
        reader = @async try
            head = String[]
            while true
                line = readline(sock)
                isempty(line) && break
                push!(head, line)
            end
            head
        catch
            String[]
        end
        timedwait(() -> istaskdone(reader), 15.0; pollint = 0.05)
        head = istaskdone(reader) ? fetch(reader) : String[]
        isempty(head) && return (0, Dict{String,String}())
        status = parse(Int, split(head[1])[2])
        headers = Dict(lowercase(strip(k)) => strip(v)
                       for (k, v) in (split(h, ':'; limit = 2) for h in head[2:end]))
        return (status, headers)
    finally
        close(sock)
    end
end

@testset "426, 400 and 101 on the wire" begin
    statuses = Channel{Int}(32)
    record = handle -> req -> begin
        resp = handle(req)
        resp isa HTTP.Response && put!(statuses, resp.status)
        resp
    end
    logger = Test.TestLogger(min_level = Logging.Debug)
    ctx, port = _ws_context(), get_free_port()
    with_logger(logger) do
        Nitro.Core.serve(ctx; port, host = HOST, async = true, show_banner = false,
                         show_errors = true, access_log = nothing, middleware = [record])
    end
    records() = @lock logger.lock copy(logger.logs)
    try
        # THE BUG: a plain GET was `200 "false"`. Both route shapes, through the real client.
        for target in ("/ws", "/ws/get")
            r = HTTP.get("http://$HOST:$port$target"; status_exception = false, retry = false)
            @test r.status == 426
            @test HTTP.header(r, "Upgrade") == "websocket"
            @test HTTP.headercontains(r, "Connection", "upgrade")
            @test String(r.body) != "false"
        end

        # `Upgrade` without `Connection: upgrade` — nginx without `Connection "upgrade"` — is not
        # an upgrade request at all (RFC 9110 §7.8), so it is the proxy case, not a malformed one.
        status, headers = _raw(port; connection = nothing)
        @test status == 426
        @test get(headers, "upgrade", "") == "websocket"
        @test first(_raw(port; upgrade = nothing)) == 426
        @test first(_raw(port; connection = "keep-alive")) == 426

        # A version this server does not speak: 426 naming the one it does (RFC 6455 §4.4).
        status, headers = _raw(port; version = "8")
        @test status == 426
        @test get(headers, "sec-websocket-version", "") == "13"

        # An upgrade that is declared but malformed: 400.
        @test first(_raw(port; key = nothing)) == 400
        @test first(_raw(port; key = "not-a-key")) == 400
        @test first(_raw(port; version = nothing)) == 400
        @test first(_raw(port; version = "")) == 400
        # A declared upgrade on another method is malformed (only GET upgrades); a POST that does
        # not ask to upgrade is the ordinary 426.
        @test first(_raw(port; target = "/ws/any", method = "POST")) == 400
        # ... even with a version that would earn a GET the 426: only GET upgrades.
        @test first(_raw(port; target = "/ws/any", method = "POST", version = "8")) == 400
        @test first(_raw(port; target = "/ws/any", method = "POST", upgrade = nothing)) == 426

        # Header tokens are case-insensitive, and a valid handshake still upgrades.
        @test first(_raw(port; upgrade = "WebSocket", connection = "keep-alive, Upgrade")) == 101
        @test first(_raw(port)) == 101

        # What a middleware on the way out sees is what the client got. (The two 101s are not
        # counted: a finished session reaches it as the serializer's placeholder, see streaming.md.)
        @test timedwait(() -> Base.n_avail(statuses) >= 13, 10.0; pollint = 0.05) === :ok
        seen = [take!(statuses) for _ in 1:Base.n_avail(statuses)]
        @test count(==(426), seen) == 7
        @test count(==(400), seen) == 6

        # One first-sighting warning per case, detail at debug level, never an error.
        logs = records()
        warns = filter(r -> r.level == Logging.Warn && occursin("WebSocket", string(r.message)), logs)
        @test length(warns) == 3
        @test any(r -> occursin("Connection: upgrade", string(r.message)), warns)
        @test !any(r -> r.level >= Logging.Error, logs)
        @test !any(r -> haskey(r.kwargs, :exception), logs)
        details = filter(r -> r.level == Logging.Debug && r.message == "WebSocket upgrade refused", logs)
        @test sort(unique([d.kwargs[:status] for d in details])) == [400, 426]
    finally
        Nitro.Core.terminate(ctx)
    end
end

@testset "in-process, with no stream at all" begin
    ctx = _ws_context()
    for target in ("/ws", "/ws/get")
        resp = Nitro.Core.internalrequest(ctx, HTTP.Request("GET", target))
        @test resp.status == 426
        @test HTTP.header(resp, "Upgrade") == "websocket"
    end
end

end
