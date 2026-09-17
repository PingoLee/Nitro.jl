# Bench route table on an isolated App (no global CONTEXT[] mutation).
# All requests go through Nitro.Core.internalrequest — the full middleware +
# serializer + router pipeline, minus the socket/task layer (see taskpattern.jl
# for a synthetic measurement of that layer).

using Nitro
using HTTP

const BENCH_CTX = Nitro.Core.App()

Nitro.Core.Routing.urlpatterns(BENCH_CTX, "", Nitro.RouteDefinition[
    Nitro.path("/bench/ping", (req) -> "pong", method="GET"),
    Nitro.path("/bench/items/<int:id>", (req, id::Int) -> Res.json(Dict("id" => id)), method="GET"),
    Nitro.path("/bench/q", function (req)
        q1 = getquery(req)   # first touch
        q2 = getquery(req)   # second touch — measures repeated queryvars cost
        return Res.json(Dict("n" => length(q2), "a" => get(q1, "a", "")))
    end, method="GET"),
    Nitro.path("/bench/json", (req) -> Res.json(getjson(req)), method="POST"),
    # Four bound params in one signature. The single-param route above barely moves
    # when the parser changes shape; the cost of the old `Vector{Any}` + per-param
    # dynamic dispatch scales with arity, so this is where #37 is visible.
    Nitro.path("/bench/multi/<int:id>/<str:slug>", function (req, id::Int, slug::String,
                                                             page::Int = 1, q::String = "")
        return Res.json(Dict("id" => id, "slug" => slug, "page" => page, "q" => q))
    end, method="GET"),
])

bench_request(method::String, target::String; body::String="") =
    isempty(body) ? HTTP.Request(method, target) :
        HTTP.Request(method, target, ["Content-Type" => "application/json"], body)

run_bench_request(req::HTTP.Request) = Nitro.Core.internalrequest(BENCH_CTX, req)

# ── A SECOND App, for the per-route-middleware path (#80, #76) ──────────────
#
# This deliberately does NOT reuse `BENCH_CTX`. `compose`'s emptiness fast path
# (src/routerhof.jl) is per *application*, not per route: one published entry anywhere in
# `custommiddleware` makes the table non-empty for every request that App serves. Adding a
# middleware-carrying route above would therefore have silently moved `full_pipeline_ping`
# and every other existing benchmark off the fast path they were written to measure.
#
# Splitting them is what makes the two paths comparable: `BENCH_CTX` is "no per-route
# middleware anywhere" (one `gethandler`), `BENCH_MW_CTX` is "at least one route has some"
# (the path #80 is about).
const BENCH_MW_CTX = Nitro.Core.App()

# Minimal pass-through: the point is the routing work around it, not the layer itself.
bench_passthrough(handler) = (req::HTTP.Request) -> handler(req)

Nitro.Core.Routing.urlpatterns(BENCH_MW_CTX, "", Nitro.RouteDefinition[
    Nitro.path("/bench/mw/ping", (req) -> "pong", method="GET",
               middleware=[bench_passthrough]),
    # Parametrized: `gethandler` populates `Params()` here, so the second resolution's
    # dict is *filled*, not merely allocated empty.
    Nitro.path("/bench/mw/items/<int:id>", (req, id::Int) -> Res.json(Dict("id" => id)),
               method="GET", middleware=[bench_passthrough]),
])

run_bench_mw_request(req::HTTP.Request) = Nitro.Core.internalrequest(BENCH_MW_CTX, req)

# `use_cache = isempty(globalmiddleware)` (src/routerhof.jl), so passing ANY global
# middleware disables the chain cache and puts `buildmiddleware` — and with it the
# `custommiddleware` destructure #76 is about — on every request, forever. That is the
# normal shape for `serve(middleware=[...])` and for every `revise=:lazy|:eager` session.
const BENCH_GLOBAL_MW = Any[bench_passthrough]

run_bench_mw_nocache_request(req::HTTP.Request) =
    Nitro.Core.internalrequest(BENCH_MW_CTX, req; middleware=BENCH_GLOBAL_MW)

# `internalrequest` rebuilds the WHOLE pipeline per call (src/core/pipeline.jl) — ~12 µs and
# ~80 allocations of fold-and-closure construction that swamp anything the request path
# itself does. `serve` builds it once and calls it per request, so that is the shape to
# measure a per-request routing change against. These two hoist `setupmiddleware` out and
# leave only the per-request work in the benchmark.
#
# `access_log=false` matches `internalrequest`'s default, so the two families differ in the
# pipeline rebuild and nothing else.
const BENCH_MW_PIPELINE = Nitro.Core.setupmiddleware(BENCH_MW_CTX)
const BENCH_PIPELINE = Nitro.Core.setupmiddleware(BENCH_CTX)

run_bench_served(req::HTTP.Request) = BENCH_PIPELINE(req)
run_bench_mw_served(req::HTTP.Request) = BENCH_MW_PIPELINE(req)

# `use_cache == false`, `serve`-shaped: the pipeline is built once, but global middleware is
# present, so nothing is cached and `buildmiddleware` — including the `custommiddleware`
# destructure (#76) — runs on every request. This is `serve(middleware = [...])` and every
# `revise=:lazy|:eager` session, which is to say the normal production configuration.
const BENCH_MW_NOCACHE_PIPELINE =
    Nitro.Core.setupmiddleware(BENCH_MW_CTX; middleware = BENCH_GLOBAL_MW)

run_bench_mw_served_nocache(req::HTTP.Request) = BENCH_MW_NOCACHE_PIPELINE(req)
