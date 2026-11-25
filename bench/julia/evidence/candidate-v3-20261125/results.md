# Measurements of the fair class: master against this PR

Every ratio is a **speed** against its reference: above 1 is faster. Cells show median [min–max] (rounds).
Each column is a fresh process every round, the columns rotated, after one throwaway slot. "master" is the base commit, "master, second build" the same commit built again (the floor), "this PR" the base with the patch, "the bypass" this PR with stock's entry points under master's names and the patch's code compiled in but unreachable. Machine and builds: `environment.md`; raw data: `raw/`.

## a, b. Closed-loop clients starved by newer work, and the mark

**Claim.** 500 clients on `:interactive` each spawn a 2 ms task on `:default` (8 threads) and wait for it, for 8 s. On master the oldest clients starve (a); with each client's task marked (`fair=true`) every client is served and the tail is gone (b). A fair wait is 500 × 2 ms / 8 = 125 ms.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step starved)

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 3008 [2790–3158] (5) | 151.0 [150.9–152.0] (5) |
| least-served client (tasks in 8 s) | 1 [1–1] (5) | 60 [60–60] (5) |
| tasks/s | 3773 [3770–3773] (5) | 3772 [3772–3774] (5) |

Criterion a: master's p99 above 1,000 ms in every round: **PASS**.  Criterion b: this PR's p99 at most 200 ms and every client served, in every round: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| master, p99 (ms) | 3008 | 2942 |
| this PR marked, p99 (ms) | 151.0 | 151.0 |
| this PR marked, least-served client | 60 | 60 |

The same cell: the reproducer keeps only the latencies, where the harness also records each request's timings and checks every task; stock's tail varies by hundreds of ms between runs in both.


## c. Beside unmarked compute, both sides advance

**Claim.** The starved cell while an unmarked fork-join (`fib_fine`, pfib(42) cut at 12) runs on `:default`. With the clients' tasks marked, both advance: the clients' p99 stays bounded and the compute keeps a share of the machine. Compute speed = its wall time alone / its wall time during the cell.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step mixed)

Shape **plain**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 7844 [5522–8067] (5) | 325.6 [324.0–336.9] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–28] (5) |
| compute speed (alone = 1) | 0.094 [0.091–0.097] (4); did not finish in 1 of 5 rounds | 0.565 [0.552–0.567] (5) |

Shape **inner**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 4772 [3830–5366] (5) | 325.0 [324.2–332.9] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–28] (5) |
| compute speed (alone = 1) | 0.099 [0.098–0.100] (2); did not finish in 3 of 5 rounds | 0.548 [0.543–0.556] (5) |

Criterion c: this PR's p99 at most 600 ms and the compute at 0.40 or better, in every round of both shapes: **PASS**.

## d. Behind a real HTTP server

**Claim.** An HTTP.jl server whose handler does 2 ms of compute (`/aggregate`), 500 connections from a closed-loop load generator on other CPUs, 8 s a round, a fresh server each round. With the accepted connections' tasks marked, the tail stays bounded at about the same throughput.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step cell81, cell80)

At **8,1**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 2309 [2174–2569] (5) | 115.9 [114.6–116.5] (5) |
| requests/s | 4910 [4891–4963] (5) | 4874 [4859–4910] (5) |
| throughput speed (master = 1) | 1 | 0.993 [0.983–1.000] (5) |

At **8,0**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 1838 [1674–2134] (5) | 112.8 [111.8–113.6] (5) |
| requests/s | 5102 [5097–5122] (5) | 5046 [5007–5078] (5) |
| throughput speed (master = 1) | 1 | 0.989 [0.982–0.996] (5) |

Criterion d: this PR's p99 at most 150 ms in every round, and its median throughput 0.98 of master's or better, at each layout: **PASS**. (8,1: master's requests/s spread 1.5% between its own rounds; 8,0: master's requests/s spread 0.5% between its own rounds.)

## e. Code that marks nothing pays nothing measurable

**Claim.** With nothing marked, this PR's speed against master lies within the distance between two builds of master itself, or the bypass build (this PR's binary with stock's entry points) stands with it. LAYOUT: the difference cannot be told from building the code differently. THE PATH: it is the patch's unmarked path, with its size in ns an operation.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step floorfib, floorh0)

| cell | master, second build | this PR |
|---|---|---|
| fib_fine, 8,1 | 1.002 [0.985–1.027] (12) | 0.996 [0.981–1.013] (12) |
| spawn path, H = 0, C = 50, 8,0 | 1.011 [1.004–1.019] (12) | 0.994 [0.988–1.005] (12) |
| spawn path, H = 0, C = 500, 8,0 | 1.006 [1.000–1.013] (12) | 0.994 [0.992–0.999] (12) |

| cell | the bypass | this PR against the bypass |
|---|---|---|
| fib_fine, 8,1 | 0.992 [0.971–1.015] (12) | 1.002 [0.994–1.037] (12) |
| spawn path, H = 0, C = 50, 8,0 | 1.008 [0.999–1.015] (12) | 0.988 [0.974–0.998] (12) |
| spawn path, H = 0, C = 500, 8,0 | 1.004 [0.992–1.010] (12) | 0.992 [0.984–1.001] (12) |

- fib_fine, 8,1: LAYOUT: this PR stands within the floor of master's second build (±0.50%).
- spawn path, H = 0, C = 50, 8,0: LAYOUT: this PR stands within the floor of master's second build (±1.06%).
- spawn path, H = 0, C = 500, 8,0: LAYOUT: this PR stands within the floor of master's second build (±0.61%).

Criterion e: every cell LAYOUT: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| fib_fine, this PR against master | 0.996 | 1.004 |

The same pfib(42) cut at 12 in both; the reproducer has 3 rounds and no harness counters, so a difference of a point is within its spread.


## f. The benchmark of JuliaLang/julia#35589

**Claim.** `pfib(25)` as posted in that PR's thread, from one root spawned on `:default`: unmarked, with the root marked, and with every spawn marked. Speed against master's unmarked run.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step pfib2, pfib81)

| speed against master, unmarked | --threads=2 | 8,1 |
|---|---|---|
| this PR, unmarked | 0.999 [0.995–1.005] (6) | 0.997 [0.986–1.017] (6) |
| master, second build | 1.005 [0.999–1.017] (6) | 1.005 [0.997–1.018] (6) |
| the bypass, unmarked | 1.003 [0.987–1.014] (6) | 1.008 [0.999–1.013] (6) |
| this PR, root marked | 0.886 [0.881–0.896] (6) | 0.889 [0.880–0.900] (6) |
| this PR, every spawn marked | 0.404 [0.400–0.413] (6) | 0.396 [0.390–0.411] (6) |

Criterion f: unmarked not slower than master by more than the floor (one-sided: max(|second build − 1|, 0.5%)), and the root marked at 0.90 or better in every round; every spawn marked is reported with no bar. --threads=2: unmarked not slower than the floor (-0.06%, floor −0.50%), the bypass at 1.003, root marked **FAIL**; 8,1: unmarked not slower than the floor (-0.28%, floor −0.53%), the bypass at 1.008, root marked **FAIL**. Overall: **FAIL**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| unmarked, --threads=2 | 0.999 | 0.993 |
| root marked | 0.886 | 0.878 |
| every spawn marked | 0.404 | 0.408 |

The same program; the harness times it with BenchmarkTools for 4 s, the reproducer with its own loop for 4 s.


## g. The cost with everything marked

**Claim.** The spawn path itself (closed-loop clients on `:default` spawning tasks, 8,0), with the clients and every task they spawn marked. Speed against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step spawnpath)

| cell | master, requests/s | this PR marked, speed |
|---|---|---|
| C = 50 | 3151894 [3147230–3163675] (6) | 0.819 [0.817–0.825] (6) |
| C = 500 | 3264020 [3234621–3269491] (6) | 0.816 [0.812–0.823] (6) |

Criterion g: speed 0.80 or better in every round: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| C = 50, this PR marked against master | 0.819 | 0.777 |
| C = 500, this PR marked against master | 0.816 | 0.777 |

The harness's handler also stamps and records each request, so the scheduler's share of a request is smaller there; the reproducer's tasks do nothing but notify, so the mark's fixed cost weighs more.


## h. What unmarked code pays once a program has marked something

**Claim.** `fib_fine` at 8,1 with nothing marked, in a process that first ran one task with `fair=true` (the scheduler's pool flag is then set for good), against the same build with nothing ever marked, and against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step arm)

|  | against this PR, never marked | against master |
|---|---|---|
| this PR, never marked | 1 | 0.995 [0.981–1.006] (6) |
| this PR, after one marked task | 0.939 [0.927–0.972] (6) | 0.934 [0.930–0.957] (6) |

Row h is a stated cost, with no bar: after one marked task, unmarked work runs 6.1% slower than on the same build never marked (rounds 2.8% to 7.3%). Earlier runs read 2.6% (2026-11-22/23, on master's port), 3.1% (the candidate, 2026-11-24) and 4.0% (v2, 2026-11-25).

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| after one marked task, against never marked | 0.939 | 0.938 |

The same work; the reproducer arms the flag by one `fair=true` spawn in the measured process, the harness by one marked task at load, and its 3 rounds spread wider.


## i. Julia's tests

**Claim.** The test sets the change touches, on master and on this PR, nothing marked: the same counts. The new tests run inside `threads_exec.jl`, which `threads` runs in a subprocess at five thread layouts; their own assertions are not in these totals.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step tests)

| build | core, threads, channels, channel_threadpool, threadpool_use, threadpool_latency, cancellation | result |
|---|---|---|
| master | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |
| this PR | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |


## v2 against v3, row by row

Medians of each run (`candidate-v2-20261124` and this one). **They are different runs**, on different days, each against its own rounds of master: a difference here is between runs, not a measurement of one build against another.

| row | measure | v2 | v3 |
|---|---|---|---|
| a | master p99 (ms) | 3142 | 3008 |
| b | marked p99 (ms) | 151.0 | 151.0 |
| b | least-served client | 60 | 60 |
| c | plain p99 (ms) | 328.0 | 325.6 |
| c | plain compute speed | 0.560 | 0.565 |
| c | inner p99 (ms) | 327.1 | 325.0 |
| c | inner compute speed | 0.555 | 0.548 |
| d | 8,1 p99 (ms) | 115.8 | 115.9 |
| d | 8,1 throughput speed | 0.990 | 0.993 |
| d | 8,0 p99 (ms) | 111.7 | 112.8 |
| d | 8,0 throughput speed | 0.990 | 0.989 |
| e | fib_fine, 8,1: unmarked against master | 1.011 | 0.996 |
| e | fib_fine, 8,1: master's second build | 1.011 | 1.002 |
| e | fib_fine, 8,1: unmarked against the bypass | 0.995 | 1.002 |
| e | H = 0, C = 50, 8,0: unmarked against master | 1.001 | 0.994 |
| e | H = 0, C = 50, 8,0: master's second build | 1.012 | 1.011 |
| e | H = 0, C = 50, 8,0: unmarked against the bypass | 1.009 | 0.988 |
| e | H = 0, C = 500, 8,0: unmarked against master | 0.999 | 0.994 |
| e | H = 0, C = 500, 8,0: master's second build | 1.009 | 1.006 |
| e | H = 0, C = 500, 8,0: unmarked against the bypass | 1.009 | 0.992 |
| f | --threads=2 unmarked | 1.012 | 0.999 |
| f | --threads=2 root marked | 0.946 | 0.886 |
| f | --threads=2 every spawn marked | 0.435 | 0.404 |
| f | 8,1 unmarked | 1.012 | 0.997 |
| f | 8,1 root marked | 0.909 | 0.889 |
| f | 8,1 every spawn marked | 0.393 | 0.396 |
| g | C = 50 marked | 0.843 | 0.819 |
| g | C = 500 marked | 0.839 | 0.816 |
| h | after one marked task, against never marked | 0.960 | 0.939 |
| h | after one marked task, against master | 0.975 | 0.934 |


## Standalone reproducers

Single files in `bench/julia/candidate/`, standard library only, each run as `julia --threads=<layout> <file>.jl [args]` on both builds, a fresh process a round, pinned as the cells. A marked mode on master prints that the keyword is not there.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step repro, repro_gh)

| reproducer (row) | master | this PR |
|---|---|---|
| `starved.jl` p99 (ms), stock order (a) | 2942 [2934–3079] (3) | 2914 [2607–3121] (3) |
| `starved.jl fair` p99 (ms), marked (b) | not supported | 151.0 [150.0–151.0] (3) |
| `starved.jl fair` least-served client (b) | not supported | 60 [60–60] (3) |
| `fib_fine.jl` median wall (s) (e) | 0.7929 [0.7886–0.8020] (3) | 0.7900 [0.7891–0.7921] (3) |
| `pfib.jl none` at --threads=2, median (s) (f) | 0.0566 [0.0566–0.0568] (3) | 0.0570 [0.0567–0.0571] (3) |
| `pfib.jl root`, median (s) (f) | not supported | 0.0644 [0.0636–0.0645] (3) |
| `pfib.jl all`, median (s) (f) | not supported | 0.1386 [0.1378–0.1406] (3) |
| `spawn_path.jl plain 50` requests/s (g) | 3876481 [3829192–3879037] (3) | 3836418 [3835228–3851406] (3) |
| `spawn_path.jl fair 50` requests/s (g) | not supported | 3010175 [2970799–3020569] (3) |
| `spawn_path.jl plain 500` requests/s (g) | 3882032 [3856971–3885097] (3) | 3833790 [3823157–3881713] (3) |
| `spawn_path.jl fair 500` requests/s (g) | not supported | 3014597 [3014446–3016303] (3) |
| `armed.jl` median wall (s), never marked (h) | 0.7887 [0.7855–0.7920] (3) | 0.7910 [0.7835–0.8044] (3) |
| `armed.jl armed` median wall (s), one task marked first (h) | not supported | 0.8437 [0.8346–0.8440] (3) |


## The description's reproducer

`bench/julia/candidate/mwe.jl` at `--threads=8,1`: once on master as it is, once on this PR with the client's spawn marked (`fair=true`).

master:

```
1.15.0-DEV.974  threads 8,1  tasks/s 3821  fair wait ≈ 125.0 ms
latency ms: p50 15.0  p99 2906.9  max 7295.0
tasks per client: min 2  median 58  max 174
```

this PR, `fair=true`:

```
1.15.0-DEV.976  threads 8,1  tasks/s 3802  fair wait ≈ 125.0 ms
latency ms: p50 131.0  p99 169.0  max 217.0
tasks per client: min 58  median 61  max 63
```

