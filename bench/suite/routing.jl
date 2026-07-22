# Full-pipeline latency for a static route + the per-request middleware-cache key.
SUITE["routing"] = BenchmarkGroup()

# Fresh Request per eval: internalrequest mutates req.context and body caches.
SUITE["routing"]["full_pipeline_ping"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", "/bench/ping")) evals=1

# genkey allocates a String cache key on EVERY request, cache hit or not
# (src/routerhof.jl:34, called from compose at src/routerhof.jl:82).
SUITE["routing"]["genkey"] = @benchmarkable Nitro.Core.RouterHOF.genkey("GET", "/bench/ping")
