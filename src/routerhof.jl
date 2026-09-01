module RouterHOF

using HTTP

using ..Util: join_url_path
using ..AppContext: ServerContext
using ..Types: Nullable, LifecycleMiddleware, CopyOnWriteDict, snapshot, cache!, publish!

export router, compose, genkey, process_middleware, HOFRouter, OuterRouter, InnerRouter

# Shared read-only stand-in for "this route has no middleware of that kind". `foldlayers` only
# ever appends *from* it, never to it, so one instance is safe to share.
#
# The win is allocation, not inference: a fresh `[]` per sanitized slot cost a `Vector{Any}` on
# every `buildmiddleware` call. (It does NOT make the destructure type-stable — the values come
# out of a `Dict{String,Tuple}` whose `Tuple` is abstract, so both slots infer as `Any` either
# way. That is #76's territory.) Measured: 224 -> 192 bytes with route middleware present,
# 192 -> 128 without.
const EMPTY_LAYERS = Function[]

# "This slot carries at least one middleware." Both registrars gate on this rather than on
# `!isnothing`, so that an explicit `middleware=[]` — which normalizes to `Function[]`, not
# `nothing` — does not publish a zero-layer entry and disable the fast path app-wide.
_has_layers(mw) = !isnothing(mw) && !isempty(mw)

"""
    normalize_middleware(middleware::Vector) -> Vector{Function}

Flatten a middleware list to plain middleware functions, unwrapping each
`LifecycleMiddleware` to its `.middleware`. **Pure — registers nothing.** This is what the
per-request path (`setupmiddleware`, src/core.jl) uses.
"""
function normalize_middleware(middleware::Vector) :: Vector{Function}
    processed = Function[]
    for mw in middleware
        push!(processed, mw isa LifecycleMiddleware ? mw.middleware : mw)
    end
    return processed
end

"""
    register_route_lifecycle!(ctx::ServerContext, middleware::Vector) -> ServerContext

Register every `LifecycleMiddleware` in `middleware` as **route-owned** — declared by the
context at `urlpatterns()`/`router()` time. These survive `terminate()` and are started again
by every subsequent `serve()`, because nothing re-registers routes on a restart (#82).

Call this ONLY from route-registration paths: `router()`, `OuterRouter`, and `register_route`
(via [`process_middleware`](@ref)). For the `serve(middleware = ...)` list use
[`register_serve_lifecycle!`](@ref); **`internalrequest` deliberately registers neither** (#68).

`internalrequest` never reaches `startup.` — that lives in `startserver` — so a lifecycle
middleware registered from there got an `on_shutdown` at the next `terminate` whose paired
`on_startup` had never run; and because `internalrequest` calls `setupmiddleware` per call,
that `push!` landed on an unsynchronized `Set` that `startup.`/`shutdown.` broadcast over.
Not fixing that with a lock is the point: the writer had no business existing.

Note also that "route registration" is not a synonym for "single-threaded startup": under
`revise=:lazy` a re-registration can run on a request-handling task, so the `Set` this writes
to is not *proven* free of concurrent writers. Closing that, along with the `Set`'s
unspecified iteration order, is tracked separately (#74); what #68 removed was the per-request
writer.

Dedup is load-bearing and comes from `Set`: one shared `RateLimiter()` passed to N routes is
one registration, so its cleanup task starts once, not N times. `LifecycleMiddleware` is an
immutable struct, so `Set` dedups it structurally.
"""
function register_route_lifecycle!(ctx::ServerContext, middleware::Vector)
    for mw in middleware
        mw isa LifecycleMiddleware && push!(ctx.service.route_lifecycle, mw)
    end
    return ctx
end

"""
    register_serve_lifecycle!(ctx::ServerContext, middleware::Vector) -> ServerContext

Register every `LifecycleMiddleware` in `middleware` as **serve-owned** — declared by this
server run, from the `serve(middleware = ...)` list. `terminate()` clears these, so
`serve(middleware=[A]); terminate(); serve(middleware=[B])` does not also start `A` (#82).

Call this ONLY from `serve` (src/core.jl), once per server.

**Route ownership wins.** A middleware object that is already route-owned is skipped here
rather than recorded twice, so it starts once per cycle instead of twice. That is also the
conservative direction: the entry then survives `terminate()`, which is the property #82
exists to restore. The asymmetry is deliberate — a shared object passed both to a route and to
`serve(middleware = ...)` is still, in the app's own terms, that route's middleware.
"""
function register_serve_lifecycle!(ctx::ServerContext, middleware::Vector)
    for mw in middleware
        mw isa LifecycleMiddleware || continue
        mw in ctx.service.route_lifecycle && continue
        push!(ctx.service.serve_lifecycle, mw)
    end
    return ctx
end

"""
    process_middleware(ctx::ServerContext, middleware) -> Vector{Function}

Registration-path helper: [`register_route_lifecycle!`](@ref) then
[`normalize_middleware`](@ref). Semantics unchanged by #68 — the per-request path stopped
calling *this*; it did not change what this does. Route-owned is the right half for every
caller of this function: all of them are route-registration paths (#82).
"""
function process_middleware(ctx::ServerContext, middleware::Vector) :: Vector{Function}
    register_route_lifecycle!(ctx, middleware)
    return normalize_middleware(middleware)
end

# Do nothing if we have no middleware to append.
#
# Returns `nothing`, NOT `Function[]`, and that is load-bearing twice over. Primarily: callers
# store the result into the `Nullable{Vector}` fields of `OuterRouter`/`InnerRouter`, and the
# guard in `(inner::InnerRouter)(http_method)` below reads those fields via `isnothing`. Return
# `[]` here and that guard becomes always-true, so every HOF route publishes a
# `(Function[], Function[])` entry into `custommiddleware`. Secondarily, and sharper since #71:
# those entries contribute zero layers but make the table permanently non-empty, which defeats
# `compose`'s per-request fast path for the whole app — every request would then pay a second
# `gethandler` for nothing.
function process_middleware(::ServerContext, ::Nothing) end


"""
This function is used to generate dictionary keys which lookup middleware for routes
"""
function genkey(http_method::String, path::String)::String
    return "$http_method|$path"
end

"""
    publish_route_middleware!(ctx::ServerContext, key::String, value::Tuple) -> Tuple

Register `value` — a `(router middleware, route middleware)` pair — as the middleware for route
`key`, and invalidate any chain already cached for it.

**Use this instead of writing `ctx.service.custommiddleware` directly.** Publishing alone is not
enough: `middleware_cache` is first-writer-wins, so a chain composed before the registration
would keep winning and the new middleware would never run — the same symptom as #71, reached
through the cache instead of the install gate. Pairing the two here means a future write site
cannot do one without the other.

Scope: this covers *adding* or *changing* a route's middleware. It does not cover **removal** —
re-running `urlpatterns` with no `middleware=` kwarg skips the registration branch entirely, so
a previously-published entry and its cached chain both survive. Pre-existing, and unchanged by
#71.

**The order is load-bearing.** Publish first, invalidate second. Inverted, a concurrent request
could miss the freshly-emptied cache, rebuild from the *old* table, and `cache!` that stale
chain — which first-writer-wins would then make permanent, on every interleaving where the
request's cache read lands between the two calls.

This order *narrows* that window; it does not close it. A request whose `buildmiddleware`
snapshot straddles the whole publish-and-invalidate can still cache a stale chain:

    req: cache read                        -> miss
    req: snapshot(custommiddleware)        -> OLD table
    reg: publish!(custommiddleware, ...)
    reg: delete!(middleware_cache, key)    -> key absent, no-op
    req: cache!(middleware_cache, key, ..) -> stale chain, first-writer-wins, permanent

Reachable only when `use_cache` is true (no global middleware at all) *and* registration races
a live request — under `revise=:lazy|:eager` `serve` injects `ReviseHandler`, so `use_cache` is
false and it cannot happen there. Closing it properly needs a generation counter, or publishing
while holding the cache lock; tracked separately.
"""
function publish_route_middleware!(ctx::ServerContext, key::String, value::Tuple)
    publish!(ctx.service.custommiddleware, key, value)
    delete!(ctx.service.middleware_cache, key)
    return value
end

"""
    foldlayers(handler::Function, layers::Vector...) -> Function

Fold `handler` and zero or more middleware vectors into a single request function.

Handler first, each vector appended in argument order, then one `reduce(|>, …)` — so the LAST
element appended ends up OUTERMOST (`reduce(|>, Function[h, a, b])` is `b(a(h))`), and a call
with no layers returns `handler` itself, because `reduce` over a one-element collection never
applies the operator.

Both fold sites go through here on purpose. [`buildmiddleware`](@ref) folds
`route, router, global`; `compose`'s empty-table fast path folds `global` alone. Whenever no
per-route middleware applies, those two must produce the same chain — appending an empty
vector contributes nothing — and sharing the fold makes that a fact about the code rather than
a coincidence between two copies of it that can drift.
"""
function foldlayers(handler::Function, layers::Vector...) :: Function
    chain::Vector{Function} = [handler]
    for layer in layers
        append!(chain, layer)
    end
    return reduce(|>, chain)
end

"""
This function is used to build up the middleware chain for all our endpoints
"""
function buildmiddleware(key::String, handler::Function, globalmiddleware::Vector,
                         custommiddleware::CopyOnWriteDict{Tuple}) :: Function

    # lookup the middleware for this path.
    #
    # `snapshot` is taken HERE — not by `compose`, not by the caller. This function runs on
    # EVERY request whenever `use_cache` is false: `serve(middleware=[...])`,
    # `internalrequest(...; middleware=[...])`, and every `revise=:lazy|:eager` session
    # (serve injects `ReviseHandler`). A snapshot hoisted to compose time would freeze the
    # route table for the life of the server, so routes registered later — Revise re-running
    # `urlpatterns` — would silently lose their middleware, with no error.
    #
    # Taking the wrapper rather than a pre-snapshotted `Dict` is the point: it leaves no
    # `snapshot(...)` expression at any call site for a future refactor to lift out of the
    # request path. See `CopyOnWriteDict` (src/types.jl) for why this read needs no lock.
    routermiddleware, routemiddleware = get(snapshot(custommiddleware), key, (nothing, nothing))

    # sanitize outputs (either value can be nothing)
    routermiddleware = isnothing(routermiddleware) ? EMPTY_LAYERS : routermiddleware
    routemiddleware = isnothing(routemiddleware) ? EMPTY_LAYERS : routemiddleware

    # Route middleware innermost, then router middleware, then global — the last appended is
    # the outermost after the fold. See `foldlayers`, which `compose`'s empty-table fast path
    # also uses, so the two agree by construction.
    return foldlayers(handler, routemiddleware, routermiddleware, globalmiddleware)
end

"""
This function dynamically determines which middleware functions to apply to a request at runtime. 
If router or route specific middleware is defined, then it's used instead of the globally defined
middleware. 
"""
function compose(router::HTTP.Router, globalmiddleware::Vector,
                 custommiddleware::CopyOnWriteDict{Tuple},
                 middleware_cache::CopyOnWriteDict{Function})
    use_cache = isempty(globalmiddleware)
    return function (handler)
        # The chain for "no per-route middleware applies": global middleware only. Built once
        # here because it never varies. `handler` alone would be WRONG — it is the fold
        # accumulator (the serializer wrapping the router), and global middleware arrives
        # sideways as `globalmiddleware`, applied only inside `buildmiddleware`. Returning
        # `handler` directly is exactly how the unmatched path used to skip every global
        # middleware in the app. With no global middleware `foldlayers` returns `handler`
        # itself, so this costs nothing in that case.
        nocustom = foldlayers(handler, globalmiddleware)

        # NOTE: `middleware_cache` is captured as an *object*; `snapshot` is called per
        # request below. Hoisting the `snapshot` call out to here would freeze the table at
        # compose time and silently disable caching — every request would rebuild its chain.
        # `custommiddleware` is captured the same way and for the same reason; it is
        # snapshotted per call below and again inside `buildmiddleware` — see its own NOTE.
        return function (req::HTTP.Request)

            # #71: `compose` is now installed unconditionally, and THIS is the emptiness test
            # that used to live in `setupmiddleware` — evaluated once there, per request here.
            # It must stay inside this closure: hoisted out, the verdict freezes at compose
            # time and an app whose first per-route middleware is registered later never sees
            # it, which is #71 verbatim. The "composed against an EMPTY table" testitem in
            # test/custommiddleware_tests.jl is what catches that — verified by mutation: the
            # non-empty-table guard in the same file stays green under the hoist.
            #
            # It is also load-bearing for correctness, not just cost: without it, requests
            # arriving while the table is empty would build a bare chain and `cache!` it, and
            # `cache!` is first-writer-wins — so middleware registered afterwards would lose
            # to that cached bare chain and #71 would reappear one level down.
            #
            # On the non-empty path this snapshot is one extra 0-allocation acquire-load: two
            # per request when `use_cache` is false, three on a `use_cache == true` cache miss
            # (here, the cache read, then `buildmiddleware`). They can disagree only in the
            # harmless direction — nothing in `src/` ever removes a key from `custommiddleware`,
            # so a later read can never see an emptier table than this one did.
            isempty(snapshot(custommiddleware)) && return nocustom(req)

            innerhandler, path, _ = HTTP.Handlers.gethandler(router, req)

            # `missing` is HTTP.jl's method-mismatch sentinel — a path that matched but not for
            # this method (405). It is NOT a match: it carries an empty `path`, so treating it
            # as one keyed the cache on `"METHOD|"` and could pick up the middleware of a route
            # registered at the empty path. `nothing` is a true miss (404). Both take the
            # unmatched path below.
            if !isnothing(innerhandler) && !ismissing(innerhandler)

                # Check if we already have a cached middleware function for this specific route.
                # Skip cache when per-call global middleware is present: caching would bake in
                # caller-specific settings (e.g. catch_errors=false) and corrupt future requests.
                key = genkey(req.method, path)
                if use_cache
                    # One acquire-load, then a lookup on a table no writer will ever mutate.
                    # See `CopyOnWriteDict` (src/types.jl) for why this read needs no lock.
                    func = get(snapshot(middleware_cache), key, nothing)
                    if !isnothing(func)
                        return func(req)
                    end
                end

                # Combine all the middleware functions together
                strategy = buildmiddleware(key, handler, globalmiddleware, custommiddleware)

                # Warmup only. Reaching here with `use_cache` means the key was absent from
                # this request's snapshot, so `cache!` (first-writer-wins, under the lock) *is*
                # the second half of the double check. The old unlocked `haskey` pre-check was
                # a deliberate lock-avoidance optimization — it skipped the lock when another
                # thread published between the read and here — traded away on purpose: it was
                # a racy read, and the lock it avoided is warmup-bounded with a short critical
                # section.
                use_cache && cache!(middleware_cache, key, strategy)

                return strategy(req)
            end

            # Unmatched (404) or method-mismatched (405). `nocustom`, NOT `handler`: the router
            # still produces the 404/405 status downstream, but global middleware must run — a
            # global `Cors()` has to emit its headers and a global `RateLimiter()` has to count
            # the request, or unmatched paths become a rate-limit bypass. Returning `handler`
            # here is what used to exempt them, and only for apps that had per-route middleware
            # somewhere — an app without it ran global middleware on 404s all along. This
            # restores parity between the two.
            return nocustom(req)
        end
    end
end


"""
This functions assists registering routes with a specific prefix.
You can optionally assign tags either at the prefix and/or route level which
are used to group and organize the autogenerated documentation
"""
function router(ctx::ServerContext, prefix::String="";
    tags::Vector{String}=Vector{String}(),
    middleware::Nullable{Vector}=nothing)

    # ensure we collect & process any lifecycle-middleware functions
    router_middleware = process_middleware(ctx, middleware)

    return OuterRouter(ctx, prefix, tags, router_middleware)
end


"""
Abstract supertype for higher-order function (HOF) routers in Nitro.

This type serves as the base for `OuterRouter` and `InnerRouter`, enabling composable routing patterns
with features like prefixes, middleware, tags, intervals, and cron jobs. HOF routers allow building
nested route configurations by chaining callable instances.
"""
abstract type HOFRouter end

"""
This struct represents the data passed to the top level "router()" call.
These properties can be shared bewteen any other endpoints that reuse the router

ex.) 

@get router("/repeat/one", interval = 1, tags=["repeat"]) function(req)
    return "one"
end

The router() function itself can be passed to routes and returns the OuterRouter struct
"""
struct OuterRouter <: HOFRouter
    ctx::ServerContext
    prefix::String
    tags::Vector{String}
    middleware::Nullable{Vector}
end

function (outer::OuterRouter)(
    path=nothing;
    tags::Vector{String}=Vector{String}(),
    middleware::Nullable{Vector}=nothing)

    # ensure we collect & process any lifecycle-middleware functions
    processed_middleware = process_middleware(outer.ctx, middleware)

    return InnerRouter(outer.ctx, outer, path, tags, processed_middleware)
end


"""
The InnerRouter struct represents the returned function from the outer router, that
lets you override properties on a route by route basis.

ex.)

repeat = router("/repeat", interval = 1, tags=["repeat"])

@get repeat("/one") function(req)
    return "one"
end

The "repeat()" function returns the InnerRouter function

"""
struct InnerRouter <: HOFRouter
    ctx::ServerContext
    outer::OuterRouter
    path::Union{Nothing, String}
    tags::Vector{String}
    middleware::Nullable{Vector}
end

function (inner::InnerRouter)(http_method::String)

    # Pull out the "router" level information 
    outer = inner.outer

    final_path = !isnothing(inner.path) ? join_url_path(outer.prefix, inner.path) : join_url_path(outer.prefix, "")

    # Non-EMPTY, not merely non-`nothing` — the same guard `register_route` (src/routing.jl)
    # applies. An explicit `middleware=[]` reaches `process_middleware`'s `::Vector` method and
    # comes back `Function[]`, which is not `nothing`; publishing that contributes zero layers
    # but makes `custommiddleware` permanently non-empty, killing `compose`'s per-request
    # emptiness fast path for the whole application.
    if _has_layers(outer.middleware) || _has_layers(inner.middleware)
        publish_route_middleware!(inner.ctx,
                                  genkey(http_method, final_path),
                                  (outer.middleware, inner.middleware))
    end



    return final_path
end



end