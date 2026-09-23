# Full-pipeline latency for a static route + the per-request middleware-chain lookup.
SUITE["routing"] = BenchmarkGroup()

# Fresh Request per eval: internalrequest mutates req.context and body caches.
SUITE["routing"]["full_pipeline_ping"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", "/bench/ping")) evals=1

# The chain-cache lookup a warm served request makes, in isolation: build the key and look it up
# (#250). It replaced a `genkey` benchmark that had stopped measuring the request path at all —
# the hit path built a different string by then, and since #250 it builds none: the key is a
# tuple of `req.method` and HTTP.jl's stored route path. Expect 0 allocations; a key change that
# reintroduces a per-request string shows up here as 1.
#
# The served number is `mw_served` against `served_ping` below: their gap is everything the
# non-fast path does — `gethandler`, this lookup, the chain call, and the route layer itself.
# An app with an empty `custommiddleware` takes the emptiness fast path before `gethandler` and
# never reaches this, which is `full_pipeline_ping` and `served_ping` — the common shape.
SUITE["routing"]["chain_cache_hit"] = @benchmarkable(
    Nitro.Core.Types.cached_chain(c, snap, (m, p)),
    setup = ((c, snap, m, p) = bench_chain_cache_hit()))

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
# #80. Both now resolve once, so the gap between them is one `gethandler`, the chain-cache
# lookup (`chain_cache_hit` above — no key string since #250), the chain call, and the per-route
# middleware layer itself — not the middleware layer alone. A regression on #80 shows up as that gap widening
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
