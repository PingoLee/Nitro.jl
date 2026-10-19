@testitem "Request cancellation: the token's contract, without a socket (#466)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Base.ScopedValues: @with
using Nitro.Core.Constants: REQUEST_SCOPE, RequestScope
using Nitro.Core: REQUEST_CANCEL_STATE_KEY

@testset "one function for a request and a worker run" begin
    @test Nitro.cancel_reason === Nitro.Workers.cancel_reason
    @test Nitro.cancel_requested === Nitro.Workers.cancel_requested
    # Both modules export it; `using` both must bind it, not leave it ambiguous.
    m = Module(:CancelBoth)
    Core.eval(m, :(using Nitro, Nitro.Workers))
    @test Core.eval(m, :(cancel_reason)) === Nitro.cancel_reason
end

@testset "an internal request has no connection: only :shutdown can fire" begin
    app = App()
    seen = Ref{Any}(nothing)
    urlpatterns(app, "", path("/ask", req -> (seen[] = (cancel_reason(req), cancel_requested(req)); "ok")))
    @test internalrequest(app, HTTP.Request("GET", "/ask")).status == 200
    @test seen[] == (:none, false)
end

@testset "a handler that never asks pays nothing: no state is created" begin
    app = App()
    urlpatterns(app, "", path("/quiet", req -> "ok"), path("/ask", req -> (cancel_requested(req); "ok")))
    quiet = HTTP.Request("GET", "/quiet")
    @test internalrequest(app, quiet).status == 200
    @test !haskey(quiet.context, REQUEST_CANCEL_STATE_KEY)
    # Positive control: the same probe sees the state when the handler asked.
    asked = HTTP.Request("GET", "/ask")
    @test internalrequest(app, asked).status == 200
    @test haskey(asked.context, REQUEST_CANCEL_STATE_KEY)
end

@testset "the run's flag: read through the scope, kept once read, sticky" begin
    flag = Threads.Atomic{Bool}(false)
    scope = RequestScope(nothing, Ref{Int64}(0), flag)
    req = HTTP.Request("GET", "/")
    @test (@with REQUEST_SCOPE => scope cancel_reason(req)) === :none
    flag[] = true
    # Read from OUTSIDE the scope, as a task the handler spawned with `_spawn_detached` would:
    # the flag was captured with the state, on the first call.
    @test cancel_reason(req) === :shutdown
    @test cancel_requested(req)
    flag[] = false
    @test cancel_reason(req) === :shutdown          # a reason never resets
end

@testset "a repeat check allocates nothing" begin
    req = HTTP.Request("GET", "/")
    @testset let a = allocs(() -> cancel_reason(req); calls = 100)
        @test a.count == 0
        @test a.bytes == 0
    end
end
end

@testitem "Request cancellation: a real client, disconnecting or shut down (#466)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Sockets

# The handler announces that it is running, then polls until a reason appears or `limit` passes,
# and reports what it saw. The client waits for the announcement before acting, so the first
# request's compile latency can never make a disconnect look instant.
started  = Channel{Nothing}(Inf)
reported = Channel{Tuple{Symbol, Int}}(Inf)
function poll(req; limit = 20.0)
    put!(started, nothing)
    probes = 0
    t0 = time()
    while time() - t0 < limit
        probes += 1
        reason = cancel_reason(req)
        if reason !== :none
            put!(reported, (reason, probes))
            return Res.send("stopped: $reason")
        end
        sleep(0.005)
    end
    put!(reported, (:none, probes))
    return Res.send("finished")
end
poll_briefly(req) = poll(req; limit = 0.5)

# `timed_out` in place of a value, shaped like one, so a red reads as a failed `@test` rather than
# a destructuring error that skips the rest of the item.
take_within(ch, secs, timed_out = :timed_out) =
    timedwait(() -> isready(ch), secs) === :ok ? take!(ch) : timed_out
const NO_REPORT = (:timed_out, 0)

# Everything up to `marker`. The connection is kept alive, so there is no EOF to read to; a timer
# closes the socket instead, which ends the read with what arrived.
function read_through(sock, marker; limit = 10.0)
    timer = Timer(_ -> close(sock), limit)
    try
        return readuntil(sock, marker; keep = true)
    catch e
        return read_failed(e)
    finally
        close(timer)
    end
end

using Nitro.Core: REQUEST_CANCEL_STATE_KEY, CANCEL_PROBE_INTERVAL_NS

# Between two probes a check reads the state and the clock and does not probe. Measured inside a
# real request, since only a request with a socket gets that far.
throttle = Channel{Any}(Inf)
function throttled(req)
    interval_s = 2 * CANCEL_PROBE_INTERVAL_NS / 1e9
    cancel_reason(req)
    state = req.context[REQUEST_CANCEL_STATE_KEY]
    # A pair counts only if its second call started inside the interval the first one armed: a GC
    # pause or a deschedule between them is not the throttle's failure. Up to five pairs.
    armed = still = zero(UInt64)
    for _ in 1:5
        sleep(interval_s)
        cancel_reason(req)                                     # probes, and arms the interval
        armed = @atomic state.next_probe_ns
        started_at = time_ns()
        cancel_reason(req)
        still = @atomic state.next_probe_ns
        started_at < armed && break
    end
    between = allocs(() -> cancel_reason(req); runs = 3, calls = 10)
    sleep(interval_s)
    cancel_reason(req)
    later = @atomic state.next_probe_ns
    put!(throttle, (; armed, still, between, later))
    return Res.send("ok")
end

# Holds on after it saw the reason, so a drain is still running when the test serves again.
release = Channel{Nothing}(1)
function stubborn(req)
    put!(started, nothing)
    probes = 0
    while (reason = cancel_reason(req)) === :none
        probes += 1
        sleep(0.005)
    end
    put!(reported, (reason, probes))
    take!(release)
    return Res.send("released")
end

asked = Ref{Any}(nothing)
function ask(req)
    asked[] = cancel_reason(req)
    return Res.send("ok")
end

app = App()
urlpatterns(app, "", path("/poll", poll), path("/brief", poll_briefly), path("/throttle", throttled),
            path("/stubborn", stubborn), path("/ask", ask))
port = get_free_port()

function send_get(target; at = port)
    sock = Sockets.connect(HOST, at)
    write(sock, "GET $target HTTP/1.1\r\nHost: x\r\n\r\n")
    return sock
end

try
    serve(app; host = HOST, port, async = true, show_banner = false, access_log = nothing,
          shutdown_timeout = 30)
    @test timedwait(() -> isopen(app.service), 10.0) === :ok

    @testset "the client closes: :client_disconnected" begin
        sock = send_get("/poll")
        @test take_within(started, 30.0) === nothing
        close(sock)
        reason, probes = take_within(reported, 10.0, NO_REPORT)
        @test reason === :client_disconnected
        @test probes >= 1
    end

    @testset "the client resets: :client_disconnected" begin
        sock = send_get("/poll")
        @test take_within(started, 30.0) === nothing
        abort_with_reset!(sock)
        reason, _ = take_within(reported, 10.0, NO_REPORT)
        @test reason === :client_disconnected
    end

    @testset "a client that stays: :none on every probe, and the response arrives" begin
        sock = send_get("/brief")
        try
            @test take_within(started, 30.0) === nothing
            reason, probes = take_within(reported, 10.0, NO_REPORT)
            @test reason === :none
            @test probes > 10                     # many checks, several of them real probes
            reply = read_through(sock, "finished")
            @test startswith(reply, "HTTP/1.1 200")
            @test endswith(reply, "finished")
        finally
            close(sock)
        end
    end

    @testset "between probes a check does not probe, and allocates nothing" begin
        @test HTTP.get("http://$HOST:$port/throttle"; status_exception = false).status == 200
        seen = take_within(throttle, 10.0)
        @test seen isa NamedTuple
        if seen isa NamedTuple
            @test seen.armed > 0
            @test seen.still == seen.armed       # the second check did not probe again
            @test seen.between.count == 0
            @test seen.between.bytes == 0
            @test seen.later > seen.armed         # past the interval, it probed again
        end
    end

    @testset "terminate: :shutdown, and the drain ends long before shutdown_timeout" begin
        sock = send_get("/poll")
        try
            @test take_within(started, 30.0) === nothing
            elapsed = @elapsed terminate(app)
            reason, _ = take_within(reported, 10.0, NO_REPORT)
            @test reason === :shutdown
            # 30 s would mean the handler never saw it and was force-closed at the deadline.
            @test elapsed < 10.0
        finally
            close(sock)
        end
    end

    @testset "a stopped app answers :none again in-process" begin
        asked[] = nothing
        @test internalrequest(app, HTTP.Request("GET", "/ask")).status == 200
        @test asked[] === :none
    end

    # The port is free as soon as the drain begins, so a `serve` admitted mid-drain must start
    # clean while the run being stopped keeps its flag set. One flag cleared at either end of
    # `terminate` would fail one of the two.
    @testset "a serve admitted during a drain starts clean; the draining run stays :shutdown" begin
        port2 = get_free_port()
        serve(app; host = HOST, port = port2, async = true, show_banner = false,
              access_log = nothing, shutdown_timeout = 30)
        @test timedwait(() -> isopen(app.service), 10.0) === :ok
        sock = send_get("/stubborn"; at = port2)
        stopping = nothing
        try
            @test take_within(started, 30.0) === nothing
            stopping = Threads.@spawn terminate(app)
            reason, _ = take_within(reported, 10.0, NO_REPORT)
            @test reason === :shutdown                       # the draining run's handler
            @test timedwait(() -> !isopen(app.service), 10.0) === :ok
            port3 = get_free_port()
            serve(app; host = HOST, port = port3, async = true, show_banner = false,
                  access_log = nothing)
            @test timedwait(() -> isopen(app.service), 10.0) === :ok
            asked[] = nothing
            @test HTTP.get("http://$HOST:$port3/ask"; status_exception = false).status == 200
            @test asked[] === :none                          # the new run's handler
        finally
            isready(release) || put!(release, nothing)
            stopping === nothing || wait(stopping)
            close(sock)
        end
    end
finally
    terminate(app)
end
end
