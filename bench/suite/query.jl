# `queryvars` used to re-parse `HTTP.URI(req.target)` and rebuild its Dict on EVERY call, so
# anything touching `req.query` more than once — a handler, or the param binder running once
# per bound query parameter — paid the whole decode again. Since #38 it is parsed once per
# request and cached in the request context (src/types.jl).
SUITE["query"] = BenchmarkGroup()

const QUERY_TARGET = "/bench/q?a=1&b=2&c=3&d=4&e=5"

# These two measure different halves of the cache, and the difference is the `evals` setting.
#
# `queryvars_5keys` takes the tuned default, so `tune!` gives it many evals per `setup` and the
# request is reused across them: the first eval builds and caches, the rest read it back. It
# therefore reports the WARM read — 22 allocs before #38, 0 after, since a cache hit allocates
# nothing at all.
#
# `queryvars_5keys_repeated` pins `evals=1`, so `setup` runs for every sample and each
# measurement is one cold build plus two warm reads on a freshly-built request. That is the
# shape of a handler with three bound query parameters, and it is the number to quote for the
# fix: 66 allocs before, 27 after.
#
# Neither is the true worst case, which is a single cold read on a request that is then thrown
# away — there the cache write is pure cost. That does not occur on a served request: by the
# time a handler runs, `stream_handler` has seeded `:ip`/`:stream` and `_app_context_seed` the
# app context, so the metadata Dict the write needs already exists.
SUITE["query"]["queryvars_5keys"] = @benchmarkable Nitro.Core.Types.queryvars(req) setup=(
    req = bench_request("GET", QUERY_TARGET))

# Three touches on one request: the shape of a handler with three bound query parameters.
SUITE["query"]["queryvars_5keys_repeated"] = @benchmarkable begin
    Nitro.Core.Types.queryvars(r); Nitro.Core.Types.queryvars(r); Nitro.Core.Types.queryvars(r)
end setup=(r = bench_request("GET", QUERY_TARGET)) evals=1

SUITE["query"]["full_pipeline_double_touch"] = @benchmarkable run_bench_request(req) setup=(
    req = bench_request("GET", QUERY_TARGET)) evals=1
