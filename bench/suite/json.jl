# JSON request→response echo: JSON.jl parse + full-String materialization
# (src/response.jl:24, src/utilities/misc.jl:185) at two payload sizes.
SUITE["json"] = BenchmarkGroup()

const SMALL_JSON = JSON.json(Dict("name" => "item", "qty" => 3, "tags" => ["a", "b"]))  # ~50B
const BIG_JSON = JSON.json(Dict("rows" => [Dict("id" => i, "label" => "row-$i", "value" => i * 1.5)
                                           for i in 1:250]))  # ~10KB

SUITE["json"]["echo_small"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("POST", "/bench/json"; body=SMALL_JSON)) evals=1

SUITE["json"]["echo_10kb"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("POST", "/bench/json"; body=BIG_JSON)) evals=1
