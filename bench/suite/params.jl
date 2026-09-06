# Path-parameter parsing: direct parseparam cost + full pipeline with an <int:id> route.
# Exercises `create_param_parser` (src/core.jl), which since #37 builds a concrete
# `Tuple` of callable strategy structs instead of a `Vector{Any}` filled through a
# `Vector{Function}`. The saving scales with parameter count, so compare
# `full_pipeline_multi_param` (4 bound params) against `full_pipeline_int_param` (1).
SUITE["params"] = BenchmarkGroup()

SUITE["params"]["parseparam_int"] = @benchmarkable Nitro.Core.Util.parseparam(Int, "42")
SUITE["params"]["parseparam_union"] = @benchmarkable Nitro.Core.Util.parseparam(Union{Int,String}, "42")

SUITE["params"]["full_pipeline_int_param"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", "/bench/items/42")) evals=1

SUITE["params"]["full_pipeline_multi_param"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", "/bench/multi/42/hello?page=3&q=x")) evals=1
