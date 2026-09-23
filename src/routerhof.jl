module RouterHOF

using HTTP

using ..Util: join_url_path
using ..AppContext: App
using ..Constants: HTTP_METHODS
using ..Types: Nullable, LifecycleMiddleware, CopyOnWriteDict, snapshot,
                publish!, RouteResolution, ROUTE_RESOLUTION_KEY,
                RouteMiddleware, NO_ROUTE_MIDDLEWARE, DeclaredMethodHandler,
                ChainCache, cached_chain, cache_chain!

export router, compose, genkey, process_middleware, HOFRouter, OuterRouter, InnerRouter

# Shared read-only stand-in for "this route has no middleware of that kind". `foldlayers` only
# ever appends *from* it, never to it, so one instance is safe to share.
#
# The win is allocation, not inference: a fresh `[]` per sanitized slot cost a `Vector{Any}` on
# every `buildmiddleware` call. Measured: 224 -> 192 bytes with route middleware present,
# 192 -> 128 without. (Inference was the *other* half of the same line, and it was fixed
# separately in #76 by narrowing the table's value type — see `RouteMiddleware`, src/types.jl.
# Until then both slots came out of a `Dict{String,Tuple}` and inferred as `Any` whatever this
# constant did.)
const EMPTY_LAYERS = Function[]

# "This slot carries at least one middleware." Both registrars gate on this rather than on
# `!isnothing`, so that an explicit `middleware=[]` — which normalizes to `Function[]`, not
# `nothing` — does not publish a zero-layer entry and disable the fast path app-wide.
_has_layers(mw) = !isnothing(mw) && !isempty(mw)

"""
    normalize_middleware(middleware::Vector) -> Vector{Function}

Flatten a middleware list to plain middleware functions, unwrapping each
`LifecycleMiddleware` to its `.middleware`. **Pure — registers nothing.** This is what the
per-request path (`setupmiddleware`, src/core/pipeline.jl) uses.
"""
function normalize_middleware(middleware::Vector) :: Vector{Function}
    processed = Function[]
    for mw in middleware
        push!(processed, mw isa LifecycleMiddleware ? mw.middleware : mw)
    end
    return processed
end

"""
    register_route_lifecycle!(ctx::App, middleware::Vector) -> App

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

Registration order is preserved and `terminate` unwinds it LIFO (#74), so this appends under
`lifecycle_lock` rather than pushing into an unsynchronized `Set`. The lock is not ceremony:
"route registration" was never a synonym for "single-threaded startup" — under `revise=:lazy`,
`Revise.revise()` runs on a request-handling task and re-running user top-level code re-enters
`urlpatterns` → `register_route` → here, so two revisions, or one revision concurrent with a
`startup.`/`shutdown.` broadcast, race this container. Those broadcasts read a
[`lifecycle_snapshot`](@ref) rather than the live vector for the same reason.

**This function also PROMOTES.** Claiming an object that is currently serve-owned removes it
from `serve_lifecycle` in the same critical section, so it is never in both halves — see
[`register_serve_lifecycle!`](@ref) for which side wins and why.

!!! note "Promotion is not order-preserving"
    A promoted object is appended to the end of `route_lifecycle`, so in the cycle where the
    promotion happens it was started in the *serve* phase but is torn down in the *route*
    phase — that is, **after every serve-owned entry**, including ones that started before it
    and that LIFO would therefore have torn down after it. The entries that followed it at
    startup are unaffected; the ones it followed are the ones now gone too early. Teardown is the exact
    reverse of startup **in any cycle where no promotion occurred**, which is every cycle after
    the first: `terminate` empties `serve_lifecycle`, so the next `serve()` starts from a
    settled split. This is inherent to route ownership winning — an object cannot both move to
    the route phase and keep its old serve-phase position — and it is why the ordering contract
    is stated per cycle.

Dedup is load-bearing, and moving off `Set` is what makes it explicit rather than structural:
one shared `RateLimiter()` passed to N routes is one registration, so its cleanup task starts
once, not N times. `∉` on a single-digit vector costs nothing.
"""
function register_route_lifecycle!(ctx::App, middleware::Vector)
    lock(ctx.service.lifecycle_lock) do
        for mw in middleware
            mw isa LifecycleMiddleware || continue
            mw ∈ ctx.service.route_lifecycle && continue
            # PROMOTE, don't just append. "Route ownership wins" has to hold in both
            # directions or the object ends up in both halves and `terminate` calls its
            # `on_shutdown` TWICE in one cycle — once per half. Reachable whenever route
            # registration follows `serve`, which is the runtime-`include_routes` /
            # `revise=:lazy` case this whole cluster exists for:
            #
            #   serve(ctx; middleware = [rl])                       -> serve-owned
            #   urlpatterns(ctx, "", [path("/x", h, middleware=[rl])])  -> also route-owned
            #   terminate(ctx)                                      -> shutdown twice
            #
            # `RateLimiter`'s hooks happen to tolerate it, but `LifecycleMiddleware` is public
            # and an app hook that closes a connection or decrements a refcount does not.
            i = findfirst(==(mw), ctx.service.serve_lifecycle)
            isnothing(i) || deleteat!(ctx.service.serve_lifecycle, i)
            push!(ctx.service.route_lifecycle, mw)
        end
    end
    return ctx
end

"""
    register_serve_lifecycle!(ctx::App, middleware::Vector) -> App

Register every `LifecycleMiddleware` in `middleware` as **serve-owned** — declared by this
server run, from the `serve(middleware = ...)` list. `terminate()` clears these, so
`serve(middleware=[A]); terminate(); serve(middleware=[B])` does not also start `A` (#82).

Call this ONLY from `serve` (src/core/lifecycle.jl), once per server.

**Route ownership wins, in both directions.** A middleware object already route-owned is
skipped here; and [`register_route_lifecycle!`](@ref) *promotes* — it removes the object from
this half when claiming it. Either way it appears in exactly one half, so it starts and stops
once per cycle. Enforcing only the direction this function can see would leave an object
registered serve-first-then-route in both halves, and `terminate` would call its `on_shutdown`
twice in one cycle.

Route is the winning side because the entry then survives `terminate()`, which is the property
#82 exists to restore — a shared object passed both to a route and to `serve(middleware = ...)`
is still, in the app's own terms, that route's middleware.
"""
function register_serve_lifecycle!(ctx::App, middleware::Vector)
    lock(ctx.service.lifecycle_lock) do
        for mw in middleware
            mw isa LifecycleMiddleware || continue
            mw ∈ ctx.service.route_lifecycle && continue      # route ownership wins
            mw ∉ ctx.service.serve_lifecycle && push!(ctx.service.serve_lifecycle, mw)
        end
    end
    return ctx
end

"""
    lifecycle_snapshot(ctx::App) -> (route, serve)

Copies of both lifecycle vectors, taken together under `lifecycle_lock` (#74).

`startup.`/`shutdown.` (src/core/lifecycle.jl) broadcast over the result rather than over the live
vectors, so an iteration can never overlap a `push!` from a concurrent registration — the
`revise=:lazy` path that re-enters `urlpatterns` on a request-handling task. Copying rather than
holding the lock across the hooks is deliberate: a user `on_startup` can block for as long as it
likes, and it must not be able to deadlock route registration by doing so.
"""
function lifecycle_snapshot(ctx::App)
    return lock(ctx.service.lifecycle_lock) do
        (copy(ctx.service.route_lifecycle), copy(ctx.service.serve_lifecycle))
    end
end

"""
    process_middleware(ctx::App, middleware) -> Vector{Function}

Registration-path helper: [`register_route_lifecycle!`](@ref) then
[`normalize_middleware`](@ref). Semantics unchanged by #68 — the per-request path stopped
calling *this*; it did not change what this does. Route-owned is the right half for every
caller of this function: all of them are route-registration paths (#82).
"""
function process_middleware(ctx::App, middleware::Vector) :: Vector{Function}
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
# `compose`'s per-request fast path for the whole app — every request would then pay a
# `gethandler` and a chain-cache lookup for nothing, plus the chain fold on the first request
# for each route. (Before #80 it also paid a SECOND `gethandler`; the fast path
# is still worth defending without it.)
function process_middleware(::App, ::Nothing) end


"""
    _clear_resolution!(req) -> Nothing

Retract any [`RouteResolution`](@ref) an earlier pass left on `req` (#80).

`compose` writes the stash on the matched path; every *other* path that got as far as calling
`gethandler` calls this instead, so the rule is "ran the lookup ⟹ wrote or cleared", with no
third outcome. That is what makes a stale hand-off structurally impossible rather than
impossible-by-argument — and the argument is why this exists: the first version reasoned that a
pass which writes no stash is unreachable after a match, because `HTTP.register!` replaces a leaf
rather than removing one. **That is not true in general.** Upstream `insert!` matches an existing
leaf with `eq = (x, y) -> x == "*" || x == y`, so registering a method-specific route *replaces*
a wildcard-method one — removing it for every other method. `path(…; method = "*")` reaches that,
so a `(method, target)` that matched once really can stop matching:

    path("/w", h,  method = "*")    → POST /w matches, stash written
    path("/w", h2, method = "GET")  → replaces the "*" leaf; POST /w is now a 405
    same request object, 2nd pass   → 405 path wrote nothing, stale stash honoured, 200

Writing `nothing` rather than deleting: `HTTP.RequestContext` has no `delete!` in the
`haskey`/`getindex`/`setindex!`/`get` surface the rest of `src/` uses, and the terminal's
`res isa RouteResolution` test rejects `nothing` anyway. The `haskey` guard keeps the common
case — a 404 on a request that never carried a stash — to one probe that cannot allocate the
metadata `Dict`, since `Base.haskey(::RequestContext, ::Symbol)` returns early when `metadata`
is `nothing`.

`compose`'s emptiness fast path deliberately does NOT call this: it returns before `gethandler`,
and it can only be taken by a request whose every earlier pass also took it, because
`custommiddleware` never shrinks — nothing in `src/` removes a key from it, and
`CopyOnWriteDict` has no `delete!` or `empty!` to do it with. That one invariant is load-bearing
and holds; the route-table one did not, which is why this function exists.
"""
function _clear_resolution!(req::HTTP.Request)
    haskey(req.context, ROUTE_RESOLUTION_KEY) && (req.context[ROUTE_RESOLUTION_KEY] = nothing)
    return nothing
end

"""
This function is used to generate dictionary keys which lookup middleware for routes
"""
function genkey(http_method::String, path::String)::String
    return "$http_method|$path"
end

"""
    publish_route_middleware!(ctx::App, key::String, value::RouteMiddleware) -> RouteMiddleware

Register `value` — a `(router middleware, route middleware)` pair — as the middleware for route
`key`.

`value` is typed as [`RouteMiddleware`](@ref) rather than `Tuple` (#76), so a pair of the wrong
arity is rejected *here*, at the one sanctioned write site, instead of surfacing as a
`MethodError` inside `buildmiddleware`'s destructure on some later request.

**Use this instead of writing `ctx.service.custommiddleware` directly**, so that check stays in
one place.

There is no separate invalidation step, and that is deliberate (#255). `publish!` allocates a new
table, and every pipeline's [`ChainCache`](@ref) serves a chain only to a request whose
`custommiddleware` snapshot is the exact table that chain was built from. So a chain composed
before this call — including one a racing request is still composing — can never be served
after it. This used to be publish-then-`delete!` against an `App`-wide cache (#71), and the
`delete!` alone could not close the window where a request built its chain from the old table
and published it after the `delete!` ran (#81); a read-time check has no such window.

Scope: this covers *adding* or *changing* a route's middleware. It does not cover **removal** —
re-running `urlpatterns` with no `middleware=` kwarg skips the registration branch entirely, so
a previously-published entry survives, and so do chains built from it. Pre-existing, and
unchanged by #71 or #255.
"""
function publish_route_middleware!(ctx::App, key::String, value::RouteMiddleware)
    publish!(ctx.service.custommiddleware, key, value)
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
    buildmiddleware(key, handler, globalmiddleware, custom) -> Function

Compose the chain for route `key` from `custom` — the `custommiddleware` snapshot the calling
request already took. Runs on a [`ChainCache`](@ref) miss only: once per route per registration
generation, per pipeline.
"""
function buildmiddleware(key::String, handler::Function, globalmiddleware::Vector{Function},
                         custom::Dict{String, RouteMiddleware}) :: Function

    # lookup the middleware for this path.
    #
    # `custom` is the CALLER's per-request snapshot, and it must be that one rather than a fresh
    # snapshot taken here (#255): `compose` stamps the resulting chain with the snapshot it
    # passed in, and `cached_chain` serves it only to requests holding that same table. Building
    # from a later snapshot than the stamp would cache a chain under a generation it was not
    # built from. The hazard the old NOTE here guarded — a snapshot hoisted to compose time,
    # freezing the route table for the server's life — now lives in `compose`'s per-request
    # closure, where its own NOTE covers it.
    #
    # Both slots infer as `Union{Nothing, Vector{Function}}` since #76; before it, the table's
    # `Tuple` value type was abstract and this line inferred `Tuple{Any, Any}`.
    # `NO_ROUTE_MIDDLEWARE` is the miss-path default; a `(nothing, nothing)` literal infers the
    # same today, and that constant's docstring says why it is still the one to use.
    routermiddleware, routemiddleware = get(custom, key, NO_ROUTE_MIDDLEWARE)

    # sanitize outputs (either value can be nothing)
    routermiddleware = isnothing(routermiddleware) ? EMPTY_LAYERS : routermiddleware
    routemiddleware = isnothing(routemiddleware) ? EMPTY_LAYERS : routemiddleware

    # Route middleware innermost, then router middleware, then global — the last appended is
    # the outermost after the fold. See `foldlayers`, which `compose`'s empty-table fast path
    # also uses, so the two agree by construction.
    return foldlayers(handler, routemiddleware, routermiddleware, globalmiddleware)
end

"""
    compose(router, globalmiddleware, custommiddleware) -> (handler -> request function)

The pipeline layer that applies per-route and per-router middleware, chosen per request from
the route the request resolves to. Global middleware is applied here too — outside the per-route
layers — so every request, matched or not, runs it exactly once.

Each pipeline gets its own [`ChainCache`](@ref) (#255), so a route's chain is composed once per
registration generation rather than per request, with or without global middleware.
"""
function compose(router::HTTP.Router, globalmiddleware::Vector{Function},
                 custommiddleware::CopyOnWriteDict{RouteMiddleware})
    return function (handler)
        # The chain for "no per-route middleware applies": global middleware only. Built once
        # here because it never varies. `handler` alone would be WRONG — it is the fold
        # accumulator (the serializer wrapping the router), and global middleware arrives
        # sideways as `globalmiddleware`, applied only inside `buildmiddleware`. Returning
        # `handler` directly is exactly how the unmatched path used to skip every global
        # middleware in the app. With no global middleware `foldlayers` returns `handler`
        # itself, so this costs nothing in that case.
        nocustom = foldlayers(handler, globalmiddleware)

        # This pipeline's chains — created HERE, once per `handler`, never shared (#255). Every
        # chain closes over `handler` and `globalmiddleware`, so a cache that outlives or spans
        # pipelines would need both in its key; `globalmiddleware` has no stable identity to key
        # on, which is why the old `App`-wide cache could not cache at all when any was present.
        # Owned by the pipeline, the key only has to name the route and the registration
        # generation. See `ChainCache` (src/types.jl).
        chains = ChainCache()

        # NOTE: `custommiddleware` is captured as an *object*; `snapshot` is called per request
        # below. Hoisting it to here would freeze the route table at compose time: routes
        # registered later — Revise re-running `urlpatterns`, a runtime `include_routes` —
        # would silently run without their middleware, and the emptiness verdict would freeze
        # with it (#71). The "sees routes registered after it was composed" and "composed
        # against an EMPTY table" items in test/custommiddleware_tests.jl catch each half.
        return function (req::HTTP.Request)

            # #71: `compose` is now installed unconditionally, and THIS is the emptiness test
            # that used to live in `setupmiddleware` — evaluated once there, per request here.
            # It must stay inside this closure: hoisted out, the verdict freezes at compose
            # time and an app whose first per-route middleware is registered later never sees
            # it, which is #71 verbatim. The "composed against an EMPTY table" testitem in
            # test/custommiddleware_tests.jl is what catches that — verified by mutation: the
            # non-empty-table guard in the same file stays green under the hoist.
            #
            # One 0-allocation acquire-load, and the only `custommiddleware` read this request
            # makes: the same snapshot is the generation stamp `cached_chain` checks and, on a
            # miss, the table `buildmiddleware` composes from — so the chain and its stamp can
            # never disagree.
            custom_snap = snapshot(custommiddleware)
            isempty(custom_snap) && return nocustom(req)

            # `params` is BOUND now, not discarded (#80). `gethandler` allocates it either
            # way — a fresh `Params()` per call, populated for a parametrized route — and the
            # router at the bottom of the chain used to allocate a second one because this
            # one was thrown away. Handing it down is what makes the second lookup
            # unnecessary; see `RouteResolution` (src/types.jl) for the full argument.
            innerhandler, path, params = HTTP.Handlers.gethandler(router, req)

            # `missing` is HTTP.jl's method-mismatch sentinel — a path that matched but not for
            # this method (405). It is NOT a match: it carries an empty `path`, so treating it
            # as one keyed the cache on `"METHOD|"` and could pick up the middleware of a route
            # registered at the empty path. `nothing` is a true miss (404). Both take the
            # unmatched path below.
            if !isnothing(innerhandler) && !ismissing(innerhandler)

                # Hand this lookup to the pipeline's terminal instead of letting it redo the
                # work (#80). `_dispatch_resolved` (src/core/pipeline.jl) consumes it, and
                # honours it only if `(router, method, target)` all still match — every input
                # `gethandler` just read. `router` is in there because this stash rides on the
                # REQUEST while the invariant that makes it safe belongs to the App; see
                # `RouteResolution` (src/types.jl). Written HERE — before the chain runs —
                # because the chain is what eventually reaches the terminal.
                #
                # Stashed unconditionally on this branch, cache hit or miss, since the chain
                # is cached but the resolution is per request. `isa Function` keeps
                # `RouteResolution.handler` concrete: HTTP.jl types `leaf.handler` as `Any`,
                # and everything Nitro registers is a closure, but a callable struct arriving
                # some other way simply declines the hand-off and takes the old double-lookup
                # rather than widening the field — so that case CLEARS instead of stashing.
                if innerhandler isa Function
                    req.context[ROUTE_RESOLUTION_KEY] =
                        RouteResolution(router, req.method, req.target, innerhandler, path, params)
                else
                    _clear_resolution!(req)
                end

                # Both keys use the method the route was DECLARED with, which is the one its
                # middleware was published under. For most leaves that is `req.method`. A
                # `DeclaredMethodHandler` leaf is reached by other methods and carries its own:
                # `GET` for an auto-`HEAD` (#277), and `*`, `STREAM` or `WEBSOCKET` for routes
                # declared that way (#282). No request carries those three, so keyed on
                # `req.method` their guards were never found and never ran. One chain then
                # serves every method that reaches the leaf, which is sound because the chain
                # wraps the router terminal and is method-agnostic. A re-publish under the
                # declared key moves `custommiddleware`, so no pipeline serves the old chain.
                declared = innerhandler isa DeclaredMethodHandler
                mw_method = declared ? innerhandler.method : req.method

                # A tuple of two strings that already exist — `req.method` or the leaf's stored
                # declared method, and HTTP.jl's stored `Leaf.path` — so a cache hit builds no key
                # string (#250). The
                # joined `genkey` is needed only below, on a miss, for the `custommiddleware`
                # lookup. See `ChainKey` (src/types.jl).
                key = (mw_method, path)

                # One acquire-load, then a lookup on a table no writer will ever mutate. `nothing`
                # both for "never built" and for "built from a table registration has since
                # replaced" — `cached_chain` never serves a chain across generations.
                func = cached_chain(chains, custom_snap, key)
                isnothing(func) || return func(req)

                # Combine all the middleware functions together, from THIS request's snapshot —
                # the one the chain is about to be stamped with.
                strategy = buildmiddleware(genkey(mw_method, path), handler, globalmiddleware,
                                           custom_snap)

                # Warmup only: once per route per registration generation. The publish decides
                # how much later requests rebuild, never whether they are served a stale chain —
                # that is `cached_chain`'s identity check alone, so a registration racing this
                # request needs no ordering argument here (it did, #81). A request whose
                # snapshot is already superseded simply declines to publish.
                #
                # Only under a key the CLIENT cannot choose. A `DeclaredMethodHandler` leaf keys on
                # the method it was registered with, so its entries are bounded by the route
                # table. Every other leaf keys on `req.method`, which the router matched exactly —
                # except a bare leaf that matches any token (a `"*"` route whose wrapper is hidden
                # by HTTP.jl-level router middleware, or one registered on the router directly).
                # Caching those under every token a client sends would grow this table without
                # bound, each insert copying the whole generation, so a method Nitro does not know
                # is composed for that one request and never cached. The check sits on the miss
                # path only, so a hit never pays for it.
                (declared || mw_method in HTTP_METHODS) &&
                    cache_chain!(chains, custommiddleware, custom_snap, key, strategy)

                return strategy(req)
            end

            # Unmatched (404) or method-mismatched (405). `nocustom`, NOT `handler`: the router
            # still produces the 404/405 status downstream, but global middleware must run — a
            # global `Cors()` has to emit its headers and a global `RateLimiter()` has to count
            # the request, or unmatched paths become a rate-limit bypass. Returning `handler`
            # here is what used to exempt them, and only for apps that had per-route middleware
            # somewhere — an app without it ran global middleware on 404s all along. This
            # restores parity between the two.
            #
            # Clear first (#80): this pass ran `gethandler` and got no route, so any stash on
            # the request belongs to an EARLIER pass over the same object and must not be
            # honoured by the terminal.
            _clear_resolution!(req)
            return nocustom(req)
        end
    end
end


"""
This functions assists registering routes with a specific prefix.
You can optionally assign tags either at the prefix and/or route level which
are used to group and organize the autogenerated documentation
"""
function router(ctx::App, prefix::String="";
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
    ctx::App
    prefix::String
    tags::Vector{String}
    # PROCESSED middleware, not the user's raw list: `router()` passes this through
    # `process_middleware`, whose two methods return exactly `Vector{Function}` or `nothing`.
    # Declaring that (#76) is what lets `(inner::InnerRouter)` publish straight into a
    # `CopyOnWriteDict{RouteMiddleware}` — the `router(...; middleware = ...)` KEYWORD stays
    # `Nullable{Vector}`, because that one really is the user's list and may hold
    # `LifecycleMiddleware` objects.
    middleware::Nullable{Vector{Function}}
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
    ctx::App
    outer::OuterRouter
    path::Union{Nothing, String}
    tags::Vector{String}
    middleware::Nullable{Vector{Function}}      # processed — see `OuterRouter.middleware`
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