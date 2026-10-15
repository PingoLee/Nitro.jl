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
├── socket/             # real-socket load: server.jl (Nitro vs bare HTTP.jl), run.sh, contention.sh (oha)
│   └── go/             # the Go net/http reference server run.sh's `go` mode builds
├── tasks/              # Julia tasks vs goroutines, no HTTP: tasks.jl, go/, run.sh
├── results/            # JSON run outputs — gitignored (machine-specific)
└── .gitignore          # ignores results/, Manifest.toml and per-version Manifest-v*.toml
```

## Setup (once)

```bash
julia --project=bench -e 'using Pkg; Pkg.instantiate()'
```

`bench/Project.toml` names this checkout as Nitro's source (`[sources] Nitro = {path = ".."}`), so
no `Pkg.develop` step is needed and setup leaves no diff behind.

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
- `httpparse/*` is the one group that does **not** go through Nitro at all: it is HTTP.jl's
  `read_request` on a buffered request head — the work the server does on its connection task,
  on the `:interactive` thread, before Nitro's per-request spawn (#462). `connreader_*` is the
  server's `_ConnReader` path, `iobuffer_*` the generic `IO` path for contrast. It opens one
  loopback TCP pair at include time (the reader type needs a real connection). Most rows never
  read from it: the head sits in the reader's buffer, so the request line takes the fast path.
  `connreader_*_socket` is what a keep-alive server actually runs: the buffer starts empty, the
  head arrives over the socket, and the request line takes `_readline_crlf`'s slow path, so the
  fill syscall is part of the number. `HTTP._ConnReader`'s layout is internal and pinned to
  HTTP 2.9.0, so a `[compat]` bump that breaks this file is doing its job.
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
bench/socket/run.sh "nitro@8,1 nitro@8,2 nitro@8,4"  # one mode per --threads, interleaved (#462)
RATE=20000 bench/socket/run.sh "nitro@8,1 nitro@8,0" # fixed rate: latency without saturation (#491)
JULIA="julia +1.12" bench/socket/run.sh              # another Julia, by juliaup channel
bench/socket/contention.sh "8,1 6,2 8,0" 5 8s       # /health while the default pool is busy (#491)
```

- `server.jl` serves `/plaintext`, `/json`, `/health`, `/cpu` and `/lag` in one of these `MODE`s:
  `nitro` (`serve()` with no middleware), `nitro_log` (the same with the access log on),
  `bare_spawn` (HTTP.jl `listen!` + `streamhandler` with a `Threads.@spawn` per request, the shape
  Nitro takes and the ceiling to compare it with), and `bare_nospawn` (the handler on HTTP.jl's
  connection task). `/cpu` burns `CPU_MS` (default 50) without yielding; `/lag` is live only with
  `LAG=1`. `WORKERS=1` adds `/burst?n=K` to the Nitro modes, which submits K Workers jobs that each
  burn `JOB_MS` (default 500).
- `run.sh` pins the server (`-t 8`) and the load generator to disjoint physical cores, warms each
  route, and reports the median, min and max of N runs plus the median p99. The default CPU sets
  assume a 6-core part whose SMT siblings are `n` and `n+6`; set `SERVER_CPUS`/`CLIENT_CPUS` for
  another layout. Results go to `results/socket-<stamp>.tsv`, profiles to
  `results/profile-<mode>-<time>-{flat,threads,interactive-tree}.txt` — the last is a call tree
  of the `:interactive` threads only, which is where HTTP.jl accepts, parses every request head
  and wakes the per-request task (#462). It keeps C frames and opens with the window's GC time.
  Without C frames, a stop-the-world GC wait (`jl_safepoint_wait_gc`) is charged to whatever
  Julia allocation the thread was parked at, and it reads as a parser cost. `Base.gc_time_ns`
  counts the collection only, not the wait to reach a safepoint, so the tree can show more GC
  wait than the header does.
- `mode@threads` (`nitro@8,2`) starts that one server with its own `--threads` and records it in
  the TSV's `threads` column, so a sweep of the interactive thread count is one interleaved run
  rather than one run per count. `-t 8` is `8,1` on Julia 1.12; note that `8,2` and `8,4` put more
  OS threads on the 8 pinned logical CPUs than `8,1` does — hold the total constant (`6,2`, `4,4`)
  as a control if the sweep moves.
- `first_request.sh [route] [repeats]` times the first request to a fresh server against a warm
  one (#450). It waits for the listening socket with `ss` rather than a request, so nothing warms
  the path first. Set `ACCESS_LOG=1` to measure `serve`'s default shape, which is the one the
  precompile workload warms; set `BASE_ROOT` to measure another checkout.
- `trace_first_request.sh [route]` runs the server under `--trace-compile` and prints exactly
  what the first request compiled, which is the list of what the precompile workload missed.
- `MODE=nitro_log` is `nitro` with the default console access log on (#443), for a one-run A/B
  of what that line costs.
- `RATE=<n>` makes `run.sh` send a fixed `n` requests per second (`oha -q`, with
  `--latency-correction`) instead of as fast as the server answers, and the TSV gains the rate and
  a p50 column. Compare latency at a rate every layout sustains: at saturation, the layout with
  the higher throughput also has the longer queue, and its p99 says so.
- `contention.sh [layouts] [rounds] [duration]` starts one server per `--threads` layout with
  `WORKERS=1 LAG=1` and probes `/health` at `PROBE_RATE` (default 200/s) while `SCENARIOS` keep
  the default pool busy: `idle`, `cpu` (`CPU_CONNS` connections on `/cpu`) and `burst<K>` (K
  Workers jobs). Each row is `/health` p50/p99/max, its success rate, and `/lag`: how late a
  10 ms `sleep` on the default pool woke, which is the delay a `Timer`-driven deadline (a Workers
  timeout) sees. It answers whether the interactive thread protects a cheap request while
  handlers or jobs hold the CPU (#491).
- `JULIA="julia +1.12"` runs the servers on another juliaup channel. Each Julia minor wants its
  own resolved manifest; `bench/Manifest-v1.12.toml` (gitignored) is the one 1.12 reads first, so
  copy `Manifest.toml` to it and `Pkg.resolve()` under 1.12 once.
- Compare modes **within one run**, not across days: the CPU governor and anything else on the box
  move absolute numbers by tens of percent. Requires `oha`, `jq`, `curl` and `taskset`.
- Every `run.sh` row also carries the server's resident memory, read from `/proc` for the process
  that owns the listening socket: at rest (once it answers `/health`), after the last run, and the
  peak (`VmHWM`).

## Comparing with Go

Go's `net/http` is the reference, not the target (#469): the point is to know which part of the gap
is HTTP.jl, which is the Julia runtime, and which is Nitro. **Only numbers from the same box and the
same run are compared**; a Go figure measured elsewhere says nothing about the Julia ones.

```bash
bench/socket/run.sh "go nitro nitro@8,0 bare_spawn bare_nospawn" 5 6s   # HTTP, Go interleaved
bench/tasks/run.sh                                                       # runtimes, no HTTP
```

- **`socket/go/`** answers `/plaintext`, `/json`, `/health`, `/cpu` and `/lag` with the same bodies
  as `server.jl`, building every response per request. `run.sh` builds it once and pins it to
  `SERVER_CPUS` like any other mode; its `threads` column is `GOMAXPROCS`, by default the number of
  server CPUs (`go@4` sets it). Go is needed only when the `go` mode is requested.
- **`tasks/`** isolates the runtimes from HTTP. `go/tasks_test.go` (`go test -bench`) and
  `tasks.jl` (BenchmarkTools) time the same shapes: spawn + wait one at a time (Nitro's
  per-request spawn), a ping-pong round trip over unbuffered channels, and a fan-out of 1000 with
  one wait for all. `parked` blocks 100,000 tasks on one event and reports resident memory per
  task; `spin` keeps every thread busy with a loop that cannot yield and measures how late a 1 ms
  heartbeat wakes, charged from the moment it was spawned. Go runs it twice, the second time with
  `GODEBUG=asyncpreemptoff=1`, which is Julia's cooperative model reproduced in Go. Both sides
  calibrate the spinners with all of them running at once: SMT siblings make one spinner alone
  several times faster than eight together.

Latest pass — Ryzen 5 5500, server on 4 cores / 8 logical CPUs, client on the other 2, governor
`powersave`, Julia 1.12.7, HTTP.jl 2.9.0, Go 1.27.1, `GOMAXPROCS=8`, Julia `--threads=8,1`
unless shown, 2026-10-15:

| `/plaintext`, c=50, median of 5 | rps | p99 | RSS at rest → after |
|---|--:|--:|--:|
| Go `net/http` | 236k | 3.5 ms | 8 → 16 MiB |
| Nitro at `--threads=8,0` | 151k | 3.1 ms | 530 → 556 MiB |
| bare HTTP.jl, spawn per request | 110k | 1.4 ms | 480 → 487 MiB |
| Nitro (`--threads=8`, i.e. `8,1`) | 101k | 2.0 ms | 507 → 530 MiB |
| bare HTTP.jl, no spawn | 53k | 2.0 ms | 481 → 483 MiB |

| Task primitive, 8 threads (1 thread) | Go | Julia 1.12 |
|---|--:|--:|
| spawn + wait, one at a time | 0.34 µs (0.32), 144 B | 3.9 µs (1.0), 320 B |
| ping-pong round trip | 0.25 µs (0.25) | 9.2 µs (4.7) |
| fan-out of 1000, per task | 0.18 µs (0.22) | 0.42 µs (0.22) |
| 100,000 parked: create, per task | 1.6 µs | 5.7 µs |
| 100,000 parked: resident memory, per task | 2.7 KiB | 2.9 KiB |
| heartbeat lateness while every thread spins 1.5 s (max) | 20 ms | 1.5 s |
| … Go with `asyncpreemptoff=1` / Julia heartbeat on `:interactive` | 1.2 s | 3 ms |
| … Julia spinners calling `yield()` every 1 ms | — | 3 ms |

What the second table says:

- **Memory per parked task is not the gap.** Julia reserves an 8 MiB stack per task, but it is
  address space: a parked task costs about as much resident memory as a goroutine. The ~500 MiB
  floor of a Julia server is the runtime and the loaded code (#451), not its tasks.
- **Hand-off latency is.** Creating and running tasks in bulk costs the same on one thread (the
  fan-out, 0.22 µs either way). What costs microseconds is a task waiting on another: a spawn +
  wait is 3× Go on one thread and 11× on eight — so most of it there is waking another thread —
  and a `Channel` round trip is 19× Go even on one thread. The 1-thread figures are not from
  `run.sh`; they are `taskset -c 0 julia --project=bench --threads=1,0 bench/tasks/tasks.jl micro`
  and, in `bench/tasks/go/`, `GOMAXPROCS=1 taskset -c 0 go test -run '^$' -bench . -benchmem`.
- **Preemption is the qualitative difference.** With every `:default` thread computing, a Julia
  task on `:default` does not run until one finishes; Go bounds the wait at its ~10 ms time
  slice. Turning Go's preemption off reproduces Julia exactly. The `:interactive` pool and a
  periodic `yield()` are Julia's two ways out (#467). Their 3 ms is mostly the timer, not the
  scheduler: Julia's `sleep` rounds a timer up to the next millisecond and adds one (libuv fires
  early), so the heartbeat wakes about 1 ms late with nothing in its way.

## juliac (compiled executable)

`juliac/` asks whether a Nitro app can be compiled with Julia 1.12's `juliac`, and what stands
between `main` and `--trim=safe` (#570). It is a readiness probe, not a benchmark group:

```bash
bench/juliac/build.sh                                   # untrimmed exe: does HTTP + Reseau + Nitro serve from an image?
bench/juliac/build.sh unsafe-warn                       # the warning list is the trim-readiness backlog
bench/juliac/build.sh safe                              # the goal
bench/juliac/smoke.sh bench/juliac/out/nitro-min-no     # first vs warm /plaintext, RSS, OS threads
bench/juliac/smoke.sh jit                               # the same app under the JIT, as the baseline
```

- `app.jl` is the smallest app the driver can be pointed at: one exact route, no middleware, and
  routes registered at **top level**, so registration (and the reflection it needs) runs in the
  build process while `main` only serves. It is both the compile input and, run as a script, the
  JIT baseline — `@main` runs when the file is the program.
- `build.sh` pins `--project` to `bench/juliac` (the driver compiles the *active* project),
  instantiates it, and logs to `results/juliac-<stamp>-<mode>.log`; the exe lands in `juliac/out/`
  (gitignored).
- `smoke.sh` exports `THREADS` as `JULIA_NUM_THREADS` for the exe — a compiled `main` does not
  parse Julia flags — and reports the OS thread count, which is how you see whether the layout took.
- `JULIA="julia +1.12"` is the default: the driver lives in 1.12's `share/julia/juliac/`.
