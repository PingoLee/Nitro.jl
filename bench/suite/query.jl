# `queryvars` used to re-parse `HTTP.URI(req.target)` and rebuild its Dict on EVERY call, so
# anything touching `req.query` more than once — a handler, or the param binder running once
# per bound query parameter — paid the whole decode again. Since #38 it is parsed once per
# request and cached in the request context (src/types.jl).
SUITE["query"] = BenchmarkGroup()

const QUERY_TARGET = "/bench/q?a=1&b=2&c=3&d=4&e=5"

# NOTE: `queryvars_5keys` is a cache's WORST case and is expected to have regressed slightly
# against pre-#38 numbers — it builds a bare `HTTP.Request` with no metadata Dict, calls the
# accessor exactly once, and throws the request away, so it pays for the cache write and never
# reads it back. It is kept as the honest floor. A real request always has metadata already
# (`stream_handler` seeds `:ip`/`:stream`, `_app_context_seed` seeds the app context), and is
# read more than once — which is what `queryvars_5keys_repeated` and the two full-pipeline
# benchmarks measure.
SUITE["query"]["queryvars_5keys"] = @benchmarkable Nitro.Core.Types.queryvars(req) setup=(
    req = bench_request("GET", QUERY_TARGET))

# Three touches on one request: the shape of a handler with three bound query parameters.
SUITE["query"]["queryvars_5keys_repeated"] = @benchmarkable begin
    Nitro.Core.Types.queryvars(r); Nitro.Core.Types.queryvars(r); Nitro.Core.Types.queryvars(r)
end setup=(r = bench_request("GET", QUERY_TARGET)) evals=1

SUITE["query"]["full_pipeline_double_touch"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", QUERY_TARGET)) evals=1
