# NOTE on naming: `Nitro.Core` already owns the name `AccessLogMiddleware` — the
# console line-logger behind `serve(access_log=true)` (core.jl). This module is the
# *structured* counterpart (records to an app-supplied sink), so it carries a
# distinct name to keep the two from shadowing each other.
module StructuredAccessLogMiddleware

# Generic HTTP access logging for any Nitro app (API, SPA, or hybrid).
#
# `AccessLog(sink)` is a LifecycleMiddleware that captures one `AccessRecord` per
# handled request — method, path, query, status, duration, client IP, User-Agent,
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

export AccessLog, AccessRecord

const _EMPTY_CONTEXT = Dict{Symbol, Any}()

"""
    AccessRecord

One captured HTTP request. Framework-level fields plus `context`, an app-supplied
`Dict{Symbol,Any}` (from the `annotate` hook) carrying identity/tenant/session/etc.
The sink maps these onto whatever storage it uses.

- `ts`          — capture time (`Dates.now()`)
- `method`      — HTTP verb
- `path`        — request path, query stripped
- `query`       — raw query string, or `nothing`
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

function _capture!(r::_Run, req::HTTP.Request, resp, t0::UInt64, annotate)
    try
        # t0 is a `time_ns()` reading; the monotonic delta can never go negative.
        duration_ms = round(Int, (time_ns() - t0) / 1_000_000)
        target = String(req.target)
        qidx = findfirst('?', target)
        path = qidx === nothing ? target : target[1:prevind(target, qidx)]
        query = (qidx === nothing || qidx == lastindex(target)) ? nothing :
                String(target[nextind(target, qidx):end])
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
    AccessLog(sink; capacity=10_000, batch=500, skip=nothing, annotate=nothing)

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

Best-effort by contract: never blocks or throws into the request; a full buffer or a
failing sink costs records (counted and warned), never latency or correctness.
"""
function AccessLog(sink::Function; capacity::Integer=10_000, batch::Integer=500,
                   skip::Union{Nothing, Function}=nothing,
                   annotate::Union{Nothing, Function}=nothing)
    capacity > 0 || throw(ArgumentError("AccessLog capacity must be positive"))
    batch > 0 || throw(ArgumentError("AccessLog batch must be positive"))

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
                _capture!(r, req, nothing, t0, annotate)   # log the failed request, then re-raise
                rethrow()
            end
            _capture!(r, req, resp, t0, annotate)
            return resp
        end
    end

    on_startup = function ()
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

    on_shutdown = function ()
        w.active[] || return nothing
        w.active[] = false
        close(w.run.channel)                                # drains buffered records, then _run exits
        w.task === nothing || timedwait(() -> istaskdone(w.task), 5.0)
        return nothing
    end

    return LifecycleMiddleware(; middleware, on_startup, on_shutdown)
end

end # module StructuredAccessLogMiddleware
