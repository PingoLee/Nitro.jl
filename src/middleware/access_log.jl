# NOTE on naming: `Nitro.Core` already owns the name `AccessLogMiddleware` — the
# console line-logger behind `serve(access_log=true)` (core/framework_middleware.jl). This module is the
# *structured* counterpart (records to an app-supplied sink), so it carries a
# distinct name to keep the two from shadowing each other.
module StructuredAccessLogMiddleware

# Generic HTTP access logging for any Nitro app (API, SPA, or hybrid).
#
# `AccessLog(sink)` is a LifecycleMiddleware that captures one `AccessRecord` per
# handled request — method, path, query (opt-in), status, duration, client IP, User-Agent,
# plus an app-supplied `context` — and delivers them to `sink(::Vector{AccessRecord})`
# ASYNCHRONOUSLY. The request task drops the record into a bounded channel and returns
# immediately; a single background task drains the channel in batches and calls the
# sink. The request is never blocked on the sink (a DB, a file, an external service),
# and a slow/stuck sink can only ever cost buffered records, never request latency.
#
# What is framework-generic lives here (timing, capture, buffering, batching, drop-on-
# overflow, task lifecycle). What is app-specific stays in the sink: WHERE records are
# persisted and HOW `context` (identity, tenant, session…) is populated. That keeps
# Nitro free of any storage dependency.
#
# Client IP comes from `getip(req)` — set by the `ExtractIP` middleware, which derives
# it from the socket peer and only trusts forwarding headers from configured proxies.
# Put `ExtractIP` before `AccessLog` in the chain to get a trustworthy IP; without it,
# `ip` is `nothing`.

using HTTP
using Dates
using ...Core: getip, LifecycleMiddleware
using ...Util: _log_target_path
using ..JanitorMiddleware: _janitor

export AccessLog, AccessRecord

const _EMPTY_CONTEXT = Dict{Symbol, Any}()

"""
    AccessRecord

One captured HTTP request. Framework-level fields plus `context`, an app-supplied
`Dict{Symbol,Any}` (from the `annotate` hook) carrying identity/tenant/session/etc.
The sink maps these onto whatever storage it uses.

- `ts`          — capture time (`Dates.now()`)
- `method`      — HTTP verb
- `path`        — request path, reduced exactly as the console access log reduces it: query
                  and fragment stripped, and an absolute-form target (`http://user:pw@h/x`)
                  cut to its path, so a well-formed authority and its credentials never
                  survive. `"-"` when the target has no usable path, `"*"` for `OPTIONS *`
- `query`       — `nothing` unless `AccessLog(sink; log_query = true)`; then the raw query
                  string (`nothing` if the request had none)
- `status`      — response status (`500` if the handler threw)
- `duration_ms` — handler wall-clock, milliseconds
- `ip`          — client IP as a `String` (see module note), or `nothing`
- `user_agent`  — `User-Agent` header, or `nothing`
- `context`     — app-supplied extras (empty when no `annotate` hook is given)
"""
struct AccessRecord
    ts          :: DateTime
    method      :: String
    path        :: String
    query       :: Union{Nothing, String}
    status      :: Int
    duration_ms :: Int
    ip          :: Union{Nothing, String}
    user_agent  :: Union{Nothing, String}
    context     :: Dict{Symbol, Any}
end

# One activation's mutable state: the buffer plus its reservation/drop counters.
# `on_startup` builds a FRESH `_Run` each time, so a drain task left over from a
# previous (e.g. grace-period-timed-out) shutdown only ever touches its own channel
# and counters — it can never corrupt a restarted writer. `queued` is a reservation
# counter kept == channel occupancy so `_enqueue!` can refuse without blocking when full.
mutable struct _Run
    channel  :: Channel{AccessRecord}
    capacity :: Int
    queued   :: Threads.Atomic{Int}
    dropped  :: Threads.Atomic{Int}
end
_Run(capacity::Int) = _Run(Channel{AccessRecord}(capacity), capacity,
                           Threads.Atomic{Int}(0), Threads.Atomic{Int}(0))

# Per-`AccessLog` writer (no module-global mutable state, so multiple AccessLog
# middlewares can coexist). `active` is atomic: it gates the request hot path, and —
# stored *after* `run` in `on_startup` — publishes the current activation to reader
# threads. Each `_Run` is self-contained, so swapping `run` on restart is race-free.
mutable struct _Writer
    sink   :: Function
    batch  :: Int
    active :: Threads.Atomic{Bool}
    run    :: _Run
    task   :: Union{Task, Nothing}
end

# ── App-hook guards: a buggy skip/annotate hook must never break a request ──────
function _skips(skip, req)::Bool
    skip === nothing && return false
    try
        return skip(req) === true
    catch err
        @warn "AccessLog: skip hook errored (logging request anyway)" exception=err
        return false
    end
end

function _annotate(annotate, req)::Dict{Symbol, Any}
    annotate === nothing && return _EMPTY_CONTEXT
    try
        v = annotate(req)
        return v isa Dict{Symbol, Any} ? v :
               v isa AbstractDict ? Dict{Symbol, Any}(Symbol(k) => val for (k, val) in v) :
               _EMPTY_CONTEXT
    catch err
        @warn "AccessLog: annotate hook errored" exception=err
        return _EMPTY_CONTEXT
    end
end

# ── Enqueue (request task): reserve a slot without blocking, else drop ──────────
function _enqueue!(r::_Run, rec::AccessRecord)
    # Reserve first: if we'd exceed capacity, drop instead of blocking the request on
    # a full buffer (a slow sink then costs records, never latency). capacity == channel
    # size, so a granted reservation guarantees put! has room and won't block.
    if Threads.atomic_add!(r.queued, 1) >= r.capacity
        Threads.atomic_sub!(r.queued, 1)
        Threads.atomic_add!(r.dropped, 1)
        return nothing
    end
    try
        put!(r.channel, rec)
    catch
        Threads.atomic_sub!(r.queued, 1)   # channel closed mid-shutdown, etc.
    end
    return nothing
end

# The query as the client sent it: after the first '?', up to any '#'. Only reached with
# `log_query = true`. A '?' inside a fragment (`/x#f?k=1`) is not a query, the same rule
# `_log_target_path` applies to the path, and an empty query is `nothing`, not `""`.
function _raw_query(target::AbstractString)::Union{Nothing, String}
    q = findfirst('?', target)
    h = findfirst('#', target)
    (q === nothing || (h !== nothing && h < q)) && return nothing
    start = nextind(target, q)
    stop = h === nothing ? lastindex(target) : prevind(target, h)
    return start > stop ? nothing : String(SubString(target, start, stop))
end

# Redaction is decided HERE, at capture, not left to the sink (#320). The record used to carry
# the raw query and a prefix-sliced path, so an app persisting it wrote password-reset tokens,
# OAuth codes and absolute-form credentials (`http://user:pw@h/x`) into its access-log store --
# while the console logger beside it had redacted both by default since #39. A sink is
# app code and cannot un-see a secret it was handed; the only safe default is to never hand it.
function _capture!(r::_Run, req::HTTP.Request, resp, t0::UInt64, annotate, log_query::Bool)
    try
        # t0 is a `time_ns()` reading; the monotonic delta can never go negative.
        duration_ms = round(Int, (time_ns() - t0) / 1_000_000)
        target = String(req.target)
        path = String(_log_target_path(target))
        query = log_query ? _raw_query(target) : nothing
        status = resp isa HTTP.Response ? Int(resp.status) : (resp === nothing ? 500 : 200)
        ipaddr = getip(req)
        ip = ipaddr === nothing ? nothing : string(ipaddr)
        ua = HTTP.header(req, "User-Agent", "")
        user_agent = isempty(ua) ? nothing : String(ua)
        rec = AccessRecord(now(), String(req.method), path, query, status, duration_ms,
                           ip, user_agent, _annotate(annotate, req))
        _enqueue!(r, rec)
    catch err
        @warn "AccessLog: failed to capture request" exception=err
    end
    return nothing
end

# ── Background drain task ───────────────────────────────────────────────────────
# Closes over exactly the `_Run` it was spawned for, so a stale task from a prior
# activation drains its own (closed) channel to completion and exits, untouched by any
# restart that installs a new `_Run`.
#
# This writer deliberately does NOT use the shared `_janitor` helper that #190 extracted from
# `SessionMiddleware`'s prune and `FixedRateLimiter`'s sweep. It is EVENT-driven, not
# interval-driven: it parks on `take!` rather than `sleep(interval)`, is stopped by `close`ing
# the channel rather than by a stop token, and because closing takes effect immediately its
# `on_shutdown` can bound-WAIT for the drain (`timedwait(..., 5.0)`) where those two can only
# signal and let the task finish its nap. Widening `_janitor` to cover a blocking-wait loop with
# a bounded shutdown would put a second shape back into the helper, which is exactly what
# extracting it removed. This divergence is by design; the three that collapsed were not.
#
# The optional RETENTION pruner (#159) is the opposite case, and does use `_janitor`: it is
# exactly "sleep `prune_interval`, then call the app's `prune`", over app code that may block on a
# SQL DELETE -- the session prune's shape, not this writer's. See `AccessLog`.
function _run(sink, r::_Run, max_batch::Int)
    while true
        local rec
        try
            rec = take!(r.channel)          # blocks until a record arrives
        catch
            break                           # channel closed & drained → shut down
        end
        Threads.atomic_sub!(r.queued, 1)
        batch = AccessRecord[rec]
        while length(batch) < max_batch && isready(r.channel)
            push!(batch, take!(r.channel))
            Threads.atomic_sub!(r.queued, 1)
        end
        _flush!(sink, batch)
        _report_drops(r)
    end
    return nothing
end

function _flush!(sink, batch::Vector{AccessRecord})
    isempty(batch) && return nothing
    try
        sink(batch)
    catch err
        @warn "AccessLog: sink failed; dropping $(length(batch)) record(s)" exception=(err, catch_backtrace())
    end
    return nothing
end

function _report_drops(r::_Run)
    n = Threads.atomic_xchg!(r.dropped, 0)
    n == 0 || @warn "AccessLog: dropped $n record(s) (buffer full)"
    return nothing
end

"""
    AccessLog(sink; capacity=10_000, batch=500, skip=nothing, annotate=nothing,
              log_query=false, prune=nothing, retention=nothing, prune_interval=nothing)

Build a `LifecycleMiddleware` that asynchronously records every handled request and
delivers batches to `sink(::Vector{AccessRecord})`. Add it to `serve(middleware=[…])`;
its background writer starts and stops with the server.

- `sink`      — `Vector{AccessRecord} -> Any`, called on the writer task (may block/do I/O)
- `capacity`  — max buffered records before new ones are dropped (protects the hot path)
- `batch`     — max records delivered to `sink` per call
- `skip`      — optional `req -> Bool`; return `true` to NOT log a request (e.g. static
                assets or health checks in an SPA/hybrid app)
- `annotate`  — optional `req -> Dict{Symbol,Any}`; its result becomes `record.context`
                (e.g. `req -> Dict(:user => current_user_id(req))`)
- `log_query` — record the query string in `record.query`. Off by default; see below
- `prune`, `retention`, `prune_interval` — optional retention pruner; see below

Best-effort by contract: never blocks or throws into the request; a full buffer or a
failing sink costs records (counted and warned), never latency or correctness.

# Retention

A sink that persists records grows by one row per request, forever, unless something deletes
old ones, and retention rules (LGPD, GDPR, HIPAA) usually require that something does. Nitro
does not know where your sink writes, so you supply the delete and Nitro schedules it:

```julia
serve(app; middleware = [
    AccessLog(sink;
        prune = cutoff -> delete_access_log_older_than!(cutoff),   # your storage code
        retention = Day(90),
        prune_interval = Hour(1)),
])
```

- `prune`          — `cutoff::DateTime -> Any`: delete every record whose `ts` is older than
                     `cutoff`. Runs on a background task, never on a request, so it may block on
                     a database.
- `retention`      — how long a record is kept: any positive `Period`, `Month(3)` included.
                     The cutoff is `Dates.now() - retention`, the same clock that stamps
                     `AccessRecord.ts`, so the comparison is like for like.
- `prune_interval` — how often `prune` runs; a positive fixed-length `Period` (`Hour(1)` when
                     omitted). `Month`/`Quarter`/`Year` are rejected, since they cannot be
                     slept on.

`prune` and `retention` go together: passing one without the other is an `ArgumentError`, never
a silently disabled pruner, and so is a `prune_interval` with no pruner to apply it to. The pruner starts and stops with the server alongside the writer,
and a `serve(); terminate(); serve()` cycle does not leak its task.

The first prune runs one `prune_interval` **after** `serve()`, not at startup. Keep the interval
well under your restart cadence: a server restarted more often than `prune_interval` never
prunes. A throwing `prune` is logged and costs that one tick; the next tick runs as usual.

# Security: what a record carries

By default a record carries the request **path only**, reduced the same way the console
access log (`serve(access_log=true)`) reduces it: `record.query` is `nothing`, and an
absolute-form target (`GET http://user:pa55w0rd@host/x`) is cut to `/x`, so a well-formed
authority and any credentials in it never reach the sink. Query strings routinely carry secrets
(password-reset and magic-link tokens, OAuth `code`/`state`, signed-URL signatures), and an
access-log table or aggregator is rarely guarded like the secrets themselves.

Pass `log_query = true`, the counterpart of `serve(...; access_log_query = true)`, to record
the raw query when you are sure no sensitive data travels in your URLs. Records are never
escaped: a record is data, and the sink decides how to store or render it.
"""
function AccessLog(sink::Function; capacity::Integer=10_000, batch::Integer=500,
                   skip::Union{Nothing, Function}=nothing,
                   annotate::Union{Nothing, Function}=nothing,
                   log_query::Bool=false,
                   prune::Union{Nothing, Function}=nothing,
                   retention::Union{Nothing, Period}=nothing,
                   prune_interval::Union{Nothing, Period}=nothing)
    capacity > 0 || throw(ArgumentError("AccessLog capacity must be positive"))
    batch > 0 || throw(ArgumentError("AccessLog batch must be positive"))

    # Retention (#159). All validation happens HERE, at the caller's constructor call; a bad
    # `prune_interval` is rejected inside `_janitor` for the same reason. A pruner that only
    # discovered its misconfiguration on its first tick would fail an hour after deploy, silently.
    (prune === nothing) == (retention === nothing) || throw(ArgumentError(
        "AccessLog: `prune` and `retention` go together -- pass both to enable the retention " *
        "pruner, or neither. Got only `$(prune === nothing ? "retention" : "prune")`."))
    # `nothing` rather than a `Hour(1)` default, so an interval passed WITHOUT a pruner is an
    # error instead of being validated by nobody and ignored -- the same "never a silently
    # disabled pruner" rule as the check above.
    prune === nothing && prune_interval !== nothing && throw(ArgumentError(
        "AccessLog: `prune_interval` only applies to the retention pruner -- pass `prune` and " *
        "`retention` too, or drop it."))
    retention === nothing || Dates.value(retention) > 0 || throw(ArgumentError(
        "AccessLog: `retention` must be positive, got $retention."))
    pruner = prune === nothing ? nothing :
        # `now()`, not `now(UTC)`: the cutoff must come from the clock that stamps
        # `AccessRecord.ts` (`_capture!`), or every record is misjudged by the UTC offset.
        _janitor(() -> prune(now() - retention), something(prune_interval, Hour(1)),
                 "AccessLog", "retention prune", "prune_interval")

    w = _Writer(sink, Int(batch), Threads.Atomic{Bool}(false), _Run(Int(capacity)), nothing)

    middleware = function (handle::Function)
        return function (req::HTTP.Request)
            (w.active[] && !_skips(skip, req)) || return handle(req)
            r  = w.run       # snapshot this request's activation; a mid-request restart
            t0 = time_ns()   # can only cost this record, never corrupt the new generation.
            local resp
            try
                resp = handle(req)
            catch
                _capture!(r, req, nothing, t0, annotate, log_query)   # log the failure, re-raise
                rethrow()
            end
            _capture!(r, req, resp, t0, annotate, log_query)
            return resp
        end
    end

    start_writer = function ()
        w.active[] && return nothing
        r = _Run(Int(capacity))          # fresh activation; a prior drain task keeps its own
        w.run = r                        # plain write, published by the atomic store below
        w.active[] = true
        # @spawn (not @async) so a blocking sink runs on a threadpool thread, not one
        # shared with request handlers.
        w.task = errormonitor(Threads.@spawn _run(w.sink, r, w.batch))
        @info "Nitro.AccessLog started" capacity=r.capacity batch=w.batch
        return nothing
    end

    stop_writer = function ()
        w.active[] || return nothing
        w.active[] = false
        close(w.run.channel)                                # drains buffered records, then _run exits
        w.task === nothing || timedwait(() -> istaskdone(w.task), 5.0)
        return nothing
    end

    # Two independent resources, each idempotent on its own, so neither guard may short-circuit
    # the other: an early `return` in the writer half must not skip the pruner. The pruner stops
    # FIRST so the drain wait below is not spent with a prune still being scheduled.
    on_startup = function ()
        start_writer()
        pruner === nothing || pruner[1]()
        return nothing
    end

    on_shutdown = function ()
        pruner === nothing || pruner[2]()
        stop_writer()
        return nothing
    end

    return LifecycleMiddleware(; middleware, on_startup, on_shutdown)
end

end # module StructuredAccessLogMiddleware
