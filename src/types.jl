module Types
"""
This module holds Structs that are used throughout the application
"""

using HTTP
using Sockets
using JSON
using Dates
using Base: @kwdef
using DataStructures: CircularDeque
using ..Util
using ..Errors: ValidationError

export Server, Nullable, Context,
    LifecycleMiddleware, startup, shutdown,
    Param, isrequired, LazyRequest, headers, pathparams, queryvars, jsonbody, formbody, textbody, multipartbody,
    CookieConfig, Cookie, Session, SessionPayload,
    AbstractSessionStore, get_session, set_session!, delete_session!, cleanup_expired_sessions!,
    MemoryStore, Extractor,
    RouteDefinition, Principal

const Nullable{T} = Union{T, Nothing}
const Server = HTTP.Server

abstract type Extractor{T} end
abstract type AbstractSessionStore{K, V} end

"""
    Principal(claims; id=nothing, kid=nothing, source=:claim)

The normalized authenticated principal that Nitro auth middleware attaches at
`req.context[:user]` (readable as `req.user`).

Behaves as a **read-only** claims dictionary — `principal["sub"]`, `get`, `haskey`,
iteration, and JSON serialization all read through to the verified claims — with
normalized identity available as typed fields:

- `id::Nullable{String}` — the resolved identity: the configured identity claim
  (default `"sub"`), or the verified key id when identity derives from `kid`.
  `nothing` when the token carries no identity claim (e.g. service/capability
  tokens) — the request is still authenticated.
- `claims::Dict{String,Any}` — the verified token claims.
- `kid::Nullable{String}` — the **keyset-verified** key id, or `nothing`. Only ever
  populated when the token was verified against a keyset; a `kid` header on a
  single-secret token is an unverified label and is never exposed here.
- `source::Symbol` — where `id` came from: `:claim` or `:kid`.

A `Principal` is immutable: it is a verified security artifact. Use `Dict(principal)`
for a mutable copy, or a `user_validator` to build an enriched application user.
"""
struct Principal <: AbstractDict{String, Any}
    id::Nullable{String}
    claims::Dict{String, Any}
    kid::Nullable{String}
    source::Symbol
end

function Principal(claims::AbstractDict; id=nothing, kid=nothing, source::Symbol=:claim)
    normalized = claims isa Dict{String, Any} ? claims :
        Dict{String, Any}(string(key) => value for (key, value) in pairs(claims))
    return Principal(
        id === nothing ? nothing : string(id),
        normalized,
        kid === nothing ? nothing : String(kid),
        source,
    )
end

# Read-only dict interface, delegating to the verified claims. `get`/`haskey` have no
# generic AbstractDict fallback, so these delegations are load-bearing for the guards'
# `get(user, key, nothing)` calls. Deliberately no `setindex!`/`delete!`/`pop!`.
Base.iterate(principal::Principal) = iterate(getfield(principal, :claims))
Base.iterate(principal::Principal, state) = iterate(getfield(principal, :claims), state)
Base.length(principal::Principal) = length(getfield(principal, :claims))
Base.get(principal::Principal, key, default) = get(getfield(principal, :claims), key, default)
Base.get(f::Base.Callable, principal::Principal, key) = get(f, getfield(principal, :claims), key)
Base.getindex(principal::Principal, key) = getindex(getfield(principal, :claims), key)
Base.haskey(principal::Principal, key) = haskey(getfield(principal, :claims), key)
Base.keys(principal::Principal) = keys(getfield(principal, :claims))
Base.values(principal::Principal) = values(getfield(principal, :claims))

@kwdef struct Param{T}
    name::Symbol
    type::Type{T} = T
    default::Nullable{T} = nothing
    hasdefault::Bool = false
end

Param(name::Symbol, type::Type{T}, default, hasdefault::Bool) where {T} =
    Param{T}(name, type, default === missing ? nothing : default, hasdefault)

isrequired(param::Param) = !param.hasdefault

function get_session(store::AbstractSessionStore{K, V}, session_id::K) where {K, V}
    payload = Base.get(store, session_id, nothing)
    if isnothing(payload)
        return nothing
    end

    if payload isa SessionPayload{V}
        if payload.expires <= Dates.now(Dates.UTC)
            return nothing
        end
        return _copy_session_value(payload.data)
    end

    return payload
end

function set_session!(store::AbstractSessionStore, session_id, data; ttl::Int = 3600)
    throw(MethodError(set_session!, (store, session_id, data)))
end

function delete_session!(store::AbstractSessionStore, session_id)
    throw(MethodError(delete_session!, (store, session_id)))
end

function cleanup_expired_sessions!(store::AbstractSessionStore)
    throw(MethodError(cleanup_expired_sessions!, (store,)))
end

# Generic cookie configuration
@kwdef struct CookieConfig
    secret_key::Nullable{String} = nothing
    httponly::Bool = true
    secure::Bool = true
    samesite::String = "Lax"
    path::String = "/"
    domain::Nullable{String} = nothing
    maxage::Nullable{Int} = nothing
    expires::Nullable{DateTime} = nothing
    max_cookie_size::Nullable{Int} = nothing
end

# Represents a cookie extractor
struct Cookie{T} <: Extractor{T}
    name::String
    value::Nullable{T}
    
    function Cookie(name::String, val_or_type::Any)
        if val_or_type isa Type
            return new{val_or_type}(name, nothing)
        else
            return new{typeof(val_or_type)}(name, val_or_type)
        end
    end

    # Also allow explicit type specification
    Cookie{T}(name::String, value::Nullable{T}=nothing) where T = new{T}(name, value)
end

# Represents a session extractor
struct Session{T} <: Extractor{T}
    name::String
    payload::Nullable{T}
    validate::Union{Function, Nothing}
    type::Type{T}

    function Session(name::String, val_or_type::Any)
        if val_or_type isa Type
            return new{val_or_type}(name, nothing, nothing, val_or_type)
        else
            return new{typeof(val_or_type)}(name, val_or_type, nothing, typeof(val_or_type))
        end
    end
    
    Session{T}(name::String, payload::Nullable{T}=nothing, validate::Union{Function, Nothing}=nothing) where T = new{T}(name, payload, validate, T)
end

# Represents a session with metadata (like discovery/expiry time)
struct SessionPayload{T}
    data::T
    expires::DateTime
end

# A thread-safe in-memory store for sessions
struct MemoryStore{K, V} <: AbstractSessionStore{K, V}
    data::Dict{K, SessionPayload{V}}
    lock::Base.ReentrantLock
    MemoryStore{K, V}() where {K, V} = new{K, V}(Dict{K, SessionPayload{V}}(), Base.ReentrantLock())
end

function Base.get(store::MemoryStore, key, default)
    lock(store.lock) do
        return Base.get(store.data, key, default)
    end
end

function _copy_session_value(value)
    if value isa AbstractDict || value isa AbstractArray
        return copy(value)
    end
    return value
end

function get_session(store::MemoryStore{K, V}, key::K) where {K, V}
    lock(store.lock) do
        payload = Base.get(store.data, key, nothing)
        if isnothing(payload)
            return nothing
        end

        if payload.expires <= Dates.now(Dates.UTC)
            return nothing
        end

        return _copy_session_value(payload.data)
    end
end

function set_session!(store::MemoryStore{K, V}, key::K, value::V; ttl::Int = 3600) where {K, V}
    lock(store.lock) do
        store.data[key] = SessionPayload(value, Dates.now(Dates.UTC) + Dates.Second(ttl))
    end
    return value
end

function delete_session!(store::MemoryStore{K, V}, key) where {K, V}
    lock(store.lock) do
        delete!(store.data, key)
    end
    return nothing
end

function cleanup_expired_sessions!(store::MemoryStore)
    current_time = Dates.now(Dates.UTC)
    lock(store.lock) do
        for (key, payload) in store.data
            if payload.expires <= current_time
                delete!(store.data, key)
            end
        end
    end
    return nothing
end

# ── Copy-on-write table (atomic publish, lock-free reads) ───────────────────────
# A `String`-keyed table read on the request hot path and written rarely, off it. The two
# instantiations no longer share a key space: `custommiddleware` keys on the route alone
# ("METHOD|path", see `genkey`), while `middleware_cache` appends the pipeline's serializer
# settings ("METHOD|path|CES", see `cachetag`) — because the chain it stores closes over those
# settings, so the route alone is not a complete key for it (#79).
#
# Two instantiations, with deliberately different write semantics:
#
#   `middleware_cache :: CopyOnWriteDict{Function}` — route key → fully-composed middleware
#       chain. Written during cache warmup only, once per route, via `cache!`
#       (FIRST-writer-wins): a cached chain must never change identity underneath a reader.
#
#   `custommiddleware :: CopyOnWriteDict{Tuple}` — route key → `(router middleware, route
#       middleware)`. Written at route registration via `publish!` (LAST-writer-wins):
#       re-running `urlpatterns` for a path must install the new middleware. "Registration"
#       is not necessarily startup-only: under `revise=:lazy`, `Revise.revise()` runs on a
#       request-handling task (src/core.jl), so re-registration can land while OTHER request
#       tasks are inside `buildmiddleware` reading this table.
#
# Shape: copy-on-write behind an atomic reference, NOT a lock around the read. A reader
# takes one acquire-load of `entries` and works on that snapshot; a writer copies the
# current table under `lock`, inserts, and release-stores the copy. No `Dict` reachable by
# a reader is ever mutated by *this module* — that is the entire safety argument. Julia's
# `Dict` tolerates concurrent *readers*, but never a reader concurrent with `setindex!`: a
# `rehash!` swaps the backing `slots`/`keys`/`vals` arrays underneath the reader, yielding
# a wrong lookup (one route's chain served for another), a `BoundsError`, or a segfault.
#
# Scope of the guarantee, stated honestly: `@atomic` makes the *publish* unwritable, but
# nothing makes a returned *snapshot* unwritable. `ServerContext` is public, so app code can
# reach `ctx.service.middleware_cache` / `ctx.service.custommiddleware` and `setindex!` a
# snapshot, reintroducing this bug with no error. `snapshot`'s "immutable by convention" is
# a convention, enforced by review rather than by the type.
#
# Why not simply lock the read: every request on an already-cached route would then
# serialize through one `ReentrantLock`. Every request runs on `Threads.@spawn`, so that is
# a permanent hot-path cost paid to close a window that only exists during warmup. The
# steady state here is pure lock-free reads instead.
#
# For `custommiddleware` that argument is *stronger*, not weaker. `compose` computes
# `use_cache = isempty(globalmiddleware)` once; when it is false the cache is never read and
# never written, so `buildmiddleware` — and its read of this table — runs on EVERY request,
# forever, not just during a warmup window. `use_cache` is false for any
# `serve(middleware=[...])` (CORS, sessions, auth, rate limiting — the normal production
# shape) and for every `revise=:lazy|:eager` session, since `serve` injects `ReviseHandler`.
#
# Cost of the trade: each write copies the whole table, so warming R routes is O(R^2)
# insertions in aggregate and discards R intermediate tables. One-time and off the
# steady-state path, but it does mean a burst of garbage proportional to the route table.
# The O(R^2) shape is the durable fact; a wall-clock number here would only rot. If a route
# table ever gets big enough for this to matter, the answer is to build the table once at
# route-registration time, not to abandon copy-on-write.
#
# `entries` is `@atomic`, so a plain `d.entries = ...` raises ConcurrencyViolationError:
# the type makes the unsynchronized publish that caused this bug unwritable. Bare *reads*
# are still legal (and only `:monotonic`) — always go through `snapshot`.
#
# Deliberately NOT `<: AbstractDict`. Subtyping would inherit `AbstractDict`-generic
# fallbacks that touch the live table with no synchronization and never go through
# `snapshot` — `get!` and `filter!` mutate it, `merge` and `copy` read it. It would also
# widen the method-ambiguity surface Aqua checks. Four operations, and no `getindex`, is
# the point. For the same reason there is no `Base.isempty`: spelling `snapshot` at a call
# site is the signal that the read is a point-in-time view.
#
# Relation to `_Writer`/`_Run` in src/middleware/access_log.jl: same generation-swap idea,
# specialized rather than departed from. `access_log` publishes a plain `run` field via the
# separate `active` atomic the reader must load anyway, so its publish rides free. Here
# there is one reference and no gate, so atomicizing that reference directly is the whole
# mechanism.
#
# Both value types are abstract on purpose. `Function`: each route's chain is a distinct
# closure type produced by `reduce(|>, layers)` in `buildmiddleware`, so no concrete type
# spans the table; narrowing needs FunctionWrappers, which pins the return type and breaks
# `serialize=false` (where a handler's raw return value flows out through `compose`).
# `Tuple`: the value is a positional `(router middleware, route middleware)` pair whose
# slots are each `Union{Vector{Function}, Nothing}`, and `buildmiddleware`'s lookup default
# is `(nothing, nothing)`.
#
# The key type is fixed to `String` rather than parameterized: both instantiations key on
# `genkey`, so a `K` parameter would be a knob no call site ever turns, at the cost of
# widening every signature in src/routerhof.jl. Adding it later is mechanical.
mutable struct CopyOnWriteDict{V}
    @atomic entries :: Dict{String, V}
    const lock      :: Base.ReentrantLock
end

CopyOnWriteDict{V}() where {V} = CopyOnWriteDict{V}(Dict{String, V}(), Base.ReentrantLock())

"""
    snapshot(d::CopyOnWriteDict{V}) -> Dict{String, V}

Reader fast path: one acquire-load, allocation-free. The returned `Dict` is immutable by
convention — never `setindex!`/`delete!` it. The `:acquire` pairs with the `:release` in
[`cache!`](@ref) / [`publish!`](@ref) / `empty!`, so a value is fully constructed by the
time a reader can observe it.

Deliberately non-parametric in the signature: one method covers every instantiation and
still infers the concrete `Dict{String,V}` from a concrete argument.
"""
@inline snapshot(d::CopyOnWriteDict) = @atomic :acquire d.entries

"""
    cache!(d::CopyOnWriteDict{V}, key::String, value::V) -> V

**First writer wins.** Publish `key => value` unless `key` is already present; return the
value now in force. Use where an entry, once observed, must never change identity under a
reader — `middleware_cache`, whose writes are warmup-only. Where re-registration must
overwrite, use [`publish!`](@ref).

Takes the lock and copies the whole table.
"""
function cache!(d::CopyOnWriteDict{V}, key::String, value::V) where {V}
    return lock(d.lock) do
        # `:monotonic` suffices: the lock's own acquire/release edges already order this
        # read against every other writer's publish and that publish's `Dict` contents.
        current = @atomic :monotonic d.entries
        # `haskey` + `getindex`, NOT `get(current, key, nothing)`: with `V` a parameter,
        # `nothing` is not a safe universal absence sentinel — it is a legal value at
        # `V === Any`, where the sentinel form silently breaks first-writer-wins. Two
        # lookups of a short `String`, once per key, ever.
        haskey(current, key) && return current[key]
        updated = _grown_copy(current)
        updated[key] = value
        @atomic :release d.entries = updated
        return value
    end
end

"""
    cache_if_current!(d::CopyOnWriteDict{V}, key::String, value::V,
                      source::CopyOnWriteDict, expected::Dict) -> Bool

**First writer wins, and only while `source` has not moved.** Publish `key => value` into `d`
unless `key` is already present *or* `source`'s table is no longer the one `value` was derived
from. Returns whether it published.

This is [`cache!`](@ref) plus a generation check, and it exists to close the stale-chain race
that publish-then-invalidate only narrowed (#81). Registration does
`publish!(custommiddleware, …)` then `delete!(middleware_cache, …)`; a request whose chain
construction straddled that whole pair used to `cache!` a chain built from the *old* table, and
first-writer-wins then made it permanent. Symptom: route middleware registered at runtime that
silently never runs.

**The generation stamp is the table's own identity — there is no counter.** Every write to a
`CopyOnWriteDict` release-stores a *freshly allocated* `Dict`, and the caller still holds a
reference to the one it read, so that object cannot be collected and its address cannot be
reused while the comparison is live. `===` on the snapshot is therefore a sound generation
check that costs one acquire-load on the miss path and nothing at all on the hit path.

**Why the window is actually closed, not merely narrower.** The check runs *inside* `d`'s lock,
and [`delete!`](@ref) acquires that same lock **unconditionally** — it locks first and only then
early-returns on an absent key. So the racing registration and this publish are totally ordered
on one lock, leaving exactly two cases:

1. This critical section precedes the registration's `delete!`. The `delete!` therefore runs
   *after* the insert, sees it (unlock→lock happens-before), and removes it.
2. The registration's `delete!` precedes this critical section. Then `publish!(source, …)`
   happened-before that `delete!` (program order), which happened-before this section (lock
   edge) — so this `snapshot(source)` **must** observe the new table, `!==` fires, and nothing
   is published.

There is no third case, so no interleaving can strand a stale entry.

!!! warning
    `delete!` must keep taking the lock even when the key is absent. A lock-free `haskey`
    pre-check added there as an "optimization" would silently reopen case 2.

`expected` is the snapshot the value was derived from. Passing an *earlier* snapshot than the
one actually used is safe and is what `compose` does — it reuses the snapshot it already took
for the emptiness test, and `buildmiddleware` takes its own, later one. If the two disagree,
this refuses to publish: conservative in the safe direction, never the other way.
"""
function cache_if_current!(d::CopyOnWriteDict{V}, key::String, value::V,
                           source::CopyOnWriteDict, expected::Dict)::Bool where {V}
    return lock(d.lock) do
        # Inside the lock, and that placement is the whole proof — see the docstring.
        snapshot(source) === expected || return false
        current = @atomic :monotonic d.entries
        haskey(current, key) && return false
        updated = _grown_copy(current)
        updated[key] = value
        @atomic :release d.entries = updated
        return true
    end
end

"""
    publish!(d::CopyOnWriteDict{V}, key::String, value::V) -> V

**Last writer wins.** Publish `key => value`, replacing any existing entry; return `value`.
Use where re-registration must take effect — `custommiddleware`, where re-running
`urlpatterns` for a path installs the new per-route middleware. Where an entry must be
stable once observed, use [`cache!`](@ref).

When `use_cache` is true, publishing to `custommiddleware` alone is not enough to change what a
route *serves*: a chain already cached in `middleware_cache` is first-writer-wins and would keep
winning. (With any global or per-call middleware nothing is cached, and `publish!` alone is
sufficient.) That is why route middleware goes through `publish_route_middleware!`
(src/routerhof.jl), which pairs this call with a [`delete!`](@ref) of the same key from the
cache. Reach for that helper rather than calling `publish!` on `custommiddleware` directly (#71).

A reader holding an earlier snapshot keeps seeing the earlier value until it takes a new
one; that is the copy-on-write contract, not a bug. A request already mid-chain finishes
against the generation it started with.

Takes the lock and copies the whole table.
"""
function publish!(d::CopyOnWriteDict{V}, key::String, value::V) where {V}
    return lock(d.lock) do
        current = @atomic :monotonic d.entries
        updated = _grown_copy(current)
        updated[key] = value
        @atomic :release d.entries = updated
        return value
    end
end

# Copy sized for exactly one more entry. Not a rehash-avoidance trick — the rehash happens
# either way. It forces a tighter growth curve (16→32→64→…) than `setindex!`'s own policy
# (16→64→256…), so each generation's backing array stays right-sized: cheaper copies and
# measurably less garbage across a warmup. It also right-sizes the odd generation where
# `copy` preserved an over-large capacity.
function _grown_copy(current::Dict{String, V}) where {V}
    updated = copy(current)
    sizehint!(updated, length(current) + 1)
    return updated
end

"""
    delete!(d::CopyOnWriteDict{V}, key::String) -> CopyOnWriteDict{V}

Drop `key` by publishing a copy without it; a no-op if the key is absent. Readers holding an
earlier snapshot keep seeing the entry until they take a new one — the copy-on-write contract.

Exists so `middleware_cache` can be *invalidated* rather than only appended to: `cache!` is
first-writer-wins, so without this a route's composed chain would be permanent and middleware
registered for that route afterwards could never take effect (#71). See
`publish_route_middleware!` (src/routerhof.jl) for the pairing and for why the order matters.

Takes the lock; copies the whole table only when the key is actually present. Uses a plain
`copy`, not `_grown_copy` — that one sizehints for an *added* entry, the wrong direction here.

!!! warning "The lock is taken unconditionally, and that is load-bearing"
    The absent-key fast path skips the *copy*, never the *lock*. [`cache_if_current!`](@ref)'s
    proof that no interleaving can strand a stale chain (#81) rests on this call and that
    publish being totally ordered on `d.lock` — a lock-free `haskey` pre-check added here as an
    optimization would silently reopen the race, with no test failure and no symptom until a
    registration happens to race a live request.
"""
function Base.delete!(d::CopyOnWriteDict{V}, key::String) where {V}
    lock(d.lock) do
        current = @atomic :monotonic d.entries
        # Skip the copy entirely when there is nothing to drop. Registration re-publishes far
        # more often than it invalidates a warmed key, so this is the common case. NOTE: this
        # skips the copy, NOT the lock — see the warning above (#81).
        haskey(current, key) || return d
        updated = copy(current)
        delete!(updated, key)
        @atomic :release d.entries = updated
    end
    return d
end

"""
    delete!(d::CopyOnWriteDict{V}, keys) -> CopyOnWriteDict{V}

Drop several keys in **one** publish. Equivalent to calling the single-key method for each, but
takes the lock once and copies the table at most once — absent keys cost nothing beyond a
lookup, and if none are present nothing is published at all.

Exists for `publish_route_middleware!` (src/routerhof.jl), which since #79 must invalidate a
route's chain under every pipeline-settings tag rather than under one key. Doing that as N
separate `delete!` calls would take the cache lock N times and publish up to N intermediate
tables for one logical invalidation.

`keys` is any iterable of `String` — a generator is the expected shape, so nothing is
materialized.

!!! warning "The lock is taken unconditionally, and that is load-bearing"
    Same invariant as the single-key method: the all-absent fast path skips the *publish*, never
    the *lock*. [`cache_if_current!`](@ref)'s proof (#81) requires this call and that publish to
    be totally ordered on `d.lock`.
"""
function Base.delete!(d::CopyOnWriteDict{V}, keys) where {V}
    lock(d.lock) do
        current = @atomic :monotonic d.entries
        # Probe first so the common case — invalidating a route nobody has warmed yet — does no
        # copying. The lock is already held either way; see the warning above.
        any(k -> haskey(current, k), keys) || return d
        updated = copy(current)
        for k in keys
            delete!(updated, k)
        end
        @atomic :release d.entries = updated
    end
    return d
end

"""
    empty!(d::CopyOnWriteDict{V}) -> CopyOnWriteDict{V}

Drop every entry by publishing a fresh table. Deliberately NOT an in-place `empty!` of the
live `Dict`: `terminate` (src/core.jl) calls this on `middleware_cache` with requests still
in `compose`, and an in-flight reader must be able to finish against a table nobody mutates.

The fresh table takes its value type from the parameter. (Belt and braces rather than a
correctness hinge: `entries` is a declared `Dict{String,V}` field, so `setfield!` would
convert a wrongly-typed table anyway.)
"""
function Base.empty!(d::CopyOnWriteDict{V}) where {V}
    lock(d.lock) do
        @atomic :release d.entries = Dict{String, V}()
    end
    return d
end

# Represents the application context
struct Context{T}
    payload::T
end


@kwdef struct LifecycleMiddleware 
    # The middleware function itself (handles incoming requests)
    middleware :: Function
    # A hook that's called when the server starts up (optional)
    on_startup :: Union{Function,Nothing} = nothing
    # A hook that's called when the server is shutdown (optional)
    on_shutdown :: Union{Function,Nothing} = nothing
end

function startup(lf::LifecycleMiddleware)
    if !isnothing(lf.on_startup)
        try 
            lf.on_startup()
        catch error
            @error "Error in LifecycleMiddleware.on_startup: " exception=(error, catch_backtrace())
        end
    end
end

function shutdown(lf::LifecycleMiddleware)
    if !isnothing(lf.on_shutdown)
        try
            lf.on_shutdown()
        catch error
            @error "Error in LifecycleMiddleware.on_shutdown: " exception=(error, catch_backtrace())
        end
    end
end


# ─── Lazy Request Accessors ───────────────────────────────────────────

struct LazyRequest
    req::HTTP.Request
end

LazyRequest(; request::HTTP.Request) = LazyRequest(request)

function Base.getproperty(request::LazyRequest, sym::Symbol)
    if sym === :request
        return getfield(request, :req)
    end
    return getfield(request, sym)
end

# Percent-decoding happens exactly ONCE, here at the boundary where the raw request becomes a
# map. Everything downstream — `parseparam`, `parsetype`, `struct_builder` — is pure type
# conversion and must never unescape again.
#
# The two sources arrive in *different* states, which is why only one of them decodes:
#   - HTTP.jl's router splits `req.target` without unescaping, so path segments are still
#     encoded and this accessor owes them the single decode. Pinned by
#     `test/http_internals_contract_tests.jl`.
#   - `HTTP.queryparams` already decodes, so `queryvars` must NOT decode again (#70).
#
# `HTTP.getparams` returns `nothing` for a request that never went through the router, and
# callers (`Core.merge_request_input!`, `req.input`) rely on that passthrough — so the `nothing`
# is preserved rather than normalized to an empty Dict.
#
# Inference NARROWS here: `HTTP.getparams` reads a `Dict{Symbol,Any}` metadata table and infers
# `Any`, while this returns `Union{Nothing,Dict{String,String}}`. `raw_pathparams[name]` in
# `create_param_parser` therefore infers `String` instead of `Any` — one dynamic dispatch fewer
# on the request path, not a new instability. Do not "restore" the old shape.
#
# Each call returns a FRESH Dict (the decode cannot be done in place), so `req.params` is a
# snapshot, not a handle: mutating it does not change what the next read returns. Use
# `req.context` to pass values down a request. Caching it per request is #38's scope.
#
# `HTTP.unescapeuri` THROWS on a malformed escape (`EOFError` for a trailing "%", `ArgumentError`
# for "%ZZ"). That is client input, so it must be a 400 -- and the decode now runs here, outside
# `parseparam_checked`, which is what used to convert it. Wrapping it keeps #18's guarantee that
# a malformed scalar param is a client error rather than a 500 with a logged backtrace.
# The offending value is deliberately not interpolated: `.msg` is app-reachable and a path
# segment can carry a token.
function pathparams(req::HTTP.Request)
    raw = HTTP.getparams(req)
    raw === nothing && return nothing
    decoded = Dict{String,String}()
    for (k, v) in raw
        value = try
            HTTP.unescapeuri(v)
        catch e
            e isa InterruptException && rethrow()
            throw(ValidationError("Malformed percent-encoding in path parameter '$k'", e))
        end
        # `unescapeuri` does not validate what the bytes decode TO: "%80" yields an invalid
        # UTF-8 `String` with no error. Nothing downstream throws on it — it propagates all the
        # way into the response, and `Res.json` will happily emit a body containing that raw byte -- an invalid
        # UTF-8 body. Refusing it here is the boundary declining to admit a value the framework
        # would go on to serialize incorrectly. `queryvars` applies the identical rule.
        isvalid(value) || throw(ValidationError("Invalid UTF-8 in path parameter '$k'"))
        decoded[k] = value
    end
    return decoded
end
# Same guard, same reason: `HTTP.queryparams` decodes internally and throws on a malformed
# escape, so `?q=%ZZ` was a 500 here too (pre-existing -- this accessor's decode was never
# inside `parseparam_checked` either). Both accessors now owe their caller a well-formed map
# or a `ValidationError`; neither leaks a raw decode failure into the server-error path.
function queryvars(req::HTTP.Request)
    # Deliberately OUTSIDE the guard: a `req.target` this malformed is a framework/router
    # problem, not client input, and must stay a logged 500 rather than be laundered into a 400.
    query = HTTP.URI(req.target).query
    vars = try
        HTTP.queryparams(query)
    catch e
        e isa InterruptException && rethrow()
        throw(ValidationError("Malformed percent-encoding in query string", e))
    end
    # Same UTF-8 rule as `pathparams` — the two accessors must not disagree about what counts
    # as a well-formed value, which is the whole point of #70.
    for (k, v) in vars
        isvalid(v) || throw(ValidationError("Invalid UTF-8 in query parameter '$k'"))
    end
    return vars
end
# HTTP.jl v2 canonicalizes header field names to Title-Case (e.g. "Content-Type").
# Header names are case-insensitive per RFC 9110, and downstream consumers (the
# `Header` extractor's `struct_builder`, cookie lookups) match against lowercase
# keys, so normalize to lowercase here for stable, case-insensitive access.
headers(req::HTTP.Request)   = Dict(lowercase(String(k)) => String(v) for (k, v) in req.headers)

jsonbody(req::HTTP.Request; kwargs...) = json(req; kwargs...)
formbody(req::HTTP.Request)           = formdata(req)
textbody(req::HTTP.Request)           = text(req)
multipartbody(req::HTTP.Request)      = multipart(req)

pathparams(request::LazyRequest) = pathparams(request.req)
queryvars(request::LazyRequest) = queryvars(request.req)
headers(request::LazyRequest) = headers(request.req)

jsonbody(request::LazyRequest; kwargs...) = jsonbody(request.req; kwargs...)
formbody(request::LazyRequest) = formbody(request.req)
textbody(request::LazyRequest) = textbody(request.req)
multipartbody(request::LazyRequest) = multipartbody(request.req)

# ─── Routing ──────────────────────────────────────────────────────────

@kwdef struct RouteDefinition
    pattern::String
    handler::Function
    methods::Vector{String} = String[]
    name::Nullable{String} = nothing
    middleware::Nullable{Vector} = nothing
    type_hints::Dict{Symbol, Type} = Dict{Symbol, Type}()
end

RouteDefinition(pattern::String, handler::Function, methods::Vector{String}, name, middleware, type_hints) =
    RouteDefinition(; pattern, handler, methods, name, middleware, type_hints)

RouteDefinition(path::String, method::String, handler::Function, middleware::Vector{Function}, name::Nullable{String}) =
    RouteDefinition(; pattern=path, handler, methods=[method], name, middleware, type_hints=Dict{Symbol, Type}())

end # module Types
