# JSON request→response echo at two payload sizes: `BodyParsers.json` parses the body into a
# `JSON.Object{String,Any}` (JSON.jl's ordered object, not a Base `Dict`), then `Res.json`
# (src/response.jl) re-serializes it. The `::Any` fallback in `format_response`
# (src/utilities/misc.jl) takes the same `JSON.json` path for a handler that returns a bare value. Named rather than line-numbered on purpose — the line numbers this comment
# used to carry had rotted by the time anyone read them.
#
# NOT measuring "full-String materialization" (#38 box 4, refuted). `HTTP.Response(200, body=str)`
# wraps the string's code units zero-copy, so there is no second copy to remove; serializing
# through an `IOBuffer` instead was implemented, measured WORSE, and reverted. See #38's disposition
# comment and docs/design/response-body-lifecycle.md §4. What these two do measure is the
# parse-and-reserialize round trip through an untyped `JSON.Object`.
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

# ── The typed extractor against `getjson` (#475) ────────────────────────────
#
# Same two payloads, bound through `Json{T}` (bench/setup.jl) instead of `getjson`, and echoed
# back with `Res.json` of the parsed value. `typed_*` is a plain struct (`BenchItem`, and
# `BenchRows` holding a `Vector{BenchRow}`); `kwdef_*` is its `@kwdef` twin, which `json_bind`
# parses into `Dict{String, JSON.JSONText}` first and then parses field by field (#294).
for (name, target, body) in (("typed_small", "/bench/json/typed/item", SMALL_JSON),
                             ("kwdef_small", "/bench/json/kwdef/item", SMALL_JSON),
                             ("typed_10kb", "/bench/json/typed/rows", BIG_JSON),
                             ("kwdef_10kb", "/bench/json/kwdef/rows", BIG_JSON))
    SUITE["json"]["echo_$name"] = @benchmarkable run_bench_request(req) setup=(
        req = bench_request("POST", $target; body=$body)) evals=1
    SUITE["json"]["echo_$(name)_served"] = @benchmarkable run_bench_served(req) setup=(
        req = bench_request("POST", $target; body=$body)) evals=1
end

# The echo, split in half. An end-to-end typed row alone cannot tell a cheaper parse from a
# dearer write: `Res.json` of a struct turns every field name into a `String` (#474), which a
# `Dict{String}` key never pays. So the parse and the write are also measured on their own.
#
# `parse_*` is the work each extractor does on the body's bytes: `parse_dict_*` is `getjson`'s
# untyped parse, `parse_typed_*` and `parse_kwdef_*` are `Json{T}`'s `json_bind`. A `Vector{UInt8}`
# because that is what the extractor reads (`_body_view`), not a `String`.
const _BP = Nitro.Core.Util.BodyParsers
const _json_bind = Nitro.Core.Extractors.json_bind

for (size, bytes, T, KwT) in (("small", Vector{UInt8}(SMALL_JSON), BenchItem, BenchKwItem),
                              ("10kb", Vector{UInt8}(BIG_JSON), BenchRows, BenchKwRows))
    SUITE["json"]["parse_dict_$size"] = @benchmarkable _BP._parse_json_bounded($bytes) evals=1
    SUITE["json"]["parse_typed_$size"] = @benchmarkable _json_bind($T, $bytes) evals=1
    SUITE["json"]["parse_kwdef_$size"] = @benchmarkable _json_bind($KwT, $bytes) evals=1
    # `write_*` serializes what the matching parse produced.
    SUITE["json"]["write_dict_$size"] = @benchmarkable Res.json(v) setup=(
        v = _BP._parse_json_bounded($bytes)) evals=1
    SUITE["json"]["write_struct_$size"] = @benchmarkable Res.json(v) setup=(
        v = _json_bind($T, $bytes)) evals=1
end
