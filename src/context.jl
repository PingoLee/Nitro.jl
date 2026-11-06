module AppContext
import Base: @kwdef, wait, close, isopen
import Base.Threads: ReentrantLock
using HTTP
using HTTP: Server
using ..Types
# Unexported from `Types` on purpose: `CopyOnWriteDict` is internal plumbing for `compose`,
# so it is named explicitly here rather than widened onto `Core`'s reexport surface.
using ..Types: CopyOnWriteDict, RouteMiddleware, RouteChainRecord, NamedRoute, NitroRouter, nitro_router,
    MissResponse, miss_response, LifecycleEntry
using ..Constants: SHUTDOWN_TIMEOUT_SECONDS, DEFAULT_MAX_FIELDS, AbstractApp, ShutdownSignal
# The serve task, a shutdown and a Revise hook log what they caught as `loggable(e)`, never `e`:
# each logs whatever reached it, and the rule holds everywhere in `src/` (#658).
using ..Errors: loggable
using ..Util: _locked

export App, EagerReviseService, Service, wait, close, isopen
export set_extension!, get_extension, delete_extension!, has_extension

# The server lifecycle phases a `Service` moves through (#812), read and written only through
# `Service.phase`. Internal: `isopen(app.service)` stays the public question "is a listener open".
#
#   IDLE ──serve──▶ STARTING ──listener up──▶ SERVING ──terminate──▶ STOPPING ──last hook──▶ IDLE
#                      │  │
#                      │  └── terminate ──▶ CANCELLING ──the start unwinds──▶ IDLE      (#834)
#                      └── any failure before SERVING ──▶ IDLE
#
# The phase shares one word with the run's GENERATION (#834), which the claim `IDLE → STARTING`
# increments. Every transition is a compare-and-swap on the whole word, so a caller only ever
# moves the run it read: a `terminate` can no longer stop, or cancel, a run that started after it
# was called, and a blocking `serve` tears down only the run it won.
const PHASE_IDLE       = 0x00
const PHASE_STARTING   = 0x01
const PHASE_SERVING    = 0x02
const PHASE_STOPPING   = 0x03
const PHASE_CANCELLING = 0x04

_phase(word::UInt64)::UInt8 = word % UInt8
_gen(word::UInt64)::UInt64 = word >> 8
_word(gen::UInt64, phase::UInt8)::UInt64 = (gen << 8) | UInt64(phase)



@kwdef struct EagerReviseService
    task::Task
    # Atomic because `close` writes it from whichever task runs `terminate`, while the watcher
    # reads it on a `:default`-pool thread.
    done::Threads.Atomic{Bool}
    # `cancel_revision_wait` from the hooks the watcher was STARTED with, not whatever is
    # registered when `close` runs, so `close` always wakes the wait the task is parked in.
    cancel::Function
end

# Set the flag, then wake the watcher out of its wait (#427). Setting the flag alone left the
# watcher parked on Revise's event until the next save, and on an autoresetting event that save
# went to the dead watcher instead of the one a restarted `serve` had just started.
#
# A cancel that returns `false` found the watcher somewhere other than its wait. It is either
# mid-revision, and then it rechecks the flag and exits on its own, or a few instructions short
# of parking, having read the flag just before it was set. Only the second case needs another
# attempt, and it parks within microseconds. So the retry runs on a `:default` task, never in
# `terminate`, which must not wait behind a revision, and gives up after a second. By then the
# watcher has either been woken or will exit at its next flag check, so giving up leaks nothing.
#
# `close` runs inside `terminate`, after the listener is already down, so nothing here may throw.
# A hook that fails, or returns something other than a `Bool`, is logged once and not retried.
# The watcher then exits at its next event, as it did before #427. The retry task also ends
# quietly on an interrupt. Under `julia -t 1` it shares thread 1, so a Ctrl-C can land in it, and
# `errormonitor` would otherwise report the press as a crash.
function Base.close(revise_service::EagerReviseService)
    revise_service.done[] = true
    task, cancel = revise_service.task, revise_service.cancel
    istaskdone(task) && return nothing
    # `true`: woken. `nothing`: the hook is broken and has been logged. Only `false` retries.
    _try_cancel(cancel, task) === false || return nothing
    errormonitor(Threads.@spawn :default try
        timedwait(1.0; pollint = 0.01) do
            istaskdone(task) || _try_cancel(cancel, task) !== false
        end
    catch e
        e isa InterruptException || rethrow()
    end)
    return nothing
end

function _try_cancel(cancel::Function, task::Task)::Union{Bool,Nothing}
    try
        return Base.invokelatest(cancel, task)::Bool
    catch e
        e isa InterruptException && rethrow()
        @error "Nitro: cancelling the eager-Revise watcher's wait failed" exception=(loggable(e), catch_backtrace())
        return nothing
    end
end

# A trimmed build's server shims hand this back instead of a result when the call threw. The
# exception never unwinds through the `@cfunction` frame: it is caught on the far side and thrown
# again, as itself, on this one, as `EndpointFailure` does for a route (src/routeendpoint.jl).
struct ServerCallFailure
    err :: Any
end

"""
    ServerHandle(server::HTTP.Server)

The running server, behind one concrete type, for `Service.server` (docs/design/juliac-trim.md
§3.3). The server's own type depends on the pipeline's, so a field holding it is abstract, and
`juliac --trim=safe` rejects each call made through it: `isopen`, `wait` and the shutdown.

**Under the JIT the handle holds only the server**, and each call is the direct call the bare
field made before. **In a trimmed build** (`Types._trimmed()`) the constructor, which
`startserver` calls where the server's type is concrete, also takes a static `@cfunction` pointer
to each shim below, specialized on that type, and the calls become a `ccall`. The pointers are
made at run time and never stored in an image. Pinned by test/juliac_internals_contract_tests.jl.
"""
struct ServerHandle
    server   :: Server
    isopen_c :: Ptr{Cvoid}    # `C_NULL` under the JIT, as are the other two
    wait_c   :: Ptr{Cvoid}
    close_c  :: Ptr{Cvoid}
end

# The shims a trimmed build calls. None of them throws: see `ServerCallFailure`.
function _handing_back(f::F, server::Server)::Any where {F}
    try
        return f(server)
    catch err
        return ServerCallFailure(err)
    end
end
_isopen_shim(server::S) where {S<:Server} = _handing_back(isopen, server)
_wait_shim(server::S) where {S<:Server} = _handing_back(wait, server)
_close_shim(server::S, timeout::Float64) where {S<:Server} =
    _handing_back(s -> _shutdown_server(s; timeout), server)

# After the shims: `@cfunction` resolves their names when this method is defined.
function ServerHandle(server::S) where {S<:Server}
    Types._trimmed() || return ServerHandle(server, C_NULL, C_NULL, C_NULL)
    return ServerHandle(server,
                        @cfunction(_isopen_shim, Any, (Ref{S},)),
                        @cfunction(_wait_shim, Any, (Ref{S},)),
                        @cfunction(_close_shim, Any, (Ref{S}, Float64)))
end

function _handed_back(result)
    result isa ServerCallFailure && throw(result.err)
    return result
end

# A handle built while `_trimmed()` was still `false` has no pointers. No build makes one today
# (the switch flips while routes register, before `serve`), but a `ccall` through `C_NULL` would
# crash the process, so it is refused instead, as `_endpoint_fptr!` refuses a missing thunk.
function _server_fptr(p::Ptr{Cvoid})::Ptr{Cvoid}
    p == C_NULL && throw(ErrorException(
        "Nitro: this server handle was built outside a trimmed build and has no code to call"))
    return p
end

function Base.isopen(h::ServerHandle)::Bool
    Types._trimmed() || return isopen(h.server)
    return _handed_back(ccall(_server_fptr(h.isopen_c), Any, (Any,), h.server))::Bool
end

function Base.wait(h::ServerHandle)::Nothing
    Types._trimmed() || return wait(h.server)
    return _handed_back(ccall(_server_fptr(h.wait_c), Any, (Any,), h.server))::Nothing
end

# A trimmed build passes `timeout` as a `Float64`, which a `ccall` needs.
function _shutdown_server(h::ServerHandle; timeout::Real)::Bool
    Types._trimmed() || return _shutdown_server(h.server; timeout)
    return _handed_back(ccall(_server_fptr(h.close_c), Any, (Any, Float64), h.server,
                              Float64(timeout)))::Bool
end

# Every mutable slot is a concrete `Base.RefValue{T}`, never `Ref{T}` (#571). `Ref{T}` is ABSTRACT
# -- it has several concrete subtypes -- so `getindex` on a `Ref{T}` field cannot be resolved
# statically and every `service.x[]` came back `Any`: a dynamic call per read, including the
# `cookies[]` read `Cookie{T}`/`Session{T}` binding makes on every request, and the first wall a
# `juliac --trim` build hits. `Ref{T}(x)` constructs a `RefValue{T}`, so the defaults and every
# `x[]`/`x[] = v` call site are unchanged.
@kwdef struct Service
    # Set by `startserver`, cleared by `close`. A `ServerHandle`, not the `HTTP.Server`, so that
    # every call through it resolves in a trimmed build.
    server              :: Base.RefValue{Nullable{ServerHandle}} = Ref{Nullable{ServerHandle}}(nothing)
    # Concrete, so every pipeline closure that captures it is too (#625). It is not a
    # customization point: a router of another type does not convert. The custom 404/405 live on
    # `App`; see `NitroRouter` (src/types.jl).
    router              :: NitroRouter              = nitro_router()
    custommiddleware    :: CopyOnWriteDict{RouteMiddleware} = CopyOnWriteDict{RouteMiddleware}()
    # Each route's chain, folded once at registration (#718), beside the entry it was folded from.
    # Written only by `publish_route_middleware!`, which publishes here and then `custommiddleware`
    # under `route_chains_lock`; `compose`'s `_route_chain` takes the same lock when the two disagree.
    route_chains        :: CopyOnWriteDict{RouteChainRecord} = CopyOnWriteDict{RouteChainRecord}()
    route_chains_lock   :: ReentrantLock            = ReentrantLock()
    named_routes        :: Dict{String, NamedRoute} = Dict{String, NamedRoute}()
    external_url        :: Base.RefValue{Nullable{String}} = Ref{Nullable{String}}(nothing)
    prefix              :: Base.RefValue{Nullable{String}} = Ref{Nullable{String}}(nothing)
    eager_revise        :: Base.RefValue{Nullable{EagerReviseService}} = Ref{Nullable{EagerReviseService}}(nothing)
    named_routes_lock     :: ReentrantLock          = ReentrantLock()
    # Route shape -> `:auto`, `:explicit` or `:retired`: who owns the `HEAD` leaf there (#277).
    # Explicit `HEAD` wins whatever the registration order; see `_register_head!`
    # (src/core/registration.jl).
    head_routes         :: Dict{String, Symbol}     = Dict{String, Symbol}()
    head_routes_lock    :: ReentrantLock            = ReentrantLock()
    # Lifecycle middleware, split by the SCOPE that declared it (#82). The two halves have
    # genuinely different lifetimes, and collapsing them into one collection is what made
    # `serve(); terminate(); serve()` silently drop every route-level startup hook:
    #
    #   `route_lifecycle` — declared by the CONTEXT, at `urlpatterns()`/`router()` time, once.
    #       Nothing re-adds these on a second `serve()`, because routes are not re-registered.
    #       Survives `terminate()`; cleared only by replacing the context (`resetstate()`).
    #
    #   `serve_lifecycle` — declared by THIS SERVER RUN, from the `serve(middleware = ...)`
    #       list, on every `serve()`. Cleared by `terminate()`, or `serve(middleware=[A]);
    #       terminate(); serve(middleware=[B])` would start `A`'s lifecycle again as well.
    #
    # This is the Spring application-context distinction: the registry is a *declaration*, not
    # a consumable, and a declaration belongs to whatever owns it. No framework clears its
    # lifecycle registry wholesale on stop — Spring closes the context and you build a new one,
    # ASP.NET disposes the `IHost`, an OTP child spec outlives its supervisor terminating.
    #
    # `Vector`, not `Set`, and guarded by `lifecycle_lock` (#74). Broadcasting `startup.`/
    # `shutdown.` over a `Set` collected it in hash order, and `LifecycleMiddleware` is an
    # immutable struct whose fields are closures — heap objects — so the order varied run to
    # run. Teardown is now LIFO: startup in registration order, shutdown in its exact reverse,
    # matching Spring's `SmartLifecycle` phases, ASP.NET Core's `IHostedService`, OTP
    # supervisors, ASGI lifespan, and `defer`/`atexit`. Nobody ships FIFO teardown, and nobody
    # should ship an unspecified one.
    #
    # Dedup moves from `Set` to a membership guard (`_holds`) in `register_*_lifecycle!` and
    # stays load-bearing: one shared `RateLimiter()` passed to N routes must start its cleanup
    # task once, not N times. Swapping the container without that guard would regress it silently.
    #
    # One lock for both halves — they are always read together, and the asymmetry #74 points at
    # (`named_routes` has `named_routes_lock`, `extensions` has `extensions_lock`) is the
    # convention here.
    #
    # Each element is a `LifecycleEntry` (src/routeendpoint.jl), not the bare middleware (#719):
    # one concrete type, so the broadcast over a half is a static call per hook, and in a trimmed
    # image the entry carries the pointer its hooks are called through. Its `mw` is the object
    # dedup and promotion compare.
    route_lifecycle       :: Vector{LifecycleEntry} = LifecycleEntry[]
    serve_lifecycle       :: Vector{LifecycleEntry} = LifecycleEntry[]
    lifecycle_lock        :: ReentrantLock          = ReentrantLock()
    cookies               :: Base.RefValue{CookieConfig} = Ref{CookieConfig}(CookieConfig())
    extensions            :: Dict{Symbol, Any}      = Dict{Symbol, Any}()
    extensions_lock       :: ReentrantLock          = ReentrantLock()
    shutdown_timeout      :: Base.RefValue{Float64} = Ref{Float64}(SHUTDOWN_TIMEOUT_SECONDS)
    # The current server run's shutdown signal: `cancel_reason(req)` reads it as `:shutdown`
    # (#466), and `Res.pause` wakes on it (#815). A handler that polls it can finish inside
    # `shutdown_timeout` instead of being force-closed. It is a flag plus the tasks parked on it
    # right now, not a registry of in-flight requests, so nothing is written per request. Each
    # pipeline captures the signal current when it is built (`_app_context_seed`). `terminate`
    # swaps in a fresh one and only then signals the old one. So the run it stops drains with its
    # own signal set, and the next run builds on the clean one. (A `serve` can no longer start
    # during that drain, #812; the swap keeps the two runs' signals apart regardless.)
    shutting_down         :: Base.RefValue{ShutdownSignal} = Ref(ShutdownSignal())
    # Where this App is in its server lifecycle (#812): `PHASE_IDLE`, `PHASE_STARTING`,
    # `PHASE_SERVING` or `PHASE_STOPPING`. `isopen(service)` answers a narrower question, whether a
    # listener is open, and `terminate` closes the listener when its drain STARTS, so a guard on
    # `isopen` alone admitted a second `serve` while the first run's teardown hooks were still to
    # run. `serve` claims `IDLE -> STARTING` and `terminate` claims `SERVING -> STOPPING`, each with
    # one compare-and-swap, so two callers can never both win; the phase returns to `IDLE` only once
    # the last `on_stopped` hook has run. See `_claim_phase!`. The word also carries the run's
    # generation (#834): `_phase`/`_gen` split it.
    phase                 :: Threads.Atomic{UInt64} = Threads.Atomic{UInt64}(_word(UInt64(0), PHASE_IDLE))
    # Notified, under its own lock, every time a run goes back to `IDLE` (`_settle_idle!`), which is
    # what a `terminate` that found the run cancelling or stopping waits for (#834).
    phase_cond            :: Threads.Condition      = Threads.Condition()
    # `serve(max_fields = …)`. The pipeline's outermost layer binds THIS cell, not a copy, in
    # `REQUEST_SCOPE` for each request's extent (#327, #444), so a pipeline built before `serve`
    # sets it still sees it. Concrete `RefValue` so the scope can hold it without a conversion.
    # `0` means unlimited.
    max_fields            :: Base.RefValue{Int64}   = Ref{Int64}(DEFAULT_MAX_FIELDS)
    # The never-firing `Timer` held while serving on the Julia versions `_needs_wake_guard`
    # names (#598). `nothing` everywhere else, and whenever nothing serves.
    wake_guard            :: Base.RefValue{Nullable{Timer}} = Ref{Nullable{Timer}}(nothing)
    wake_guard_lock       :: ReentrantLock          = ReentrantLock()
end

"""
    App(; mod = nothing, not_found = HTTP.Response(404), method_not_allowed = HTTP.Response(405)) -> App

A Nitro application: its own router, middleware, cookie config, lifecycle hooks and app
context. Several can coexist in one process, each serving independently.

```julia
using Nitro

app = App(mod = @__MODULE__)
urlpatterns(app, "", Routes.urlpatterns(config))
serve(app; host = "127.0.0.1", port = 8080, context = config)
```

Every routing, serving and cookie function takes an `App` as its first argument:
`urlpatterns`, `serve`, `terminate`, `internalrequest`,
`url`, `staticfiles`, `configcookies`, `getexternalurl`.
The argument-less forms of those functions are a convenience layer over one process-wide
`App`; reach for an explicit handle whenever a second app, or an isolated test, would
otherwise have to mutate that global.

# Keyword arguments
- `mod = nothing`: the module whose code Revise should track for `serve(revise = :lazy|:eager)`.
  **Pass `@__MODULE__` from your own module** — writing it at the call site is the only way it
  can be correct, because a `@__MODULE__` *default* would expand where `App` is defined (inside
  Nitro) rather than where it is called. Only `revise` reads this; leaving it `nothing` is fine
  for everything else and `serve` says so if you ask for `revise` without it.
- `not_found = HTTP.Response(404)`: the response to a request no route matches, static mounts
  and a path outside `serve(prefix = …)` included.
- `method_not_allowed = HTTP.Response(405)`: the response to a request whose path is served under
  other methods only. Nitro adds an `Allow` header listing those methods unless the response
  already carries one.

  Both are **fixed values**, shared by every request they answer, and never changed: `Allow`
  goes on a new response, and the server hands HTTP.jl a copy of whatever it sends, as it does
  for every response. The copies share the body, so it must be one that can be sent any number
  of times: **no body** (`HTTP.Response(404)`), a **`String`** or a
  **`Vector{UInt8}`**, which is what `Res.json(…; status = 404)` and `Res.send(…; status = 404)`
  build. Another string or byte vector (a `SubString`, a `view`) is copied into one of those. A
  `Vector{UInt8}` body is kept as given, so do not resize or overwrite it afterwards.
  Anything else throws an `ArgumentError` naming the keyword, including a cursor or streaming
  body such as `HTTP.BytesBody`, which only the first miss could send; it is refused, not read
  into bytes. They are values rather than handlers, and of those three body types only, so that
  `App` stays concretely typed, which `juliac --trim` needs (docs/design/juliac-trim.md §3.1). To
  vary a miss per request, use a middleware that checks `route_missed(req)` on the response's
  way out. A miss outside `serve(prefix = …)` is the one it cannot reach: that is answered before
  any middleware passed to `serve`, a router or a route runs.

The remaining fields are internal: `service` holds the router and per-server state, and
`app_context` carries the payload passed to `serve(context = ...)` — read that through
`getcontext` on the request, never off the `App`, or you reintroduce the race #31
removed.
"""
@kwdef struct App <: AbstractApp
    service :: Service          = Service()
    mod     :: Nullable{Module} = nothing
    # `Base.RefValue{Any}`, not `Ref{Any}`: `Ref` is abstract, so `getindex` on it was a dynamic call
    # on every request, as it was for the `Service` slots before #571.
    app_context :: Base.RefValue{Any} = Ref{Any}(missing) # This stores a reference to an Context{T} object
    # Only the three resendable body types (`Types.MissResponse`); the constructor below converts
    # or refuses anything else. Shared by every miss; the transport hands HTTP.jl a copy
    # (`_handoff_copy` in src/core/transport.jl, #628).
    not_found          :: MissResponse = HTTP.Response(404)
    method_not_allowed :: MissResponse = HTTP.Response(405)

    function App(service, mod, app_context, not_found, method_not_allowed)
        return new(service, mod, app_context, miss_response(:not_found, not_found),
                   miss_response(:method_not_allowed, method_not_allowed))
    end
end

# SECURITY: `App` is public now, so it lands in REPL auto-display, `@show`, and interpolated
# log lines. The default `show` would walk `service`, whose router and middleware closures
# capture the cookie/JWT `secret_key`, DB credentials and API keys — the same disclosure the
# `NitroStreamHandler` override exists to prevent for `HTTP.Server` (src/core/lifecycle.jl).
# Print only the module and whether it is serving. (`dump` still walks raw fields; that is
# explicit introspection, not accidental disclosure.)
function Base.show(io::IO, app::App)
    print(io, "App(")
    app.mod === nothing || print(io, "mod=", app.mod, ", ")
    print(io, isopen(app.service) ?
              "serving on $(something(app.service.external_url[], "an open listener"))" :
              "not serving", ")")
end
Base.show(io::IO, ::MIME"text/plain", app::App) = show(io, app)

function Base.isopen(service::Service)
    handle = service.server[]
    return !isnothing(handle) && isopen(handle)
end

# Move `service` from the phase word `from` to `to` if, and only if, it holds `from` now. One
# compare-and-swap, so of two tasks racing for the same transition exactly one wins (#812), and a
# word from an earlier run never matches a later one (#834).
_claim_phase!(service::Service, from::UInt64, to::UInt64)::Bool =
    Threads.atomic_cas!(service.phase, from, to) === from

# Whether `service` has no server run in any phase: not starting, serving or stopping.
_idle(service::Service)::Bool = _phase(service.phase[]) === PHASE_IDLE

# Hand run `gen` back to `IDLE` and wake every `terminate` waiting for it (#834). The notify is
# under the condition's lock, so a waiter that checked the word under that lock is either already
# parked (and woken) or about to read the new word. The store and the notify both sit inside
# one deferred-SIGINT region: an interrupt landing between them would leave such a waiter parked for
# good. The raw `sigatomic_begin`/`sigatomic_end` pair rather than `Base.disable_sigint(f)`, whose closure allocates,
# and so is a safepoint, BEFORE the region begins: an interrupt there would skip the store and leave
# the run stopping for good. A press that arrived inside is raised by `sigatomic_end`, after both;
# in `terminate`'s `finally` it then replaces whatever was propagating, which is the price of never
# losing the settle.
function _settle_idle!(service::Service, gen::UInt64)
    Base.sigatomic_begin()
    try
        service.phase[] = _word(gen, PHASE_IDLE)
        lock(service.phase_cond)
        try
            notify(service.phase_cond)
        finally
            unlock(service.phase_cond)
        end
    finally
        Base.sigatomic_end()
    end
    return nothing
end

# Park until `service`'s phase word is no longer `word` (#834). Only a transition to `IDLE` is
# notified, so this is for words that can only move there: `CANCELLING` and `STOPPING`.
# `_locked`, not `lock(f, c)` (#861): on the Julia 1.14 alpha1 nightly `lock(f, ::Threads.Condition)`
# was compiled for `f::Function`, so its call into `lock`'s keyword body was dynamic, on `serve`'s
# stop path. Fixed in Base by JuliaLang/julia#64415, and the keyword itself left the 1.14 branch
# with JuliaLang/julia#64651 (it is 1.15's); `_locked` is correct on every version, so it stays.
function _await_phase_change(service::Service, word::UInt64)
    _locked(service.phase_cond) do
        while service.phase[] === word
            wait(service.phase_cond)
        end
    end
    return nothing
end

function Base.wait(service::Service)
    handle = service.server[]
    return !isnothing(handle) && wait(handle)
end

"""
    _shutdown_server(server::Server; timeout::Real) -> Bool

Bounded graceful shutdown of an `HTTP.Server`, modeled on Go's `http.Server.Shutdown(ctx)`:
stop accepting, let in-flight work finish for at most `timeout` seconds, then cut whatever
is left. Returns `true` when the graceful drain finished on its own, `false` when it had to
be forced.

`HTTP.close(::Server)` already releases the **listening socket first**, so the port is freed
either way and the timeout only ever escalates *connection* teardown. What `close` does not
bound is the drain that follows: it loops on `HTTP._close_idle_conns!`, which force-closes
only `IDLE` connections (and `NEW` ones older than 5s) and returns `true` only once nothing
is tracked at all. A connection whose handler is still running stays `ACTIVE` for that
handler's whole lifetime — and HTTP 2.4 declares `_ConnState.HIJACKED` but never assigns it,
so a WebSocket, SSE, or STREAM handler pins its connection `ACTIVE` forever and that loop
never terminates. `terminate()` called from *inside* a handler is the same deadlock against
its own connection.

Overlapping `close` and `forceclose` is safe: `_begin_shutdown!` and `_close_listener!` are
lock-guarded and idempotent, and Reseau documents a repeated `close` on a connection as a
no-op.

The drain task is *not* waited on after the force. A handler blocked on its own socket
unwinds as soon as `forceclose` tears the transport down, and the task exits within
milliseconds. A handler blocked on something else — an app lock, an `Event`, a long `sleep` —
never unwinds, so its drain task keeps polling for the life of the process. That is a bounded
per-forced-shutdown cost (one task in a backoff loop, capped at a 0.5s poll), and it can hold
neither the listening socket, which is released before this function returns, nor the server
handle, which the caller releases. Waiting on it instead would add the whole grace period
again to every forced shutdown and still not collect it.
"""
function _shutdown_server(server::Server; timeout::Real)::Bool
    timeout >= 0 || throw(ArgumentError("`timeout` must be >= 0 seconds, got $timeout"))

    # `HTTP.close` and `HTTP.forceclose` both call `wait(server)`, which rethrows a serve task
    # that already died (an accept-loop error is rethrown, not swallowed). Tolerate exactly
    # that — a shutdown must still be able to finish over a server that is already broken, and
    # letting it escape would stop the caller clearing its own handle.
    #
    # Everything else must stay loud. A bare `catch` here would demote structural breakage —
    # an HTTP upgrade renaming `forceclose`, say — to a debug line, silently skipping the
    # force-close and quietly reinstating the unbounded hang this function exists to prevent.
    _expected(err) = err isa TaskFailedException

    # The serve task's own failure is only logged by the *blocking* `startserver` path, so for
    # `async=true` this is the first and only place it gets reported. `maxlog=1` keeps a
    # repeatedly-terminated broken server from flooding.
    _report(err, what) =
        @warn "Nitro: $what ran against a serve task that had already failed" exception=loggable(err) maxlog=1

    # Documented opt-out of the graceful phase.
    if iszero(timeout)
        try
            HTTP.forceclose(server)
        catch err
            _expected(err) || rethrow()
            _report(err, "force-close")
        end
        return false
    end

    drain = Threads.@spawn begin
        try
            close(server)
        catch err
            # Rethrowing here would *hide* the error: nothing ever fetches this task, so a
            # failed task is silent. Log instead, at a level that matches the cause.
            if _expected(err)
                _report(err, "graceful shutdown")
            else
                @error "Nitro: graceful server shutdown failed unexpectedly" exception=(loggable(err), catch_backtrace())
            end
        end
    end

    timedwait(() -> istaskdone(drain), Float64(timeout); pollint = 0.05) === :ok && return true

    @warn "Nitro: server did not drain within $(timeout)s — force-closing the remaining " *
          "connections. Long-lived WebSocket/SSE/STREAM handlers are the usual cause: they hold " *
          "their connection for the handler's whole lifetime, so the graceful drain has nothing " *
          "to wait for. Set `serve(shutdown_timeout = …)` or `terminate(timeout = …)` to tune this."

    try
        HTTP.forceclose(server)
    catch err
        _expected(err) || rethrow()
        _report(err, "force-close")
    end

    # Deliberately do NOT wait on `drain` — see the docstring. Briefly: the case that reaches
    # this branch is often a handler that `forceclose` cannot unblock, so waiting would cost
    # the whole grace period again and still not collect the task.
    return false
end

"""
    close(service::Service; timeout = service.shutdown_timeout[])

Shut the service's HTTP server down within `timeout` seconds (see `_shutdown_server`) and
release the handle.
"""
function Base.close(service::Service; timeout::Real = service.shutdown_timeout[])
    handle = service.server[]
    if !isnothing(handle)
        _shutdown_server(handle; timeout)
        # Drop the handle — a closed `HTTP.Server` can never be restarted, so keeping it only
        # lets `serve()`'s already-serving guard mistake a corpse for a live listener.
        #
        # Compare-and-clear, NOT an unconditional nil. `HTTP.close` releases the listener up
        # front, so `isopen(service)` goes false while the drain is still running. A concurrent
        # `serve()` used to be admitted there, and clearing blindly afterwards stranded *that*
        # server: live, listening, and unreachable from `terminate()`. `serve` now refuses until
        # the phase is back to `PHASE_IDLE` (#812), which closes the window; the compare stays as
        # the second line of defence, since a handle written by anyone else is never ours to drop.
        service.server[] === handle && (service.server[] = nothing)
    end
    _release_wake_guard!(service)
    _close_eager_revise(service)
    return nothing
end

# Stop the `revise = :eager` watcher, if one runs. A trimmed build never starts one (`serve` refuses
# Revise there), so the branch folds away, and with it the watcher's `invokelatest`
# (docs/design/juliac-trim.md §3).
function _close_eager_revise(service::Service)
    Types._trimmed() && return nothing
    watcher = service.eager_revise[]
    watcher === nothing || close(watcher)
    return nothing
end

# JuliaLang/julia#63882 (#586, #598). On Julia 1.13.0-rc3 through 1.13.x, a task parked on a
# `Timer` -- a `sleep`, a `timedwait`, a deadline -- does not wake while every `:default` thread
# runs a handler that calls `yield()`, as long as its timer is the only live libuv handle in the
# process. It begins with the scheduler backports in JuliaLang/julia#62665; 1.12 and 1.14-DEV are
# not affected. A Nitro app with no janitor (no `SessionMiddleware`, no `FixedRateLimiter`, no
# Workers cleanup scheduler) is exactly that process: `bench/socket/wake.sh` measured a parked
# handler waking 1.48 s late on 1.13.2, against 3-8 ms on 1.12.7. Any second live `Timer`
# removes the stall, even one that never fires, so `serve` holds one for as long as it serves:
# one libuv handle, no callback, no wake-up, nothing on the request path.
#
# The upper bound drops to the first fixed 1.13.x when upstream ships one. Once Nitro's Julia
# floor passes the last affected release, delete this, its call sites (`_hold_wake_guard!`, and
# `_consumer_wake_guard` in Workers, #514) and both `wake_guard` fields.
_needs_wake_guard(v::VersionNumber = VERSION) = v"1.13.0-rc3" <= v < v"1.14.0-"

# Tests only: it drives the serve path wherever the gate is shut (a fixed 1.13.x, a later Julia).
const _WAKE_GUARD_FORCED = Ref(false)

# Called by `startserver` once the listener is set. Reuses a guard that is still open rather
# than overwriting the only handle to it.
#
# Both halves run under `wake_guard_lock`. `close` checks "nothing serves" and then closes, and
# closing a `Timer` waits on the uv close callback. A `serve()` used to be admitted in that gap
# (the previous run's drain), and without the lock it would set its listener, find the doomed
# guard still open, keep it, and serve unguarded. The phase guard refuses that `serve` now
# (#812); the reuse and the lock stay, because neither costs anything on the request path.
function _hold_wake_guard!(service::Service;
                           needed::Bool = _WAKE_GUARD_FORCED[] || _needs_wake_guard())
    needed || return nothing
    lock(service.wake_guard_lock) do
        guard = service.wake_guard[]
        (isnothing(guard) || !isopen(guard)) && (service.wake_guard[] = Timer(typemax(Int32)))
    end
    return nothing
end

# Called by `close(::Service)`. Only once nothing serves, the same second line of defence as
# `close`'s compare-and-clear: a server that holds the handle keeps the guard it found.
function _release_wake_guard!(service::Service)
    lock(service.wake_guard_lock) do
        guard = service.wake_guard[]
        if !isnothing(guard) && isnothing(service.server[])
            close(guard)
            service.wake_guard[] = nothing
        end
    end
    return nothing
end

function set_extension!(ctx::App, key::Symbol, value)
    lock(ctx.service.extensions_lock) do
        ctx.service.extensions[key] = value
    end
    return value
end

function get_extension(ctx::App, key::Symbol, default=nothing)
    lock(ctx.service.extensions_lock) do
        return Base.get(ctx.service.extensions, key, default)
    end
end

function delete_extension!(ctx::App, key::Symbol)
    lock(ctx.service.extensions_lock) do
        if haskey(ctx.service.extensions, key)
            delete!(ctx.service.extensions, key)
        end
    end
    return nothing
end

function has_extension(ctx::App, key::Symbol)
    lock(ctx.service.extensions_lock) do
        return haskey(ctx.service.extensions, key)
    end
end


end
