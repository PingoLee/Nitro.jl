# Full-pipeline latency for a static route + the per-request middleware-cache key.
SUITE["routing"] = BenchmarkGroup()

# Fresh Request per eval: internalrequest mutates req.context and body caches.
SUITE["routing"]["full_pipeline_ping"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", "/bench/ping")) evals=1

# genkey allocates a String cache key on EVERY request, cache hit or not
# (src/routerhof.jl `genkey`, called from `compose` just before the middleware-cache lookup).
SUITE["routing"]["genkey"] = @benchmarkable Nitro.Core.RouterHOF.genkey("GET", "/bench/ping")

# ── The per-route-middleware path (#80, #76) ────────────────────────────────
#
# `full_pipeline_ping` above runs on an App with an EMPTY `custommiddleware`, so it returns
# from `compose`'s emptiness fast path before `gethandler` and has never measured any of
# this. The three below run on `BENCH_MW_CTX`, where the table is non-empty:
#
#   mw_cache_hit   — the chain is cached, so the request pays `compose`'s `gethandler` plus
#                    whatever the chain's terminal does. This is where #80's second trie
#                    walk lives.
#   mw_cache_hit_param — same, on a route with a path variable, so `Params()` is populated
#                    rather than just allocated.
#   mw_nocache     — `use_cache == false`, so `buildmiddleware` runs per request and the
#                    `custommiddleware` destructure (#76) is on the hot path.
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
# `served_ping` is the no-per-route-middleware control (compose's emptiness fast path, one
# `gethandler`); the `mw_served_*` pair is the path that resolves twice today.
SUITE["routing"]["served_ping"] = @benchmarkable run_bench_served(req) setup=(
    req = bench_request("GET", "/bench/ping")) evals=1

SUITE["routing"]["mw_served"] = @benchmarkable run_bench_mw_served(req) setup=(
    req = bench_request("GET", "/bench/mw/ping")) evals=1

SUITE["routing"]["mw_served_param"] = @benchmarkable run_bench_mw_served(req) setup=(
    req = bench_request("GET", "/bench/mw/items/42")) evals=1

# `use_cache == false`, pipeline built once: `buildmiddleware` and its `custommiddleware`
# destructure run per request here, which is the only place #76 is observable.
SUITE["routing"]["mw_served_nocache"] = @benchmarkable run_bench_mw_served_nocache(req) setup=(
    req = bench_request("GET", "/bench/mw/items/42")) evals=1
