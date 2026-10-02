module RateLimiterMiddleware
using HTTP
using Dates
using Sockets
using ...Core: getip, header_name_isequal, own_response_headers
using ...Errors: is_unrecoverable

# Import top level types module
using ...Types 
using ..ExtractIPMiddleware: ExtractIP, _norm, _full_mask
using ..JanitorMiddleware: _janitor, _janitor_loop

export RateLimiter

# Response returned when the limiter fails closed (its default). Built fresh per
# call so callers can't mutate a shared response object's headers.
SERVICE_UNAVAILABLE() = HTTP.Response(503, "Service Unavailable")

"""
    RateLimiter(; strategy::Symbol = :fixed_window, kwargs...)

Per-client request rate limiting, as a [`LifecycleMiddleware`](@ref).
Every keyword other than `strategy` is forwarded to the chosen strategy.

`strategy` picks the algorithm, and **only the algorithm** — both strategies return the same
type (#172), so nothing about composing the result depends on which one you chose:

- `:fixed_window` (default) — [`FixedRateLimiter`](@ref). One counter per client per window,
  reaped by a background sweep that `serve()` starts and `terminate()` stops. Cheapest per
  request; a client can burst across a window boundary.
- `:sliding_window` — [`SlidingRateLimiter`](@ref). One timestamp per request per client,
  pruned inline. No background task, so both lifecycle hooks are `nothing`. More precise, more
  memory.

Both key on a *prefix* of the client address — `/32` for IPv4 and `/64` for IPv6 by default —
so an IPv6 client cannot buy quota by rotating source addresses inside its own allocation
(#22). See the two strategy docstrings for the full keyword list.

# Capacity

Both hold about `max_clients` client buckets (default 10 000; split across lock stripes, see
[`SlidingRateLimiter`](@ref)) and **never evict a live one** (#403). When the store is full, buckets whose window has ended are reaped on the spot;
if it is still full, a *new* client gets `503 Service Unavailable` with `Retry-After` — or is
let through unrecorded under `fail_open = true` — and a warning is logged, once per process
across all limiters. Clients
already being counted are unaffected. Evicting instead would hand a client rotating through
many addresses (one IPv6 /48 is 65 536 /64s) a fresh quota on every rotation, and reset
everyone else's. Raise `max_clients` if your app legitimately sees more distinct clients
within one `window`.

```julia
serve(app, middleware = [RateLimiter(rate_limit = 100, window = Minute(1))])

# Behind a proxy, name the proxy and the one header it writes:
RateLimiter(strategy = :sliding_window, rate_limit = 100,
            forwarded_header = :x_forwarded_for, trusted_proxies = [ip"127.0.0.1"])
```

`serve()` and `path()`/`urlpatterns()` accept the result directly; only code composing a
middleware chain by hand needs the `.middleware` field.

# Errors

`fail_open` is about the limiter's own failures: a request it cannot key (no client address),
an error in its bookkeeping, a full store. An exception from anything *below* the limiter is
never caught by it: a session store, a guard, a hand-composed handler, or under
`catch_errors = false` (or `serialize = false`) the route handler itself. That exception
propagates untouched and the downstream chain runs once (#421). It never becomes the limiter's
`503`. Nitro's error handling answers it as it would any other: a `500`, or a `400` for a
`ValidationError`. With `catch_errors = false` (or `serialize = false`), it reaches the server
unhandled.
"""
function RateLimiter(;strategy::Symbol = :fixed_window, kwargs...)
    # The element type is load-bearing: `Dict(kwargs)` narrows to the value type it happens to
    # see, so `RateLimiter(rate_limit=100)` built a `Dict{Symbol, Int64}` and missed the
    # `Dict{Symbol, Any}` signatures below with a `MethodError`. Only calls mixing two unrelated
    # value types widened to `Any` and worked, which is why the tests never caught it.
    kwargs_dict = Dict{Symbol, Any}(kwargs)

    # setup alias for :window_period => :window (for backwards compatibility for v1.9.0)
    rename_key!(kwargs_dict, :window_period, :window; message = "The :window_period keyword argument was renamed to :window")

    # `trust_forwarded` was removed here as well as on `ExtractIP` (#16). Deleting a keyword
    # outright leaves only Julia's bare "unsupported keyword argument", which names no
    # replacement, so reject it explicitly — this is a migration error, not a compatibility shim.
    reject_key!(kwargs_dict, :trust_forwarded,
        "RateLimiter: `trust_forwarded` was removed. It honored forwarding headers from every " *
        "peer and guessed which header to read, so a client connecting directly could choose " *
        "the IP its rate-limit bucket keyed on. Name the proxies you trust and the one header " *
        "they write instead, e.g. `RateLimiter(rate_limit=100, " *
        "forwarded_header=:x_forwarded_for, trusted_proxies=[ip\"127.0.0.1\"])`; " *
        "`trusted_proxies` accepts CIDR strings when your proxy addresses are dynamic.")

    # `cleanup_threshold` was removed (#319). The sweep deleted any bucket older than it, whether
    # or not the bucket's window had ended, so a threshold shorter than `window` handed a
    # throttled client a fresh quota mid-window. Julia's own error would name the keyword but not
    # say that dropping it loses nothing, which is the whole migration.
    reject_key!(kwargs_dict, :cleanup_threshold,
        "RateLimiter: `cleanup_threshold` was removed. The background sweep now deletes a " *
        "bucket as soon as its window has ended, and never before, so there is nothing left to " *
        "configure: an expired bucket answers exactly like a missing one. Drop the keyword; " *
        "`cleanup_period` still sets how often the sweep runs.")

    # Return the rate limiter middleware
    dispatch_rate_limiter(Val(strategy); kwargs_dict...)
end

# Call the RateLimiter based on the strategy
dispatch_rate_limiter(::Val{:fixed_window}; kwargs...) = FixedRateLimiter(;kwargs...)
dispatch_rate_limiter(::Val{:sliding_window}; kwargs...) = SlidingRateLimiter(;kwargs...)

# `strategy` was the last value this constructor READ without validating. With no fallback here,
# `strategy=:slidingwindow` produced a raw `MethodError` naming `dispatch_rate_limiter` -- an
# internal the caller has never heard of, cannot find in the docs, and which says nothing about
# `strategy` being the wrong argument or what the valid values are. Same reasoning as
# `reject_key!` below, applied to a value instead of a key: name the fix, not the mechanism.
# Every misconfiguration this constructor INSPECTS now throws an `ArgumentError` that names it --
# `trust_forwarded`, the `auto_extract_ip`/`forwarded_header`/`trusted_proxies` combination, the
# numeric bounds, and now `strategy` (#187).
#
# Not every misconfiguration, and deliberately so: neither strategy takes a catch-all `kwargs...`,
# so a keyword that does not exist on the chosen one -- `cleanup_period` under `:sliding_window`,
# say, or a plain typo -- still surfaces as Julia's keyword `MethodError`. That one at least names the
# offending keyword; this one named nothing the caller could act on.
#
# `::Val{S} where {S}`, not a bare `::Val`, so this is strictly less specific than the two methods
# above and can never shadow them.
dispatch_rate_limiter(::Val{S}; kwargs...) where {S} = throw(ArgumentError(
    "RateLimiter: unknown strategy $(repr(S)). Valid strategies are :fixed_window (default) " *
    "and :sliding_window."))

"""
Updates the key name inside a dictionary
"""
function rename_key!(kwargs_dict::Dict{Symbol, Any}, old_key::Symbol, new_key::Symbol; message::Union{String,Nothing}=nothing)
    if haskey(kwargs_dict, old_key)
        # show any custom warning message for this rename case
        if !isnothing(message) 
            @warn message
        end
        # remove and reassign value to new key
        kwargs_dict[new_key] = pop!(kwargs_dict, old_key)
    end
end

"""
Rejects a keyword that was removed outright, with a message naming what replaced it.

`rename_key!`'s sibling for the case where there is no new key to forward the value to.
"""
function reject_key!(kwargs_dict::Dict{Symbol, Any}, key::Symbol, message::String)
    haskey(kwargs_dict, key) && throw(ArgumentError(message))
end

"""
Builds the `ExtractIP` middleware the limiter composes in front of itself, or `nothing` when
`auto_extract_ip=false`.

`ExtractIP` is the only thing that acts on `forwarded_header`/`trusted_proxies`. Building it here
rather than inside the composed middleware moves its `ArgumentError` from `serve()` to
`RateLimiter(...)`, where the offending call actually is. With `auto_extract_ip=false` there is
nothing to build, so both keywords would be accepted, never validated, and silently have no
effect — the same "looks configured, isn't" failure `ExtractIP` throws to prevent, so reject the
combination rather than degrade into one bucket for every client.
"""
function build_ip_extractor(auto_extract_ip::Bool, forwarded_header::Symbol, trusted_proxies)
    if !auto_extract_ip
        if forwarded_header !== :none || trusted_proxies !== nothing
            throw(ArgumentError(
                "RateLimiter misconfiguration: `forwarded_header`/`trusted_proxies` have no " *
                "effect when `auto_extract_ip=false`, because the limiter then keys on whatever " *
                "`getip(req)` your own middleware assigned. Every client behind the proxy would " *
                "share one bucket while the setting looks active. Drop the two keywords and set " *
                "the IP yourself, or drop `auto_extract_ip=false` and let the limiter run " *
                "`ExtractIP` with them."))
        end
        return nothing
    end
    return ExtractIP(; forwarded_header, trusted_proxies)
end

# ── Bucket keying (#22) ────────────────────────────────────────────────────────────────────
#
# The bucket key is a PREFIX of the client address, not the address itself. Keying on the full
# address means an IPv6 client — who typically controls an entire /64, i.e. 2^64 addresses —
# gets a brand-new bucket for every request simply by picking a different source address inside
# their own allocation. The limit is then never reached, while the `X-RateLimit-*` headers keep
# reporting that limiting is in effect. Masking to /64 collapses that whole allocation onto one
# bucket. A client holding MANY /64s still gets one bucket per /64; what bounds that is the
# store's capacity policy (#403), below.
#
# Defaults are /32 for IPv4 (i.e. unchanged — one bucket per host) and /64 for IPv6.
# django-ratelimit (`RATELIMIT_IPV4_MASK`/`RATELIMIT_IPV6_MASK`) and HAProxy
# (`src,ipmask(32,64)`) independently settled on exactly this pair, and Cloudflare groups IPv6
# by /64 as well. Both are configurable because the right IPv6 prefix is a deployment fact, not
# a universal one: Let's Encrypt rate-limits by /48 because a single customer may hold one.
#
# `_norm` (src/middleware/extract_ip.jl) returns the family-tagged `(v6, host)` pair this masks,
# and demotes IPv4-mapped `::ffff:a.b.c.d` to its IPv4 form, so the mapped and plain spellings of
# one host share a bucket. Since #66 the socket peer already arrives demoted from the transport,
# but the fold still matters here: the key is built from `getip(req)`, which behind a trusted
# proxy is the HEADER-derived address, and which any middleware may have written with `setip!`.
#
# The key type is CONCRETE. The stores were previously `Dict{IPAddr,…}`/`LRU{IPAddr,…}`, whose
# key type is abstract, so every lookup boxed on the request hot path (nitro-core §7).
const BucketKey = Tuple{Bool, UInt128}

# Contiguous high-bit mask of `len` bits, in the family's width. Mirrors `_parse_prefix`'s mask
# construction in extract_ip.jl.
function _prefix_mask(v6::Bool, len::Int)
    bits = v6 ? 128 : 32
    full = _full_mask(v6)
    return (full << (bits - len)) & full
end

# Validates the two prefix lengths and resolves them to masks once, at construction.
#
# A /0 is rejected rather than accepted: it maps every client on the internet onto a single
# bucket, so the limiter would throttle the whole world collectively while still looking
# per-client. That is the same catch-all footgun `ExtractIP` rejects for `trusted_proxies`.
function _prefix_masks(ipv4_prefix::Int, ipv6_prefix::Int)
    (0 < ipv4_prefix <= 32) || throw(ArgumentError(
        "RateLimiter: ipv4_prefix must be between 1 and 32, got $ipv4_prefix. A /0 would put " *
        "every client in one shared bucket."))
    (0 < ipv6_prefix <= 128) || throw(ArgumentError(
        "RateLimiter: ipv6_prefix must be between 1 and 128, got $ipv6_prefix. A /0 would put " *
        "every client in one shared bucket."))
    return (_prefix_mask(false, ipv4_prefix), _prefix_mask(true, ipv6_prefix))
end

@inline function _bucket_key(ip::IPAddr, v4mask::UInt128, v6mask::UInt128)::BucketKey
    v6, host = _norm(ip)
    return (v6, host & (v6 ? v6mask : v4mask))
end

# ── Exempt paths (#319) ────────────────────────────────────────────────────────────────────
#
# An entry covers whole path segments, the rule `_strip_prefix` (src/core/framework_middleware.jl)
# has applied to `serve(prefix = …)` since #315: `/health` covers `/health`, `/health/…` and
# `/health?…`, and not `/healthz-admin`. The bare `startswith` this replaces exempted the last one
# too, so exempting a health check could lift the limit off a neighbouring route.
#
# An entry that already ends in `/` is bounded by that slash, so `"/static/"` and `"/"` match
# exactly what they matched before: the fix only narrows. The byte after a matched entry is
# compared against two ASCII bytes, which a UTF-8 continuation byte can never equal, so the byte
# offsets are safe on any target. `req.target` reaches middleware in canonical percent-encoding
# (#351), so an entry has to be written that way to match at all.
function _is_exempt(target::String, exempt_paths::Vector{String})::Bool
    for ex in exempt_paths
        startswith(target, ex) || continue
        n = ncodeunits(ex)
        (ncodeunits(target) == n || endswith(ex, '/')) && return true
        next = codeunit(target, n + 1)
        (next == UInt8('/') || next == UInt8('?')) && return true
    end
    return false
end

# ── Lock striping (#22) ────────────────────────────────────────────────────────────────────
#
# Buckets are independent — one per client prefix — but a single `store_lock` serialised every
# request through one critical section regardless, capping throughput independently of thread
# count. Striping splits the store into N independent `(lock, store)` pairs chosen by key hash,
# so two clients contend only when their keys collide. Same shape as Guava's `Striped` and
# pre-8 `ConcurrentHashMap`'s segments.
#
# It also shortens the LONGEST hold, not just the average: the fixed limiter's background sweep
# walks one stripe at a time, so it never blocks more than 1/N of the traffic at once.
#
# `next_reap` is the earliest instant any bucket in this stripe can have expired — a lower bound,
# since a bucket only ever moves its expiry later. It is what lets a full stripe skip the reaping
# scan until reaping could actually free a slot; see `_has_room!`.
struct _Stripe{S}
    lock      :: ReentrantLock
    store     :: S
    next_reap :: Base.RefValue{DateTime}
end

# `typemin`: nothing is known about the store yet, so the first full-stripe check scans.
_Stripe(lock::ReentrantLock, store::S) where {S} = _Stripe{S}(lock, store, Ref(typemin(DateTime)))

# Power of two, so stripe selection is a mask rather than a division.
const _DEFAULT_STRIPES = 16

_make_stripes(build, n::Int) = [_Stripe(ReentrantLock(), build()) for _ in 1:n]

@inline function _stripe_for(stripes::Vector{<:_Stripe}, key::BucketKey)
    return @inbounds stripes[(hash(key) & UInt(length(stripes) - 1)) + 1]
end

# Stripe count for a size-BOUNDED store — both strategies' since #403. Each stripe gets its own
# share of `max_clients`, so N stripes over a small `max_clients` would turn clients away far
# earlier than the caller asked for — with `max_clients=100`, 16 stripes of 7 entries each would
# refuse a client while the store held 30. Keep at least ~64 entries per stripe and fall back to
# a single stripe for small stores, where the bound is exact.
const _MIN_ENTRIES_PER_STRIPE = 64

function _bounded_stripe_count(max_entries::Int)
    # `fld`, not `cld`: rounding the stripe count UP is what breaks the floor. With
    # `cld`, max_entries=500 gives 8 stripes and cld(500, 8) == 63 entries each — just
    # under the very bound this function exists to hold.
    max_entries >= 2 * _MIN_ENTRIES_PER_STRIPE || return 1
    return min(_DEFAULT_STRIPES, prevpow(2, fld(max_entries, _MIN_ENTRIES_PER_STRIPE)))
end

# Reaps every bucket whose window has ended, and no other.
#
# `window` is the only safe age (#319). A bucket past it answers exactly like a missing one: the
# request path's "expired window" case and its "new client" case both store `(1, now)` and report
# a full window, so deleting it changes no response. A bucket inside it is a client's count, and
# deleting that hands a throttled client a fresh quota. The age used to be a separate
# `cleanup_threshold` (10 minutes by default) that was never compared with `window`, so any longer
# window was cut to about the threshold: `window = Hour(1)` on a login route let a brute-forcer
# back in within 10-20 minutes. The comparison is the request path's own strict `>`, so the two
# agree about which buckets have expired.
#
# A named function rather than an inline loop so the janitor's `try` wraps ONE call — the shape
# `_janitor_loop` (src/middleware/janitor.jl) now enforces for every janitor in Nitro, and which
# `_prune_janitor` feeds the same way with `prunesessions!`. An inline body invites a later edit
# to hoist the `try` outside the `while`, which turns a single transient failure into a
# permanently dead sweep with a still-green suite (#169).
function _sweep_expired!(stripes::Vector{<:_Stripe}, window::Period, current_time::DateTime)
    # One stripe at a time: the sweep is O(N) in that stripe, and holding all of them
    # would reinstate exactly the global stall striping exists to remove.
    for stripe in stripes
        lock(stripe.lock) do
            stripe.next_reap[] = _reap_expired!(stripe.store, window, current_time)
        end
    end
    return nothing
end

# ── Capacity (#403) ────────────────────────────────────────────────────────────────────────
#
# Per-/64 keying (#22) stops rotation INSIDE one allocation, but a client holding many /64s — a
# /56 is 256 of them, a /48 is 65,536, and hosting providers hand out both — still gets a fresh
# bucket per /64. Both stores are therefore capped at `max_clients`, and a full one REFUSES the
# new key rather than evicting a live bucket. Evicting is what the sliding limiter's LRU used to
# do, and it inverted the limiter: a rotating client evicted legitimate clients' buckets (their
# quota reset) and its own (every rotation started from a full quota), so capacity pressure
# lowered enforcement. The fixed window had no cap at all, so its memory scaled with attack rate
# x `cleanup_period`. Refusing is the fail-closed choice, matching the missing-IP 503 above; the
# coarser-prefix alternative (fold new keys onto a /48) still needs a terminal refusal for a
# client holding many /48s, so it would add machinery without removing this.
#
# An expired bucket answers exactly like a missing one (#319), so reaping it is never an
# eviction — it is what a full stripe does before it refuses anyone.
#
# Expiry is dispatched on the bucket type rather than passed as a closure, so the reaper stays
# concrete on the request path (nitro-core §7). `_expires_at` is the FIRST instant `_is_expired`
# holds, which is what makes `next_reap` exact rather than off by one tick.

# Fixed window: the request path's own strict `>` (see `_sweep_expired!`).
@inline _is_expired(b::Tuple{Int, DateTime}, window::Period, t::DateTime) = t - b[2] > window
@inline _expires_at(b::Tuple{Int, DateTime}, window::Period) = b[2] + window + Millisecond(1)

# Sliding window: expired once its newest timestamp is at or before the `filter!` cutoff, i.e.
# the request path would prune every timestamp. `maximum`, not `last`: a clock step backwards
# can push out of order, and reaping a bucket that still holds a live timestamp is an eviction.
@inline _is_expired(b::Vector{DateTime}, window::Period, t::DateTime) =
    isempty(b) || maximum(b) <= t - window
@inline _expires_at(b::Vector{DateTime}, window::Period) =
    isempty(b) ? typemin(DateTime) : maximum(b) + window

# Deletes every expired bucket and returns the earliest instant a survivor can expire (`typemax`
# when none survive). The caller holds the stripe's lock.
function _reap_expired!(store::AbstractDict{BucketKey}, window::Period, t::DateTime)::DateTime
    to_delete = BucketKey[]
    next = typemax(DateTime)
    # Collect first, delete after — mutating a collection while iterating it is not a supported
    # pattern. (On the current `Dict` a `delete!` only tombstones and never rehashes, so the
    # one-pass form happens to work; this does not depend on that.)
    for (key, bucket) in store
        if _is_expired(bucket, window, t)
            push!(to_delete, key)
        else
            next = min(next, _expires_at(bucket, window))
        end
    end
    for key in to_delete
        delete!(store, key)
    end
    return next
end

# Whether `stripe` can take one more bucket, reaping it first if it is full. The caller holds
# the stripe's lock and has already checked that the key is new.
#
# The scan runs only once `t` reaches `next_reap`. Without that gate a flood of refused keys
# would buy an O(stripe) walk under the lock on EVERY request, turning the refusal path into a
# CPU amplifier. `next_reap` is a lower bound (buckets only ever move their expiry later), so the
# gate can cost a fruitless scan but can never skip a reapable bucket.
function _has_room!(stripe::_Stripe, cap::Int, window::Period, t::DateTime)::Bool
    length(stripe.store) < cap && return true
    t >= stripe.next_reap[] || return false
    stripe.next_reap[] = _reap_expired!(stripe.store, window, t)
    return length(stripe.store) < cap
end

# Records a bucket just inserted into `stripe`. The caller holds the stripe's lock.
#
# This is what keeps `next_reap` a lower bound. A reap sets it from the buckets that SURVIVED, so
# without this a bucket inserted afterwards was invisible to it: a reap that emptied the stripe
# left `typemax`, the gate in `_has_room!` never opened again, and once that stripe refilled it
# refused every new client -- for the life of the process under the sliding strategy, which has
# no sweep. It also covers a wall clock stepping backwards, which can give a new bucket an
# earlier expiry than any survivor.
@inline _note_expiry!(stripe::_Stripe, expires_at::DateTime) =
    (stripe.next_reap[] = min(stripe.next_reap[], expires_at); nothing)

# Seconds a refused client should wait: until the stripe's next bucket can expire, which is the
# soonest a slot can free up. Clamped to [1, window], and the typemax case is caught before the
# subtraction rather than after it.
@inline function _retry_after(next_reap::DateTime, t::DateTime, window_seconds::Int)::Int
    next_reap >= t + Second(window_seconds) && return window_seconds
    return clamp(ceil(Int, Dates.value(next_reap - t) / 1000), 1, window_seconds)
end

# `Retry-After` granularity is a second, and a sub-second window still has to say "1".
_window_seconds(window::Period) = max(1, ceil(Int, Dates.toms(window) / 1000))

# The decision both strategies' `decide` returns, as the first element of a concrete
# `Tuple{Int,Int,Int}` (see the #364 note in `FixedRateLimiter`). `_ADMIT`/`_LIMIT`/`_FULL` come
# out of the lock; `_EXEMPT` and `_UNDECIDED` are reached before it. `_UNDECIDED` means the
# limiter could not do its job -- no client address, or an error in its own bookkeeping -- so
# `fail_open` picks the answer.
const _ADMIT     = 0
const _LIMIT     = 1
const _FULL      = 2
const _EXEMPT    = 3
const _UNDECIDED = 4

# A new client arrived at a full stripe. Outside the lock: it logs and may run the handler.
#
# `maxlog=1` makes the warning one-shot per process — an operator learns that the store filled
# (address rotation, or a `max_clients` too small for real traffic) before a user reports it,
# without a log line per refused request. It names no address: the point is the capacity event.
# `fail_open` lets the client through UNRECORDED; it already means "prefer availability when the
# limiter cannot do its job", and a full store is that case.
function _refuse_new_client(handle::Function, req::HTTP.Request, fail_open::Bool,
                            retry_after::Int, max_clients::Int)
    @warn "RateLimiter: the client store is full, so new clients are being refused until a " *
          "bucket's window ends. One host rotating through many addresses (e.g. IPv6 /64s " *
          "inside a /48) fills it; raise `max_clients` if this is legitimate traffic." max_clients maxlog=1
    fail_open && return handle(req)
    resp = SERVICE_UNAVAILABLE()
    HTTP.setheader(resp, "Retry-After" => string(retry_after))
    return resp
end

# Acts on a decision -- the half of the request path that may run the downstream chain, shared
# by both strategies. It is called OUTSIDE the limiter's `try` and reaches `handle(req)` at most
# once, so whatever the chain throws propagates untouched to `ErrorBoundary` or the caller (#421).
# Both strategies used to run this inside the `try` that guards their bookkeeping, so a
# downstream exception was read as a limiter failure: logged under the limiter's label and
# answered `503`, or under `fail_open` sent through the chain a second time.
#
# `limit_body` is the strategy's own 429 text; the two have always differed.
function _respond(handle::Function, req::HTTP.Request, outcome::Int, remaining::Int,
                  reset_time::Int, rate_limit::Int, fail_open::Bool, max_clients::Int,
                  limit_body::String)
    outcome == _EXEMPT && return handle(req)
    # Fail closed by default: a bug or attacker-triggered error in the limiter must not become a
    # way to bypass the limit. `fail_open = true` prefers availability instead.
    outcome == _UNDECIDED && return fail_open ? handle(req) : SERVICE_UNAVAILABLE()
    outcome == _FULL && return _refuse_new_client(handle, req, fail_open, reset_time, max_clients)
    if outcome == _LIMIT
        resp = HTTP.Response(429, limit_body)
        set_rate_headers!(resp, rate_limit, 0, reset_time)
        return resp
    end
    # Own the handler's (possibly shared/`const`) response before adding headers.
    response = own_response_headers(handle(req))
    set_rate_headers!(response, rate_limit, remaining, reset_time)
    return response
end

# This limiter's janitor `work`, and the labels its failures are logged under — defined once so
# `_cleanup_loop` and `FixedRateLimiter` cannot drift apart the way the three janitors #190
# collapsed did. `now(UTC)` is evaluated per tick, inside the closure, not captured here.
const _SWEEP_LABEL = "RateLimiter"
const _SWEEP_WHAT  = "bucket cleanup sweep"
_sweep_work(stripes::Vector{<:_Stripe}, window::Period) =
    () -> _sweep_expired!(stripes, window, now(UTC))

# The janitor loop, now this limiter's `work` bound to the shared loop in `_janitor_loop`
# (src/middleware/janitor.jl), which owns the `try` placement (#169), the post-`sleep` token
# re-check and the `InterruptException` rethrow for every janitor in Nitro (#190).
#
# Still a named function with this signature, for the reason it always had one: it lets a test
# drive the loop over a deliberately-failing store, which is the only way in — the limiter's own
# stripes are closure-local. `test/middleware/lifecycle_middleware_tests.jl` imports it by name.
#
# `token` is per activation, never a shared `running` flag — see `_janitor`.
function _cleanup_loop(token::Ref{Bool}, stripes::Vector{<:_Stripe},
                       cleanup_period::Period, window::Period)
    return _janitor_loop(_sweep_work(stripes, window),
                         token, cleanup_period, _SWEEP_LABEL, _SWEEP_WHAT)
end

"""
    FixedRateLimiter(; rate_limit::Int = 100, window::Period = Minute(1), cleanup_period::Period = Minute(10), max_clients::Int = 10000, auto_extract_ip::Bool = true, forwarded_header::Symbol = :none, trusted_proxies = nothing, fail_open::Bool = false, exempt_paths::Vector{String} = String[], ipv4_prefix::Int = 32, ipv6_prefix::Int = 64)

Creates a middleware function that enforces rate limiting based on IP address, with automatic background cleanup to prevent memory leaks.

# Arguments
- `rate_limit::Int`: Maximum number of requests allowed per IP within the window period. Default is 100. Must be positive.
- `window::Period`: Time window for rate limiting. Default is 1 minute. Must be a positive fixed-length `Period`; calendar periods (`Month`, `Quarter`, `Year`) are rejected.
- `cleanup_period::Period`: How often the background sweep runs. Default is 10 minutes. Must be a positive fixed-length `Period`. The sweep deletes every client entry whose window has ended, and never one whose window is still running, so a throttled client stays throttled for the whole `window` and an idle client's entry is held for at most `window + cleanup_period`.
- `max_clients::Int`: Maximum distinct client buckets held at once. Default 10000. Must be positive. A full store refuses a *new* client with 503 rather than evicting a live bucket; see *Capacity* in [`RateLimiter`](@ref).
- `auto_extract_ip::Bool`: If `true` (default), the middleware will automatically extract the client IP address from the request using the built-in extractor. Setting `false` is incompatible with `forwarded_header`/`trusted_proxies`, since nothing would then apply them.
- `forwarded_header::Symbol`: Forwarded to [`ExtractIP`](@ref) — the single header your reverse proxy writes. Any value `ExtractIP` accepts, `:none` being the default. Must be set together with `trusted_proxies`.
- `trusted_proxies`: Forwarded to [`ExtractIP`](@ref) — the proxies whose forwarding header may be believed, as `IPAddr` values or CIDR strings (`"10.244.0.0/16"`). The header is read only when the socket peer matches one of them.
- `fail_open::Bool`: If `true`, an internal error in the limiter lets the request through instead of returning 503, and so does a *new* client arriving at a full store — admitted unrecorded, so a client rotating addresses while the store is full is not limited at all. Default `false` (fail closed). Only the limiter's own failures count: an exception from the downstream chain is never caught here, so it reaches Nitro's error handling unchanged and the chain runs once.
- `exempt_paths::Vector{String}`: Request paths to skip rate limiting. Default is empty. Each entry covers whole path segments: `"/health"` exempts `/health`, `/health/live` and `/health?full=1`, but not `/healthz`. An entry ending in `/` covers only what is below it. Entries are compared with `req.target`, whose path is in canonical percent-encoding by the time middleware runs, so write them that way (`"/caf%C3%A9"`, not `"/café"`).
- `ipv4_prefix::Int`: Network prefix length the IPv4 bucket key is masked to. Default 32 — one bucket per host, i.e. unchanged. Must be 1-32.
- `ipv6_prefix::Int`: Network prefix length the IPv6 bucket key is masked to. Default 64. Must be 1-128. A single IPv6 host normally controls a whole /64, so keying on the full /128 lets a client rotate source addresses inside its own allocation and never reach the limit; /64 collapses the allocation onto one bucket. Widen to /48 if your clients hold /48s (Let's Encrypt limits this way), narrow only if you know your addressing.

# Behind a reverse proxy
Without `trusted_proxies`, every client shares the proxy's socket address and therefore one rate-limit bucket. Declaring the proxy and the header it writes restores per-client limits:

```julia
RateLimiter(rate_limit = 100,
            forwarded_header = :x_forwarded_for,
            trusted_proxies  = [ip"127.0.0.1"])
```

Forwarding headers are **never** honored from a peer that is not a listed proxy, so a client cannot pick its own bucket. See [`ExtractIP`](@ref) for the full trust model.

# Customization
To customize IP extraction, set `auto_extract_ip=false` and insert your own middleware before the rate limiter to assign the desired IP address to `getip(req)`. This is useful for advanced scenarios such as extracting IPs from custom headers, authentication tokens, or supporting non-standard proxy setups.

# Note
This implementation uses UTC time to avoid timezone and DST issues. Significant system clock adjustments (NTP sync, manual changes) may temporarily affect rate limiting accuracy.

Concurrency: the store is striped across independent locks chosen by bucket-key hash, so two clients contend only when their keys collide. The background sweep walks one stripe at a time and therefore never stalls more than its share of the traffic.

# Returns
A [`LifecycleMiddleware`](@ref). Its `on_startup` spawns the background
cleanup sweep and `on_shutdown` signals it to stop, so `serve()` and `terminate()` own the task's
lifetime. Pass it straight to `serve(middleware = [...])` or `path(...; middleware = [...])`; only
hand-composition needs its `.middleware` field.
"""
function FixedRateLimiter(;
    rate_limit          :: Int = 100,
    window              :: Period = Minute(1),
    cleanup_period      :: Period = Minute(10),
    max_clients         :: Int = 10000,
    auto_extract_ip     :: Bool = true,
    forwarded_header    :: Symbol = :none,
    trusted_proxies     :: Union{Nothing, AbstractVector} = nothing,
    fail_open           :: Bool = false,
    exempt_paths        :: Vector{String} = String[],
    ipv4_prefix         :: Int = 32,
    ipv6_prefix         :: Int = 64)

    # Validate parameters
    rate_limit > 0 || throw(ArgumentError("rate_limit must be positive, got $rate_limit"))
    # `Dates.value(...) > 0` was the old test and it admits calendar periods: `Month(1)` has
    # value 1, so it passed, and then `sleep(cleanup_period)` threw inside the sweep — which was
    # an un-monitored `@async` at the time, so the background cleanup died silently for the life
    # of the process. #169 closed that second half; this check still closes the first, and
    # rejecting at construction still beats reporting from a background task.
    require_fixed_period("window", window)
    require_fixed_period("cleanup_period", cleanup_period)
    max_clients > 0 || throw(ArgumentError("max_clients must be positive, got $max_clients"))
    v4mask, v6mask = _prefix_masks(ipv4_prefix, ipv6_prefix)

    # Validates the trust configuration here, not at `serve()` — see `build_ip_extractor`.
    extract_client_ip = build_ip_extractor(auto_extract_ip, forwarded_header, trusted_proxies)

    # Striped store — see `_Stripe`. Capped at `max_clients` split across the stripes (#403); it
    # used to be unbounded, reaped only by the sweep below, so between sweeps it held one entry
    # per distinct prefix seen — memory a client rotating through many /64s controlled.
    nstripes = _bounded_stripe_count(max_clients)
    per_stripe = cld(max_clients, nstripes)
    stripes = _make_stripes(() -> Dict{BucketKey, Tuple{Int, DateTime}}(), nstripes)
    window_seconds = _window_seconds(window)
    
    # The hooks, and every piece of discipline behind them, come from `_janitor`
    # (src/middleware/janitor.jl): the per-activation stop token that stops a restart leaking a
    # task (#82), `Threads.@spawn`-not-`@async` and `errormonitor` (#169), the per-tick `try`, and
    # the `finally` that retires the activation so a janitor whose loop died can be restarted
    # (#185). All three of Nitro's janitors were hand-rolled copies of this and had drifted, which
    # is #190 — read that file for the full rationale rather than re-deciding any of it here.
    #
    # `on_startup` returns the `Task` it spawned (or `nothing` if one was live); `on_shutdown`
    # returns the `Task` it signalled. `startup(::LifecycleMiddleware)` discards both, but tests
    # call the hooks directly to get task handles, which is the only way to observe that a stale
    # activation's task actually exits. Keep these return values.
    #
    # `require_fixed_period("RateLimiter: cleanup_period", ...)` fires inside `_janitor` too; the
    # explicit call above stays because it names the keyword the caller actually typed.
    #
    # The sweep reaps at `window`, the age at which the request path would reset a bucket anyway.
    # Reaping at any shorter age cuts the window short for a throttled client (#319); see
    # `_sweep_expired!`.
    on_startup, on_shutdown = _janitor(_sweep_work(stripes, window), cleanup_period,
                                       _SWEEP_LABEL, _SWEEP_WHAT, "cleanup_period")

    # The limiter's own work for one request, and nothing else: it never calls `handle`, so the
    # `try` around it in `rate_limit_only` catches only the limiter's failures (#421). Returns
    # `(outcome, remaining_requests, reset_time)`; see `_ADMIT` and `_respond`.
    function decide(req::HTTP.Request)::Tuple{Int,Int,Int}
        _is_exempt(req.target, exempt_paths) && return (_EXEMPT, 0, 0)

        # No client address means there is no bucket to key on. Without this guard the
        # `nothing` reaches `_bucket_key` and fails closed via the catch, logging a backtrace
        # per request. Honour `fail_open` the same way.
        ip = getip(req)
        if ip === nothing
            @warn "Rate limiter: no client IP on this request; cannot apply a per-IP " *
                  "limit. Put `ExtractIP` before the limiter, or leave " *
                  "`auto_extract_ip=true`." maxlog=1
            return (_UNDECIDED, 0, 0)
        end

        # Derive the key and pick the stripe BEFORE taking the lock — neither needs it,
        # and both used to run inside the critical section (`getip` was also called a
        # second time in there).
        key = _bucket_key(ip, v4mask, v6mask)
        stripe = _stripe_for(stripes, key)
        rate_limit_store = stripe.store

        # Each case RETURNS `(outcome, remaining_requests, reset_time)` as a concrete
        # `Tuple{Int,Int,Int}` -- `outcome` is `_ADMIT`/`_LIMIT`/`_FULL`, and for `_FULL`
        # the third slot is the `Retry-After`. These used to be locals declared above the
        # block and assigned inside it, which boxed them and handed `set_rate_headers!`
        # `Any`s on every request (#364) -- see the sliding limiter's note on the same
        # shape. `test/closure_boxing_tests.jl` now fails on any boxed closure in Nitro.
        return lock(stripe.lock) do
            current_time = now(UTC)

            if haskey(rate_limit_store, key)
                count, last_reset = rate_limit_store[key]

                # Case 2: Expired Window
                if current_time - last_reset > window
                    rate_limit_store[key] = (1, current_time)
                    # Reset to current time, so reset time is full window period
                    return (_ADMIT, rate_limit - 1,
                            calculate_reset_time(current_time, current_time, window))

                # Case 3: Limit Exceeded
                elseif count >= rate_limit
                    # Use original last_reset to calculate remaining time
                    return (_LIMIT, 0, calculate_reset_time(current_time, last_reset, window))

                # Case 4: Within Limit
                else
                    rate_limit_store[key] = (count + 1, last_reset)
                    # Calculate reset based on original last_reset
                    return (_ADMIT, rate_limit - (count + 1),
                            calculate_reset_time(current_time, last_reset, window))
                end
            end

            # Case 1: New IP -- the only case that grows the store, so the only one that
            # can find it full (#403). A full stripe refuses; it never evicts.
            if !_has_room!(stripe, per_stripe, window, current_time)
                return (_FULL, 0,
                        _retry_after(stripe.next_reap[], current_time, window_seconds))
            end
            bucket = (1, current_time)
            rate_limit_store[key] = bucket
            _note_expiry!(stripe, _expires_at(bucket, window))
            # Start from current time, full window period
            return (_ADMIT, rate_limit - 1,
                    calculate_reset_time(current_time, current_time, window))
        end
    end

    function rate_limit_only(handle::Function)
        return function(req::HTTP.Request)
            # The `try` covers `decide` ONLY. It used to wrap the whole request, `handle(req)`
            # included, which is #421 -- see `_respond`.
            outcome, remaining_requests, reset_time = try
                decide(req)
            catch error
                # An interrupt, a stack overflow or an out-of-memory is not a limiter outcome
                # (#254) -- the same carve-out every other middleware `catch` makes.
                is_unrecoverable(error) && rethrow()
                @error "Fixed Rate limiter error" exception=(error, catch_backtrace())
                (_UNDECIDED, 0, 0)
            end
            return _respond(handle, req, outcome, remaining_requests, reset_time,
                            rate_limit, fail_open, max_clients, "Rate limit exceeded")
        end
    end

    # If auto_extract_ip is true, then we'll use this composed version of the middleware
    function extract_ip_and_rate_limit(handle::Function) :: Function
        reduce(|>, [handle, rate_limit_only, extract_client_ip])
    end

    return LifecycleMiddleware(;
        middleware = auto_extract_ip ? extract_ip_and_rate_limit : rate_limit_only, 
        on_startup = on_startup,
        on_shutdown = on_shutdown
    )
end



"""
    SlidingRateLimiter(; rate_limit::Int=100, window::Period=Minute(1), max_clients::Int=10000, exempt_paths::Vector{String}=String[], auto_extract_ip::Bool=true, forwarded_header::Symbol=:none, trusted_proxies=nothing, fail_open::Bool=false, ipv4_prefix::Int=32, ipv6_prefix::Int=64)

Creates a middleware function that enforces rate limiting with a per-client log of request timestamps.
This implementation provides true sliding window behavior where each request creates its own expiration time,
offering more precise rate limiting than fixed windows but with higher memory usage.

# Arguments
- `rate_limit::Int`: Maximum requests per client per window. Default 100. Must be positive.
- `window::Period`: Sliding time window duration. Default 1 minute. Must be a positive fixed-length `Period`; calendar periods (`Month`, `Quarter`, `Year`) are rejected.
- `max_clients::Int`: Maximum distinct client buckets held at once. Default 10000. Must be positive. A full store refuses a *new* client with 503 rather than evicting a live bucket; see *Capacity* in [`RateLimiter`](@ref).
- `exempt_paths::Vector{String}`: Request paths to skip rate limiting. Default empty. Matched on whole path segments against the canonical `req.target`, exactly as for [`FixedRateLimiter`](@ref): `"/health"` exempts `/health` and `/health/live`, not `/healthz`.
- `auto_extract_ip::Bool`: If true, automatically extract IP address from request. Default true. Setting `false` is incompatible with `forwarded_header`/`trusted_proxies`, since nothing would then apply them.
- `forwarded_header::Symbol`: Forwarded to [`ExtractIP`](@ref) — the single header your reverse proxy writes. Any value `ExtractIP` accepts, `:none` being the default. Must be set together with `trusted_proxies`.
- `trusted_proxies`: Forwarded to [`ExtractIP`](@ref) — the proxies whose forwarding header may be believed, as `IPAddr` values or CIDR strings (`"10.244.0.0/16"`). The header is read only when the socket peer matches one of them.
- `fail_open::Bool`: If `true`, an internal error in the limiter lets the request through instead of returning 503, and so does a *new* client arriving at a full store — admitted unrecorded, so a client rotating addresses while the store is full is not limited at all. Default `false` (fail closed). Only the limiter's own failures count: an exception from the downstream chain is never caught here, so it reaches Nitro's error handling unchanged and the chain runs once.
- `ipv4_prefix::Int`: Network prefix length the IPv4 bucket key is masked to. Default 32 — one bucket per host, i.e. unchanged. Must be 1-32.
- `ipv6_prefix::Int`: Network prefix length the IPv6 bucket key is masked to. Default 64. Must be 1-128. A single IPv6 host normally controls a whole /64, so keying on the full /128 lets a client rotate source addresses inside its own allocation and never reach the limit; /64 collapses the allocation onto one bucket. Widen to /48 if your clients hold /48s (Let's Encrypt limits this way), narrow only if you know your addressing.

# Behind a reverse proxy
Without `trusted_proxies`, every client shares the proxy's socket address and therefore one rate-limit bucket. Declaring the proxy and the header it writes restores per-client limits:

```julia
RateLimiter(strategy = :sliding_window, rate_limit = 100,
            forwarded_header = :x_forwarded_for,
            trusted_proxies  = [ip"127.0.0.1"])
```

Forwarding headers are **never** honored from a peer that is not a listed proxy, so a client cannot pick its own bucket. See [`ExtractIP`](@ref) for the full trust model.

# Algorithm
Uses a sliding window approach where:
1. Each request timestamp is stored individually
2. On each request, expired timestamps are pruned
3. Current request count is checked against limit
4. A client with no live timestamps is reaped only when the store is full; it is never evicted
   while it still has one

The store is striped across independent locks (see `_Stripe`), and `max_clients` is divided
among the stripes, so the total bound holds to within one entry per stripe (the per-stripe
quota is rounded up). Capacity is per stripe too: a stripe holding an unusually busy share of
the key space fills, and refuses new clients, at its own quota. Stores too small to divide
(under 128 entries) use a single stripe, where the bound is exact.

# Note
- The `X-RateLimit-Reset` header indicates when the oldest request expires (when at least 1 request slot becomes available), not when the full quota resets.
- This implementation uses UTC time to avoid timezone and DST issues. Significant system clock adjustments (NTP sync, manual changes) may temporarily affect rate limiting accuracy.
- Concurrency: the downstream handler runs **outside** the limiter's internal lock, so a slow handler delays only its own request. The lock guards only the per-client timestamp bucket; `X-RateLimit-Remaining`/`-Reset` are sampled when the request is admitted.

# Returns
A [`LifecycleMiddleware`](@ref) whose `on_startup`/`on_shutdown` are
both `nothing` — this strategy owns no background task. Pass it straight to `serve(middleware =
[...])` or `path(...; middleware = [...])`; only hand-composition needs its `.middleware` field.
"""
function SlidingRateLimiter(;
    rate_limit      :: Int = 100,
    window          :: Period = Minute(1),
    max_clients     :: Int = 10000,
    exempt_paths    :: Vector{String} = String[],
    auto_extract_ip :: Bool = true,
    forwarded_header:: Symbol = :none,
    trusted_proxies :: Union{Nothing, AbstractVector} = nothing,
    fail_open       :: Bool = false,
    ipv4_prefix     :: Int = 32,
    ipv6_prefix     :: Int = 64)

    # Validate parameters
    rate_limit > 0 || throw(ArgumentError("rate_limit must be positive, got $rate_limit"))
    require_fixed_period("window", window)   # see FixedRateLimiter — calendar periods are unusable
    max_clients > 0 || throw(ArgumentError("max_clients must be positive, got $max_clients"))
    v4mask, v6mask = _prefix_masks(ipv4_prefix, ipv6_prefix)

    # Validates the trust configuration here, not at `serve()` — see `build_ip_extractor`.
    extract_client_ip = build_ip_extractor(auto_extract_ip, forwarded_header, trusted_proxies)

    # Striped store: BucketKey -> Vector of request timestamps. `max_clients` is split across the
    # stripes (rounded up, so the total may exceed `max_clients` by at most `nstripes - 1`) and
    # capacity becomes per-stripe — a hot stripe refuses at its own share rather than globally.
    # That is the standard sharded-cache trade; `_bounded_stripe_count` keeps it honest by
    # collapsing to a single stripe for small stores.
    #
    # A `Dict`, not the `LRU` it was until #403: a full stripe now refuses the new key (see
    # `_has_room!`) instead of evicting the least-recently-used client, so the recency order an
    # LRU maintains on every access had nothing left to pay for.
    nstripes = _bounded_stripe_count(max_clients)
    per_stripe = cld(max_clients, nstripes)
    stripes = _make_stripes(() -> Dict{BucketKey, Vector{DateTime}}(), nstripes)

    # The window in whole seconds: the empty-vector fallback below and the refusal's
    # `Retry-After`. It used to be `Dates.value(window) / 1000`, which is milliseconds only when
    # `window` is a `Millisecond` -- `Minute(1)` came out as 1 second. Unreachable then (a bucket
    # is never empty when the fallback is asked), but `_window_seconds` converts properly.
    window_seconds = _window_seconds(window)

    # Compute reset time from timestamps (safe for empty vectors)
    function compute_reset_time_safe(current_time::DateTime, timestamps::Vector{DateTime})
        if isempty(timestamps)
            return window_seconds
        else
            oldest_timestamp = minimum(timestamps)
            return calculate_reset_time(current_time, oldest_timestamp, window)
        end
    end

    # The limiter's own work for one request; it never calls `handle` (#421). See the fixed
    # limiter's `decide`.
    function decide(req::HTTP.Request)::Tuple{Int,Int,Int}
        # Check exempt paths first (most efficient early return)
        _is_exempt(req.target, exempt_paths) && return (_EXEMPT, 0, 0)

        # No client address means there is no bucket to key on. Without this guard the
        # `nothing` reaches `_bucket_key` and fails closed via the catch, logging a backtrace
        # per request. Honour `fail_open` the same way.
        ip = getip(req)
        if ip === nothing
            @warn "Rate limiter: no client IP on this request; cannot apply a per-IP " *
                  "limit. Put `ExtractIP` before the limiter, or leave " *
                  "`auto_extract_ip=true`." maxlog=1
            return (_UNDECIDED, 0, 0)
        end

        # Derive the key and pick the stripe BEFORE taking the lock — see the fixed
        # limiter for why (`getip` used to be called a second time inside it).
        key = _bucket_key(ip, v4mask, v6mask)
        stripe = _stripe_for(stripes, key)
        rate_limit_store = stripe.store

        # CONCURRENCY (nitro-core §2) — DO NOT call `handle(req)` in here.
        # Nitro serves every request via `Threads.@spawn`; this lock is shared
        # by every client whose key lands on this stripe, so anything held
        # under it is serialised. Running the downstream chain here made one
        # slow handler block every other request from every IP (#15).
        #
        # The lock guards the stripe's `Dict` and the *shared mutable*
        # `Vector{DateTime}` it hands back, so every read/write of `timestamps`
        # must stay inside this block.
        #
        # The decision is returned as a concrete `Tuple{Int,Int,Int}` rather
        # than assigned to hoisted locals: assigning an enclosing-scope local
        # from inside a closure boxes it, which would hand `set_rate_headers!`
        # three `Any`s on the request hot path (nitro-core §7). `outcome` is
        # `_ADMIT`/`_LIMIT`/`_FULL`; for `_FULL` the third slot is the `Retry-After`.
        return lock(stripe.lock) do
            current_time = now(UTC)

            # A new client is the only thing that grows the store, so it is the only
            # thing that can find it full (#403). A full stripe refuses; it never evicts.
            existing = get(rate_limit_store, key, nothing)
            if existing === nothing
                if !_has_room!(stripe, per_stripe, window, current_time)
                    return (_FULL, 0,
                            _retry_after(stripe.next_reap[], current_time, window_seconds))
                end
                timestamps = DateTime[]
                rate_limit_store[key] = timestamps
                # A new bucket is never throttled (`rate_limit > 0`), so the `push!`
                # below always records `current_time`; note that expiry now.
                _note_expiry!(stripe, current_time + window)
            else
                timestamps = existing
            end

            # Prune expired timestamps (sliding window cleanup)
            # Keep only timestamps within the current window
            cutoff_time = current_time - window
            filter!(timestamp -> timestamp > cutoff_time, timestamps)

            # Check if adding this request would exceed the limit
            if length(timestamps) >= rate_limit
                return (_LIMIT, 0, compute_reset_time_safe(current_time, timestamps))
            end

            # Within the limit: consume the slot and snapshot the header values
            # now, while the vector is still guarded. These are the same values
            # the old code produced — it computed them after `handle(req)`, but
            # the vector could not change meanwhile because the lock was
            # (wrongly) held across the handler.
            push!(timestamps, current_time)
            # Remaining quota, and time until the oldest request expires (when
            # 1 slot becomes available).
            return (_ADMIT, rate_limit - length(timestamps),
                    compute_reset_time_safe(current_time, timestamps))
        end
    end

    function rate_limit_only(handle::Function)
        return function(req::HTTP.Request)
            # The `try` covers `decide` ONLY (#421) -- the response, and with it the
            # downstream chain, is `_respond`'s, outside the lock and outside the `try`.
            outcome, remaining_requests, reset_time = try
                decide(req)
            catch error
                is_unrecoverable(error) && rethrow()   # #254, as in the fixed limiter
                @error "Sliding Window Rate limiter error" exception=(error, catch_backtrace())
                (_UNDECIDED, 0, 0)
            end
            return _respond(handle, req, outcome, remaining_requests, reset_time,
                            rate_limit, fail_open, max_clients, "429 Too Many Requests")
        end
    end

    # Compose with IP extraction if auto_extract_ip is enabled
    function extract_ip_and_rate_limit(handle::Function) :: Function
        return reduce(|>, [handle, rate_limit_only, extract_client_ip])
    end

    # A `LifecycleMiddleware` with both hooks left `nothing` (#172). This strategy owns no
    # background task — a full stripe reaps its expired buckets inline (#403), so there is
    # nothing to start or stop — but
    # `RateLimiter(strategy = ...)` must not hand back a different TYPE depending on which
    # algorithm you picked. `startup`/`shutdown` already no-op on a `nothing` hook
    # (src/types.jl), so the wrapper costs one allocation at construction and nothing per
    # request.
    return LifecycleMiddleware(;
        middleware = auto_extract_ip ? extract_ip_and_rate_limit : rate_limit_only)
end



"""
    calculate_reset_time(current_time::DateTime, last_reset::DateTime, window::Period) -> Int

Calculates the number of seconds remaining until the current rate limit window resets.

# Arguments
- `current_time::DateTime`: The current server time.
- `last_reset::DateTime`: The start time of the current rate limit window for the client/IP.
- `window::Period`: The duration of the rate limit window.

# Returns
- `Int`: The number of seconds until the rate limit window resets. Returns 0 if the window has already expired.

This value is used for the `X-RateLimit-Reset` response header, allowing clients to know when they can make new requests.
"""
function calculate_reset_time(current_time::DateTime, last_reset::DateTime, window::Period)
    window_end = last_reset + window
    seconds_remaining = ceil(Int, Dates.value(window_end - current_time) / 1000)
    return max(0, seconds_remaining)
end


"""
    set_rate_headers!(resp::HTTP.Response, rate_limit::Int, remaining_requests::Int, reset_time::Int)

Conditionally sets standard rate limiting headers on an HTTP response if they are not already present.
This function implements a "header preservation" pattern, ensuring that headers set by inner middleware
(e.g., route-level rate limits) are not overwritten by outer middleware (e.g., router-level limits),
allowing the most restrictive or specific limits to take precedence in nested middleware chains.

# Arguments
- `resp::HTTP.Response`: The HTTP response object to modify. Headers are added in-place.
- `rate_limit::Int`: The maximum number of requests allowed in the current window. Used for the `X-RateLimit-Limit` header.
- `remaining_requests::Int`: The number of requests remaining in the current window. Used for the `X-RateLimit-Remaining` header (clamped to 0 if negative).
- `reset_time::Int`: The number of seconds until the rate limit window resets. Used for the `X-RateLimit-Reset` header.
"""
function set_rate_headers!(resp::HTTP.Response, rate_limit::Int, remaining_requests::Int, reset_time::Int)
    
    # Header flags which are set to true when they're found
    has_limit = false
    has_remaining = false
    has_reset = false
    has_retry = false
    
    # Loop over the headers once and try to find each header
    for (k, _) in resp.headers
        # End if all headers are found
        if has_retry && has_limit && has_remaining && has_reset
            break
        elseif !has_retry && header_name_isequal(k, "Retry-After")
            has_retry = true
        elseif !has_limit && header_name_isequal(k, "X-RateLimit-Limit")
            has_limit = true
        elseif !has_remaining && header_name_isequal(k, "X-RateLimit-Remaining" )
            has_remaining = true
        elseif !has_reset && header_name_isequal(k, "X-RateLimit-Reset")
            has_reset = true
        end
    end

    # Conditionally set the headers if they don't exist
    if !has_retry
        HTTP.setheader(resp, "Retry-After" => string(reset_time))
    end
    if !has_limit
        HTTP.setheader(resp, "X-RateLimit-Limit" => string(rate_limit))
    end
    if !has_remaining
        HTTP.setheader(resp, "X-RateLimit-Remaining" => string(max(0, remaining_requests)))
    end
    if !has_reset
        HTTP.setheader(resp, "X-RateLimit-Reset" => string(reset_time))
    end  

end

end