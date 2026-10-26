@testitem "SSE" tags=[:handler, :network, :slow] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App

# Every wait in this file is a bounded `timedwait` whose sentinel is asserted, and NOT the
# `while !eof(io)` loop this file used before #160.
#
# That is not style. An unbounded read against a stream the server never closes hangs the item
# until the runner's 600s watchdog stops the whole run, and every item after it goes unrun (until
# #754 the coverage leg had no such ceiling at all, #244, and hung until GitHub's job limit). A
# hang is a strictly worse outcome than a failure, and an SSE endpoint is the easiest thing in the
# suite to hang on. Pattern follows test/middleware_cache_race_tests.jl.
#
# `sse_callback` is HTTP.jl's public client-side SSE reader: it hands us one parsed `SSEEvent` at a
# time, and `close(stream)` from inside it stops consumption -- which is what lets the client bound
# itself rather than relying on the server to finish.
function collect_sse(url; want::Int, timeout::Real = 20.0, headers = Pair{String,String}[])
    events = HTTP.SSEEvent[]
    response = Ref{Union{Nothing,HTTP.Response}}(nothing)
    failure = Ref{Any}(nothing)
    reader = function (stream, event)
        push!(events, event)
        # Client-side bound: stop as soon as we have what we came for, so a server that keeps
        # producing cannot keep this task alive.
        length(events) >= want && close(stream)
        return nothing
    end
    task = Threads.@spawn begin
        try
            response[] = HTTP.get(url, headers; sse_callback = reader)
        catch err
            failure[] = err
        end
    end
    finished = timedwait(() -> istaskdone(task), Float64(timeout); pollint = 0.05)
    return (; finished, events, response = response[], failure = failure[])
end

# Producers signal their own unwinding through these, so a test can assert that the producer task
# actually finished rather than inferring it from timing.
const PRODUCER_STOPPED = Threads.Atomic{Bool}(false)
const PRODUCER_WROTE = Threads.Atomic{Int}(0)

# ── Handlers, named rather than inlined into `path(...)` ───────────────────────────────────────
# Same reason test/streaming_tests.jl names its stream handlers: a multi-line producer body inside
# a call argument list is awkward to read and does not always parse.

# The ordinary shape: a paced producer that ends by returning.
function ticks(req::HTTP.Request)
    return Res.sse() do events
        for i in 1:3
            isopen(events) || break
            write(events, SSEEvent("tick-$i"; event = "tick", id = string(i)))
        end
    end
end

# FAST PRODUCER (#160). Writes and closes before `serve` has drained a single byte, which is the
# state that used to lose the whole body: `Base.BufferStream` reports `!isopen` the moment it is
# closed while the bytes are still queued, so `_write_response_body!`'s old
# `while !HTTP.body_closed(body)` pre-check never entered the loop and the client got an empty
# stream with a 200. This route is the regression, and it fails on the unpatched writer.
function fast_burst(req::HTTP.Request)
    response = Res.sse()
    events = response.body::HTTP.SSEStream
    write(events, SSEEvent("burst-1"))
    write(events, SSEEvent("burst-2"))
    close(events)
    return response
end

# Caller headers must still win over the builder's defaults.
function nostore(req::HTTP.Request)
    return Res.sse(; headers = ["Cache-Control" => "no-store", "X-Custom" => "1"]) do events
        write(events, SSEEvent("once"))
    end
end

# A producer that throws after emitting. The head is already on the wire, so the status cannot
# change -- the stream just ends, and the server must keep serving.
function boom(req::HTTP.Request)
    return Res.sse() do events
        write(events, SSEEvent("before-the-throw"))
        error("producer exploded")
    end
end

# Never-ending producer, for the disconnect test. It paces itself and checks `isopen`, which is the
# contract `Res.sse`'s docstring tells applications to follow.
function forever(req::HTTP.Request)
    return Res.sse() do events
        try
            while isopen(events)
                write(events, SSEEvent("keepalive"))
                Threads.atomic_add!(PRODUCER_WROTE, 1)
                sleep(0.05)
            end
        finally
            PRODUCER_STOPPED[] = true
        end
    end
end

# HEAD regression (#160). `stream_handler` used to drain the body whenever the handler had not
# started the response itself -- with no check of the request method. For HEAD, HTTP sets
# `ignore_writes`, so `_server_write` returns without touching the socket: the drain then consumes
# the producer's events forever, and because it never touches the socket, `terminate`'s force-close
# cannot unblock it. The request task, the connection task and the producer task are pinned for the
# life of the process, and one `curl -I` is enough to leak a set.
#
# The producer is BOUNDED and PACED, and both matter.
#
# Bounded (`HEAD_EVENTS` iterations, not `while true`) because an open-ended producer reproduces
# the real hang, and a hang stops the whole run at the watchdog's timeout -- a regression would
# take the whole leg down instead of failing one item.
#
# Paced because without a `sleep` the producer can run to completion before `_release_response_body!`
# (which fires in `stream_handler`'s `finally`, after the whole chain unwinds) ever closes the
# stream. Nothing synchronizes those two, so an unpaced producer reaches `HEAD_EVENTS` on the
# GUARDED path too under multithreading -- which would make the pass and fail values overlap and
# the assertion meaningless. At 10ms a tick the release always wins by orders of magnitude, while an
# unguarded drain still needs the full ~2s to consume them all: a slow failure, never a hang.
#
# One set of counters PER ROUTE (#671). They used to be shared, and a case's GET follow-up leaves
# its own producer running until it notices the client hung up -- writing into the same count and
# setting the same "stopped" flag the NEXT case asserts on. A drained body could then pass, because
# the flag it waited for had been set by somebody else's producer.
const HEAD_EVENTS = 200
const PROBES = Dict(route => (wrote = Threads.Atomic{Int}(0), stopped = Threads.Atomic{Bool}(false))
                    for route in ("/events/head", "/events/head-auto", "/events/status/204",
                                  "/events/status/304", "/events/pin"))

function paced_probe(route::String; status::Int = 200, n::Int = HEAD_EVENTS)
    probe = PROBES[route]
    return Res.sse(; status = status) do events
        try
            for _ in 1:n
                isopen(events) || break
                write(events, SSEEvent("x"))
                Threads.atomic_add!(probe.wrote, 1)
                sleep(0.01)
            end
        finally
            probe.stopped[] = true
        end
    end
end

head_probe(req::HTTP.Request) = paced_probe("/events/head")
head_auto_probe(req::HTTP.Request) = paced_probe("/events/head-auto")

# A bodyless STATUS is the same hazard as HEAD (#671). HTTP's `startwrite` sets `ignore_writes` for
# 1xx, 204 and 304 as well, so a drain of these consumes the producer exactly as HEAD's used to --
# and `Res.sse(; status)` hands the status straight to `HTTP.sse_stream`, so nothing stops a handler
# asking for one. 1xx is not exercised over the wire: a client reads it as an interim response and
# waits for the final one. The predicate's agreement with HTTP's rule for every status, 1xx
# included, is pinned in test/http_internals_contract_tests.jl.
status_204(req::HTTP.Request) = paced_probe("/events/status/204"; status = 204)
status_304(req::HTTP.Request) = paced_probe("/events/status/304"; status = 304)

health(req::HTTP.Request) = Res.send("alive")

ctx = App()

urlpatterns(ctx, "", Nitro.RouteDefinition[
    path("/events/ticks", ticks),
    path("/events/fast", fast_burst),
    path("/events/nostore", nostore),
    path("/events/boom", boom),
    path("/events/forever", forever),
    path("/events/head", head_probe, methods = ["GET", "HEAD"]),
    # GET-only: its HEAD is the auto-HEAD (#277), which must not drain the body either.
    path("/events/head-auto", head_auto_probe),
    path("/events/status/204", status_204),
    path("/events/status/304", status_304),
    path("/health", health),
])

port = get_free_port()
localhost = "http://$HOST:$port"

# `Cors` and `SecurityHeaders` are the whole point of the middleware testset below: they add
# headers to the response the chain returns, which is exactly what a `method="STREAM"` handler
# throws away.
serve(ctx; host = HOST, port = port, async = true, show_banner = false, show_errors = false,
      access_log = nothing,
      middleware = [Cors(allowed_origins = ["https://app.example"]), SecurityHeaders()])
@test timedwait(() -> Base.isopen(ctx.service), 10.0) === :ok

try
    @testset "Res.sse streams events and sets the SSE header contract" begin
        got = collect_sse("$localhost/events/ticks"; want = 3)
        @test got.finished === :ok
        @test got.failure === nothing

        resp = got.response
        @test resp !== nothing
        @test resp.status == 200
        @test HTTP.header(resp, "Content-Type") == "text/event-stream"
        @test HTTP.header(resp, "Cache-Control") == "no-cache"
        # Nitro's own addition -- HTTP.jl sets the two above but not this one, and without it nginx
        # buffers the stream and the endpoint looks hung.
        @test HTTP.header(resp, "X-Accel-Buffering") == "no"
        # No length is knowable for a stream, so framing must be chunked and `Content-Length` absent.
        @test HTTP.header(resp, "Transfer-Encoding") == "chunked"
        @test !HTTP.hasheader(resp, "Content-Length")

        @test length(got.events) == 3
        @test [e.data for e in got.events] == ["tick-1", "tick-2", "tick-3"]
        @test [e.event for e in got.events] == ["tick", "tick", "tick"]
        @test [e.id for e in got.events] == ["1", "2", "3"]
    end

    @testset "a producer that closes before the drain begins still delivers (#160)" begin
        # Fails on the unpatched `_write_response_body!`: 200 with zero events.
        got = collect_sse("$localhost/events/fast"; want = 2)
        @test got.finished === :ok
        @test got.failure === nothing
        @test got.response !== nothing && got.response.status == 200
        @test [e.data for e in got.events] == ["burst-1", "burst-2"]
    end

    @testset "middleware applies to an SSE response" begin
        # THE reason `Res.sse` is a response builder rather than a STREAM handler. A STREAM handler
        # sets `response_started`, so `stream_handler` discards the chain's response and every one
        # of these headers silently vanishes -- which is why the pre-#160 version of this file set
        # its CORS headers by hand on the raw stream.
        got = collect_sse("$localhost/events/ticks"; want = 3,
                          headers = ["Origin" => "https://app.example"])
        @test got.finished === :ok
        resp = got.response
        @test resp !== nothing
        @test HTTP.header(resp, "Access-Control-Allow-Origin") == "https://app.example"
        @test HTTP.header(resp, "X-Content-Type-Options") == "nosniff"
        @test HTTP.header(resp, "X-Frame-Options") == "DENY"   # SecurityHeaders() default
        # ... and the SSE contract survived the chain rebuilding the response around the body.
        @test HTTP.header(resp, "Content-Type") == "text/event-stream"
        @test !HTTP.hasheader(resp, "Content-Length")
        @test length(got.events) == 3
    end

    @testset "caller headers override the builder's defaults" begin
        got = collect_sse("$localhost/events/nostore"; want = 1)
        @test got.finished === :ok
        resp = got.response
        @test resp !== nothing
        @test HTTP.header(resp, "Cache-Control") == "no-store"
        @test HTTP.header(resp, "X-Custom") == "1"
        # Not overridden, so still the builder's.
        @test HTTP.header(resp, "Content-Type") == "text/event-stream"
        @test [e.data for e in got.events] == ["once"]
    end

    @testset "a throwing producer ends the stream and leaves the server serving" begin
        # NOTE: this testset deliberately provokes one `Nitro.Res.sse: the event producer failed`
        # @error line in the captured logs. That is the assertion's whole point -- a producer that
        # throws for its own reasons IS an error -- so the line is expected output, not a failure.
        # It is not wrapped in `@test_logs`: the log is emitted on the producer's own task,
        # concurrently with this one, so capturing it would be a race.
        got = collect_sse("$localhost/events/boom"; want = 5)
        @test got.finished === :ok
        # The head went out before the throw, so the status stays 200 and the body is simply short.
        @test got.response !== nothing && got.response.status == 200
        @test [e.data for e in got.events] == ["before-the-throw"]

        # The process is still healthy -- a failed producer must not take the server with it.
        @test HTTP.get("$localhost/health").status == 200
    end

    @testset "a client disconnect stops the producer" begin
        PRODUCER_STOPPED[] = false
        PRODUCER_WROTE[] = 0

        got = collect_sse("$localhost/events/forever"; want = 2)
        @test got.finished === :ok
        @test length(got.events) == 2

        # The client hung up. `isopen(events)` going false (or the next `write` throwing) is what
        # the producer is supposed to notice, and its `finally` is what proves it unwound rather
        # than leaking a task that writes into a dead socket for the life of the process.
        @test timedwait(() -> PRODUCER_STOPPED[], 15.0; pollint = 0.05) === :ok
        # Loose on purpose: the point is "stopped", not a write count. Timing is only ever used
        # here to separate "unwound" from "did not unwind".
        @test PRODUCER_WROTE[] >= 2

        @test HTTP.get("$localhost/health").status == 200
    end
    # Explicit HEAD route, then the auto-HEAD of a GET-only route (#277), then a GET whose STATUS
    # forbids a body (#671). Each route counts into its own `PROBES` entry.
    @testset "a bodyless response does not drain an SSE body (#160, #671): $method $route" for (method, route, status) in (
            ("HEAD", "/events/head", 200),
            ("HEAD", "/events/head-auto", 200),
            ("GET", "/events/status/204", 204),
            ("GET", "/events/status/304", 304))
        probe = PROBES[route]
        probe.wrote[] = 0
        probe.stopped[] = false

        # Response and error land in `Ref`s rather than being `fetch`ed, for the same reason
        # `collect_sse` does it: a `fetch` after a failed `timedwait` is an UNBOUNDED wait, which
        # is precisely what this file's header forbids. On a regression the assertions fail and
        # the item finishes; it never parks.
        resp = Ref{Union{Nothing,HTTP.Response}}(nothing)
        failure = Ref{Any}(nothing)
        # `request_timeout`, not `readtimeout`: the latter is deprecated in HTTP 2.7 (it warns and
        # maps to `read_idle_timeout`), and an INACTIVITY timeout never fires against a server that
        # is steadily streaming -- which is the exact failure this test guards.
        task = Threads.@spawn begin
            try
                resp[] = HTTP.request(method, "$localhost$route"; request_timeout = 15,
                                      retry = false, status_exception = false)
            catch err
                failure[] = err
            end
        end
        @test timedwait(() -> istaskdone(task), 25.0; pollint = 0.05) === :ok
        @test failure[] === nothing

        r = resp[]
        @test r !== nothing
        if r !== nothing
            @test r.status == status
            @test isempty(r.body)
            # `Res.sse` declares no length, so HEAD must not invent one.
            @test !HTTP.hasheader(r, "Content-Length")
            method == "HEAD" && @test HTTP.header(r, "Content-Type") == "text/event-stream"
        end

        # The heart of it: the body was RELEASED, not consumed. `_release_response_body!` closes
        # the stream, the producer's `isopen` check fails, and it unwinds almost immediately.
        # Against the unguarded handler the drain consumes every event, so this reads HEAD_EVENTS
        # -- a value the guarded path cannot reach, because the producer is paced.
        #
        # "Almost immediately" is not "before `HTTP.head` returns" (#287): the client returns on the
        # response head, while the producer only notices the closed stream on its next `isopen`
        # check, up to one 10ms tick later. Read once, the flag lost that race on loaded CI runners.
        # Wait for it with a bound, as the PRODUCER_STOPPED check above does. A drained body still
        # fails, on the count below, which the wait also makes final.
        @test timedwait(() -> probe.stopped[], 5.0; pollint = 0.01) === :ok
        @test probe.wrote[] < HEAD_EVENTS

        # And a HEAD route still streams normally over GET, so the guard is scoped to what makes a
        # response bodyless -- the method or the status -- and not to the route.
        if method == "HEAD"
            got = collect_sse("$localhost$route"; want = 3)
            @test got.finished === :ok
            @test length(got.events) == 3
        end

        @test HTTP.get("$localhost/health").status == 200
    end
finally
    terminate(ctx)
end

# What the pin costs at shutdown (#160, #671). A drain HTTP is ignoring never touches the socket, so
# the connection task waits on it, the graceful close cannot finish, and `terminate` falls through
# to its force-close -- which cannot unblock it either, so the producer outlives the server.
# `terminate` itself is bounded by `shutdown_timeout` whatever happens, so "does not hang" is
# asserted as what it actually means: the graceful drain finishes and no force-close is needed.
#
# The producer is bounded at 30s of pacing -- far past every wait here, so an unguarded drain is
# still running when they expire, yet a regression is a slow failure, never a hang.
pin_probe(req::HTTP.Request) = paced_probe("/events/pin"; status = 204, n = 3000)

@testset "a bodyless SSE response leaves terminate a graceful drain (#671)" begin
    probe = PROBES["/events/pin"]
    probe.stopped[] = false
    pin_app = App()
    urlpatterns(pin_app, "", Nitro.RouteDefinition[path("/events/pin", pin_probe)])
    pin_port = get_free_port()
    serve(pin_app; host = HOST, port = pin_port, async = true, show_banner = false,
          show_errors = false, access_log = nothing, shutdown_timeout = 5)
    @test timedwait(() -> Base.isopen(pin_app.service), 10.0) === :ok

    stopping = nothing
    logger = Test.TestLogger(min_level = Base.CoreLogging.Warn)
    try
        # `Ref`s and a bounded `timedwait`, as everywhere in this file -- never a bare request.
        resp = Ref{Union{Nothing,HTTP.Response}}(nothing)
        failure = Ref{Any}(nothing)
        task = Threads.@spawn begin
            try
                resp[] = HTTP.get("http://$HOST:$pin_port/events/pin"; request_timeout = 15,
                                  retry = false, status_exception = false)
            catch err
                failure[] = err
            end
        end
        @test timedwait(() -> istaskdone(task), 25.0; pollint = 0.05) === :ok
        @test failure[] === nothing
        @test resp[] !== nothing && resp[].status == 204
        @test timedwait(() -> probe.stopped[], 5.0; pollint = 0.01) === :ok
    finally
        # Spawned and waited on with a bound, so a `terminate` that did block could not park the item.
        stopping = Threads.@spawn Base.CoreLogging.with_logger(() -> terminate(pin_app), logger)
        @test timedwait(() -> istaskdone(stopping), 20.0; pollint = 0.05) === :ok
    end
    forced = lock(logger.lock) do
        any(rec -> occursin("did not drain", string(rec.message)), logger.logs)
    end
    @test !forced
end

end
