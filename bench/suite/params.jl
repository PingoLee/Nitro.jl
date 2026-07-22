# Path-parameter parsing: direct parseparam cost + full pipeline with an <int:id> route
# (exercises create_param_parser's Vector{Any} + Vector{Function} dispatch, src/core.jl:1016).
SUITE["params"] = BenchmarkGroup()

SUITE["params"]["parseparam_int"] = @benchmarkable Nitro.Core.Util.parseparam(Int, "42")
SUITE["params"]["parseparam_union"] = @benchmarkable Nitro.Core.Util.parseparam(Union{Int,String}, "42")

SUITE["params"]["full_pipeline_int_param"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", "/bench/items/42")) evals=1
