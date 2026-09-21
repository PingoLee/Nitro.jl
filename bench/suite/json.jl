# JSON request→response echo at two payload sizes: `BodyParsers.json` parses the body into a
# `Dict{String,Any}`, then `Res.json` (src/response.jl) re-serializes it. The `::Any` fallback in
# `format_response` (src/utilities/misc.jl) takes the same `JSON.json` path for a handler that
# returns a bare value. Named rather than line-numbered on purpose — the line numbers this comment
# used to carry had rotted by the time anyone read them.
#
# NOT measuring "full-String materialization" (#38 box 4, refuted). `HTTP.Response(200, body=str)`
# wraps the string's code units zero-copy, so there is no second copy to remove; serializing
# through an `IOBuffer` instead was implemented, measured WORSE, and reverted. See #38's disposition
# comment and docs/design/response-body-lifecycle.md §4. What these two do measure is the
# parse-and-reserialize round trip through a Dict-of-Any.
#
# `echo_*` goes through `run_bench_request`, which rebuilds the WHOLE pipeline per call (~12 µs /
# ~80 allocs, see setup.jl) — enough to bury the serialization cost at the small size. `*_served`
# hoists that out and is the number to quote for a change to the JSON path itself. Both are kept
# because the pair is what tells the two costs apart.
SUITE["json"] = BenchmarkGroup()

const SMALL_JSON = JSON.json(Dict("name" => "item", "qty" => 3, "tags" => ["a", "b"]))  # ~50B
const BIG_JSON = JSON.json(Dict("rows" => [Dict("id" => i, "label" => "row-$i", "value" => i * 1.5)
                                           for i in 1:250]))  # ~10KB

SUITE["json"]["echo_small"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("POST", "/bench/json"; body=SMALL_JSON)) evals=1

SUITE["json"]["echo_10kb"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("POST", "/bench/json"; body=BIG_JSON)) evals=1

# ── Same two, `serve`-shaped: pipeline built ONCE ───────────────────────────
#
# `/bench/json` is registered on `BENCH_CTX` (setup.jl), which `BENCH_PIPELINE` wraps, so these
# call the same route with `internalrequest`'s per-call rebuild taken out. Mirrors the
# `routing/*_served` family.
SUITE["json"]["echo_small_served"] = @benchmarkable run_bench_served(req) setup=(
    req = bench_request("POST", "/bench/json"; body=SMALL_JSON)) evals=1

SUITE["json"]["echo_10kb_served"] = @benchmarkable run_bench_served(req) setup=(
    req = bench_request("POST", "/bench/json"; body=BIG_JSON)) evals=1
