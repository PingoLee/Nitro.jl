@testitem "Request cancellation: the token's contract, without a socket (#466)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Base.ScopedValues: @with
using Nitro.Core.Constants: REQUEST_SCOPE, RequestScope, ShutdownSignal, signal_shutdown!
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
    # The run's signal is a `ShutdownSignal` since #815 (a bare `Atomic{Bool}` before).
    flag = ShutdownSignal()
    scope = RequestScope(nothing, Ref{Int64}(0), flag)
    req = HTTP.Request("GET", "/")
    @test (@with REQUEST_SCOPE => scope cancel_reason(req)) === :none
    signal_shutdown!(flag)
    # Read from OUTSIDE the scope, as a task the handler spawned with `_spawn_detached` would:
    # the flag was captured with the state, on the first call.
    @test cancel_reason(req) === :shutdown
    @test cancel_requested(req)
    # A signal has no reset; clear the field by hand to show the REASON does not follow it.
    @atomic flag.set = false
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

    # The port is free as soon as the drain begins, but a `serve` of the same app is refused
    # until `terminate` returns (#812), and the run after it starts clean. The draining run keeps
    # its own flag set throughout: one flag cleared at either end of `terminate` would fail one
    # of the two halves.
    @testset "a serve during a drain is refused; the next run starts clean (#812)" begin
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
            @test_throws ArgumentError serve(app; host = HOST, port = get_free_port(),
                                             async = true, show_banner = false,
                                             access_log = nothing)
            @test !istaskdone(stopping)                      # still inside the drain
        finally
            isready(release) || put!(release, nothing)
            stopping === nothing || wait(stopping)
            close(sock)
        end
        port3 = get_free_port()
        serve(app; host = HOST, port = port3, async = true, show_banner = false,
              access_log = nothing)
        @test timedwait(() -> isopen(app.service), 10.0) === :ok
        asked[] = nothing
        @test HTTP.get("http://$HOST:$port3/ask"; status_exception = false).status == 200
        @test asked[] === :none                              # the new run's handler
    end
finally
    terminate(app)
end
end

@testitem "Request cancellation: the deadline and the token, without a socket (#661, #662)" tags=[:core] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Base.CoreLogging: with_logger, Debug
using Test: TestLogger
using Nitro.Core: REQUEST_CANCEL_STATE_KEY, _CancelState, _deadline_returned!, _serve_listener,
                  _handler_timeout_ns, setupmiddleware, stream_handler, DEFAULT_MAX_BODY_BYTES
using Nitro.Core.Constants: ShutdownSignal, NEVER_SHUTTING_DOWN, signal_shutdown!

@testset "handler_timeout is refused before anything is mutated" begin
    app = App()
    urlpatterns(app, "", path("/", req -> "ok"))
    for bad in (0, -1, 0.0, NaN, Inf, true, "1", 1e10)
        @test_throws ArgumentError serve(app; port = get_free_port(), async = true,
                                         show_banner = false, access_log = nothing,
                                         handler_timeout = bad)
        @test !isopen(app.service)
    end
    custom = pipeline -> (stream -> nothing)
    @test_throws ArgumentError serve(app; port = get_free_port(), async = true, show_banner = false,
                                     access_log = nothing, handler = custom, handler_timeout = 1)
    @test !isopen(app.service)
    @test _handler_timeout_ns(nothing) == 0
    @test _handler_timeout_ns(1.5) == 1_500_000_000
    @test _handler_timeout_ns(1e-12) == 1            # never rounds down to "off"
end

@testset "the listener's type does not depend on the deadline" begin
    # So a server with a deadline runs the code the precompile workload compiled, and the unset
    # case captures the same two fields, an `Int64` and a `ShutdownSignal`, it only branches on.
    app = App()
    pipeline = setupmiddleware(app)
    off = first(_serve_listener(pipeline, stream_handler, DEFAULT_MAX_BODY_BYTES, 0, 0, nothing))
    on = first(_serve_listener(pipeline, stream_handler, DEFAULT_MAX_BODY_BYTES, 0, 0, nothing,
                               Int64(5_000_000_000), ShutdownSignal()))
    @test typeof(off) === typeof(on)
end

@testset "a token reads the request's causes, then :completed; the request never does" begin
    app = App()
    kept = Ref{Any}(nothing)
    urlpatterns(app, "",
        path("/keep", req -> (kept[] = (req, cancel_token(req)); "ok")),
        path("/nested", req -> (kept[] = (req, cancel_token(req));
                                (cancel_reason(kept[][2]), cancel_requested(kept[][2])))))
    @test internalrequest(app, HTTP.Request("GET", "/keep")).status == 200
    req, token = kept[]
    @test token isa _CancelState
    @test cancel_token(req) === token                 # one token per request
    @test cancel_reason(token) === :completed
    @test cancel_requested(token)
    @test cancel_reason(req) === :none                # Go's footgun stays off the request
    @test !cancel_requested(req)
    # While the handler runs, the token reads the request's view: `:none`, not `:completed`.
    resp = internalrequest(app, HTTP.Request("GET", "/nested"))
    @test String(resp.body) == "[\"none\",false]"
end

@testset "a request object run again gets a fresh token; the old one stays :completed" begin
    app = App()
    seen = Ref{Any}(nothing)
    urlpatterns(app, "", path("/again", req -> (t = cancel_token(req); seen[] = (t, cancel_reason(t)); "ok")))
    req = HTTP.Request("GET", "/again")
    @test internalrequest(app, req).status == 200
    first_token, during_first = seen[]
    @test during_first === :none
    @test cancel_reason(first_token) === :completed
    @test internalrequest(app, req).status == 200
    second_token, during_second = seen[]
    @test second_token !== first_token
    @test during_second === :none                     # not the previous run's :completed
    @test cancel_reason(first_token) === :completed
end

@testset "a cause that came before the end keeps reading; nothing settles after it" begin
    flag = ShutdownSignal()
    early = _CancelState(flag, nothing)
    signal_shutdown!(flag)
    @test cancel_reason(early) === :shutdown          # settled while the request was live
    Nitro.Core._mark_ended!(early)
    @test cancel_reason(early) === :shutdown          # first cause wins over :completed

    flag2 = ShutdownSignal()
    late = _CancelState(flag2, nothing)
    Nitro.Core._mark_ended!(late)
    signal_shutdown!(flag2)
    @test cancel_reason(late) === :completed          # the end came first
    @test Nitro.Core._request_reason(late) === :none  # and the request's view adds nothing after it
end

@testset "the deadline: :timeout once passed, first cause wins, disarmed when the handler returns" begin
    past = _CancelState(NEVER_SHUTTING_DOWN, nothing, time_ns() - UInt64(1))
    @test cancel_reason(past) === :timeout
    flag = ShutdownSignal()
    first_ = _CancelState(flag, nothing, time_ns() + UInt64(3_600_000_000_000))
    signal_shutdown!(flag)
    @test cancel_reason(first_) === :shutdown
    @atomic first_.deadline_ns = time_ns() - UInt64(1)
    @test cancel_reason(first_) === :shutdown         # the deadline came second
    future = _CancelState(NEVER_SHUTTING_DOWN, nothing, time_ns() + UInt64(3_600_000_000_000))
    @test cancel_reason(future) === :none
    @test Nitro.Core._disarm_deadline!(future) != 0
    @test (@atomic future.deadline_ns) == 0
end

@testset "a late return is logged at debug with the route pattern and the overrun" begin
    logger = TestLogger(min_level = Debug)
    req = HTTP.Request("GET", "/reports/7?token=secret-in-query")
    req.context[:route] = "/reports/{id}"
    state = _CancelState(NEVER_SHUTTING_DOWN, nothing, time_ns() - UInt64(250_000_000))
    with_logger(logger) do
        _deadline_returned!(state, req)
    end
    on_time = _CancelState(NEVER_SHUTTING_DOWN, nothing, time_ns() + UInt64(3_600_000_000_000))
    with_logger(logger) do
        _deadline_returned!(on_time, req)
    end
    records = lock(() -> copy(logger.logs), logger.lock)
    late = filter(r -> occursin("after its deadline", string(r.message)), records)
    @test length(late) == 1                           # the on-time return logs nothing
    if length(late) == 1
        rec = late[1]
        @test rec.level == Debug
        @test rec.kwargs[:route] == "/reports/{id}"
        @test rec.kwargs[:overrun_ms] >= 250
        # The target, query included, never reaches the record.
        @test !any(v -> occursin("secret-in-query", string(v)), values(rec.kwargs))
    end
    @test (@atomic state.deadline_ns) == 0            # disarmed either way
end

@testset "a repeat token check allocates nothing" begin
    token = _CancelState(NEVER_SHUTTING_DOWN, nothing, time_ns() + UInt64(3_600_000_000_000))
    @testset let a = allocs(() -> cancel_reason(token); calls = 100)
        @test a.count == 0
        @test a.bytes == 0
    end
end
end

@testitem "Request cancellation: a real client, the deadline and the token (#661, #662)" tags=[:core, :network] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
using Sockets
using Nitro.Core: REQUEST_CANCEL_STATE_KEY

take_within(ch, secs, timed_out = :timed_out) =
    timedwait(() -> isready(ch), secs) === :ok ? take!(ch) : timed_out

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

const TIMEOUT_S = 0.5

# Whether the handler's request carried a cancellation state before it asked for one.
armed = Channel{Tuple{Bool, UInt64}}(Inf)
function peek_state(req)
    st = Base.get(req.context, REQUEST_CANCEL_STATE_KEY, nothing)
    put!(armed, st === nothing ? (false, zero(UInt64)) : (true, @atomic st.deadline_ns))
    return Res.send("ok")
end

# The #898 shape: count in bursts of about 1 ms, yield between them, check the request. The counter
# shows the handler executing; a 10 s bound of its own ends it if the deadline never fires.
mutable struct Burst
    @atomic count::Int
    @atomic thread::Int
end
burst = Burst(0, 0)
started = Channel{Nothing}(Inf)
reported = Channel{Tuple{Symbol, Float64}}(Inf)
function bursts(req)
    put!(started, nothing)
    t0 = time()
    bound = time_ns() + 10_000_000_000
    reason = :none
    while time_ns() < bound
        @atomic burst.thread = Threads.threadid()
        stop = time_ns() + 1_000_000
        while time_ns() < stop
            @atomic burst.count += 1
        end
        yield()
        (reason = cancel_reason(req)) === :none || break
    end
    put!(reported, (reason, time() - t0))
    return Res.send("stopped: $reason")
end

# Ignores every check, returns after its deadline: the body must still arrive.
late(req) = (sleep(TIMEOUT_S + 0.4); Res.send("late body"))

# A spawned task holds the token; the handler parks on the task and never touches `req` meanwhile.
spawned_saw = Channel{Symbol}(Inf)
function spawner(req)
    token = cancel_token(req)
    put!(started, nothing)
    t = Threads.@spawn begin
        t0 = time()
        r = :none
        while time() - t0 < 20.0
            (r = cancel_reason(token)) === :none || break
            sleep(0.005)
        end
        r
    end
    put!(spawned_saw, fetch(t))
    return Res.send("done")
end

kept = Ref{Any}(nothing)
keep(req) = (kept[] = (req, cancel_token(req)); Res.send("kept"))

# Sees the deadline, then holds on through a `terminate`: the reason must stay `:timeout`.
release = Channel{Nothing}(1)
after_terminate = Channel{Symbol}(Inf)
function stubborn(req)
    while cancel_reason(req) === :none
        sleep(0.005)
    end
    put!(reported, (cancel_reason(req), 0.0))
    take!(release)
    put!(after_terminate, cancel_reason(req))
    return Res.send("released")
end

routes = (path("/peek", peek_state), path("/bursts", bursts), path("/late", late),
          path("/spawn", spawner), path("/keep", keep), path("/stubborn", stubborn))

function send_get(target, port)
    sock = Sockets.connect(HOST, port)
    write(sock, "GET $target HTTP/1.1\r\nHost: x\r\n\r\n")
    return sock
end

@testset "without handler_timeout nothing is written to the request" begin
    app = App()
    urlpatterns(app, "", routes...)
    port = get_free_port()
    try
        serve(app; host = HOST, port, async = true, show_banner = false, access_log = nothing)
        @test timedwait(() -> isopen(app.service), 10.0) === :ok
        @test HTTP.get("http://$HOST:$port/peek"; status_exception = false).status == 200
        @test take_within(armed, 10.0) == (false, zero(UInt64))

        # Here rather than under the deadline below, so the time a disconnect takes to be seen
        # (the first run compiles the spawned closure, at `-O0` on CI) can never read `:timeout`.
        @testset "a spawned task sees the client leave through the token" begin
            sock = send_get("/spawn", port)
            @test take_within(started, 30.0) === nothing
            close(sock)
            @test take_within(spawned_saw, 15.0) === :client_disconnected
        end
    finally
        terminate(app)
    end
end

# A WebSocket's handler runs for the socket's life, and HTTP.jl closes the stream's write side
# before calling it. It must still see `:shutdown`, never the deadline, and its token must not read
# `:completed` while it runs.
ws_started = Channel{Nothing}(Inf)
ws_mid = Channel{Tuple{Symbol, Symbol}}(Inf)
ws_end = Channel{Symbol}(Inf)
function ws_handler(ws::HTTP.WebSockets.WebSocket; request)
    token = cancel_token(request)
    put!(ws_started, nothing)
    sleep(TIMEOUT_S + 0.3)                           # past the deadline
    put!(ws_mid, (cancel_reason(request), cancel_reason(token)))
    t0 = time()
    reason = :none
    while time() - t0 < 20.0
        (reason = cancel_reason(request)) === :none || break
        sleep(0.005)
    end
    put!(ws_end, reason)
    return nothing
end

# Runs until the client closes: the request ends with the socket, so a held token reads :completed.
ws_token = Channel{Any}(Inf)
function ws_until_closed(ws::HTTP.WebSockets.WebSocket; request)
    put!(ws_token, cancel_token(request))
    try
        for _ in ws
        end
    catch
    end
    return nothing
end

@testset "a WebSocket: no deadline, no :completed while open, :shutdown at terminate" begin
    wsapp = App()
    urlpatterns(wsapp, "", path("/ws", ws_handler, method = "WEBSOCKET"),
                path("/ws/closes", ws_until_closed, method = "WEBSOCKET"))
    wsport = get_free_port()
    client = nothing
    stopping = nothing
    try
        serve(wsapp; host = HOST, port = wsport, async = true, show_banner = false,
              access_log = nothing, handler_timeout = TIMEOUT_S, shutdown_timeout = 30)
        @test timedwait(() -> isopen(wsapp.service), 10.0) === :ok

        # The socket's end is the request's: the token reads :completed once the client closed.
        HTTP.WebSockets.open(ws -> nothing, "ws://$HOST:$wsport/ws/closes")
        token = take_within(ws_token, 30.0)
        @test token !== :timed_out
        if token !== :timed_out
            @test timedwait(() -> cancel_reason(token) === :completed, 10.0) === :ok
        end

        client = Threads.@spawn try
            HTTP.WebSockets.open("ws://$HOST:$wsport/ws") do ws
                try
                    HTTP.WebSockets.receive(ws)
                catch
                end
            end
        catch
        end
        @test take_within(ws_started, 30.0) === nothing
        @test take_within(ws_mid, 10.0, (:timed_out, :timed_out)) === (:none, :none)
        stopping = Threads.@spawn terminate(wsapp)
        @test take_within(ws_end, 15.0) === :shutdown
    finally
        stopping === nothing || wait(stopping)
        terminate(wsapp)
        client === nothing || timedwait(() -> istaskdone(client), 10.0)
    end
end

app = App()
urlpatterns(app, "", routes...)
port = get_free_port()
try
    serve(app; host = HOST, port, async = true, show_banner = false, access_log = nothing,
          handler_timeout = TIMEOUT_S, shutdown_timeout = 30)
    @test timedwait(() -> isopen(app.service), 10.0) === :ok

    @testset "with it, the state is there before the handler asks, deadline armed" begin
        before = time_ns()
        @test HTTP.get("http://$HOST:$port/peek"; status_exception = false).status == 200
        has, deadline = take_within(armed, 10.0, (false, zero(UInt64)))
        @test has
        # Stamped for this request, `handler_timeout` after a clock read that came after `before`.
        @test deadline >= before + UInt64(round(Int, TIMEOUT_S * 1e9))
        @test deadline <= time_ns() + UInt64(round(Int, TIMEOUT_S * 1e9))
    end

    @testset "the deadline fires in a handler that computes in bounded bursts" begin
        sock = send_get("/bursts", port)
        try
            @test take_within(started, 30.0) === nothing
            if Threads.nthreads(:default) >= 2
                # Executing, not parked: the test task holds its own thread without yielding and
                # watches the counter move, so the handler is running on another one.
                c0 = @atomic burst.count
                stop = time_ns() + 2_000_000_000
                moved = false
                while time_ns() < stop
                    (@atomic burst.count) > c0 && (moved = true; break)
                    GC.safepoint()
                end
                @test moved
                @test (@atomic burst.thread) != Threads.threadid()
            end
            reason, elapsed = take_within(reported, 15.0, (:timed_out, 0.0))
            @test reason === :timeout
            # The clock started at the head, before the handler: never late by much, never early
            # past the head-to-handler gap.
            @test elapsed < TIMEOUT_S + 5.0
            reply = read_through(sock, "stopped: timeout")
            @test startswith(reply, "HTTP/1.1 200")
            @test endswith(reply, "stopped: timeout")
        finally
            close(sock)
        end
    end

    @testset "a handler that returns after its deadline still has its response written" begin
        r = HTTP.get("http://$HOST:$port/late"; status_exception = false)
        @test r.status == 200
        @test String(r.body) == "late body"
    end

    @testset "the token reads :completed after the response; the request reads :none" begin
        kept[] = nothing
        @test HTTP.get("http://$HOST:$port/keep"; status_exception = false).status == 200
        @test kept[] !== nothing
        if kept[] !== nothing
            req, token = kept[]
            @test timedwait(() -> cancel_reason(token) === :completed, 5.0) === :ok
            # Past the deadline too: the handler returned, so the deadline was disarmed.
            sleep(TIMEOUT_S + 0.1)
            @test cancel_reason(token) === :completed
            @test cancel_reason(req) === :none
        end
    end

    @testset "first cause wins: a deadline, then terminate, stays :timeout" begin
        sock = send_get("/stubborn", port)
        stopping = nothing
        try
            reason, _ = take_within(reported, 15.0, (:timed_out, 0.0))
            @test reason === :timeout
            stopping = Threads.@spawn terminate(app)
            @test timedwait(() -> !isopen(app.service), 10.0) === :ok
            put!(release, nothing)
            @test take_within(after_terminate, 10.0) === :timeout
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
