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
│   ├── claims.jl       # a Claims{T} bind against two untyped getprincipal reads (#527)
│   ├── taskpattern.jl  # SYNTHETIC replica of parallel_stream_handler's task overhead
│   ├── httpparse.jl    # HTTP.jl's request-head parse on the connection task
│   ├── holds.jl        # how long one large JSON / multipart / file call holds its thread (#588)
│   ├── passwords.jl    # one check_password at the default pbkdf2 and bcrypt costs (#587)
│   └── aggregate.jl    # the /aggregate kernel alone: sum, mean, groupby at N = 10^3..10^7 (#590)
├── socket/             # real-socket load: server.jl (Nitro vs bare HTTP.jl), run.sh, contention.sh, stall.sh, wake.sh (oha)
│   └── go/             # the Go net/http reference server run.sh's `go` mode builds; `go test -bench Aggregate`
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
- `NITRO_BENCH_GROUPS="holds passwords"` — run only these groups (one per `suite/` file, named
  after it); an unknown name is an error. A group left out is not even included, so a run of
  `json` alone does not build `holds`' 100 MiB file. Default: every group.

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

- `holds/*` and `passwords/*` (#588, #587) ask how long ONE call holds its `:default` thread, which
  Julia never preempts (#467): run them at `--threads=1`, and read the minimum against the ~1 ms
  the issue treats as "nothing to do". Sizes are nominal (the JSON rows are ~40 bytes each). The
  JSON parse rows pass `max_fields = 0`, because at the default field cap (1000 keys) a 100 KB
  array of three-key rows is refused before it is parsed; that is the configuration an app that
  accepts such bodies runs. `file_100mib_stream_read` is the read side of the streamed write loop
  only: on a socket each 64 KiB chunk's write is where the task can give its thread up, so the
  hold that matters there is the total divided by 1,600 chunks.

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
bench/socket/stall.sh "nitro nitro@8,0 go" 3 6s      # /plaintext while K handlers compute (#467)
VARIANTS="login login_bcrypt" bench/socket/stall.sh "nitro go" 3 6s   # ... while K check a password (#587)
AGG_ROWS=10000000 ROUTE_MS=115 VARIANTS="route:/aggregate?n=10000000&op=groupby" \
  bench/socket/stall.sh "nitro go" 3 8s                                # ... while K aggregate (#590)
bench/socket/night2.sh                               # the #587/#588/#590 night run, unattended
bench/socket/wake.sh 3                               # does a parked handler wake while K yield? (#598)
```

- `server.jl` serves `/plaintext`, `/json`, `/health`, `/cpu` and `/lag` in one of these `MODE`s:
  `nitro` (`serve()` with no middleware), `nitro_log` (the same with the access log on),
  `bare_spawn` (HTTP.jl `listen!` + `streamhandler` with a `Threads.@spawn` per request, the shape
  Nitro takes and the ceiling to compare it with), `bare_nospawn` (the handler on HTTP.jl's
  connection task), and `bare_pool` (`bare_spawn` with the spawn replaced by `POOL` long-lived
  tasks, default `nthreads(:default)`, fed by a `Channel`: no task created per request, #468). `/cpu` burns `CPU_MS` (default 50) without yielding; `/lag` is live only with
  `LAG=1`. `/cpu_yield` burns the same but calls `yield()` every `YIELD_MS` (default 2).
  `WORKERS=1` adds `/burst?n=K` to the Nitro modes, which submits K Workers jobs that each burn
  `JOB_MS` (default 500), and `/cpu_job`, which submits one `/cpu` of work to a queue of
  concurrency `BURST_K` and answers `202` (a full queue answers `503`); `/jobs` counts the
  `/cpu_job` jobs not yet finished. `LOGIN=1` adds `/login` and `/login_bcrypt` to the Nitro
  modes: one `Nitro.Auth.check_password` per request against a pbkdf2_sha256 or bcrypt hash minted
  at startup at the default cost, answering a fixed `ok` (#587). `AGG_ROWS=<n>` builds `n` rows at
  startup and serves `/aggregate?n=<N>&op=<sum|mean|groupby>` in every mode, Go included (#590): a
  plain loop over the first N rows (`socket/aggregate.jl`, mirrored line for line in
  `socket/go/aggregate.go`; both generate the same rows from one splitmix64 seed), and with
  `WORKERS=1` `&queue=1` sends it to the `/cpu_job` queue instead. `HOLDS=1` adds the two largest
  holds of #588's inventory as routes: `GET /hold/json` (`Res.json` of a ~12 MB untyped value) and
  `POST /hold/multipart` (`getfiles` of the request body; `socket/multipart_body.jl` writes a 64 MiB
  one). `/gc` answers every field of `Base.gc_num()`.
- `run.sh` pins the server (`-t 8`) and the load generator to disjoint physical cores, warms each
  route, and reports the median, min and max of N runs plus the median p99. The default CPU sets
  assume a 6-core part whose SMT siblings are `n` and `n+6`; set `SERVER_CPUS`/`CLIENT_CPUS` for
  another layout. Results go to `results/socket-<stamp>.tsv`, profiles to
  `results/profile-<mode>-<time>-{flat,threads,interactive-tree,sched}.txt`. `sched` is the share of
  each pool's awake samples whose leaf-most deciding frame is task machinery (Base's `task.jl`,
  `partr.jl`, …, the runtime's `task.c`, `scheduler.c`, …) or GC (allocation and waiting for a
  collection included), with sleeping samples counted apart. A libc or libuv frame decides
  nothing, so a thread wake-up's `pthread_cond_signal` counts as `scheduler.c`. Threads that run
  no tasks, the parallel GC's and the I/O poller's, are counted apart too. It is an upper bound on
  task overhead, since a thread spinning for work counts too. `interactive-tree` is a call tree
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
- Pool against spawn (#468), on the box and versions of the *Comparing with Go* tables below,
  in a run of its own: `bare_pool` served 93k `/plaintext`
  requests per second against `bare_spawn`'s 112k at `--threads=8` (p99 2.8 ms against 1.2 ms),
  and 153k against 168k at `8,0`. Under the profiler, creating the per-request task is about 8% of
  the interactive thread at `8,1`; waking a default thread for it is twice that, and a pool's
  hand-off pays the wake too. The conclusion is recorded beside `parallel_stream_handler` in
  `src/core/transport.jl`.
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
- `stall.sh [modes] [rounds] [duration]` keeps K requests computing `CPU_MS` (default 200) in
  flight while `CONNS` connections saturate `/plaintext`, and reports `/plaintext`'s throughput
  and p50/p99 for each K in `KS`: how few computing handlers it takes to stall the server (#467).
  `VARIANTS` runs the same work as `cpu` (in the handler), `cpu_yield` and `cpu_job` (a Workers
  queue, offered at the rate that would keep K busy and drained between passes); the `load_2xx`
  column is the share of those submissions the queue accepted. `login` and `login_bcrypt` keep K
  password checks in flight instead, and start the servers with `LOGIN=1`; Nitro bounds those
  checks itself since #587, and `PASSWORD_CONCURRENCY=0` in the environment turns the bound off
  for an A/B. `route:<target>` keeps K requests of any route in flight (`route:<target>@<file>`
  POSTs `<file>` with `ROUTE_CT`); a target with `queue=1` is offered at a rate like `cpu_job`.
  `ROUTE_MS` is one request's cost. `KEEP_JSON=1` keeps every oha report under
  `results/stall-<stamp>-raw/`. Modes are `nitro`,
  `nitro@N,M` and `go`, which runs `cpu` only. The latest table is in the deployment guide's *Handlers that
  compute*.
- `wake.sh [rounds]` asks whether a handler parked on a `Timer` wakes while every default thread
  runs a `yield()`ing handler: `LAG=1`'s probe is the parked task, K = 8 requests of `/cpu_yield`
  (`SPIN_MS`, default 1500) the yielding ones, and `/lag`'s max is the answer, with and without
  `/plaintext` traffic beside them. Each of `CONFIGS` is `<juliaup channel>/<PARK>/<GUARD>`
  (`server.jl`'s two knobs): `event/0` is a server with no `Timer` of the bench's own, the shape
  JuliaLang/julia#63882 stalls on 1.13.0-rc3..1.13.2 (#586). Since #598 `serve()` holds the guard
  itself on those versions, so `event/0` there measures that guard; run it against an older
  checkout's `src/` to see the stall.
- `JULIA="julia +1.12"` runs the servers on another juliaup channel. Each Julia minor wants its
  own resolved manifest; `bench/Manifest-v1.12.toml` (gitignored) is the one 1.12 reads first, so
  copy `Manifest.toml` to it and `Pkg.resolve()` under 1.12 once.
- Compare modes **within one run**, not across days: the CPU governor and anything else on the box
  move absolute numbers by tens of percent. Requires `oha`, `jq`, `curl` and `taskset`.
- `KEEP_JSON=1` makes `run.sh` keep every measured oha report (p99.9 and the histogram are in it)
  under `results/socket-<stamp>-raw/`, and `GC_SNAPSHOTS=1` records each server's GC counters
  around every run in `socket-<stamp>-gc.tsv`: a Julia mode's `/gc`, a Go mode's log line count,
  which with `GODEBUG=gctrace=1` is one line per collection. `socket/gc_tail.jl <stem>` sets each
  run's p99/p99.9 against those deltas (#590).
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

| Task primitive, 8 threads (1 thread) | Go | Julia 1.12 | Julia 1.13.2 |
|---|--:|--:|--:|
| spawn + wait, one at a time | 0.34 µs (0.32), 144 B | 3.9 µs (1.0), 320 B | 1.35–1.42 µs (1.1), 320 B |
| ping-pong round trip | 0.25 µs (0.25) | 9.2 µs (4.7) | 8.2–8.7 µs (4.6) |
| fan-out of 1000, per task | 0.18 µs (0.22) | 0.42 µs (0.22) | 0.41–0.46 µs (0.21) |
| 100,000 parked: create, per task | 1.6 µs | 5.7 µs | 5.1–5.4 µs |
| 100,000 parked: resident memory, per task | 2.7 KiB | 2.9 KiB | 2.95 KiB |
| heartbeat lateness while every thread spins 1.5 s (max) | 20 ms | 1.5 s | 1.25–1.48 s |
| … Go with `asyncpreemptoff=1` / Julia heartbeat on `:interactive` | 1.2 s | 3 ms | 2.3–4.9 ms |
| … Julia spinners calling `yield()` every 1 ms | — | 3 ms | **1.4–2.2 s** (#586) |

The Julia 1.13.2 column is a second pass on the same box, 2026-10-16: each 8-thread cell is the
range over four `run.sh` runs, in which Go stayed within 0.5%. Its 1-thread figures are the
minimum of two rounds of the `micro` command below, interleaved with 1.12, whose own figures
repeated the column beside it.

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
- **1.13.2 makes waking another thread cheaper, and breaks one of those ways out.** Spawn + wait
  at eight threads is 2.4× cheaper than on 1.12 in every run (still 4× Go), while the 1-thread
  figures do not move, so the gain is in the cross-thread wake. But spinners that call `yield()`
  every 1 ms no longer let a timer-woken task run: the heartbeat is about as late as with no
  yield at all. A 30-line repro without Nitro shows the same thing on 1.13.1 and 1.13.2, and not on 1.12.7
  or master. It is tracked in #586; the `:interactive` row is unaffected.
- **That 1.13 row is a Julia bug, reported as
  [JuliaLang/julia#63882](https://github.com/JuliaLang/julia/issues/63882).** It begins at
  1.13.0-rc3, with the scheduler backports in JuliaLang/julia#62665 (rc2 does not stall), and it
  needs the sleeper's own `Timer` to be the only live libuv handle in the process: any second live
  `Timer`, even one that never fires, removes it. That is why `socket/server.jl`, which parks its
  main task in `wait(Timer(typemax(Int32)))`, never showed it, and why `stall.sh` cannot be used to
  look for it. `wake.sh` can: a Nitro server with no other timer stalled the same way on 1.13.2,
  which is why `serve()` now holds such a guard on those versions (#598). Until a fixed 1.13.x
  ships, compare this row only across versions, never as a property of `yield()`.

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
