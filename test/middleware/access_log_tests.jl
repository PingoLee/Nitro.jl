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
    @test rec.query === nothing              # redacted by default (#320)
    @test rec.status == 201
    @test rec.duration_ms >= 0
    @test rec.context[:user] == "u1"
end

# #320: the record used to carry the raw query and a prefix-sliced path, so a sink persisting
# it stored reset tokens and absolute-form credentials. The console log had redacted both since
# #39; the record now gets the same reduction, and the query only on opt-in.
@testset "records redact the query and URL credentials by default" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink; batch = 10)
    handler = lf.middleware(req -> Response(200, "ok"))

    startup(lf)
    handler(Request("GET", "/reset?token=S3CRET-RESET-TOKEN"))
    handler(Request("GET", "http://alice:pa55w0rd@h.example/x?code=S3CRET-CODE"))
    handler(Request("GET", "//bob:pa55w0rd@evil.example/y?k=S3CRET"))
    handler(Request("GET", "/frag#part?k=S3CRET"))
    shutdown(lf)

    @test [r.path for r in records] == ["/reset", "/x", "/y", "/frag"]
    for r in records
        @test r.query === nothing
        fields = string(r.path, r.query, r.user_agent, r.ip)
        @test !occursin("S3CRET", fields)
        @test !occursin("pa55w0rd", fields)
        @test !occursin("example", fields)
    end
end

@testset "log_query=true opts back into the raw query, never the credentials" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink; batch = 10, log_query = true)
    handler = lf.middleware(req -> Response(200, "ok"))

    startup(lf)
    handler(Request("POST", "/api/things?limit=5"))
    handler(Request("GET", "http://alice:pa55w0rd@h.example/x?code=abc"))
    handler(Request("GET", "/q?a=1#frag"))          # the fragment is not part of the query
    handler(Request("GET", "/f#frag?a=1"))          # a '?' inside a fragment is no query
    handler(Request("GET", "/empty?"))              # an empty query is `nothing`, not ""
    handler(Request("GET", "/none"))
    shutdown(lf)

    @test [r.query for r in records] == ["limit=5", "code=abc", "a=1", nothing, nothing, nothing]
    @test records[2].path == "/x"                   # opting into the query keeps the path reduced
    @test !occursin("pa55w0rd", string(records[2].path, records[2].query))
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

# #159: the retention pruner. `AccessLog(sink; prune, retention, prune_interval)` schedules the
# app's `prune(cutoff)` through the shared `_janitor`, starting and stopping with the writer.
@testitem "AccessLog retention pruner" tags=[:middleware] setup=[NitroCommon] begin
using Nitro.Core
using Nitro
using Dates

# Records every cutoff it is handed, under a lock -- `prune` runs on the janitor task, and a
# stale tick can still push after `shutdown`, so reads go through the lock too.
function recording_prune()
    buf = DateTime[]
    lk = ReentrantLock()
    prune = cutoff -> lock(() -> push!(buf, cutoff), lk)
    count() = lock(() -> length(buf), lk)
    cutoffs() = lock(() -> copy(buf), lk)
    return cutoffs, prune, count
end

# Poll instead of sleeping a fixed time: a loaded CI box can be slow to schedule the janitor.
function wait_for(cond; timeout = 10.0)
    t = time()
    while !cond()
        time() - t > timeout && return false
        sleep(0.01)
    end
    return true
end

@testset "prune runs every interval with cutoff = now() - retention" begin
    cutoffs, prune, count = recording_prune()
    lf = AccessLog(recs -> nothing; prune, retention = Day(90),
                   prune_interval = Millisecond(20))
    startup(lf)
    before = now()
    @test wait_for(() -> count() >= 3)                # it keeps firing, not just once
    after = now()
    shutdown(lf)

    # Each cutoff is 90 days behind the clock that stamps `AccessRecord.ts` (`now()`). Only the
    # first three are bounded by `after`: on >1 thread a later tick can land between `after` and
    # `shutdown` -- pushes are in order, so these three were computed before `wait_for` returned.
    @test all(c -> before - Day(90) - Second(5) <= c <= after - Day(90), cutoffs()[1:3])
end

@testset "a calendar retention is allowed" begin
    cutoffs, prune, count = recording_prune()
    lf = AccessLog(recs -> nothing; prune, retention = Month(3),
                   prune_interval = Millisecond(20))
    startup(lf)
    before = now()
    @test wait_for(() -> count() >= 1)
    after = now()
    shutdown(lf)
    @test before - Month(3) - Second(5) <= cutoffs()[1] <= after - Month(3)   # first only, as above
end

@testset "no startup sweep: the first prune waits one interval" begin
    cutoffs, prune, count = recording_prune()
    lf = AccessLog(recs -> nothing; prune, retention = Day(1), prune_interval = Hour(1))
    startup(lf)
    sleep(0.2)
    @test count() == 0
    shutdown(lf)
end

@testset "a throwing prune costs one tick, not the pruner or the writer" begin
    calls = Threads.Atomic{Int}(0)
    prune = function (cutoff)
        Threads.atomic_add!(calls, 1)
        error("prune boom")
    end
    records = AccessRecord[]
    lk = ReentrantLock()
    lf = AccessLog(recs -> lock(() -> append!(records, recs), lk); prune,
                   retention = Day(1), prune_interval = Millisecond(20))
    handler = lf.middleware(req -> Response(200, "ok"))

    startup(lf)
    @test wait_for(() -> calls[] >= 3)                # still ticking after throwing
    resp = handler(Request("GET", "/api/data"))
    @test resp.status == 200
    shutdown(lf)
    @test length(records) == 1                        # the writer was unaffected
end

@testset "shutdown stops the pruner, and a restart does not leak a second one" begin
    cutoffs, prune, count = recording_prune()
    lf = AccessLog(recs -> nothing; prune, retention = Day(1),
                   prune_interval = Millisecond(50))

    startup(lf)
    @test wait_for(() -> count() >= 1)
    shutdown(lf)
    sleep(0.2)                                        # let a stale tick, if any, land
    n = count()
    sleep(0.3)                                        # 6 intervals: a live pruner would tick
    @test count() == n                                # stopped

    startup(lf)
    startup(lf)                                       # idempotent: no second task
    t0 = count()
    sleep(1.0)                                        # ~20 intervals
    ticks = count() - t0
    shutdown(lf)
    # One pruner ticks at most once per 50 ms interval; two would roughly double that. The bound
    # sits between the two so a slow machine (fewer ticks) cannot fail it.
    @test 1 <= ticks <= 24
end

@testset "prune and retention go together; bad values fail at construction" begin
    sink = recs -> nothing
    @test_throws ArgumentError AccessLog(sink; prune = c -> nothing)
    @test_throws ArgumentError AccessLog(sink; retention = Day(90))
    @test_throws ArgumentError AccessLog(sink; prune = c -> nothing, retention = Day(0))
    @test_throws ArgumentError AccessLog(sink; prune = c -> nothing, retention = Day(-1))
    # Calendar intervals cannot be slept on -- rejected here, not on the first tick.
    @test_throws ArgumentError AccessLog(sink; prune = c -> nothing, retention = Day(90),
                                         prune_interval = Month(1))
    @test_throws ArgumentError AccessLog(sink; prune = c -> nothing, retention = Day(90),
                                         prune_interval = Millisecond(0))
    # An interval with no pruner is simply unused -- the default is always passed.
    @test AccessLog(sink; prune_interval = Hour(2)) isa Nitro.Core.Types.LifecycleMiddleware
end

end # @testitem
