@testitem "WebSocket" tags=[:handler, :network, :slow] setup=[NitroCommon] begin
using Test
using HTTP
using HTTP.WebSockets
using Nitro

urlpatterns("",
    path("/ws", function(ws::HTTP.WebSocket)
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
    path("/router/ws", function(ws::HTTP.WebSocket)
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
    path("/ws/get", function(ws::HTTP.WebSocket)
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

serve(port=PORT, host=HOST, async=true,  show_errors=false, show_banner=false, access_log=nothing)

@testset "Websocket Tests" begin

    @testset "/ws route" begin
        WebSockets.open("ws://$HOST:$PORT/ws") do ws
            send(ws, "Test message")
            response = receive(ws)
            @test response == "Received message: Test message"
        end
    end

    @testset "/router/ws route" begin
        WebSockets.open("ws://$HOST:$PORT/router/ws") do ws
            send(ws, "Test message")
            response = receive(ws)
            @test response == "Received message: Test message"
        end
    end

    @testset "/ws with arg route" begin
        WebSockets.open("ws://$HOST:$PORT/ws/9") do ws
            send(ws, "Test message")
            response = receive(ws)
            @test response == "Received message from 9: Test message"
        end
    end

    @testset "/ws with route(GET)" begin
        WebSockets.open("ws://$HOST:$PORT/ws/get") do ws
            send(ws, "Test message")
            response = receive(ws)
            @test response == "Received message: Test message"
        end
    end

end

terminate()
println()
end