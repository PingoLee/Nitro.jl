# Nitro.jl Benchmarks

Micro-benchmarks for the request hot path, added alongside the security/architecture/performance
audit. They run entirely in-process via `Nitro.Core.internalrequest` (no live socket), so they are
fast and deterministic. The one exception is `socket/`, a load test over a real loopback socket for
the transport layer the in-process suite cannot see (see [Socket benchmarks](#socket-benchmarks)).

## Layout

```
bench/
├── Project.toml        # deps: BenchmarkTools, HTTP, JSON; Nitro dev'd from ".."
├── runbenchmarks.jl    # entry point: builds the SUITE, tunes, runs, prints a table, saves JSON
├── setup.jl            # a fresh App + bench routes (no global CONTEXT[] mutation)
├── suite/              # one file per benchmark group
│   ├── routing.jl      # full-pipeline routes, served pipelines, chain-cache lookup
│   ├── params.jl       # parseparam + <int:id> pipeline
│   ├── query.jl        # queryvars URI re-parse
│   ├── json.jl         # JSON echo (small + 10 KB)
│   ├── session.jl      # MemoryStore read/write (payload-size scaling)
│   ├── ratelimiter.jl  # limiter hot path: keying, lock contention, exempt-path scan
│   └── taskpattern.jl  # SYNTHETIC replica of parallel_stream_handler's task overhead
├── socket/             # real-socket throughput: server.jl (Nitro vs bare HTTP.jl) + run.sh (oha)
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
- `ratelimiter/*_contended` is the exception to that last point: it fans 64 tasks over **distinct**
  client keys and measures wall time for the batch, so it does reflect lock contention. Run it with
  `--threads=4` or more, or it measures nothing. Two sibling groups are deliberately different
  shapes and should not be compared to each other:
  - `*_contended` uses one address per /64, i.e. genuinely distinct buckets.
  - `*_rotating_one_prefix` uses 1024 addresses inside **one** /64 — the #22 attack. Since the fix
    those collapse to a single bucket, so this group is *expected* to be slower than `*_contended`,
    and expected to have got slower than it was before the fix. That is the limiter working.
- `exempt_miss_k{1,8,64}` is meaningful only as a **delta across k**, not as an absolute: the
  absolute is dominated by response construction. The delta is what justifies keeping the
  `exempt_paths` matcher a linear scan (#22).

## Socket benchmarks

`internalrequest` skips everything between the socket and the middleware chain: the per-request
`Threads.@spawn`, the request build in `_http_stream_request`, the response write, and HTTP.jl's
connection loop. That is where #453's 2.2× lived, and no in-process profile could see it. `socket/`
measures it over loopback with [`oha`](https://github.com/hatoo/oha):

```bash
bench/socket/run.sh                                  # nitro, bare_spawn, bare_nospawn; 5 x 6 s each
bench/socket/run.sh "nitro bare_spawn" 3 5s          # modes, runs, duration
ACCESS_LOG=1 bench/socket/run.sh nitro               # the serve() default access log on
PROFILE=10 bench/socket/run.sh nitro 1 20s           # sample every thread for 10 s under load
```

- `server.jl` serves `/plaintext`, `/json` and `/health` in one of three `MODE`s: `nitro`
  (`serve()` with no middleware), `bare_spawn` (HTTP.jl `listen!` + `streamhandler` with a
  `Threads.@spawn` per request, the shape Nitro takes and the ceiling to compare it with), and
  `bare_nospawn` (the handler on HTTP.jl's connection task).
- `run.sh` pins the server (`-t 8`) and the load generator to disjoint physical cores, warms each
  route, and reports the median, min and max of N runs plus the median p99. The default CPU sets
  assume a 6-core part whose SMT siblings are `n` and `n+6`; set `SERVER_CPUS`/`CLIENT_CPUS` for
  another layout. Results go to `results/socket-<stamp>.tsv`, profiles to
  `results/profile-<mode>-<time>-{flat,threads}.txt`.
- Compare modes **within one run**, not across days: the CPU governor and anything else on the box
  move absolute numbers by tens of percent. Requires `oha`, `jq`, `curl` and `taskset`.
