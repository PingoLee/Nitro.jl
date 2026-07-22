# Nitro.jl Benchmarks

Micro-benchmarks for the request hot path, added alongside the security/architecture/performance
audit. They run entirely in-process via `Nitro.Core.internalrequest` (no live socket), so they are
fast and deterministic.

## Layout

```
bench/
├── Project.toml        # deps: BenchmarkTools, HTTP, JSON; Nitro dev'd from ".."
├── runbenchmarks.jl    # entry point: builds the SUITE, tunes, runs, prints a table, saves JSON
├── setup.jl            # a fresh ServerContext + bench routes (no global CONTEXT[] mutation)
├── suite/              # one file per benchmark group
│   ├── routing.jl      # full-pipeline static route + genkey
│   ├── params.jl       # parseparam + <int:id> pipeline
│   ├── query.jl        # queryvars URI re-parse
│   ├── json.jl         # JSON echo (small + 10 KB)
│   ├── session.jl      # MemoryStore read/write (payload-size scaling)
│   └── taskpattern.jl  # SYNTHETIC replica of parallel_stream_handler's task overhead
├── results/            # JSON run outputs — gitignored (machine-specific)
└── .gitignore          # ignores results/ and Manifest.toml
```

## Setup (once)

```bash
julia --project=bench -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
```

## Run

```bash
julia --project=bench --threads=4 bench/runbenchmarks.jl
```

Environment knobs:

- `NITRO_BENCH_SECONDS` — per-benchmark time budget (default `1.0`).
- `NITRO_BENCH_QUICK=1` — smoke mode (0.1 s/benchmark, does not write a results file).

Each full run prints a table and writes `bench/results/<git-sha>-<timestamp>.json` with a metadata
header (git SHA, Julia version, thread count, CPU model — no hostname or paths).

## Notes

- `taskpattern/*` is **synthetic**: `internalrequest` bypasses the socket/task layer, so that group
  measures the `Threads.@spawn` + inner `@async` pattern standalone rather than through a real request.
- These are single-node micro-benchmarks, not a load test — they measure per-call cost and allocations,
  not sustained throughput under concurrency.
