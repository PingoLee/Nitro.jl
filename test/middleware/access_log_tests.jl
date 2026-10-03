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
    lf = AccessLog(sink; skip = (req, resp) -> startswith(String(req.target), "/static/"))
    handler = lf.middleware(req -> Response(200, "ok"))

    startup(lf)
    handler(Request("GET", "/static/app.js"))   # skipped
    handler(Request("GET", "/api/data"))        # logged
    shutdown(lf)

    @test length(records) == 1
    @test records[1].path == "/api/data"
end

# #401: `skip` used to be `req -> Bool`, called BEFORE the handler, so it could not see the status
# -- the one thing a scanner-probe filter needs. It now runs after, with the response.
@testset "skip runs after the handler and sees the response" begin
    records, sink = collecting_sink()
    seen = Any[]
    lf = AccessLog(sink; batch = 10, skip = (req, resp) -> begin
        push!(seen, resp === nothing ? nothing : resp.status)
        resp !== nothing && resp.status == 404
    end)
    handler = lf.middleware(req -> req.target == "/boom" ? error("boom") :
                                   Response(req.target == "/missing" ? 404 : 200, "x"))

    startup(lf)
    handler(Request("GET", "/missing"))          # 404 -> skipped
    handler(Request("GET", "/found"))            # 200 -> logged
    @test_throws ErrorException handler(Request("GET", "/boom"))   # resp === nothing -> logged
    shutdown(lf)

    @test seen == [404, 200, nothing]            # (unpatched: skip was never given a response)
    @test [r.path for r in records] == ["/found", "/boom"]
    @test records[2].status == 500
end

@testset "skip can drop the record of a handler that threw" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink; skip = (req, resp) -> resp === nothing)
    handler = lf.middleware(req -> error("boom"))
    startup(lf)
    @test_throws ErrorException handler(Request("GET", "/x"))
    shutdown(lf)
    @test isempty(records)
end

@testset "a pre-#401 one-argument skip is refused at construction" begin
    @test_throws ArgumentError AccessLog(recs -> nothing; skip = req -> true)
    err = try AccessLog(recs -> nothing; skip = req -> true); nothing catch e; e end
    @test occursin("(req, resp)", sprint(showerror, err))
    # A typed two-argument hook is accepted even though it has no `(Request, Any)` method.
    @test AccessLog(recs -> nothing; skip = (req::Request, resp::Union{Nothing,Response}) -> false) isa
          LifecycleMiddleware
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
    @test_throws ArgumentError AccessLog(recs -> nothing; capacity = 4, unmatched_capacity = 0)
    @test_throws ArgumentError AccessLog(recs -> nothing; capacity = 4, unmatched_capacity = 5)
    @test_throws ArgumentError AccessLog(recs -> nothing; max_field_bytes = 14)   # marker size
    @test AccessLog(recs -> nothing; max_field_bytes = 15) isa LifecycleMiddleware
    @test AccessLog(recs -> nothing; capacity = 1) isa LifecycleMiddleware      # default budget >= 1
end

# What the router does on a miss (#401): the only thing that makes a record unmatched.
missed(status = 404) = req -> (Nitro.Core._mark_route_miss!(req); Response(status, "x"))

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

# #401: client-controlled fields are bounded. HTTP.jl's only limit is 64 KiB per line, so a probe
# flood could buffer ~1.25 GiB of paths and User-Agents before a sink saw any of it.
@testset "client-controlled fields are cut to max_field_bytes on a character boundary" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink; batch = 10, log_query = true, max_field_bytes = 32)
    handler = lf.middleware(req -> Response(200, "ok"))
    marker = "…[truncated]"

    startup(lf)
    # '/' then 2-byte 'é's: the 18-byte budget beside the marker ends mid-character.
    handler(Request("GET", "/" * "é"^50 * "?" * "q"^100, ["User-Agent" => "u"^5000]))
    handler(Request("X"^100, "/short", ["User-Agent" => "curl/8"]))
    shutdown(lf)

    long, short = records
    for v in (long.path, long.query, long.user_agent, short.method)
        @test ncodeunits(v) <= 32                # (unpatched: the full 5000-byte UA survives)
        @test endswith(v, marker)
        @test isvalid(v)                         # never a split character
    end
    @test long.path == "/" * "é"^8 * marker      # the straddling 'é' is dropped whole
    @test short.path == "/short"                 # short values are untouched
    @test short.user_agent == "curl/8"
    @test long.method == "GET"
end

# #401: when the buffer was full the NEWEST record was dropped, so a probe flood that filled it
# dropped the authenticated requests arriving during the sweep. Unmatched records now draw on
# their own smaller budget.
@testset "a flood of unmatched records cannot evict matched ones" begin
    s = blocking_sink()
    lf = AccessLog(s.sink; capacity = 4, unmatched_capacity = 1, batch = 1)
    probe = missed()
    handler = lf.middleware(req -> startswith(req.target, "/api") ? Response(200, "x") : probe(req))
    startup(lf)

    handler(Request("GET", "/api/0"))       # taken by the drain -> parks in the sink
    wait(s.entered)
    for i in 1:5
        handler(Request("GET", "/.env$i"))  # 1 buffered, 4 dropped against the unmatched budget
    end
    for i in 1:3
        handler(Request("GET", "/api/$i"))  # still room: capacity 4 - 1 unmatched = 3
    end

    notify(s.release)
    shutdown(lf)

    matched = [r.path for r in s.records if r.matched]
    unmatched = [r.path for r in s.records if !r.matched]
    @test matched == ["/api/0", "/api/1", "/api/2", "/api/3"]   # (unpatched: only "/api/0")
    @test unmatched == ["/.env1"]
    @test all(r -> r.status == 404, filter(r -> !r.matched, s.records))
end

# The writer must hand back each unmatched reservation as it takes the record, or the budget leaks
# and unmatched logging stops for good after `unmatched_capacity` records (review of #401).
@testset "the unmatched budget is released as records drain" begin
    records, sink = collecting_sink()
    lf = AccessLog(sink; capacity = 4, unmatched_capacity = 1, batch = 1)
    handler = lf.middleware(missed())
    startup(lf)
    for i in 1:5
        handler(Request("GET", "/.env$i"))
        # Let the writer drain before the next one, so each lands in an empty budget.
        @test timedwait(() -> length(records) >= i, 10.0; pollint = 0.01) === :ok
    end
    shutdown(lf)
    @test [r.path for r in records] == ["/.env$i" for i in 1:5]   # (leaky release: only "/.env1")
    @test all(r -> !r.matched, records)
end

end # @testitem

# #401, end to end: `matched` is the ROUTER's verdict (`route_missed`), so it has to survive the
# real pipeline -- a handler's own 404 is matched, a router miss is not, a static mount's miss (a
# catch-all leaf that defers to the router's 404) is not either, and a request a guard or
# middleware REFUSED on a real route is matched: it never reached a lookup that came up empty.
@testitem "AccessLog matched marker through the pipeline" tags=[:middleware] setup=[NitroCommon] begin
using Nitro
using HTTP
# Not `using Nitro.Core`: its `urlpatterns` would collide with `Nitro`'s (src/methods.jl).
using Nitro.Core: startup, shutdown

records = AccessRecord[]
lk = ReentrantLock()
lf = AccessLog(recs -> lock(() -> append!(records, recs), lk); batch = 100)
deny = handle -> req -> HTTP.Response(403, "denied")

root = mktempdir()
write(joinpath(root, "a.txt"), "a")
app = App(mod = @__MODULE__)
urlpatterns(app, "",
    path("/real", () -> "ok"),
    path("/gone", () -> HTTP.Response(404, "no such thing")),
    path("/admin", () -> "secret"; middleware = [deny]),   # a route-level guard refusing
)
staticfiles(app, root, "static")

startup(lf)
for (method, target) in [("GET", "/real"), ("GET", "/gone"), ("GET", "/.env"),
                         ("GET", "/static/a.txt"), ("GET", "/static/nope"),
                         ("POST", "/static/a.txt"), ("GET", "/admin")]
    internalrequest(app, HTTP.Request(method, target); middleware = [lf])
end
# A global middleware after AccessLog refusing before the router runs.
internalrequest(app, HTTP.Request("PUT", "/real"); middleware = [lf, deny])
shutdown(lf)

got = Dict((r.method, r.path) => (r.status, r.matched) for r in records)
@test got[("GET", "/real")] == (200, true)
@test got[("GET", "/gone")] == (404, true)            # the handler's own 404 is a real request
@test got[("GET", "/.env")] == (404, false)           # a router miss
@test got[("GET", "/static/a.txt")] == (200, true)
@test got[("GET", "/static/nope")] == (404, false)    # a mount miss is a miss too
@test got[("POST", "/static/a.txt")] == (405, false)  # as is the mount's 405
@test got[("GET", "/admin")] == (403, true)           # a guard's denial is NOT a probe
@test got[("PUT", "/real")] == (403, true)            # nor is a global refusal before routing

# The documented probe filter keeps everything but the misses -- the denials included.
kept = AccessRecord[]
lf2 = AccessLog(recs -> lock(() -> append!(kept, recs), lk); batch = 100,
                skip = (req, resp) -> route_missed(req))
startup(lf2)
for target in ["/real", "/gone", "/.env", "/wp-login.php", "/static/nope", "/admin"]
    internalrequest(app, HTTP.Request("GET", target); middleware = [lf2])
end
shutdown(lf2)
@test sort([r.path for r in kept]) == ["/admin", "/gone", "/real"]
end

# The no-route answers outside the router proper. The prefix strip's 404 and OriginForm's 400 sit
# outside `compose`, so only the console line (and any other framework-level reader) sees them --
# assert the marker directly. The retired auto-HEAD is a router LEAF that answers a method miss,
# so the router's own miss path never marks it.
@testitem "route_missed marks every no-route answer" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Nitro

strip = Nitro.Core.PrefixStripMiddleware("/api")(req -> HTTP.Response(200, "in"))
outside = HTTP.Request("GET", "/elsewhere")
@test strip(outside).status == 404
@test route_missed(outside)
inside = HTTP.Request("GET", "/api/x")
@test strip(inside).status == 200
@test !route_missed(inside)

origin = Nitro.Core.OriginFormMiddleware()(req -> HTTP.Response(200, "in"))
traversal = HTTP.Request("GET", "/../etc/passwd")
@test origin(traversal).status == 400
@test route_missed(traversal)
@test !route_missed(let r = HTTP.Request("GET", "/fine"); origin(r); r end)

app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/swap", () -> "ok"))
urlpatterns(app, "", path("/swap", (stream::HTTP.Stream) -> nothing; method = "STREAM"))
head = HTTP.Request("HEAD", "/swap")
@test internalrequest(app, head).status == 405
@test route_missed(head)                     # (unpatched: false -- a leaf answered)
end

# A miss belongs to the request shape that missed. A global fallback that rewrites a 404 to a
# served target must not leave the request reading as a miss, or the documented probe filter
# drops a request a route served (delta review of #401).
@testitem "route_missed follows a re-dispatched request" tags=[:middleware] setup=[NitroCommon] begin
using HTTP
using Nitro
app = App(mod = @__MODULE__)
urlpatterns(app, "", path("/real", () -> "ok"))
fallback = handle -> req -> begin
    resp = handle(req)
    resp.status == 404 || return resp
    req.target = "/real"
    return handle(req)
end
r = HTTP.Request("GET", "/old-link")
@test internalrequest(app, r; middleware = [fallback]).status == 200
@test !route_missed(r)                       # (bare-`true` marker: still true)
miss = HTTP.Request("GET", "/nowhere")
@test internalrequest(app, miss).status == 404
@test route_missed(miss)
end

# #401: the console line (`serve(access_log=true)`) had no hook at all; it now takes the same
# post-response `skip`.
@testitem "Console access log skip" tags=[:middleware] setup=[NitroCommon] begin
using Nitro
using HTTP

lines(mw, req, resp = HTTP.Response(200)) = begin
    logger = Test.TestLogger()
    Base.CoreLogging.with_logger(logger) do
        mw(_req -> resp)(req)
    end
    [string(l.message) for l in logger.logs]
end

quiet = Nitro.Core.AccessLogMiddleware(skip = (req, resp) -> resp.status == 404)
@test isempty(lines(quiet, HTTP.Request("GET", "/.env"), HTTP.Response(404)))
@test length(lines(quiet, HTTP.Request("GET", "/ok"))) == 1

# A throwing hook warns and the line is still written.
msgs = lines(Nitro.Core.AccessLogMiddleware(skip = (req, resp) -> error("hook boom")),
             HTTP.Request("GET", "/ok"))
@test any(m -> occursin("access_log_skip hook errored", m), msgs)
@test any(m -> occursin("\"GET /ok\" 200", m), msgs)

# The old one-argument shape and a non-function are refused before `serve` touches the App.
@test_throws ArgumentError Nitro.Core.AccessLogMiddleware(skip = req -> true)
app = App(mod = @__MODULE__)
# `port`/`async`: should validation ever regress, this binds a free port and returns instead of
# blocking on 8080.
@test_throws ArgumentError serve(app; access_log_skip = req -> true, show_banner = false,
                                 port = get_free_port(), host = HOST, async = true)
@test_throws ArgumentError serve(app; access_log_skip = "nope", show_banner = false,
                                 port = get_free_port(), host = HOST, async = true)
@test !isopen(app.service)
end

# #159: the retention pruner. `AccessLog(sink; prune, retention, prune_interval)` schedules the
# app's `prune(cutoff)` through the shared `_janitor`, starting and stopping with the writer.
@testitem "AccessLog retention pruner" tags=[:middleware, :slow] setup=[NitroCommon] begin
using Nitro.Core
using Nitro
using Dates

# Records every cutoff it is handed, and the task that handed it, under a lock -- `prune` runs
# on the janitor task, and a stale tick can still push after `shutdown`, so reads go through
# the lock too.
function recording_prune()
    buf = DateTime[]
    tasks = Task[]
    lk = ReentrantLock()
    prune = cutoff -> lock(lk) do
        push!(buf, cutoff)
        push!(tasks, current_task())
    end
    count() = lock(() -> length(buf), lk)
    cutoffs() = lock(() -> copy(buf), lk)
    tasks_since(n) = lock(() -> tasks[n+1:end], lk)
    return cutoffs, prune, count, tasks_since
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
    cutoffs, prune, count, tasks_since = recording_prune()
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
    cutoffs, prune, count, tasks_since = recording_prune()
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
    cutoffs, prune, count, tasks_since = recording_prune()
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
    cutoffs, prune, count, tasks_since = recording_prune()
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
    @test wait_for(() -> count() >= t0 + 6)
    shutdown(lf)
    # Identity, not a tick-rate bound: a leaked second pruner would interleave its own ticks
    # with the first's, and a rate bound goes red whenever a loaded runner oversleeps.
    @test length(unique(objectid.(tasks_since(t0)))) == 1
end

@testset "prune and retention go together; bad values fail at construction" begin
    sink = recs -> nothing
    # Match the message, so each case pins the guard that fired rather than any ArgumentError.
    function rejects(needle; kw...)
        try
            AccessLog(sink; kw...)
            return false
        catch e
            return e isa ArgumentError && occursin(needle, e.msg)
        end
    end
    @test rejects("go together"; prune = c -> nothing)
    @test rejects("go together"; retention = Day(90))
    @test rejects("must be positive"; prune = c -> nothing, retention = Day(0))
    @test rejects("must be positive"; prune = c -> nothing, retention = Day(-1))
    # Calendar intervals cannot be slept on -- rejected here, not on the first tick.
    @test rejects("fixed-length"; prune = c -> nothing, retention = Day(90),
                  prune_interval = Month(1))
    @test rejects("at least 1 millisecond"; prune = c -> nothing, retention = Day(90),
                  prune_interval = Millisecond(0))
    # An interval with no pruner to apply it to is refused, not validated by nobody and ignored.
    @test rejects("only applies to the retention pruner"; prune_interval = Hour(2))
    @test rejects("only applies to the retention pruner"; prune_interval = Month(1))
end

end # @testitem

# #443: the console line's timestamp no longer goes through `Dates.format` (~6.7 µs a request),
# but it must still print exactly what that call printed -- the line is parsed by whatever reads
# the logs.
@testitem "Console access log timestamp matches Dates.format (#443)" tags=[:middleware] setup=[NitroCommon] begin
using Dates
using Random
using Nitro
using HTTP

fmt(t) = Dates.format(t, "yyyy-mm-ddTHH:MM:SS")
edges = [DateTime(0, 1, 1), DateTime(1, 1, 1), DateTime(999, 12, 31, 23, 59, 59),
         DateTime(1000, 1, 1), DateTime(2026, 10, 3, 9, 5, 7), DateTime(2026, 12, 31, 23, 59, 59, 999),
         DateTime(9999, 12, 31, 23, 59, 59), DateTime(10000, 1, 1), DateTime(-1, 6, 15, 12)]
for t in edges
    @test Nitro.Core._iso_seconds(t) == fmt(t)
end
# A spread of ordinary instants, from `RandomDevice` because `@testset` reseeds the default RNG.
rng = Random.RandomDevice()
lo, hi = Dates.value(DateTime(1970)), Dates.value(DateTime(2100))
for _ in 1:2000
    t = DateTime(Dates.UTM(rand(rng, lo:hi)))
    @test Nitro.Core._iso_seconds(t) == fmt(t)
end

# And through the layer: the line still opens with that timestamp.
logger = Test.TestLogger()
Base.CoreLogging.with_logger(logger) do
    Nitro.Core.AccessLogMiddleware()(req -> HTTP.Response(200))(HTTP.Request("GET", "/x"))
end
@test occursin(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d - nothing - \"GET /x\" 200$",
               string(only(logger.logs).message))
end
