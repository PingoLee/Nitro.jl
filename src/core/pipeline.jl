# ── Middleware pipeline assembly ────────────────────────────────────────────────
# Builds the per-request chain, and runs one request through it in-process.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

# Outermost wrapper that seeds the per-request context with the application
# context (`serve(context = ...)`), so `getcontext(req)` works everywhere in the
# pipeline — global/custom middleware, per-route middleware, and handlers alike.
# Runs before any other middleware, so the app context is visible from the very
# first hook a request passes through.
# Seeds only when the key is ABSENT (#31). `internalrequest(context = ...)` stamps its
# per-call override onto the request before handing it to this pipeline, and that override
# must win — this layer supplies the server's default, it does not overwrite a caller's
# choice.
#
# There are exactly two reads of `ctx.app_context[]` left on the request path — this one and
# `internalrequest`'s — plus `serve`'s one-shot startup write (src/core/lifecycle.jl). Both
# reads happen ONCE per request, before any middleware or handler runs, and each immediately
# copies the value onto the request. Nothing downstream of here touches the shared cell, which
# is what removes the window a concurrent request could observe.
#
# `haskey` + assignment rather than `get!`: `HTTP.RequestContext` is reached through
# `haskey`/`getindex`/`setindex!`/`get` throughout `src/` (see `request_input`), and `get!`
# is not part of that surface.
function _app_context_seed(ctx::App)
    return function(handler::Function)
        return function(req::HTTP.Request)
            haskey(req.context, REQUEST_CONTEXT_KEY) ||
                (req.context[REQUEST_CONTEXT_KEY] = ctx.app_context[])
            return handler(req)
        end
    end
end

"""
    _dispatch_resolved(r, req) -> response

The pipeline's innermost layer: dispatch `req` to its handler, reusing the lookup `compose`
already did when there is one (#80).

`compose` (src/routerhof.jl) must call `HTTP.Handlers.gethandler` before it can key the
middleware cache, so by the time a request reaches the bottom of the chain the route has already
been resolved once. This used to call `(r::Router)(req)` regardless, which resolved it a second
time — two `split`s of the target, two trie walks, two `Params()` dicts per request, for every
app with per-route middleware. `compose` now leaves a [`Types.RouteResolution`](@ref) on the
request and this reads it.

**The three lines in the fast branch are `(r::Router)(req)`'s matched branch, deliberately
verbatim** (HTTP.jl `http_handlers.jl`): set `:route`, set `:params` only when non-empty, call
the handler. Keeping the *position* matters as much as the values — these land immediately
before the handler, after every middleware layer has run, which is what
`request_input`/`pathparams` (src/core/request.jl, src/types.jl) build their
"params appeared late" cache-invalidation rule on. A stash written by `compose` does not move
that transition, because nothing reads it until here.

The guard is `(router, method, target)` — every input `gethandler` reads — and
`RouteResolution` documents why each one is there, including the cross-`App` misroute the
`router` check exists to prevent. Falling through to [`_route_unresolved`](@ref) is always
correct: it is `(r::Router)(req)` plus the `Allow` header (#281), so every path that declines the
hand-off degrades to the previous cost, never to a wrong route.

`r` is deliberately untyped: `Service.router` is declared as the unparameterized `Router`, and
the caller `let`-binds it to keep that dynamic dispatch out of the request path. It doubles as
the identity the stash is checked against, so this function needs nothing else to know which
application it belongs to.
"""
function _dispatch_resolved(r, req::HTTP.Request)
    res = get(req.context, Types.ROUTE_RESOLUTION_KEY, nothing)
    if res isa Types.RouteResolution && res.router === r &&
       res.method === req.method && res.target === req.target
        req.context[:route] = res.route
        isempty(res.params) || (req.context[:params] = res.params)
        return res.handler(req)
    end
    return _route_unresolved(r, req)
end

"""
    _route_unresolved(r, req) -> response

`(r::Router)(req)` (HTTP.jl `http_handlers.jl`), except for how it answers a method mismatch (#281):

- **A `405` carries `Allow`**, which RFC 9110 §15.5.6 requires. HTTP.jl's `default405` sends a
  bare `Response(405)`. See [`_method_not_allowed`](@ref).
- **A method mismatch that HTTP.jl reports as a miss is a `405`, not a `404`.** Upstream `match`
  overwrites its `anymissing` flag on every branch it tries, so a later branch that finds nothing
  hides an earlier one that found the path under another method. With `/users/me` (GET) and
  `/users/{name}/posts` registered, `POST /users/me` came back `404`. A `nothing` from `gethandler`
  is therefore re-checked against the route tree, and it is a `405` when the path has any method
  there. That costs one walk of the target's branches on each `404`, the same order of work as
  the lookup that produced it.

The matched branch keeps upstream's order (`:route`, `:params` only when non-empty, then the
handler) for the reason `_dispatch_resolved`'s fast branch gives.

`r` is typed here, unlike in `_dispatch_resolved`: this is the function barrier that gives the
lookup a concrete `Router`.
"""
function _route_unresolved(r::HTTP.Router, req::HTTP.Request)
    handler, route, params = HTTP.Handlers.gethandler(r, req)
    if handler === nothing
        allowed = _allowed_methods(r, req.target)
        return isempty(allowed) ? r._404(req) : _method_not_allowed(r, req, allowed)
    elseif handler === missing
        return _method_not_allowed(r, req)
    end
    req.context[:route] = route
    isempty(params) || (req.context[:params] = params)
    return handler(req)
end

"""
    _method_not_allowed(r, req[, allowed]) -> response

The router's own `_405`, plus an `Allow` header listing what `req.target` does answer (#281).
`allowed` is that list when the caller already walked the tree for it; otherwise it is computed
here, and only if the header is actually added.

A custom `_405` (`Service(router = Router(my404, my405))`) still decides the response. `Allow` is
added to it only when it returned an `HTTP.Response` with no `Allow` of its own, and it is added
by building a new response, since a handler's response may be a shared `const` (nitro-core §4).
Anything else it returns (a `Dict` for the serializer, say) is passed through untouched.
"""
function _method_not_allowed(r::HTTP.Router, req::HTTP.Request,
                             allowed::Nullable{Vector{String}} = nothing)
    res = r._405(req)
    res isa HTTP.Response || return res
    HTTP.hasheader(res, "Allow") && return res
    list = allowed === nothing ? _allowed_methods(r, req.target) : allowed
    return add_response_headers(res, "Allow" => join(list, ", "))
end

"""
    _allowed_methods(r, target) -> Vector{String}

The methods `r` would serve at `target`, sorted. Built from HTTP.jl's route tree in two steps:

1. Collect the leaf methods at **every** node `target` reaches: exact, pattern-constrained
   variable, bare variable and `**`, in the order upstream `match` tries them. The router serves
   a method if *any* of those nodes has it, because `match` falls through to the next branch when
   one lacks it.
2. Keep a candidate only if upstream's own `match` resolves it to a leaf, and that leaf is not a
   [`RetiredHeadHandler`](@ref). The list is then exactly what the router would serve, precedence
   included, rather than a second implementation of it.

`"*"` leaves are skipped. They take every method, so a node that has one can never answer `405`.

Reads HTTP.jl internals (`Router.routes`, the `Node`/`Leaf`/`Variable` fields, `match`,
`_route_variable_matches`, `_router_request_path`). Each one is canaried in
test/http_internals_contract_tests.jl.
"""
function _allowed_methods(r::HTTP.Router, target::String)::Vector{String}
    segments = split(HTTP.Handlers._router_request_path(target), '/'; keepempty = false)
    candidates = String[]
    _collect_leaf_methods!(candidates, r.routes, segments, 1)
    allowed = String[]
    for method in candidates
        leaf = HTTP.Handlers.match(r.routes, method, segments, 1)
        leaf isa HTTP.Handlers.Leaf && !(leaf.handler isa RetiredHeadHandler) && push!(allowed, method)
    end
    return sort!(allowed)
end

function _collect_leaf_methods!(acc::Vector{String}, node::HTTP.Handlers.Node,
                                segments::Vector{SubString{String}}, i::Int)::Nothing
    if i > length(segments)
        for leaf in node.methods
            leaf.method == "*" || leaf.method in acc || push!(acc, leaf.method)
        end
        return nothing
    end
    segment = segments[i]
    for child in node.exact
        child.segment == segment && _collect_leaf_methods!(acc, child, segments, i + 1)
    end
    for child in node.conditional
        pattern = (child.segment::HTTP.Handlers.Variable).pattern::Regex
        HTTP.Handlers._route_variable_matches(pattern, segment) &&
            _collect_leaf_methods!(acc, child, segments, i + 1)
    end
    node.wildcard === nothing ||
        _collect_leaf_methods!(acc, node.wildcard::HTTP.Handlers.Node, segments, i + 1)
    node.doublestar === nothing ||
        _collect_leaf_methods!(acc, node.doublestar::HTTP.Handlers.Node, segments, length(segments) + 1)
    return nothing
end

function setupmiddleware(ctx::App; middleware::Vector=[], serialize::Bool=true, catch_errors::Bool=true, show_errors::Bool=true, access_log=false, access_log_query::Bool=false)::Function
    raw_middleware = reverse(middleware)
    # `normalize_middleware`, NOT `process_middleware`: this runs once per `serve` but ONCE
    # PER CALL from `internalrequest`, so it must have no registration side effect. `serve`
    # registers explicitly, just before it calls this. (#68)
    processed_middleware = normalize_middleware(raw_middleware)

    global_prefix_middleware = !isnothing(ctx.service.prefix[]) ? [PrefixStripMiddleware(ctx.service.prefix[])] : []
    serializer = serialize ? [DefaultSerializer(catch_errors; show_errors)] : []
    # The outer half of error handling (#256) -- see `ErrorBoundary`. Gated exactly like the
    # serializer's catch: `serialize=false` still means Nitro installs no error or format layer at
    # all, and `catch_errors=false` would make it a pass-through, so it is left out rather than
    # paid for per request.
    error_boundary = serialize && catch_errors ? [ErrorBoundary(catch_errors; show_errors)] : []
    # Accept `true` to enable; `nothing`/`false` (or the old logfmt value) disable it.
    access_log_middleware = access_log === true ? [AccessLogMiddleware(; log_query=access_log_query)] : []

    # `compose` is installed UNCONDITIONALLY (#71). The old gate here — install it only if
    # `custommiddleware` was already non-empty — was evaluated once, and `serve` calls this
    # once, so an app whose first per-route middleware was registered AFTER the server started
    # (Revise re-running `urlpatterns`, a runtime `include_routes`) never got `compose` at all
    # and that middleware silently never ran. The emptiness test now lives inside `compose`,
    # per request, where it also short-circuits to a prebuilt global-middleware-only chain
    # BEFORE `gethandler` — so an app with no per-route middleware does strictly less routing
    # work here than the old compose branch did (one `gethandler`, not two). Since #80 the
    # matched path resolves once as well, so that contrast is with the PRE-#80 compose branch,
    # not with the other path through this pipeline today. Against the old
    # non-compose branch it costs one closure call, one acquire-load and an `isempty` per
    # request, and no extra allocation. (Deliberately no wall-clock figure: this comment already
    # carried one that went stale the moment `router_entry` was added below.)
    #
    # `processed_middleware` travels SIDEWAYS into `compose` rather than being spliced into the
    # list below: `compose` applies it inside `buildmiddleware` and inside that fast path,
    # which lands it outside route middleware and inside the serializer — the same effective
    # position it held in this list. Do NOT do both, or every global middleware runs twice.
    # `HTTP.Router` is a *callable struct*, not a `Function` — `HTTP.Handlers.Router <: Function`
    # is false. Three of the layers that can end up wrapping it are typed on `Function` and so
    # reject it outright: `_app_context_seed` below, and `foldlayers`/`buildmiddleware` in
    # src/routerhof.jl. (`DefaultSerializer`, `PrefixStripMiddleware` and user middleware are
    # untyped and accept it fine.) So start the fold from an adapter rather than the bare router.
    #
    # `serialize=false` is what exposes this, because the serializer is otherwise the thing that
    # wraps the router into a closure on the first fold step. On `serve` it used to survive by
    # luck — `access_log` defaults to true, and `AccessLogMiddleware` accepts the raw router —
    # while `internalrequest(...; serialize=false)`, which defaults `access_log` to false, threw
    # a `MethodError` out of `_app_context_seed` even before #71. Now that `compose` is always
    # installed it receives the accumulator directly, so without this adapter every
    # `serialize=false` app would fail at pipeline-construction time, before any request.
    #
    # `let`-bound rather than closing over `ctx`: `Service.router` is declared as the
    # unparameterized `Router` (an abstract UnionAll), so reading it per request would put a
    # dynamic dispatch at the innermost layer of every request. `Service` is immutable, so the
    # value is fixed at construction and hoisting it out is free.
    router_entry = let r = ctx.service.router
        (req::HTTP.Request) -> _dispatch_resolved(r, req)
    end

    return reduce(|>, [
        router_entry,
        serializer...,
        # `catch_errors`/`show_errors`/`serialize` travel into `compose` because the chain it
        # caches closes over them, via `serializer` above — so they belong in the cache key
        # (#79). They are not otherwise used there.
        #
        # `show_errors` is declared `::Bool` above for this reason: `DefaultSerializer` converts
        # whatever it gets, so an untyped truthy value (`1`) would bake `true` into the chain
        # while `cachetag` recorded `e` — two pipelines with different behaviour sharing one
        # cache key, which is the exact failure #79 removed. Typing it makes the projection
        # lossless by construction rather than by luck.
        compose(ctx.service.router, processed_middleware,
                ctx.service.custommiddleware, ctx.service.middleware_cache;
                catch_errors, show_errors, serialize),
        global_prefix_middleware...,
        # Outside every layer that can throw, inside the access log so that log line records
        # the 500 this produces (#256).
        error_boundary...,
        access_log_middleware...,
        _app_context_seed(ctx),
    ])
end

# NOTE on STREAMING response bodies (#41). This runs the whole pipeline *minus* the socket layer,
# so it never reaches `_write_response_body!` — which is what drains and closes a streaming body.
# A handler or mount that streams (`Res.file(req, path; stream=true)`, or a mounted file above
# `stream_threshold`) therefore hands back a response whose body is an OPEN cursor, and the caller
# owns it: drain it with `HTTP.body_read!` until it reports 0, or call `HTTP.body_close!`. Until
# then the file handle stays open, which on Windows also blocks deleting the file. Over a real
# socket none of this applies — the write path always closes.
function internalrequest(ctx::App, req::HTTP.Request; middleware::Vector=[], serialize::Bool=true, catch_errors=true, context=missing)::HTTP.Response
    req.context[:ip] = IPv4("127.0.0.1")

    # Stamp the per-call override onto THIS REQUEST, never onto `ctx.app_context[]` (#31).
    #
    # The old shape was save / overwrite the shared `Ref` / restore in a `finally`. Because
    # `serve()` dispatches every request on `Threads.@spawn` and `_app_context_seed` read that
    # same cell per request, any live request entering the pipeline inside the window was
    # seeded with THIS caller's context — `getcontext(req)` then returned the wrong tenant's
    # object for that request's whole lifetime. Worse, `old_ctx` was snapshotted without
    # synchronisation, so two overlapping calls clobbered the original permanently: the second
    # `finally` wrote back whatever the first had installed.
    #
    # Carrying it on the request removes the window by construction rather than narrowing it —
    # there is no shared mutable state left for a concurrent request to observe. Regression:
    # test/appcontext_race_tests.jl.
    # ALWAYS stamp, even with no override — the value is then just what `_app_context_seed`
    # would have supplied. Writing unconditionally is what makes the outcome independent of
    # whatever the caller's `req` was already carrying.
    #
    # The conditional version of this leaked: `_app_context_seed` seeds only when the key is
    # absent, so re-running a request object that had picked up an override on an earlier call
    # kept the STALE context instead of resolving to the server's. That is the same class of
    # defect this commit exists to remove — a request observing a context that is not its own —
    # just reached by reuse rather than by a data race. Covered by the "a reused request object
    # does not inherit a previous call's context" item in test/appcontext_race_tests.jl.
    req.context[REQUEST_CONTEXT_KEY] = ismissing(context) ? ctx.app_context[] : Context(context)

    return req |> setupmiddleware(ctx; middleware, serialize, catch_errors)
end
