# queryvars re-parses HTTP.URI(req.target) and builds a fresh Dict on every call
# (src/types.jl:235); handlers touching req.query more than once pay it repeatedly.
SUITE["query"] = BenchmarkGroup()

const QUERY_TARGET = "/bench/q?a=1&b=2&c=3&d=4&e=5"

SUITE["query"]["queryvars_5keys"] = @benchmarkable Nitro.Core.Types.queryvars(req) setup=(
    req = bench_request("GET", QUERY_TARGET))

SUITE["query"]["full_pipeline_double_touch"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", QUERY_TARGET)) evals=1
