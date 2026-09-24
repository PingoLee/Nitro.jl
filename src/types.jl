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
using ..Errors: ValidationError, StoreInterfaceError, implements_contract_method, store_contract_error

export Server, Nullable, Context,
    LifecycleMiddleware, startup, shutdown, require_fixed_period,
    Param, isrequired, LazyRequest, headers, pathparams, queryvars, jsonbody, formbody, textbody, multipartbody,
    CookieConfig, Cookie, Session, SessionPayload,
    AbstractSessionStore, get_session, set_session!, delete_session!, cleanup_expired_sessions!,
    is_expired,
    MemoryStore, Extractor, missing_session_methods,
    RouteDefinition, Principal

const Nullable{T} = Union{T, Nothing}
const Server = HTTP.Server

abstract type Extractor{T} end
"""
    AbstractSessionStore{K, V}

The storage contract behind `SessionMiddleware`. `MemoryStore` ships in core and
`PormGSessionStore` in `NitroPormGExt`; an application may add its own. `K` is the session-id type
and `V` the payload type — the middleware pins both to `AbstractSessionStore{String, Dict{String,Any}}`.

# Required

| Method | Contract |
|---|---|
| `Base.get(store, session_id, default)` | The stored `SessionPayload`, or `default` when absent |
| `set_session!(store, session_id, data; ttl::Int)` | Persist `data` under a fixed-point expiry, returns `data` |
| `delete_session!(store, session_id)` | Remove one session |

`Base.get` is easy to miss and is genuinely mandatory: both the generic `get_session` and the
middleware's own load path call it directly. Each of the three has a fallback on this abstract type
raising `StoreInterfaceError`, and [`missing_session_methods`](@ref) lists what a type still owes:

```julia
@test isempty(missing_session_methods(MySessionStore))
```

# Optional

`cleanup_expired_sessions!(store)` prunes expired rows and **defaults to a no-op**. That is the one
asymmetry with `AbstractWorkerStore`, whose fifteen data-and-policy methods are all required, and it
is deliberate: expiry here is enforced on the *read* path — `get_session` refuses a payload whose
`expires` has passed — so a store that never prunes wastes rows but never serves a stale session.
Implement it for any store whose rows outlive the process.

(This paragraph used to cite `shutdown!` as the required worker-store method a backend could forget
and thereby leak live tasks. That has not been true since #167 moved every running resource onto
`WorkerRuntime`: a worker store owns nothing that runs, so there is no teardown method on it to
require or to forget.)

`storesession!` and `prunesessions!` are the framework's entry points and delegate here; a store may
override those instead if it has a cheaper path.
"""
abstract type AbstractSessionStore{K, V} end

"""
    Principal(claims; id=nothing, kid=nothing, source=:claim)

The normalized authenticated principal that Nitro auth middleware attaches at
`req.context[:user]` (readable as `getuser(req)`).

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

# What an auth validator may hand back as the request's user, and what `login_required` counts
# as logged in (#313). ONE predicate for the auth middleware, `jwt_validator` and the guard, so
# they cannot disagree about who is authenticated.
#
# Not an identity: `nothing`/`missing` (the documented "reject"); any `Bool`, because a
# predicate's answer is not a user — `BearerAuth(t -> t == API_KEY)` authenticated a WRONG key
# as `false` before #313, and `true` names nobody either; an empty string; and an empty dict,
# including a `Principal` with no claims AND no `id`. Everything else is, deliberately including
# `0` (a real user id in some schemas), a non-empty `Principal` whose `id` is `nothing` (how a
# service token authenticates), and a claim-less `Principal` that does carry an `id` (a
# keyset-verified signer under `identity_from = :kid` is a principal whatever its payload).
function _is_identity(x)::Bool
    (x === nothing || x === missing || x isa Bool) && return false
    x isa AbstractString && return !isempty(x)
    x isa Principal && return x.id !== nothing || !isempty(x)
    x isa AbstractDict && return !isempty(x)
    return true
end

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
        if is_expired(payload)
            return nothing
        end
        return _copy_session_value(payload.data)
    end

    return payload
end

# Required-method fallbacks. `Base.get` is not piracy: the store argument is our own type.
#
# Every non-store parameter is left untyped so a backend's own method is strictly more specific in
# every slot and can never be ambiguous with these. `store_contract_error` then separates "this
# backend implemented nothing" from "the caller passed the wrong arguments to a conforming store".
@noinline Base.get(store::AbstractSessionStore, session_id, default) =
    store_contract_error(Base.get, AbstractSessionStore, 1, store, session_id, default)

@noinline function set_session!(store::AbstractSessionStore, session_id, data; ttl::Int = 3600)
    store_contract_error(set_session!, AbstractSessionStore, 1, store, session_id, data)
end

@noinline function delete_session!(store::AbstractSessionStore, session_id)
    store_contract_error(delete_session!, AbstractSessionStore, 1, store, session_id)
end

"""
    SESSION_STORE_INTERFACE

The *required* half of the [`AbstractSessionStore`](@ref) contract as data, read by
[`missing_session_methods`](@ref) and by the fallbacks above. `cleanup_expired_sessions!` is absent
on purpose — it is optional, and its default is the no-op below.
"""
const SESSION_STORE_INTERFACE = (Base.get, set_session!, delete_session!)

"""
    cleanup_expired_sessions!(store::AbstractSessionStore)

Prune expired sessions. **Optional** — this default does nothing and returns `nothing`.

Optionality used to be encoded in `prunesessions!` (`src/cookies.jl`), which called this and
swallowed any `MethodError` whose `.f` was this function. That was two bugs in one: a conforming
store whose cleanup body happened to raise such a `MethodError` internally had it silently
discarded, and the contract's optionality was discoverable only by reading the rescuer. Stating it
as a default method puts it in the type system, where `methods` and `which` can see it.

See [`AbstractSessionStore`](@ref) for why this one is optional while every `AbstractWorkerStore`
method is required.
"""
cleanup_expired_sessions!(store::AbstractSessionStore) = nothing

"""
    missing_session_methods(S::Type{<:AbstractSessionStore}) -> Vector{Symbol}

The **required** [`AbstractSessionStore`](@ref) methods `S` has not implemented. Empty means `S` is
conforming. `cleanup_expired_sessions!` is never reported: it is optional.

```julia
@test isempty(missing_session_methods(MySessionStore))
```
"""
function missing_session_methods(S::Type{<:AbstractSessionStore})
    names = Symbol[]
    for f in SESSION_STORE_INTERFACE
        if !implements_contract_method(f, S, AbstractSessionStore, 1)
            push!(names, nameof(f))
        end
    end
    return names
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

"""
    Cookie{T}

Handler-parameter extractor that reads one request cookie and parses it as `T`.

```julia
path("/prefs", function(req, theme::Cookie{String})
    Res.json(Dict("theme" => something(theme.value, "light")))
end)
```

HTTP.jl also exports a `Cookie`, so in a module that has `using HTTP` too, write `Nitro.Cookie`
or import it explicitly (`using Nitro: Cookie`).

The cookie is looked up by the **parameter name** (`theme` above). To read a cookie under
another name, including one that is not a legal Julia identifier, give the parameter a
`Cookie(name, T)` default:

```julia
path("/prefs", function(req, theme::Cookie{String} = Cookie("ui-theme", String))
    Res.json(Dict("theme" => something(theme.value, "light")))
end)
```

The default also carries an extractor-local validator, as it does for every other extractor:
`Cookie("ui-theme", String, t -> t in ("light", "dark"))`. A present cookie that fails it is a
`ValidationError` (400); the validator does not run when the cookie is absent.

`value` is `nothing` when the request carries no such cookie; a present cookie that does not
parse as `T` is a `ValidationError` (400). When the app has a cookie `secret_key` configured
(see `configcookies`), the value is decrypted before parsing, so a cookie written by
`set_cookie!` round-trips. The raw value is not percent-decoded.
"""
struct Cookie{T} <: Extractor{T}
    name::String
    value::Nullable{T}
    validate::Union{Function, Nothing}

    function Cookie(name::String, val_or_type::Any, validate::Union{Function, Nothing}=nothing)
        if val_or_type isa Type
            return new{val_or_type}(name, nothing, validate)
        else
            return new{typeof(val_or_type)}(name, val_or_type, validate)
        end
    end

    # Also allow explicit type specification
    Cookie{T}(name::String, value::Nullable{T}=nothing, validate::Union{Function, Nothing}=nothing) where T =
        new{T}(name, value, validate)
end

"""
    Session{T}

Handler-parameter extractor that resolves the request's session id to a stored value of type `T`.

```julia
path("/profile", function(req, session::Session{User})
    isnothing(session.payload) && return Res.status(401)
    Res.json(Dict("name" => session.payload.name))
end)

serve(context = store)   # the store the extractor reads from
```

The session id comes from the cookie named `"session"` (decrypted when a cookie `secret_key` is
configured); give the parameter a `Session("sid", T)` default to read another cookie name. The
id is looked up in the **app context**: an [`AbstractSessionStore`](@ref) is read through its
interface, and any other `get`-able value (a `Dict`) is indexed directly. An expired
`SessionPayload` counts as absent.

`payload` is `nothing` when there is no cookie, no context, no entry, or the entry has expired.

This is the store-on-the-context shape. Behind `SessionMiddleware`, read the session with
`getsession` instead. Without `SessionMiddleware` nothing prunes the store: for an
`AbstractSessionStore`, add a `SessionPruner`; a plain `Dict` context is yours to prune.
"""
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

"""
    is_expired(payload::SessionPayload, at::DateTime = Dates.now(Dates.UTC)) -> Bool

Whether `payload` has expired as of `at`. **The boundary counts as expired**: a payload whose
`expires` is exactly `at` is refused, so a session is served only while `expires` is strictly in
the future.

This is the single definition of session expiry (#173). It used to be written out at six call
sites -- five spelled `<=` and the `Session{T}` extractor spelled `<`, so a payload landing on
exactly the current millisecond was served by the extractor and refused by every store. The
window was one millisecond wide and nothing was exploitable, but expiry is a security-adjacent
predicate and a seventh site would have drifted the same way.

Pass `at` explicitly when sweeping a whole store, so the clock is read once rather than once per
entry -- [`cleanup_expired_sessions!`](@ref) does exactly this. It is also what makes the
boundary itself testable: every read path reads the clock internally, so `expires == now` cannot
otherwise be staged.

Implementing [`AbstractSessionStore`](@ref)? Call this rather than comparing `expires` yourself.

```julia
payload = SessionPayload(Dict{String,Any}("user_id" => 7), Dates.now(Dates.UTC) + Dates.Hour(1))
is_expired(payload)                            # false
is_expired(payload, payload.expires)           # true -- the boundary is expired
```
"""
is_expired(payload::SessionPayload, at::DateTime = Dates.now(Dates.UTC)) = payload.expires <= at

# A thread-safe in-memory store for sessions
struct MemoryStore{K, V} <: AbstractSessionStore{K, V}
    data::Dict{K, SessionPayload{V}}
    lock::Base.ReentrantLock
    MemoryStore{K, V}() where {K, V} = new{K, V}(Dict{K, SessionPayload{V}}(), Base.ReentrantLock())
end

"""
    MemoryStore()

Build a `MemoryStore{String, Dict{String,Any}}` -- the exact type parameters
`SessionMiddleware` pins its `store` keyword to, so this is the store to reach for
when you just want in-process sessions:

```julia
serve(middleware = [SessionMiddleware(store = MemoryStore())])
```

Sessions live in this process only: they are lost on restart and not shared between processes.
Use a persistent store (`pormg_nitro_session()`) behind more than one worker.

Each call builds a **separate** store. There is no shared default (#171) -- two `App`s that each
want their own session table simply call this twice.
"""
MemoryStore() = MemoryStore{String, Dict{String,Any}}()

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

        if is_expired(payload)
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

function cleanup_expired_sessions!(store::MemoryStore{K, V}) where {K, V}
    current_time = Dates.now(Dates.UTC)
    lock(store.lock) do
        # Collect first, delete after. Mutating a collection while iterating it is not a
        # supported pattern in Julia and `Dict` promises nothing about it.
        #
        # Honest scope: on the current implementation `delete!` only tombstones a slot and
        # never rehashes, so the one-pass form did NOT observably skip entries — measured, it
        # is correct today. This is hygiene against a documented-unsafe pattern whose validity
        # rests on an internal detail, not a fix for a reproduced bug. The rate limiter's
        # sweep (src/middleware/rate_limiter.jl) is two-pass for the same reason.
        expired = K[]
        for (key, payload) in store.data
            if is_expired(payload, current_time)
                push!(expired, key)
            end
        end
        for key in expired
            delete!(store.data, key)
        end
    end
    return nothing
end

# ── Copy-on-write table (atomic publish, lock-free reads) ───────────────────────
# A `String`-keyed table read on the request hot path and written rarely, off it. One
# instantiation: `custommiddleware :: CopyOnWriteDict{RouteMiddleware}`, route key
# ("METHOD|path", see `genkey`) → `(router middleware, route middleware)`. Written at route
# registration via `publish!` (LAST-writer-wins): re-running `urlpatterns` for a path must
# install the new middleware. "Registration" is not necessarily startup-only: under
# `revise=:lazy`, `Revise.revise()` runs on a request-handling task (src/core/lifecycle.jl), so
# re-registration can land while OTHER request tasks are inside `compose` reading this table.
#
# (There used to be a second instantiation, `middleware_cache :: CopyOnWriteDict{Function}`,
# shared by every pipeline on the `App`. #255 replaced it with a per-pipeline
# [`ChainCache`](@ref) below, which is why `cache!`, `cache_if_current!`, `delete!` and
# `empty!` are gone from this type: nothing invalidates or clears this table any more.)
#
# Shape: copy-on-write behind an atomic reference, NOT a lock around the read. A reader
# takes one acquire-load of `entries` and works on that snapshot; a writer copies the
# current table under `lock`, inserts, and release-stores the copy. No `Dict` reachable by
# a reader is ever mutated by *this module* — that is the entire safety argument. Julia's
# `Dict` tolerates concurrent *readers*, but never a reader concurrent with `setindex!`: a
# `rehash!` swaps the backing `slots`/`keys`/`vals` arrays underneath the reader, yielding
# a wrong lookup (one route's middleware served for another), a `BoundsError`, or a segfault.
#
# Scope of the guarantee, stated honestly: `@atomic` makes the *publish* unwritable, but
# nothing makes a returned *snapshot* unwritable. `App` is public, so app code can
# reach `ctx.service.custommiddleware` and `setindex!` a snapshot, reintroducing this bug with
# no error. `snapshot`'s "immutable by convention" is a convention, enforced by review rather
# than by the type.
#
# Why not simply lock the read: `compose` snapshots this table on EVERY request that reaches it,
# not just during a warmup window — it is the emptiness test, and the generation stamp the
# `ChainCache` is checked against. Every request runs on `Threads.@spawn`, so a lock would
# serialize the whole server through one `ReentrantLock` to protect writes that happen at
# registration time.
#
# The snapshot's IDENTITY is load-bearing, not just its contents: every write release-stores a
# freshly allocated `Dict`, so `===` between two snapshots answers "has anything been
# registered since?" That is the generation stamp `ChainCache` uses. A write path that mutated
# the published `Dict` in place would therefore break the chain cache as well as the readers.
#
# Cost of the trade: each write copies the whole table, so registering R routes is O(R^2)
# insertions in aggregate and discards R intermediate tables. One-time and off the
# steady-state path. The O(R^2) shape is the durable fact; a wall-clock number here would only
# rot. If a route table ever gets big enough for this to matter, the answer is to build the
# table once at route-registration time, not to abandon copy-on-write.
#
# `entries` is `@atomic`, so a plain `d.entries = ...` raises ConcurrencyViolationError:
# the type makes the unsynchronized publish that caused #68 unwritable. Bare *reads*
# are still legal (and only `:monotonic`) — always go through `snapshot`.
#
# Deliberately NOT `<: AbstractDict`. Subtyping would inherit `AbstractDict`-generic
# fallbacks that touch the live table with no synchronization and never go through
# `snapshot` — `get!` and `filter!` mutate it, `merge` and `copy` read it. It would also
# widen the method-ambiguity surface Aqua checks. Two operations, and no `getindex`, is
# the point. For the same reason there is no `Base.isempty`: spelling `snapshot` at a call
# site is the signal that the read is a point-in-time view.
#
# Relation to `_Writer`/`_Run` in src/middleware/access_log.jl: same generation-swap idea,
# specialized rather than departed from. `access_log` publishes a plain `run` field via the
# separate `active` atomic the reader must load anyway, so its publish rides free. Here
# there is one reference and no gate, so atomicizing that reference directly is the whole
# mechanism.
#
# The value type stays a parameter although one instantiation remains: `RouteMiddleware` is
# defined further down this file (it names `Nullable`, and its docstring belongs with the other
# route types), and the tests pin the container's semantics at a second `V` so they do not
# silently depend on the one in use.
#
# The key type is fixed to `String`, and #250 considered and declined parameterizing it: the only
# table keys on `genkey`, and a request reads it by key only on a chain-cache MISS (the hit path
# reads nothing but the snapshot's identity and `isempty`), so a tuple key here would buy
# nothing per request and would cost a wider signature everywhere. The per-request key that did
# cost a `String` is `ChainCache`'s, and that one is a tuple — see `ChainKey`.
mutable struct CopyOnWriteDict{V}
    @atomic entries :: Dict{String, V}
    const lock      :: Base.ReentrantLock
end

CopyOnWriteDict{V}() where {V} = CopyOnWriteDict{V}(Dict{String, V}(), Base.ReentrantLock())

"""
    snapshot(d::CopyOnWriteDict{V}) -> Dict{String, V}

Reader fast path: one acquire-load, allocation-free. The returned `Dict` is immutable by
convention — never `setindex!`/`delete!` it. The `:acquire` pairs with the `:release` in
[`publish!`](@ref), so a value is fully constructed by the time a reader can observe it.

Deliberately non-parametric in the signature: one method covers every instantiation and
still infers the concrete `Dict{String,V}` from a concrete argument.
"""
@inline snapshot(d::CopyOnWriteDict) = @atomic :acquire d.entries

"""
    publish!(d::CopyOnWriteDict{V}, key::String, value::V) -> V

**Last writer wins.** Publish `key => value`, replacing any existing entry; return `value`.
Use where re-registration must take effect — `custommiddleware`, where re-running
`urlpatterns` for a path installs the new per-route middleware.

Every publish release-stores a **new** `Dict`, which is what moves every pipeline's
[`ChainCache`](@ref) to a new generation: a chain composed before this call can no longer be
served, with no separate invalidation step (#255). Route middleware still goes through
`publish_route_middleware!` (src/routerhof.jl), the one sanctioned write site, so the
`RouteMiddleware` arity check stays in one place.

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
# `copy` preserved an over-large capacity. Shared by `publish!` and `cache_chain!`, which key
# on different types.
function _grown_copy(current::Dict{K, V}) where {K, V}
    updated = copy(current)
    sizehint!(updated, length(current) + 1)
    return updated
end

"""
    Context{T}

Handler-parameter extractor for the application context: the value passed as
`serve(context = …)` (or `internalrequest(…; context = …)`), wrapped with its type written down.

```julia
function health(req::HTTP.Request, ctx::Context{AppConfig})
    Res.json(Dict("env" => ctx.payload.env))
end

serve(context = config)
```

Declaring the type is what keeps the handler body type-stable, so prefer this over the untyped
`getcontext(req)`. Where only the request is at hand (inside middleware, or in
a helper), use the typed `getcontext(req, T)`.
"""
struct Context{T}
    payload::T
end



"""
    require_fixed_period(name::String, p::Period) -> Period

Validate a `Period` keyword that will be slept on or compared against a wall-clock duration.

Two checks, and both exist because the obvious `Dates.value(p) > 0` catches neither:

- **Calendar periods are rejected.** `Dates.value` is unit-relative, so `Dates.value(Month(1))`
  is `1` and sails past a positivity test — then `sleep(Month(1))` throws a `MethodError`
  (`Month` has no fixed length, so it cannot convert to `Second`). In a background task that
  throw lands *outside* the caller's control: the task dies at its first tick and the feature
  is silently off for the life of the process. `Dates.toms` is not a usable test either — it
  happily returns an *average* month for `Month(1)`.
- **Periods that round to a zero-length sleep are rejected**, since they would spin. Note this
  is a ~500 µs floor rather than exactly 1 ms: `Dates.toms` rounds to nearest, so
  `Microsecond(999)` survives as 1 ms while `Nanosecond(500)` does not.

Throwing here puts the error on the constructor call that is actually wrong, which is the same
reason `build_ip_extractor` validates trust configuration at construction rather than at
`serve()` (src/middleware/rate_limiter.jl).
"""
function require_fixed_period(name::String, p::Dates.Period)
    p isa Dates.FixedPeriod || throw(ArgumentError(
        "$name must be a fixed-length Period (Week, Day, Hour, Minute, Second, Millisecond, " *
        "Microsecond, Nanosecond), got $(typeof(p)). Calendar periods (Month, Quarter, Year) " *
        "have no fixed length, so they can neither be slept on nor compared against a " *
        "wall-clock duration — a background task using one dies on its first tick."))
    Dates.toms(p) > 0 || throw(ArgumentError(
        "$name must be at least 1 millisecond, got $p."))
    return p
end

"""
    LifecycleMiddleware(; middleware, on_startup = nothing, on_shutdown = nothing)

A middleware that owns a resource for as long as the server runs — a background task, a
connection, a buffer to flush. Bundles the request function with the hooks that start and stop
whatever sits behind it.

This is a **return type users meet**, not something most apps construct: `RateLimiter`,
`AccessLog`, `SessionMiddleware`, `SessionPruner` and `worker_startup` all hand one back.

# Fields

- `middleware::Function` — the request function, `handle -> req -> resp`. This is the part the
  chain actually runs.
- `on_startup::Union{Function,Nothing}` — called once by `serve()`, with no arguments. Its
  return value is discarded.
- `on_shutdown::Union{Function,Nothing}` — called once by `terminate()`, with no arguments.

Both hooks are optional; `nothing` means "nothing to do", which is why a middleware with no
resource to own can still be one of these rather than a bare function (`RateLimiter`'s
`:sliding_window` strategy is exactly that case).

# A middleware list accepts either form

```julia
serve(app, middleware = [RateLimiter(), SessionMiddleware(store = store)])
path("/api", handler, middleware = [RateLimiter()])
```

Only code composing a chain **by hand** needs the request function, and then it is the
`.middleware` field:

```julia
wrapped = SessionMiddleware(store = store).middleware(handler)
```

The type is not exported, so spell it `Nitro.LifecycleMiddleware` if you construct one:

```julia
serve(app, middleware = [Nitro.LifecycleMiddleware(
    middleware  = handle -> (req -> handle(req)),
    on_startup  = () -> @info("up"),
    on_shutdown = () -> @info("down"))])
```

# Ordering, and the idempotency requirement

Startup runs route-owned entries (declared via `path`/`urlpatterns`) before serve-owned ones
(declared via `serve(middleware = ...)`), each in registration order. Teardown is the exact
reverse — **LIFO**, matching Spring's `SmartLifecycle`, OTP supervisors and `defer`/`atexit`.
So a middleware may rely on anything registered before it still being up during its own
`on_shutdown`.

The one exception is **promotion**: hand the *same* object to both `serve(middleware = ...)`
and a route, and route ownership wins — it moves to the end of the route-owned half. Since
`terminate()` unwinds the serve-owned half first and the route-owned half second, a promoted
object is torn down **after every serve-owned entry** — including ones that started *before* it,
which LIFO would have torn down after it. For that object, in that one cycle, the guarantee above
is inverted: middleware it was registered after may already be down when its own `on_shutdown`
runs. Later cycles are settled, because `terminate()` clears only the serve-owned half. See
`register_route_lifecycle!` (`src/routerhof.jl`).

**The hooks must be idempotent across a `serve(); terminate(); serve()` cycle.** Route-owned
entries are registered once and survive `terminate()`, so a second `serve()` calls `on_startup`
again on the same object. A hook that spawns unconditionally leaks one task per restart. Give
each activation its own state and have `on_shutdown` retire it — see `_janitor`
(`src/middleware/janitor.jl`) for the per-activation token every periodic janitor in Nitro shares,
or `AccessLog` for the per-activation run struct.

A hook that throws is logged and swallowed, and the rest of the sequence still runs — see
[`startup`](@ref) and [`shutdown`](@ref). Ctrl-C is the one throw that is not discarded: the
sequence still runs to completion, and `serve()`/`terminate()` then re-raise the interrupt
once (#185).
"""
@kwdef struct LifecycleMiddleware 
    # The middleware function itself (handles incoming requests)
    middleware :: Function
    # A hook that's called when the server starts up (optional)
    on_startup :: Union{Function,Nothing} = nothing
    # A hook that's called when the server is shutdown (optional)
    on_shutdown :: Union{Function,Nothing} = nothing
end

# Report an interrupt caught by `startup`/`shutdown`, and hand it back to the broadcast site.
#
# Logged HERE, once per occurrence, because a broadcast re-raises only the FIRST one it collects:
# an interrupt from a later hook in the same sequence would otherwise vanish completely. No
# backtrace — an interrupt's stack is wherever the signal happened to land, which says nothing
# about the hook. One shared site so the two callers' wording cannot drift apart.
function _report_interrupt(e::InterruptException, which::String)
    @warn "Nitro: interrupt during LifecycleMiddleware.$which — the rest of the lifecycle " *
          "sequence still runs, then the interrupt is re-raised."
    return e
end

"""
    startup(lf::LifecycleMiddleware) -> Union{Nothing, InterruptException}

Run `lf.on_startup` if it has one. Called by `serve()` for every registered
[`LifecycleMiddleware`](@ref); apps do not normally call it.

A `nothing` hook is a no-op. A **throwing** hook is logged and swallowed, never rethrown: one
middleware failing to start must not abort the server and leave the middlewares already started
without their paired `on_shutdown`. The hook's own return value is discarded — `startup` returns
`nothing`, or the interrupt described below.

`InterruptException` is the one exception that is neither swallowed nor rethrown here: it is
**deferred**. `startup` logs it and *returns* it, and `startserver` (`src/core/lifecycle.jl`)
finishes broadcasting over the remaining hooks, unwinds through `terminate` — so the listener it
just opened does not stay open — and re-raises the interrupt once. Ctrl-C during startup is
honored without stranding the sequence (#185).

!!! note "Why not `e isa InterruptException && rethrow()`"
    That idiom (`src/utilities/misc.jl`, `src/middleware/janitor.jl`) is for *leaf* catch-alls,
    where rethrowing kills one operation and nothing else. `startup`/`shutdown` are *sequencers*,
    broadcast over every registered hook, so an escape from this frame abandons the rest of the
    sequence — on the teardown path it would skip `close(service)` outright and leave the server
    listening. Same intent, different mechanism: report and defer instead of rethrowing in place.

A hook that `fetch`es an interrupted task raises `TaskFailedException`, not `InterruptException`,
and is deliberately **not** unwrapped — the same narrowness the leaf idiom has.
"""
function startup(lf::LifecycleMiddleware)::Union{Nothing,InterruptException}
    isnothing(lf.on_startup) && return nothing
    try
        lf.on_startup()
    catch error
        error isa InterruptException && return _report_interrupt(error, "on_startup")
        @error "Error in LifecycleMiddleware.on_startup: " exception=(error, catch_backtrace())
    end
    # NOT the hook's value. The docstring has always said it is discarded, but this frame used to
    # return it anyway — `_janitor`'s `on_startup` hands back a `Task`, which leaked through here
    # into a slot that now means "was this hook interrupted?".
    return nothing
end

"""
    shutdown(lf::LifecycleMiddleware) -> Union{Nothing, InterruptException}

Run `lf.on_shutdown` if it has one. Called by `terminate()` for every registered
[`LifecycleMiddleware`](@ref), in the reverse of startup order; apps
do not normally call it.

A `nothing` hook is a no-op. A **throwing** hook is logged and swallowed, never rethrown — one
middleware failing to stop must not prevent the rest from being torn down. The hook's own return
value is discarded.

`InterruptException` is **deferred** the same way [`startup`](@ref) defers it: `shutdown` logs it
and returns it, and `terminate()` completes **both** shutdown broadcasts, clears the serve-owned
lifecycle list, closes the listener — escalating an interrupted drain to
a force-close — and only then re-raises it. If more than one hook is interrupted, each is logged
and the first is re-raised; the rest are dropped, since an `InterruptException` carries nothing to
tell them apart (#185).
"""
function shutdown(lf::LifecycleMiddleware)::Union{Nothing,InterruptException}
    isnothing(lf.on_shutdown) && return nothing
    try
        lf.on_shutdown()
    catch error
        error isa InterruptException && return _report_interrupt(error, "on_shutdown")
        @error "Error in LifecycleMiddleware.on_shutdown: " exception=(error, catch_backtrace())
    end
    return nothing  # not the hook's value — see `startup`
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

# ── Per-request accessor cache (#38) ──────────────────────────────────────────
#
# `pathparams`, `queryvars` and `headers` were the only request accessors with no
# memoization: each one re-decoded and rebuilt its whole `Dict` on every call, and the
# param binder calls them once *per bound parameter*, so a handler with three query
# params re-parsed the same unchanged target three times. `getjson`/`getform` have
# been memoized all along; this closes the gap.
#
# Deliberately reaches `getfield(req, :context)` — the raw `HTTP.RequestContext` —
# rather than `req.context`. The property accessor calls `_request_context_metadata!`,
# which *creates* the backing `Dict{Symbol,Any}` on first touch, so a plain cache
# probe would allocate the very thing it is trying to save. `RequestContext`'s own
# `haskey`/`getindex`/`setindex!` short-circuit on `metadata === nothing`, so a miss
# on an untouched request costs nothing.
#
# `haskey` + `getindex` rather than `get(ctx, key, nothing)` so a legitimately-cached value
# is never confused with a miss.
#
# `pathparams` is the one accessor that must NOT cache a `nothing`. `HTTP.getparams` reads
# `req.context[:params]`, a slot the ROUTER fills -- and middleware runs *before* the router.
# A pre-router read -- a guard doing `getparams(req)["user_id"]`, or anything touching `payload(req)`,
# which merges path params in -- would otherwise memoize `nothing` for the rest of the request,
# and the path binder would then index into `nothing` and turn every parameterized route into
# a 500. "Unrouted" is a transient state of the request, not a property of it, so it is
# returned uncached until the router has actually run.
#
# `payload(req)` needs its own handling on top of this and does not get it for free here: it
# merges a *copy* of the params, so refusing to cache the `nothing` is not enough to keep its
# merged map correct. `Core.request_input` carries that rule.
#
# Note also that the FIRST non-`nothing` value wins for the rest of the request. Nothing
# rewrites `req.context[:params]` after the router has set it -- there is one `HTTP.Router`
# per `App` and routers do not nest -- but a future layer that did would not be
# picked up here.
#
# A throwing builder caches nothing and rethrows on the next touch. That is correct and
# load-bearing: `queryvars` raises `ValidationError` on malformed percent-encoding, and
# a memoized *value* would be the wrong shape for an error the caller turns into a 400.
const REQUEST_PATHPARAMS_CACHE_KEY = :__nitro_request_pathparams
const REQUEST_QUERY_CACHE_KEY      = :__nitro_request_query
const REQUEST_HEADERS_CACHE_KEY    = :__nitro_request_headers

@inline function request_cache!(builder::Function, req::HTTP.Request, key::Symbol)
    ctx = getfield(req, :context)
    haskey(ctx, key) && return ctx[key]
    value = builder()
    ctx[key] = value
    return value
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
# callers (`Core.merge_request_input!`, `payload(req)`) rely on that passthrough — so the `nothing`
# is preserved rather than normalized to an empty Dict.
#
# Inference NARROWS here: `HTTP.getparams` reads a `Dict{Symbol,Any}` metadata table and infers
# `Any`, while this returns `Union{Nothing,Dict{String,String}}`. `raw_pathparams[name]` in
# `create_param_parser` therefore infers `String` instead of `Any` — one dynamic dispatch fewer
# on the request path, not a new instability. Do not "restore" the old shape.
#
# The decode cannot be done in place, so this builds a Dict — but it is built ONCE per request
# and cached by the `pathparams` wrapper below (#38), which makes `getparams(req)` a live handle
# rather than a snapshot: mutating it is visible to every later read. Treat it as read-only and
# use `req.context` to pass values down a request. `getjson`/`getform` have always behaved
# this way; this accessor and `queryvars` were the outliers.
#
# `HTTP.unescapeuri` THROWS on a malformed escape (`EOFError` for a trailing "%", `ArgumentError`
# for "%ZZ"). That is client input, so it must be a 400 -- and the decode now runs here, outside
# `parseparam_checked`, which is what used to convert it. Wrapping it keeps #18's guarantee that
# a malformed scalar param is a client error rather than a 500 with a logged backtrace.
# The offending value is deliberately not interpolated: `.msg` is app-reachable and a path
# segment can carry a token.
# The decode failure itself IS attached as `.cause`. Unlike the body and scalar wrap sites this one
# carries almost nothing -- `unescapeuri` fails inside `parse(UInt8, "ZZ"; base=16)` (the two hex
# digits) or as a message-free `EOFError` -- but the rule is uniform: since #130 none of `showerror`,
# `show` or `JSON.lower` renders a cause by default, at any of the four sites that attach one.
function _pathparams_uncached(req::HTTP.Request)
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
# Upper bound on how much of a client-supplied query-parameter NAME may be echoed into a
# `ValidationError.msg`, which is reachable from the `@debug` line in `handlerequest` (#72).
# Same shape as `MAX_REGEX_PARAM_LENGTH` in `src/utilities/misc.jl`: a cap defined beside the
# guard it serves, so the reason travels with it.
const MAX_QUERY_KEY_REPORT = 64

# Same guard, same reason: `HTTP.queryparams` decodes internally and throws on a malformed
# escape, so `?q=%ZZ` was a 500 here too (pre-existing -- this accessor's decode was never
# inside `parseparam_checked` either). Both accessors now owe their caller a well-formed map
# or a `ValidationError`; neither leaks a raw decode failure into the server-error path.
# Same `.cause` rule as `pathparams` above (#130): attached, never rendered by default.
function _queryvars_uncached(req::HTTP.Request)
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
        isvalid(v) && continue
        # #132: unlike `pathparams`, whose `k` is a ROUTE-DECLARED name, this key is
        # percent-decoded client input -- and `.msg` is on a log path since #72
        # (`@debug "Request rejected (400 Bad Request)" message=error.msg`). Interpolating it
        # raw let `?a%0AFAKE=%80` put a literal newline into a log field.
        #
        # `repr` rather than `isvalid(k)`: a control character IS valid UTF-8, so a UTF-8 check
        # alone leaves the newline. `repr` escapes control characters and invalid bytes alike,
        # which makes the escaping a property of this boundary rather than of whichever logger
        # the app happened to install -- `ConsoleLogger` escapes through `show` today, a
        # structured JSON logger interpolating the value need not. The cap bounds how much one
        # request can write into one log line; a key that long is not a useful diagnostic anyway.
        name = ncodeunits(k) > MAX_QUERY_KEY_REPORT ? "(name too long)" : repr(k)
        throw(ValidationError("Invalid UTF-8 in query parameter $name"))
    end
    return vars
end
# HTTP.jl v2 canonicalizes header field names to Title-Case (e.g. "Content-Type").
# Header names are case-insensitive per RFC 9110, and downstream consumers (the
# `Header` extractor's `struct_builder`, cookie lookups) match against lowercase
# keys, so normalize to lowercase here for stable, case-insensitive access.
_headers_uncached(req::HTTP.Request) = Dict(lowercase(String(k)) => String(v) for (k, v) in req.headers)

# The cached public accessors. The return annotations are not decoration: the cache
# round-trips through a `Dict{Symbol,Any}`, so without them every cached read would come
# back as `Any` and hand back the type instability #37 just removed from this path.
function pathparams(req::HTTP.Request) :: Nullable{Dict{String,String}}
    ctx = getfield(req, :context)
    haskey(ctx, REQUEST_PATHPARAMS_CACHE_KEY) &&
        return ctx[REQUEST_PATHPARAMS_CACHE_KEY] :: Dict{String,String}
    decoded = _pathparams_uncached(req)
    # See the note above: `nothing` here means the router has not run yet, so caching it
    # would poison every later read on this request.
    decoded === nothing && return nothing
    ctx[REQUEST_PATHPARAMS_CACHE_KEY] = decoded
    return decoded
end

queryvars(req::HTTP.Request) =
    request_cache!(req, REQUEST_QUERY_CACHE_KEY) do
        _queryvars_uncached(req)
    end :: Dict{String,String}

headers(req::HTTP.Request) =
    request_cache!(req, REQUEST_HEADERS_CACHE_KEY) do
        _headers_uncached(req)
    end :: Dict{String,String}

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

"""
    RouteDefinition

One route, as returned by `path`: the `pattern` (already converted from the Django-style
`<int:id>` to the router's `{id}` form), the `handler`, the HTTP `methods` it answers, an
optional reverse-lookup `name` (see `url`), optional route `middleware`, and the `type_hints`
parsed from the pattern's converters (`<int:id>` → `id => Int`).

A `RouteDefinition` registers nothing on its own. Pass it to `urlpatterns`, or collect several
in a `Vector` and prefix them with `include_routes`.
"""
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

"""
    RouteMiddleware

One route's middleware, as `ctx.service.custommiddleware` stores it: `(router-level,
route-level)`, each present or absent (#76).

The field used to be declared `CopyOnWriteDict{Tuple}`. Unparameterized `Tuple` is **abstract**,
so `buildmiddleware`'s destructure (src/routerhof.jl) inferred `Any` in both slots — followed by
two `append!` calls on values of unknown type. At the time that was not a once-per-route cost:
any pipeline with global middleware — `serve(middleware = [...])`,
`internalrequest(...; middleware = [...])`, and every `revise=:lazy|:eager` session — ran
`buildmiddleware` on **every request, forever** (#68). So it was steady-state dynamic dispatch
on the hot path for the normal production configuration, which is what put it under the "no
`Any` in the request hot path" rule rather than under cosmetics. (Since #255 every pipeline
caches its chains, so `buildmiddleware` is back to once per route per registration generation —
the narrowing still stands, it is just off the steady-state path now.)

Exactly two shapes are ever stored, from the only two write sites, and both go through
`publish_route_middleware!`:

  - `register_route` (src/routing.jl)      → `(nothing, route middleware)`
  - `(inner::InnerRouter)` (src/routerhof.jl) → `(router middleware, route middleware)`

Naming that type also **enforces the 2-arity**, which `Tuple` left entirely unchecked — a
three-slot or one-slot write is now a conversion error at the publish site instead of a
`MethodError` inside the destructure on some later request. That is a correctness property, and
it is worth more here than the inference is.

!!! note "What did NOT change: storage layout"
    `RouteMiddleware` is itself non-concrete — `isconcretetype` and `Base.allocatedinline` are
    both `false`, because each slot is a `Union` — so `Dict{String,RouteMiddleware}` still
    stores boxed values, exactly as `Dict{String,Tuple}` did. The win is entirely at the
    destructure, which is what the benchmark and `test/custommiddleware_tests.jl` measure. Do
    not read this narrowing as an inline-storage change; it is not one.

See [`NO_ROUTE_MIDDLEWARE`](@ref) for the lookup default.
"""
const RouteMiddleware = Tuple{Nullable{Vector{Function}}, Nullable{Vector{Function}}}

"""
    NO_ROUTE_MIDDLEWARE

The `get` default for a route absent from `custommiddleware` — "no middleware of either kind".

!!! note "#76's issue body is wrong about why this exists, and the correction is worth keeping"
    It argues that `get(table, key, (nothing, nothing))` would infer a `Union`, because
    `Tuple{Nothing,Nothing}` "is not a subtype of the pair type". **Julia's tuple types are
    covariant**, so `Tuple{Nothing,Nothing} <: RouteMiddleware` is in fact true, and a bare
    literal default infers exactly the same
    `Tuple{Union{Nothing,Vector{Function}}, Union{Nothing,Vector{Function}}}` this constant
    does. Measured, not argued. The narrowing's real win is the other end — before #76 the
    same destructure inferred `Tuple{Any, Any}`.

What the constant is still worth: it pins the miss path to whatever
[`RouteMiddleware`](@ref) is *declared* to be, rather than to a literal that happens to be a
subtype of today's declaration. Narrow the pair further later — say, to non-optional slots —
and a `(nothing, nothing)` literal would quietly widen the lookup's inferred type back out
while every test stayed green; this cannot, because it would stop constructing.
"""
const NO_ROUTE_MIDDLEWARE = RouteMiddleware((nothing, nothing))

"""
    ChainKey

A [`ChainCache`](@ref) key: `(method, route path)` — the same two strings `genkey` joins into
`"METHOD|path"` for `custommiddleware`, kept apart (#250).

Joining them was the one allocation a cache hit paid: a fresh `String` per request, on every
app with per-route middleware. Both halves already exist as strings when `compose` needs the key
— `req.method` (or the literal `"GET"` for an auto-`HEAD` leaf) and HTTP.jl's stored `Leaf.path`
— so a tuple of them costs nothing to build, and hashing it hashes the same bytes the joined
string would have.

Not a collision fix, and not claimed as one: `("A|/b", "/c")` and `("A", "/b|/c")` are distinct
here but join to the same `genkey`, and the chain cached under either is still *composed* from
`custommiddleware[genkey(...)]`. That needs a method containing `|` — a legal HTTP token
character that no real method uses — and it predates this key.
"""
const ChainKey = Tuple{String, String}

"""
    ChainCacheState(source, chains)

One generation of a [`ChainCache`](@ref): the `custommiddleware` snapshot `source`, and the
composed chains built **from that snapshot**. Immutable, so a reader that loaded it can never see
a chain paired with the wrong table.
"""
struct ChainCacheState
    source :: Dict{String, RouteMiddleware}
    chains :: Dict{ChainKey, Function}
end

"""
    ChainCache()

One pipeline's composed middleware chains (#255). `compose` (src/routerhof.jl) creates one per
pipeline, so it lives exactly as long as the pipeline does: the server's lifetime under `serve`,
one call under `internalrequest`.

# Why per pipeline, and why that makes the key complete

A chain is `foldlayers(handler, route mw, router mw)`. `handler`, which bakes in
`catch_errors`/`show_errors`/`serialize`, is fixed for one pipeline's lifetime; the other two
come from one `custommiddleware` snapshot. So *(this pipeline, that snapshot, method, path)*
determines the chain, and a cache owned by the pipeline and stamped with the snapshot is
complete **by construction**. (Global middleware is no longer part of a cached chain: since #291
it wraps route selection itself, folded once per pipeline.)

The `App`-wide `middleware_cache` this replaced had to rebuild that completeness argument in its
key, and could not: `cachetag` carried the three serializer booleans (#79), but global
middleware has no stable identity to key on, so every pipeline *with* global middleware —
`serve(middleware = [...])`, every `revise=:lazy|:eager` session — could not cache at all and
rebuilt its chain on every request, forever. Per-call tokens in a shared key would have fixed that
for `serve` and leaked an entry per `internalrequest` call; a pipeline-owned cache is thrown away
with the pipeline instead.

# Invalidation is a read-time check, not a write-time one

[`cached_chain`](@ref) returns a chain only when the stored generation's `source` is the **very
object** (`===`) the request just snapshotted. Every `publish!` to `custommiddleware` allocates a
new table, so after any registration no earlier chain can be served — there is nothing to
delete, and no ordering between the registration and a racing warmup to get right. That replaced
two mechanisms and a proof: publish-then-`delete!` in `publish_route_middleware!` (#71) and
`cache_if_current!`'s lock-ordering argument (#81).

The identity compare is sound because both sides are live when it runs: the state holds its
`source`, and the request holds its snapshot, so neither address can be reused by a new table.

# Why the world age is NOT part of the stamp

Composing a chain *calls* each middleware factory, so it is fair to ask whether a Revise edit to a
factory — which redefines its method without re-running `urlpatterns` — needs to invalidate the
cache. Under `serve` it cannot matter: a new task inherits its parent's world age, so every
request task runs in the world the listener was started in, and `compose` dispatches factories in
that fixed world whether it caches or not. Measured on the pre-#255 code, which recomposed on
every request: an edited factory served the old middleware under `serve` all the same.
(`ReviseHandler`'s `invokelatest` sits *inside* the chain, which is why edits to functions the
middleware calls do take effect — and still do, since the chain calls them by name.)

A world stamp was tried during #255's review and removed: it changed nothing under `serve`,
recomposed on every world bump in REPL- and test-driven pipelines, and leaned on the internal
`Base.tls_world_age`.

`internalrequest` rebuilds its pipeline per call, so it no longer reuses a chain across calls. It
already pays ~12 µs of pipeline construction per call; one fold on top is noise.
"""
mutable struct ChainCache
    @atomic state :: ChainCacheState
    const lock    :: Base.ReentrantLock
end

# Every new cache starts from this one shared state. Its `source` is a `Dict` no
# `custommiddleware` snapshot can ever be `===` to — each `CopyOnWriteDict` allocates its own —
# so an empty cache misses on every request until the first `cache_chain!`, which never writes
# into a state it did not just allocate. Sharing it rather than allocating per cache matters
# because `internalrequest` builds a pipeline, and so a cache, on every call: 3 allocations
# each, on apps with no per-route middleware that will never use the cache at all.
const EMPTY_CHAIN_STATE = ChainCacheState(Dict{String, RouteMiddleware}(), Dict{ChainKey, Function}())

ChainCache() = ChainCache(EMPTY_CHAIN_STATE, Base.ReentrantLock())

"""
    cached_chain(c::ChainCache, source::Dict{String,RouteMiddleware}, key::ChainKey) -> Union{Function, Nothing}

The chain cached for `key` **in the generation built from `source`**, or `nothing`. One
acquire-load, then a lookup on a table no writer mutates — allocation-free, which
test/middleware_cache_tests.jl pins (#250).

`source` must be the `custommiddleware` snapshot the caller takes for this request. A chain
cached under any other generation is not returned, however recently it was cached — that check
is the entire staleness guarantee, see [`ChainCache`](@ref).
"""
@inline function cached_chain(c::ChainCache, source::Dict{String, RouteMiddleware}, key::ChainKey)
    state = @atomic :acquire c.state
    state.source === source || return nothing
    return get(state.chains, key, nothing)
end

"""
    cache_chain!(c::ChainCache, table::CopyOnWriteDict{RouteMiddleware},
                 source::Dict{String,RouteMiddleware}, key::ChainKey, chain::Function) -> Bool

Record `chain`, built from the snapshot `source` of `table`, under `key`. Returns whether it
published.

- **Same generation** (`source` is the one already stored): first writer wins. A chain that is
  already cached keeps its identity and nothing is copied.
- **Different generation**: start a fresh generation holding only this chain — but only if
  `source` is still `table`'s *current* snapshot. A slow request that composed against an older
  table must not throw away a newer generation other requests are already filling.

Neither rule is what keeps a stale chain from being *served*; [`cached_chain`](@ref)'s identity
check does that on its own. These two only decide how much gets rebuilt, which is why this can be
checked without holding `table`'s lock: a registration landing just after the check leaves a
generation nobody will match, and the next request replaces it.

Takes the lock and, on the same-generation path, copies that generation's chain table.
"""
function cache_chain!(c::ChainCache, table::CopyOnWriteDict{RouteMiddleware},
                      source::Dict{String, RouteMiddleware}, key::ChainKey, chain::Function)::Bool
    return lock(c.lock) do
        state = @atomic :monotonic c.state
        if state.source === source
            haskey(state.chains, key) && return false
            chains = _grown_copy(state.chains)
        else
            snapshot(table) === source || return false
            chains = Dict{ChainKey, Function}()
        end
        chains[key] = chain
        @atomic :release c.state = ChainCacheState(source, chains)
        return true
    end
end

"""
    ROUTE_RESOLUTION_KEY

`req.context` key carrying the [`RouteResolution`](@ref) `compose` produced for this request
(#80). Internal — never part of the handler-facing context surface, which is `:route`,
`:params` and HTTP.jl's own keys.
"""
const ROUTE_RESOLUTION_KEY = :__nitro_route_resolution

"""
    RouteResolution(router, method, target, handler, route, params, mw_method, table, source)

One request's route lookup, handed from `compose` (src/routerhof.jl) to the innermost layer of
the pipeline (`_dispatch_resolved`, src/core/pipeline.jl) so the route is resolved **once**
(#80).

`compose` has to call `HTTP.Handlers.gethandler` before it can build a middleware-cache key, and
used to keep only `leaf.path` from it — discarding the handler and the `Params()` dict, which
`(r::Router)(req)` then recomputed at the bottom of the chain. That is two
`_router_request_path` + `split`, two trie walks and two `Dict{String,String}` per request, on
every app that registers per-route middleware. This struct is what carries the first lookup down
to where the second one used to happen.

# The guard is `(router, method, target)` — every input the lookup read

`_dispatch_resolved` honours this hand-off only when all three still match. That set is not a
judgement call: `HTTP.Handlers.gethandler` resolves from exactly `r.routes`, `req.method` and
`req.target`, so re-checking those three is what makes "reuse the lookup" indistinguishable
from "do the lookup again". A `router` mismatch falls through to `r(req)`, which is always
correct; a `method` or `target` mismatch is the rewrite case below, and is not.

**`router`** — because the stash lives on the *request*, while the invariant that makes it safe
lives on the *`App`*. A single `HTTP.Request` object can be passed to `internalrequest` more
than once, and nothing stops the second call naming a **different `App`** — or the same
`CONTEXT[]` after `resetstate()` replaced it. Those have their own `custommiddleware` and their
own router, so "the tables only grow" says nothing about them. Without this field, App A's
resolution is honoured by App B: B serves A's handler, skipping B's own route middleware, and
an `App` that never registered the path at all answers `200` instead of `404`.

The identity check assumes **one `Router` per `App`**, which is how `Service` is constructed
(`router = Router()` per instance). `Service` is exported and takes `router` as a keyword, so two
`App`s deliberately built around one shared `Router` but separate `custommiddleware` tables would
defeat it and reinstate the misroute. Nothing in `src/`, `test/` or `docs/` does that; it is
recorded here so the assumption is written down rather than inferred. Found in review;
regression: the cross-`App` items in test/custommiddleware_tests.jl, at both the
`_dispatch_resolved` and the `internalrequest` level. (The `resetstate()` variant is the same
mechanism — the dispatching router is not the one that stashed — and is deliberately *not* a
test; the note at that testset says why.)

!!! note "`router` is declared as the `UnionAll`, and parameterizing it was measured and rejected"
    `HTTP.Router` is not concrete — every real instance is a
    `Router{typeof(default404),typeof(default405),Nothing}` — so this field is a boxed
    pointer. An isolated microbenchmark of the constructor makes `struct RouteResolution{R}`
    with `router::R` look like it saves an allocation per matched request. **It does not, in
    the pipeline**: measured through a built `setupmiddleware` chain, both shapes come out at
    exactly 40 allocations and 1936 bytes per served request. `Service.router` is itself
    declared as the unparameterized `Router`, so the concrete type is not known where it
    matters anyway. Left unparameterized on purpose — do not re-derive the microbenchmark and
    "fix" it.

**`method`** and **`target`** — `gethandler` matches on both, and both are mutable fields. Since
#291 `compose` resolves the route *after* global middleware, so a global
`X-HTTP-Method-Override` or path-alias layer has already run by the time this is written and
never trips the guard. Only **router-level and route-level** middleware sit between `compose`'s
lookup and the terminal, so a mismatch here means one of those rewrote the request after its
chain was chosen. (`PrefixStripMiddleware` folds outside `compose` too, src/core/pipeline.jl.)

A mismatch is **not** simply re-resolved, and that is the #291 fix. The chain that already ran
was chosen for the stashed route; the rewritten request may reach a different leaf whose own
guards never ran. So the terminal re-resolves and serves the new leaf only when the entry the
running chain was built from — `genkey(mw_method, route)` in `table` — is exactly what that leaf
requires, or the leaf has no router or route middleware. Otherwise it refuses with a `500`. See
`_route_rerouted` (src/core/pipeline.jl). The entry itself is not stashed: that would cost a
`genkey` string on every matched request, which #250 removed from the cache-hit path, to serve
a case that is rare by construction.

What the new leaf requires is read from a **fresh** snapshot of `source`, not from `table`. The
router is live, so a route registered while this request sat in route middleware (Revise, a
runtime `include_routes`) can be the leaf the rewrite reaches, and `table` predates its entry —
reading "no entry" there would serve it unguarded. Across generations the check stays
fail-closed: an entry no registration touched is the same tuple in both tables, and one that was
replaced compares unequal.

**`===` on `String` compares contents, not addresses** — Julia's strings are egal by value, so
the method and target checks ask "is this still what I resolved against?" rather than "is it
the same object". That is the right question, and it is why a rewrite to a *byte-identical*
target correctly keeps the hand-off: same target, same route, nothing to redo. Still cheap —
the pointer-equal case, which is every request nothing rewrote, short circuits before comparing
contents. The `router` check is a true identity compare, which is what it should be.

# Staleness within one `App`

`compose` overwrites this entry on every request it matches — cache hit or miss alike, since
the write sits above the chain-cache lookup — so a later pass that re-resolves the same
`(router, method, target)` always installs the fresh handler. Re-registration is therefore
handled by construction, not by invalidation, which is why a pipeline's cached chain
([`ChainCache`](@ref)) can stay cached while the handler it reaches changes.

That leaves passes that write **no** stash, and those do not rely on an argument at all:
`compose` calls `_clear_resolution!` (src/routerhof.jl) on every path that reached `gethandler`
and did not stash — a 404 or a 405. (A non-`Function` leaf used to clear too; since #291 it
stashes like any other match, see `compose`.) Ran the lookup ⟹ wrote or cleared,
no third outcome, so a stale hand-off is structurally impossible rather than argued away.

It was argued away, once, and the argument was wrong. The claim was that a pass writing no
stash is unreachable after a match, because `HTTP.register!` replaces a leaf rather than
removing one. Upstream `insert!` matches an existing leaf with
`eq = (x, y) -> x == "*" || x == y`, so a method-specific registration **replaces a
wildcard-method one**, removing the route for every other method — and `path(…; method = "*")`
reaches it from ordinary Nitro code. `_clear_resolution!`'s docstring carries the reproduction.

One invariant of that shape survives, because `compose`'s **emptiness fast path** returns before
`gethandler` and so cannot clear: a request can only take it if every earlier pass took it too,
since `custommiddleware` never shrinks — nothing in `src/` removes a key from it, and
`CopyOnWriteDict` no longer has a `delete!` or `empty!` at all (#255). That one holds.

**And all of it is scoped per router, which is the other half.** Reading the old version as
unconditional is how the cross-`App` defect above got written; the `router` field is what
confines a stash to the router this reasoning is about.

"""
struct RouteResolution
    router     :: HTTP.Router
    method     :: String
    target     :: String
    handler    :: Function
    route      :: String
    params     :: Dict{String,String}
    mw_method  :: String                           # the method the running chain is keyed on
    table      :: Dict{String,RouteMiddleware}     # the snapshot that chain was built from
    source     :: CopyOnWriteDict{RouteMiddleware} # the live table, for the rerouted leaf's entry
end

"""
    DeclaredMethodHandler(method, handler)

A router leaf that is reached by requests whose method is not the one its route was declared
with. It calls `handler` unchanged and remembers the declared `method`, because the route's
middleware is published under that method (`genkey(method, path)`) and HTTP.jl's `gethandler`
returns the leaf's handler but not the leaf's own method. `compose` (src/routerhof.jl) reads
`method` back from here after the lookup, and keys both the middleware table and the cached chain
on it. Keyed on `req.method` instead, the lookup finds nothing and the route's guards never run.

Four leaves are registered this way:

| Declared | Reached by | Keyed on |
|---|---|---|
| `GET` (the auto-`HEAD`, #277) | `HEAD` | `GET` |
| `"*"` | any method | `*` |
| `STREAM` | `GET`, `POST` | `STREAM` |
| `WEBSOCKET` | `GET` | `WEBSOCKET` |

`STREAM` and `WEBSOCKET` are not methods on the wire; `registerhandler` resolves them to the
methods above (#282). Every other leaf is registered bare and keys on `req.method`, which then is
its declared method.

The auto-`HEAD` passes the request on as-is, still saying `req.method == "HEAD"`, and the write
path drops the body (src/core/transport.jl). An explicit `HEAD` route replaces that leaf with a bare
one and keys on `HEAD` as it always did.

A router built with HTTP.jl-level `middleware` wraps every leaf in it, which hides this type.
Registration handles that per case: no auto-`HEAD` at all, and an `ArgumentError` for a `"*"`,
`STREAM` or `WEBSOCKET` route that has middleware to key (src/core/registration.jl).

Subtypes `Function` so the `RouteResolution` hand-off stores it as-is, without the wrapper
closure `compose` gives a non-`Function` leaf. `method` is a `String` for every `F`, so `compose`
reads it without widening.
"""
struct DeclaredMethodHandler{F<:Function} <: Function
    method  :: String
    handler :: F
end

(h::DeclaredMethodHandler)(req::HTTP.Request) = h.handler(req)

end # module Types
