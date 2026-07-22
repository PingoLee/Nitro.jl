@testitem "AccessLog middleware" tags=[:middleware] setup=[NitroCommon] begin
using Nitro.Core
using Nitro

# Collect sink deliveries under a lock — the sink runs on the writer task/thread.
function collecting_sink()
    records = AccessRecord[]
    lk = ReentrantLock()
    sink = recs -> lock(() -> append!(records, recs), lk)
    return records, sink
end

@testset "captures a request and delivers it to the sink" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink; batch = 10, annotate = req -> Dict{Symbol, Any}(:user => "u1"))
    handler = lf.middleware(req -> Response(201, "created"))

    startup(lf)
    resp = handler(Request("POST", "/api/things?limit=5"))
    @test resp.status == 201                 # response passes through unchanged
    shutdown(lf)                             # flushes buffered records, waits for the writer

    @test length(records) == 1
    rec = records[1]
    @test rec.method == "POST"
    @test rec.path == "/api/things"
    @test rec.query == "limit=5"
    @test rec.status == 201
    @test rec.duration_ms >= 0
    @test rec.context[:user] == "u1"
end

@testset "no query string → query is nothing" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink)
    handler = lf.middleware(req -> Response(200, "ok"))

    startup(lf)
    handler(Request("GET", "/health"))
    shutdown(lf)

    @test length(records) == 1
    @test records[1].path == "/health"
    @test records[1].query === nothing
end

@testset "inactive middleware is a passthrough (no capture)" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink)
    handler = lf.middleware(req -> Response(200, "ok"))

    # No startup() → writer inactive; the request must still be served, nothing logged.
    resp = handler(Request("GET", "/health"))
    @test resp.status == 200
    @test isempty(records)
end

@testset "skip predicate excludes matching requests" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink; skip = req -> startswith(String(req.target), "/static/"))
    handler = lf.middleware(req -> Response(200, "ok"))

    startup(lf)
    handler(Request("GET", "/static/app.js"))   # skipped
    handler(Request("GET", "/api/data"))        # logged
    shutdown(lf)

    @test length(records) == 1
    @test records[1].path == "/api/data"
end

@testset "handler exception is logged as 500 then re-raised" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink)
    handler = lf.middleware(req -> error("boom"))

    startup(lf)
    @test_throws ErrorException handler(Request("GET", "/api/fail"))
    shutdown(lf)

    @test length(records) == 1
    @test records[1].status == 500
    @test records[1].path == "/api/fail"
end

@testset "invalid capacity/batch are rejected" begin
    @test_throws ArgumentError AccessLog(recs -> nothing; capacity = 0)
    @test_throws ArgumentError AccessLog(recs -> nothing; batch = 0)
end

# A sink that parks on its first delivery (signalling `entered`) until the test
# releases it — lets us fill the buffer deterministically while the drain is stuck.
function blocking_sink()
    records = AccessRecord[]
    batch_sizes = Int[]
    lk = ReentrantLock()
    entered = Base.Event()
    release = Base.Event()
    first_call = Threads.Atomic{Bool}(true)
    sink = function (recs)
        Threads.atomic_xchg!(first_call, false) && notify(entered)
        wait(release)
        lock(lk) do
            push!(batch_sizes, length(recs))
            append!(records, recs)
        end
    end
    return (; records, batch_sizes, entered, release, sink)
end

@testset "overflow drops records instead of blocking the request" begin
    # capacity=2, batch=1: the drain pulls the first record into the (parked) sink,
    # leaving room for exactly `capacity` more before new records are dropped.
    s = blocking_sink()
    lf = AccessLog(s.sink; capacity = 2, batch = 1)
    handler = lf.middleware(req -> Response(200, "ok"))
    startup(lf)

    handler(Request("GET", "/api/1"))    # taken by the drain → parks in the sink
    wait(s.entered)                      # sink is now stuck; buffer is empty

    # With the drain parked, submit more than the buffer can hold. Every call must
    # return without blocking; the excess beyond `capacity` is dropped, not queued.
    for i in 2:6
        resp = handler(Request("GET", "/api/$i"))
        @test resp.status == 200         # request never blocks on the full buffer
    end

    notify(s.release)                    # let the sink (and drain) proceed
    shutdown(lf)                         # drains buffered records, waits for the writer

    # Delivered = 1 in-flight + `capacity` (2) buffered = 3; the other 3 were dropped.
    @test length(s.records) == 3
end

@testset "buffered records drain together in one batch" begin
    s = blocking_sink()
    lf = AccessLog(s.sink; capacity = 100, batch = 100)
    handler = lf.middleware(req -> Response(200, "ok"))
    startup(lf)

    handler(Request("GET", "/api/1"))    # taken alone → first (parked) sink call
    wait(s.entered)
    for i in 2:4                          # queue up while the drain is parked
        handler(Request("GET", "/api/$i"))
    end

    notify(s.release)
    shutdown(lf)

    @test length(s.records) == 4
    @test 3 in s.batch_sizes             # rec 2..4 delivered together in a single batch
end

@testset "a throwing sink never breaks request handling" begin
    calls = Threads.Atomic{Int}(0)
    sink = function (recs)
        Threads.atomic_add!(calls, length(recs))
        error("sink boom")               # swallowed by the writer, never reaches the request
    end
    lf = AccessLog(sink)
    handler = lf.middleware(req -> Response(200, "ok"))

    startup(lf)
    resp = handler(Request("GET", "/api/data"))
    @test resp.status == 200             # request unaffected by the failing sink
    shutdown(lf)                         # must not hang despite the sink throwing

    @test calls[] >= 1                   # the sink really was invoked (and threw)
end

@testset "restart after shutdown logs again on a fresh buffer" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink; batch = 10)
    handler = lf.middleware(req -> Response(200, "ok"))

    startup(lf)
    handler(Request("GET", "/api/first"))
    shutdown(lf)                             # closes the first activation's channel

    startup(lf)                              # builds a fresh _Run; must not touch the old one
    handler(Request("GET", "/api/second"))
    shutdown(lf)

    @test length(records) == 2
    @test records[1].path == "/api/first"
    @test records[2].path == "/api/second"
end

end # @testitem
