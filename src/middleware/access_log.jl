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
using ...Core: getip, route_missed, LifecycleMiddleware
using ...Util: _log_target_path, _check_access_log_skip
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
- `matched`     — `false` only when the router found no route for the request (the 404/405 a
                  scanner probe gets, including a static mount's miss); see `route_missed`.
                  `true` otherwise, including a route that returns 404 itself and a request a
                  guard or middleware refused
- `duration_ms` — handler wall-clock, milliseconds
- `ip`          — client IP as a `String` (see module note), or `nothing`
- `user_agent`  — `User-Agent` header, or `nothing`
- `context`     — app-supplied extras (empty when no `annotate` hook is given)

`method`, `path`, `query` and `user_agent` are client-controlled, so each is cut to at most
`max_field_bytes` bytes (see [`AccessLog`](@ref)) and a cut value ends in `"…[truncated]"`.
"""
struct AccessRecord
    ts          :: DateTime
    method      :: String
    path        :: String
    query       :: Union{Nothing, String}
    status      :: Int
    matched     :: Bool
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
#
# `queued_unmatched` is the same reservation, counted only for records no route answered
# (#401). It is bounded by `unmatched_capacity`, so a probe flood can hold at most that many
# slots and the rest of the buffer stays free for the requests an audit log exists for.
mutable struct _Run
    channel            :: Channel{AccessRecord}
    capacity           :: Int
    unmatched_capacity :: Int
    queued             :: Threads.Atomic{Int}
    queued_unmatched   :: Threads.Atomic{Int}
    dropped            :: Threads.Atomic{Int}
    dropped_unmatched  :: Threads.Atomic{Int}
end
_Run(capacity::Int, unmatched_capacity::Int) =
    _Run(Channel{AccessRecord}(capacity), capacity, unmatched_capacity,
         Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
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
#
# `skip` runs AFTER the handler and sees the response (#401): `resp` is the `HTTP.Response`, or
# `nothing` when the handler threw. A pre-handler `req -> Bool` could not tell a scanner's
# unmatched 404 from a real request, which is the one distinction a probe filter needs.
function _skips(skip, req, resp)::Bool
    skip === nothing && return false
    try
        return skip(req, resp) === true
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

# Unmatched means the router positively answered "no route" (`route_missed`), never merely "no
# `:route` written": `:route` is set at the terminal, after global and route middleware, so a
# guard's 403 on a real route has no `:route` either. Reading its absence put every denied login
# in the small unmatched budget, and dropped it under the documented filter (review of #401).
# Unknown therefore counts as matched -- the audit log never sheds a record it cannot prove was
# a probe.
_matched(req::HTTP.Request)::Bool = !route_missed(req)

# ── Enqueue (request task): reserve a slot without blocking, else drop ──────────
function _enqueue!(r::_Run, rec::AccessRecord)
    # An unmatched record reserves from its own, smaller budget FIRST (#401). Dropping the
    # NEWEST record is right for a slow sink, but on its own it let a probe flood fill the buffer
    # and then drop every real request arriving during the sweep -- an attacker could blind the
    # audit trail on purpose. With this reservation the flood can never hold more than
    # `unmatched_capacity` slots, so matched records always keep `capacity - unmatched_capacity`.
    unmatched = !rec.matched
    if unmatched && Threads.atomic_add!(r.queued_unmatched, 1) >= r.unmatched_capacity
        Threads.atomic_sub!(r.queued_unmatched, 1)
        Threads.atomic_add!(r.dropped_unmatched, 1)
        return nothing
    end
    # Reserve first: if we'd exceed capacity, drop instead of blocking the request on
    # a full buffer (a slow sink then costs records, never latency). capacity == channel
    # size, so a granted reservation guarantees put! has room and won't block.
    if Threads.atomic_add!(r.queued, 1) >= r.capacity
        Threads.atomic_sub!(r.queued, 1)
        unmatched && Threads.atomic_sub!(r.queued_unmatched, 1)
        Threads.atomic_add!(r.dropped, 1)
        return nothing
    end
    try
        put!(r.channel, rec)
    catch
        Threads.atomic_sub!(r.queued, 1)   # channel closed mid-shutdown, etc.
        unmatched && Threads.atomic_sub!(r.queued_unmatched, 1)
    end
    return nothing
end

# Every client-controlled string field is cut to `max_bytes` bytes, marker included (#401).
# HTTP.jl's only bound is its 64 KiB line limit, so at the default capacity a buffer of
# long-path, long-User-Agent probes could hold about 1.25 GiB before the sink saw any of it, and
# every sink ended up truncating on its own to fit its columns. Cut on a character boundary so
# the result is still valid UTF-8 wherever the input was.
const _TRUNCATED = "…[truncated]"

function _truncate_field(s::AbstractString, max_bytes::Int)::String
    ncodeunits(s) <= max_bytes && return String(s)
    keep = max_bytes - ncodeunits(_TRUNCATED)
    # `thisind` lands on the start of the character holding byte `keep + 1`; the character before
    # it is the last one that ends within `keep` bytes, so a straddling character is dropped whole.
    stop = keep < 1 ? 0 : prevind(s, thisind(s, keep + 1))
    return string(SubString(s, 1, stop), _TRUNCATED)
end
_truncate_field(::Nothing, ::Int) = nothing

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
function _capture!(r::_Run, req::HTTP.Request, resp, t0::UInt64, annotate, log_query::Bool,
                   max_field_bytes::Int)
    try
        # t0 is a `time_ns()` reading; the monotonic delta can never go negative.
        duration_ms = round(Int, (time_ns() - t0) / 1_000_000)
        target = String(req.target)
        path = _truncate_field(_log_target_path(target), max_field_bytes)
        query = log_query ? _truncate_field(_raw_query(target), max_field_bytes) : nothing
        status = resp isa HTTP.Response ? Int(resp.status) : (resp === nothing ? 500 : 200)
        ipaddr = getip(req)
        ip = ipaddr === nothing ? nothing : string(ipaddr)
        ua = HTTP.header(req, "User-Agent", "")
        user_agent = isempty(ua) ? nothing : _truncate_field(ua, max_field_bytes)
        method = _truncate_field(req.method, max_field_bytes)
        rec = AccessRecord(now(), method, path, query, status, _matched(req), duration_ms,
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
        _release!(r, rec)
        batch = AccessRecord[rec]
        while length(batch) < max_batch && isready(r.channel)
            rec = take!(r.channel)
            _release!(r, rec)
            push!(batch, rec)
        end
        _flush!(sink, batch)
        _report_drops(r)
    end
    return nothing
end

# Give back the reservation(s) `_enqueue!` took for a record the writer has now taken.
function _release!(r::_Run, rec::AccessRecord)
    Threads.atomic_sub!(r.queued, 1)
    rec.matched || Threads.atomic_sub!(r.queued_unmatched, 1)
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
    u = Threads.atomic_xchg!(r.dropped_unmatched, 0)
    u == 0 || @warn "AccessLog: dropped $u unmatched record(s) (unmatched_capacity full)"
    return nothing
end

"""
    AccessLog(sink; capacity=10_000, unmatched_capacity=capacity ÷ 10, batch=500,
              skip=nothing, annotate=nothing, log_query=false, max_field_bytes=2048,
              prune=nothing, retention=nothing, prune_interval=nothing)

Build a `LifecycleMiddleware` that asynchronously records every handled request and
delivers batches to `sink(::Vector{AccessRecord})`. Add it to `serve(middleware=[…])`;
its background writer starts and stops with the server.

- `sink`      — `Vector{AccessRecord} -> Any`, called on the writer task (may block/do I/O)
- `capacity`  — max buffered records before new ones are dropped (protects the hot path)
- `unmatched_capacity` — how many of those slots records with `matched == false` may hold;
                see *Scanner traffic* below. An integer in `1:capacity`
- `batch`     — max records delivered to `sink` per call
- `skip`      — optional `(req, resp) -> Bool`, called **after** the handler; return `true` to
                NOT log the request. `resp` is the `HTTP.Response`, or `nothing` when the
                handler threw. A one-argument `req -> Bool` hook is an `ArgumentError`
- `annotate`  — optional `req -> Dict{Symbol,Any}`; its result becomes `record.context`
                (e.g. `req -> Dict(:user => current_user_id(req))`)
- `log_query` — record the query string in `record.query`. Off by default; see below
- `max_field_bytes` — cap, in bytes and marker included, on each of `method`, `path`,
                `query` and `user_agent`; a longer value is cut on a character boundary and ends
                in `"…[truncated]"`
- `prune`, `retention`, `prune_interval` — optional retention pruner; see below

Best-effort by contract: never blocks or throws into the request; a full buffer or a
failing sink costs records (counted and warned), never latency or correctness.

# Scanner traffic

Global middleware runs on unmatched routes too (#71), so an internet-facing app logs every probe
for `/.env` or `/wp-login.php`. Two things keep those from crowding out the records an audit log
is for (#401):

- **Filter them out.** `skip` sees the response, and `route_missed(req)` says whether the router
  found no route (also exposed as `!record.matched`):

  ```julia
  AccessLog(sink; skip = (req, resp) -> route_missed(req))   # drop router 404/405 misses
  ```

  A route that returns 404 itself is not a miss, and neither is a request a guard or middleware
  refused, so a denied login is never filtered as a probe. The flip side: a global middleware
  listed after `AccessLog` that refuses a request **before** the router runs (an app-wide
  `BearerAuth`, a `RateLimiter`) leaves no lookup to report, so a probe it refuses counts as
  matched. Filter on `resp.status` there if you need to. Under an SPA history-mode fallback
  (`spafiles`) every GET is answered by the shell, so a probe there is matched too; filter on the
  path.
- **Bound them.** Records with `matched == false` may hold at most `unmatched_capacity` buffer
  slots; past that, *they* are dropped (counted and warned separately) and the remaining
  `capacity - unmatched_capacity` slots stay free for matched requests. A probe flood can no
  longer make the buffer drop the authenticated requests that arrive during it.

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
a silently disabled pruner, and so is a `prune_interval` with no pruner to apply it to. The
pruner starts and stops with the server alongside the writer, and a
`serve(); terminate(); serve()` cycle does not leak its task.

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
function AccessLog(sink::Function; capacity::Integer=10_000,
                   unmatched_capacity::Integer=max(1, capacity ÷ 10), batch::Integer=500,
                   skip::Union{Nothing, Function}=nothing,
                   annotate::Union{Nothing, Function}=nothing,
                   log_query::Bool=false,
                   max_field_bytes::Integer=2048,
                   prune::Union{Nothing, Function}=nothing,
                   retention::Union{Nothing, Period}=nothing,
                   prune_interval::Union{Nothing, Period}=nothing)
    capacity > 0 || throw(ArgumentError("AccessLog capacity must be positive"))
    1 <= unmatched_capacity <= capacity || throw(ArgumentError(
        "AccessLog unmatched_capacity must be in 1:capacity (1:$capacity), got $unmatched_capacity"))
    batch > 0 || throw(ArgumentError("AccessLog batch must be positive"))
    # Room for at least one character beside the marker, so a cut value is never marker-only.
    max_field_bytes > ncodeunits(_TRUNCATED) || throw(ArgumentError(
        "AccessLog max_field_bytes must be > $(ncodeunits(_TRUNCATED)) (the truncation marker's " *
        "size), got $max_field_bytes"))
    _check_access_log_skip(skip, "AccessLog")
    field_cap = Int(max_field_bytes)

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

    w = _Writer(sink, Int(batch), Threads.Atomic{Bool}(false),
                _Run(Int(capacity), Int(unmatched_capacity)), nothing)

    middleware = function (handle::Function)
        return function (req::HTTP.Request)
            w.active[] || return handle(req)
            r  = w.run       # snapshot this request's activation; a mid-request restart
            t0 = time_ns()   # can only cost this record, never corrupt the new generation.
            local resp
            try
                resp = handle(req)
            catch
                # Log the failure, re-raise. `skip` sees `nothing` for the response.
                _skips(skip, req, nothing) ||
                    _capture!(r, req, nothing, t0, annotate, log_query, field_cap)
                rethrow()
            end
            _skips(skip, req, resp) || _capture!(r, req, resp, t0, annotate, log_query, field_cap)
            return resp
        end
    end

    start_writer = function ()
        w.active[] && return nothing
        # Fresh activation; a prior drain task keeps its own.
        r = _Run(Int(capacity), Int(unmatched_capacity))
        w.run = r                        # plain write, published by the atomic store below
        w.active[] = true
        # @spawn (not @async) so a blocking sink runs on a threadpool thread, not one
        # shared with request handlers.
        w.task = errormonitor(Threads.@spawn _run(w.sink, r, w.batch))
        @info "Nitro.AccessLog started" capacity=r.capacity unmatched_capacity=r.unmatched_capacity batch=w.batch
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
