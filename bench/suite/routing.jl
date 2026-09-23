# Full-pipeline latency for a static route + the per-request middleware-cache key.
SUITE["routing"] = BenchmarkGroup()

# Fresh Request per eval: internalrequest mutates req.context and body caches.
SUITE["routing"]["full_pipeline_ping"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", "/bench/ping")) evals=1

# `genkey` IN ISOLATION — which since #79 is no longer the shape of the request path, so read
# this number as a floor on the key cost and not as a per-request cost. What `compose` actually
# builds (src/routerhof.jl, see #250):
#
#   * cache HIT  — `cachekey = string(req.method, '|', path, cache_suffix)`, not `genkey`; and
#                  only when `use_cache`, i.e. when the app passes NO global middleware.
#   * cache MISS — that, plus `genkey`. `genkey` sits outside the `use_cache` branch, so it also
#                  runs on every request of an app that DOES have global middleware.
#   * neither    — an app with an empty `custommiddleware` returns from the emptiness fast path
#                  before `gethandler`, and builds no key at all. That is `full_pipeline_ping`
#                  and `served_ping` below, and it is the common shape.
#
# So this benchmarkable is comparable across commits, but the `mw_served*` / `served_ping` gap is
# what says whether a key change moved a served request.
SUITE["routing"]["genkey"] = @benchmarkable Nitro.Core.RouterHOF.genkey("GET", "/bench/ping")

# ── The per-route-middleware path (#80, #76) ────────────────────────────────
#
# `full_pipeline_ping` above runs on an App with an EMPTY `custommiddleware`, so it returns
# from `compose`'s emptiness fast path before `gethandler` and has never measured any of
# this. The three below run on `BENCH_MW_CTX`, where the table is non-empty:
#
#   mw_cache_hit   — `compose`'s `gethandler` plus whatever the chain's terminal does. This is
#                    where #80's second trie walk USED to live; these exist to show it no longer
#                    does, and to catch it coming back.
#   mw_cache_hit_param — same, on a route with a path variable, so `Params()` is populated
#                    rather than just allocated.
#   mw_nocache     — same with one global middleware layer.
#
# The names predate #255 and are kept so results compare across commits, but read them
# literally no more: `internalrequest` builds a fresh pipeline per call, and since #255 each
# pipeline owns its chain cache, so EVERY request here is a cache miss that composes its chain.
# The `mw_served_*` family below is the one that measures a warm cache.
SUITE["routing"]["mw_cache_hit"] = @benchmarkable run_bench_mw_request(req) setup=(
    req = bench_request("GET", "/bench/mw/ping")) evals=1

SUITE["routing"]["mw_cache_hit_param"] = @benchmarkable run_bench_mw_request(req) setup=(
    req = bench_request("GET", "/bench/mw/items/42")) evals=1

SUITE["routing"]["mw_nocache"] = @benchmarkable run_bench_mw_nocache_request(req) setup=(
    req = bench_request("GET", "/bench/mw/items/42")) evals=1

# ── Same three paths, `serve`-shaped: pipeline built ONCE ───────────────────
#
# The `*_request` benchmarks above all pay `internalrequest`'s per-call pipeline rebuild,
# which is ~12 µs and ~80 allocations — enough to bury a per-request routing change
# entirely. These call a pre-built pipeline, which is what a served request actually does,
# so a change to the request path shows up as a change here.
#
# `served_ping` is the no-per-route-middleware control (compose's emptiness fast path, which
# returns BEFORE `gethandler`); the `mw_served_*` pair is the path that resolved twice before
# #80. Both now resolve once, so the gap between them is one `gethandler`, the cache-key
# string, the cache snapshot and lookup, the chain call, and the per-route middleware layer
# itself — not the middleware layer alone. A regression on #80 shows up as that gap widening
# by a second trie walk and a second `Params()`.
SUITE["routing"]["served_ping"] = @benchmarkable run_bench_served(req) setup=(
    req = bench_request("GET", "/bench/ping")) evals=1

SUITE["routing"]["mw_served"] = @benchmarkable run_bench_mw_served(req) setup=(
    req = bench_request("GET", "/bench/mw/ping")) evals=1

SUITE["routing"]["mw_served_param"] = @benchmarkable run_bench_mw_served(req) setup=(
    req = bench_request("GET", "/bench/mw/items/42")) evals=1

# Global middleware, pipeline built once. Until #255 this cached nothing, so `buildmiddleware`
# and its `custommiddleware` destructure (#76) ran per request here; now the chain is cached
# like `mw_served_param`'s, and the gap between the two is the global layer's own call cost.
SUITE["routing"]["mw_served_nocache"] = @benchmarkable run_bench_mw_served_nocache(req) setup=(
    req = bench_request("GET", "/bench/mw/items/42")) evals=1

# The static-route partner of `mw_served_nocache`, so each global-middleware benchmark has a
# route-shape twin in the no-global family (`mw_served` ↔ this, `mw_served_param` ↔
# `mw_served_nocache`). Read the pairs across families for the global layer's cost, and the
# two routes within a family for the cost of a populated `Params()` (#255).
SUITE["routing"]["mw_served_nocache_static"] = @benchmarkable run_bench_mw_served_nocache(req) setup=(
    req = bench_request("GET", "/bench/mw/ping")) evals=1
