# Nitro.jl micro-benchmarks.
#
# Setup (once):  julia --project=bench -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
# Run:           julia --project=bench --threads=4 bench/runbenchmarks.jl
#
# Env knobs: NITRO_BENCH_SECONDS (per-benchmark budget, default 1.0),
#            NITRO_BENCH_QUICK=1 (smoke mode: 0.1s, no result file).

using BenchmarkTools
using JSON
using Dates

const BENCH_DIR = @__DIR__
const QUICK = get(ENV, "NITRO_BENCH_QUICK", "0") == "1"
const SECONDS = QUICK ? 0.1 : parse(Float64, get(ENV, "NITRO_BENCH_SECONDS", "1.0"))

BenchmarkTools.DEFAULT_PARAMETERS.seconds = SECONDS

include(joinpath(BENCH_DIR, "setup.jl"))

const SUITE = BenchmarkGroup()
for f in ["routing.jl", "params.jl", "query.jl", "json.jl", "session.jl", "taskpattern.jl"]
    include(joinpath(BENCH_DIR, "suite", f))
end

@info "Tuning suite..." seconds = SECONDS threads = Threads.nthreads()
tune!(SUITE)
@info "Running suite..."
results = run(SUITE; verbose = true)

# Flatten to a stable name → stats map.
flat = Dict{String,Any}()
for (group, benches) in results
    for (name, trial) in benches
        flat["$group/$name"] = Dict(
            "time_ns_min" => minimum(trial).time,
            "time_ns_median" => BenchmarkTools.median(trial).time,
            "allocs" => minimum(trial).allocs,
            "memory_bytes" => minimum(trial).memory,
            "samples" => length(trial.times),
        )
    end
end

meta = Dict(
    "git_sha" => strip(read(`git -C $(joinpath(BENCH_DIR, "..")) rev-parse --short HEAD`, String)),
    "julia_version" => string(VERSION),
    "nthreads" => Threads.nthreads(),
    "cpu" => Sys.cpu_info()[1].model,
    "timestamp_utc" => string(Dates.now(Dates.UTC)),
    "seconds_per_benchmark" => SECONDS,
)

println("\n", "="^72)
println("Nitro.jl micro-benchmarks @ ", meta["git_sha"], " — Julia ", meta["julia_version"],
    ", ", meta["nthreads"], " threads")
println("="^72)
for name in sort!(collect(keys(flat)))
    s = flat[name]
    println(rpad(name, 40),
        lpad(BenchmarkTools.prettytime(s["time_ns_min"]), 12),
        lpad(string(s["allocs"], " allocs"), 14),
        lpad(BenchmarkTools.prettymemory(s["memory_bytes"]), 12))
end

if !QUICK
    outdir = joinpath(BENCH_DIR, "results")
    mkpath(outdir)
    stamp = Dates.format(Dates.now(Dates.UTC), "yyyymmdd-HHMMSS")
    outfile = joinpath(outdir, "$(meta["git_sha"])-$stamp.json")
    open(outfile, "w") do io
        JSON.print(io, Dict("meta" => meta, "results" => flat), 2)
    end
    println("\nResults saved: ", relpath(outfile, joinpath(BENCH_DIR, "..")))
end
