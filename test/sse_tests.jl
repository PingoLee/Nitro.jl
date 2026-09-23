@testitem "SSE" tags=[:handler, :network, :slow] setup=[NitroCommon] begin
using Test
using HTTP
using Nitro
import Nitro: App

# Every wait in this file is a bounded `timedwait` whose sentinel is asserted, and NOT the
# `while !eof(io)` loop this file used before #160.
#
# That is not style. CI runs the suite under coverage, which forces ReTestItems to `nworkers = 0`,
# which makes `testitem_timeout` inert (#244) -- so an unbounded read against a stream the server
# never closes hangs the CI leg until GitHub's job ceiling instead of failing at 600s. A hang is a
# strictly worse outcome than a failure, and an SSE endpoint is the easiest thing in the suite to
# hang on. Pattern follows test/middleware_cache_race_tests.jl.
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
# the real hang, and under CI coverage `nworkers = 0` makes `testitem_timeout` inert (#244) -- a
# regression would take the whole leg down instead of failing.
#
# Paced because without a `sleep` the producer can run to completion before `_release_response_body!`
# (which fires in `stream_handler`'s `finally`, after the whole chain unwinds) ever closes the
# stream. Nothing synchronizes those two, so an unpaced producer reaches `HEAD_EVENTS` on the
# GUARDED path too under multithreading -- which would make the pass and fail values overlap and
# the assertion meaningless. At 10ms a tick the release always wins by orders of magnitude, while an
# unguarded drain still needs the full ~2s to consume them all: a slow failure, never a hang.
const HEAD_EVENTS = 200
const HEAD_WROTE = Threads.Atomic{Int}(0)
const HEAD_STOPPED = Threads.Atomic{Bool}(false)

function head_probe(req::HTTP.Request)
    return Res.sse() do events
        try
            for _ in 1:HEAD_EVENTS
                isopen(events) || break
                write(events, SSEEvent("x"))
                Threads.atomic_add!(HEAD_WROTE, 1)
                sleep(0.01)
            end
        finally
            HEAD_STOPPED[] = true
        end
    end
end

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
    path("/events/head-auto", head_probe),
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
    # Explicit HEAD route, then the auto-HEAD of a GET-only route (#277). One at a time: they
    # share the probe's counters.
    @testset "HEAD does not drain an SSE body (#160): $route" for route in ("/events/head", "/events/head-auto")
        HEAD_WROTE[] = 0
        HEAD_STOPPED[] = false

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
                resp[] = HTTP.head("$localhost$route"; request_timeout = 15, retry = false)
            catch err
                failure[] = err
            end
        end
        @test timedwait(() -> istaskdone(task), 25.0; pollint = 0.05) === :ok
        @test failure[] === nothing

        r = resp[]
        @test r !== nothing
        if r !== nothing
            @test r.status == 200
            @test isempty(r.body)
            # `Res.sse` declares no length, so HEAD must not invent one.
            @test !HTTP.hasheader(r, "Content-Length")
            @test HTTP.header(r, "Content-Type") == "text/event-stream"
        end

        # The heart of it: the body was RELEASED, not consumed. `_release_response_body!` closes
        # the stream, the producer's `isopen` check fails, and it unwinds almost immediately.
        # Against the unguarded handler the drain consumes every event, so this reads HEAD_EVENTS
        # -- a value the guarded path cannot reach, because the producer is paced.
        @test HEAD_STOPPED[]
        @test HEAD_WROTE[] < HEAD_EVENTS

        # And the same route still streams normally over GET, so the guard is method-scoped.
        got = collect_sse("$localhost$route"; want = 3)
        @test got.finished === :ok
        @test length(got.events) == 3

        @test HTTP.get("$localhost/health").status == 200
    end
finally
    terminate(ctx)
end

end
