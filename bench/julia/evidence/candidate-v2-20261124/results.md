# Measurements of the fair class: master against this PR

Every ratio is a **speed** against its reference: above 1 is faster. Cells show median [min–max] (rounds).
Each column is a fresh process every round, the columns rotated, after one throwaway slot. "master" is the base commit, "master, second build" the same commit built again (the floor), "this PR" the base with the patch, "the bypass" this PR with stock's entry points under master's names and the patch's code compiled in but unreachable. Machine and builds: `environment.md`; raw data: `raw/`.

## a, b. Closed-loop clients starved by newer work, and the mark

**Claim.** 500 clients on `:interactive` each spawn a 2 ms task on `:default` (8 threads) and wait for it, for 8 s. On master the oldest clients starve (a); with each client's task marked (`fair=true`) every client is served and the tail is gone (b). A fair wait is 500 × 2 ms / 8 = 125 ms.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step starved)

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 3142 [2894–3388] (5) | 151.0 [150.0–151.4] (5) |
| least-served client (tasks in 8 s) | 1 [1–1] (5) | 60 [60–60] (5) |
| tasks/s | 3773 [3772–3773] (5) | 3772 [3771–3774] (5) |

Criterion a: master's p99 above 1,000 ms in every round: **PASS**.  Criterion b: this PR's p99 at most 200 ms and every client served, in every round: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| master, p99 (ms) | 3142 | 2878 |
| this PR marked, p99 (ms) | 151.0 | 159.0 |
| this PR marked, least-served client | 60 | 60 |

The same cell: the reproducer keeps only the latencies, where the harness also records each request's timings and checks every task; stock's tail varies by hundreds of ms between runs in both.


## c. Beside unmarked compute, both sides advance

**Claim.** The starved cell while an unmarked fork-join (`fib_fine`, pfib(42) cut at 12) runs on `:default`. With the clients' tasks marked, both advance: the clients' p99 stays bounded and the compute keeps a share of the machine. Compute speed = its wall time alone / its wall time during the cell.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step mixed)

Shape **plain**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 6881 [5656–8091] (5) | 328.0 [326.0–335.5] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–28] (5) |
| compute speed (alone = 1) | did not finish in any of 5 rounds | 0.560 [0.558–0.577] (5) |

Shape **inner**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 4747 [4449–5006] (5) | 327.1 [322.0–331.4] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–28] (5) |
| compute speed (alone = 1) | 0.100 [0.100–0.102] (4); did not finish in 1 of 5 rounds | 0.555 [0.543–0.562] (5) |

Criterion c: this PR's p99 at most 600 ms and the compute at 0.40 or better, in every round of both shapes: **PASS**.

## d. Behind a real HTTP server

**Claim.** An HTTP.jl server whose handler does 2 ms of compute (`/aggregate`), 500 connections from a closed-loop load generator on other CPUs, 8 s a round, a fresh server each round. With the accepted connections' tasks marked, the tail stays bounded at about the same throughput.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step cell81, cell80)

At **8,1**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 2263 [2148–2484] (5) | 115.8 [115.1–116.0] (5) |
| requests/s | 4951 [4907–4961] (5) | 4868 [4863–4903] (5) |
| throughput speed (master = 1) | 1 | 0.990 [0.980–0.999] (5) |

At **8,0**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 1849 [1712–2186] (5) | 111.7 [110.9–112.8] (5) |
| requests/s | 5120 [5101–5138] (5) | 5060 [5037–5088] (5) |
| throughput speed (master = 1) | 1 | 0.990 [0.983–0.995] (5) |

Criterion d: this PR's p99 at most 150 ms in every round, and its median throughput 0.98 of master's or better, at each layout: **PASS**. (8,1: master's requests/s spread 1.1% between its own rounds; 8,0: master's requests/s spread 0.7% between its own rounds.)

## e. Code that marks nothing pays nothing measurable

**Claim.** With nothing marked, this PR's speed against master lies within the distance between two builds of master itself, or the bypass build (this PR's binary with stock's entry points) stands with it. LAYOUT: the difference cannot be told from building the code differently. THE PATH: it is the patch's unmarked path, with its size in ns an operation.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step floorfib, floorh0)

| cell | master, second build | this PR |
|---|---|---|
| fib_fine, 8,1 | 1.011 [0.987–1.034] (12) | 1.011 [0.977–1.039] (12) |
| spawn path, H = 0, C = 50, 8,0 | 1.012 [0.995–1.020] (12) | 1.001 [0.981–1.012] (12) |
| spawn path, H = 0, C = 500, 8,0 | 1.009 [1.001–1.015] (12) | 0.999 [0.992–1.006] (12) |

| cell | the bypass | this PR against the bypass |
|---|---|---|
| fib_fine, 8,1 | 1.020 [1.002–1.036] (12) | 0.995 [0.975–1.012] (12) |
| spawn path, H = 0, C = 50, 8,0 | 0.991 [0.982–0.998] (12) | 1.009 [0.990–1.022] (12) |
| spawn path, H = 0, C = 500, 8,0 | 0.992 [0.987–0.998] (12) | 1.009 [0.995–1.012] (12) |

- fib_fine, 8,1: LAYOUT: the bypass stands with this PR (-0.52% against ±1.12%).
- spawn path, H = 0, C = 50, 8,0: LAYOUT: this PR stands within the floor of master's second build (±1.24%).
- spawn path, H = 0, C = 500, 8,0: LAYOUT: this PR stands within the floor of master's second build (±0.89%).

Criterion e: every cell LAYOUT: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| fib_fine, this PR against master | 1.011 | 1.000 |

The same pfib(42) cut at 12 in both; the reproducer has 3 rounds and no harness counters, so a difference of a point is within its spread.


## f. The benchmark of JuliaLang/julia#35589

**Claim.** `pfib(25)` as posted in that PR's thread, from one root spawned on `:default`: unmarked, with the root marked, and with every spawn marked. Speed against master's unmarked run.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step pfib2, pfib81)

| speed against master, unmarked | --threads=2 | 8,1 |
|---|---|---|
| this PR, unmarked | 1.012 [0.995–1.014] (6) | 1.012 [0.994–1.043] (6) |
| master, second build | 1.011 [0.995–1.019] (6) | 1.000 [0.983–1.026] (6) |
| the bypass, unmarked | 1.010 [1.002–1.017] (6) | 0.995 [0.969–1.021] (6) |
| this PR, root marked | 0.946 [0.934–0.952] (6) | 0.909 [0.906–0.927] (6) |
| this PR, every spawn marked | 0.435 [0.426–0.448] (6) | 0.393 [0.390–0.397] (6) |

Criterion f: unmarked within the floor, and the root marked at 0.90 or better in every round; every spawn marked is reported with no bar. --threads=2: unmarked outside the floor (+1.17% against ±1.05%), the bypass at 1.010, root marked **PASS**; 8,1: unmarked outside the floor (+1.17% against ±0.50%), the bypass at 0.995, root marked **PASS**. Overall: **FAIL**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| unmarked, --threads=2 | 1.012 | 1.012 |
| root marked | 0.946 | 0.945 |
| every spawn marked | 0.435 | 0.438 |

The same program; the harness times it with BenchmarkTools for 4 s, the reproducer with its own loop for 4 s.


## g. The cost with everything marked

**Claim.** The spawn path itself (closed-loop clients on `:default` spawning tasks, 8,0), with the clients and every task they spawn marked. Speed against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step spawnpath)

| cell | master, requests/s | this PR marked, speed |
|---|---|---|
| C = 50 | 3141394 [3128275–3164183] (6) | 0.843 [0.833–0.849] (6) |
| C = 500 | 3245714 [3239705–3248886] (6) | 0.839 [0.830–0.843] (6) |

Criterion g: speed 0.80 or better in every round: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| C = 50, this PR marked against master | 0.843 | 0.807 |
| C = 500, this PR marked against master | 0.839 | 0.810 |

The harness's handler also stamps and records each request, so the scheduler's share of a request is smaller there; the reproducer's tasks do nothing but notify, so the mark's fixed cost weighs more.


## h. What unmarked code pays once a program has marked something

**Claim.** `fib_fine` at 8,1 with nothing marked, in a process that first ran one task with `fair=true` (the scheduler's pool flag is then set for good), against the same build with nothing ever marked, and against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step arm)

|  | against this PR, never marked | against master |
|---|---|---|
| this PR, never marked | 1 | 1.026 [1.008–1.042] (6) |
| this PR, after one marked task | 0.960 [0.935–0.972] (6) | 0.975 [0.961–1.006] (6) |

Criterion h: after one marked task, speed 0.965 or better against the same build never marked, in every round: **FAIL**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| after one marked task, against never marked | 0.960 | 0.947 |

The same work; the reproducer arms the flag by one `fair=true` spawn in the measured process, the harness by one marked task at load, and its 3 rounds spread wider.


## i. Julia's tests

**Claim.** The test sets the change touches, on master and on this PR, nothing marked: the same counts. The new tests run inside `threads_exec.jl`, which `threads` runs in a subprocess at five thread layouts; their own assertions are not in these totals.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step tests)

| build | core, threads, channels, channel_threadpool, threadpool_use, threadpool_latency, cancellation | result |
|---|---|---|
| master | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |
| this PR | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |


## Standalone reproducers

Single files in `bench/julia/candidate/`, standard library only, each run as `julia --threads=<layout> <file>.jl [args]` on both builds, a fresh process a round, pinned as the cells. A marked mode on master prints that the keyword is not there.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step repro, repro_gh)

| reproducer (row) | master | this PR |
|---|---|---|
| `starved.jl` p99 (ms), stock order (a) | 2878 [2782–2952] (3) | 2879 [2778–2894] (3) |
| `starved.jl fair` p99 (ms), marked (b) | not supported | 159.0 [153.0–162.0] (3) |
| `starved.jl fair` least-served client (b) | not supported | 60 [59–60] (3) |
| `fib_fine.jl` median wall (s) (e) | 0.7995 [0.7942–0.8080] (3) | 0.7996 [0.7842–0.8002] (3) |
| `pfib.jl none` at --threads=2, median (s) (f) | 0.0576 [0.0573–0.0577] (3) | 0.0569 [0.0565–0.0574] (3) |
| `pfib.jl root`, median (s) (f) | not supported | 0.0610 [0.0607–0.0615] (3) |
| `pfib.jl all`, median (s) (f) | not supported | 0.1315 [0.1310–0.1317] (3) |
| `spawn_path.jl plain 50` requests/s (g) | 3839933 [3825045–3847620] (3) | 3828024 [3823824–3831163] (3) |
| `spawn_path.jl fair 50` requests/s (g) | not supported | 3097427 [3084357–3112529] (3) |
| `spawn_path.jl plain 500` requests/s (g) | 3846673 [3828648–3870741] (3) | 3817352 [3811418–3841603] (3) |
| `spawn_path.jl fair 500` requests/s (g) | not supported | 3114772 [3109520–3115662] (3) |
| `armed.jl` median wall (s), never marked (h) | 0.7888 [0.7876–0.8200] (3) | 0.7818 [0.7809–0.7838] (3) |
| `armed.jl armed` median wall (s), one task marked first (h) | not supported | 0.8255 [0.8220–0.8273] (3) |


## The description's reproducer

`bench/julia/candidate/mwe.jl` at `--threads=8,1`: once on master as it is, once on this PR with the client's spawn marked (`fair=true`).

master:

```
1.15.0-DEV.974  threads 8,1  tasks/s 3820  fair wait ≈ 125.0 ms
latency ms: p50 15.0  p99 2958.0  max 7515.0
tasks per client: min 3  median 55  max 169
```

this PR, `fair=true`:

```
1.15.0-DEV.976  threads 8,1  tasks/s 3796  fair wait ≈ 125.0 ms
latency ms: p50 132.0  p99 159.7  max 186.0
tasks per client: min 59  median 61  max 63
```


## Variant, not part of this PR: the clock is `time_ns()` everywhere

The candidate with `time_ns()` in place of the cycle counter on every platform (no calibration, no architecture branch, one cap), measured beside the candidate in steps of its own (`tstarved`, `tmixed`, `tspawnpath`, `tarm`, `tfloorfib`, `tfloorh0`). Speeds against master unless said.

| starved cell (b) | this PR, marked | variant, marked |
|---|---|---|
| p99 latency (ms) | 151.0 [150.0–151.3] (6) | 151.0 [150.7–152.0] (6) |
| least-served client | 60 [60–60] (6) | 60 [60–60] (6) |

| mixed cell, plain (c) | this PR, marked | variant, marked |
|---|---|---|
| clients' p99 latency (ms) | 327.6 [327.0–336.5] (6) | 331.5 [327.7–338.5] (6) |
| compute speed (alone = 1) | 0.557 [0.550–0.571] (6) | 0.560 [0.554–0.576] (6) |

| mixed cell, inner (c) | this PR, marked | variant, marked |
|---|---|---|
| clients' p99 latency (ms) | 326.2 [319.0–331.0] (6) | 321.4 [320.0–330.7] (6) |
| compute speed (alone = 1) | 0.556 [0.544–0.573] (6) | 0.559 [0.555–0.569] (6) |

| spawn path, everything marked (g) | this PR | variant |
|---|---|---|
| C = 50 | 0.843 [0.838–0.846] (6) | 0.827 [0.822–0.830] (6) |
| C = 500 | 0.837 [0.829–0.842] (6) | 0.823 [0.819–0.833] (6) |

| fib_fine after one marked task (h) | this PR | variant |
|---|---|---|
| against the same build never marked | 0.950 [0.916–0.965] (6) | 0.949 [0.931–0.965] (6) |

| nothing marked (e) | this PR | variant |
|---|---|---|
| fib_fine, 8,1 (master's second build: 1.009) | 1.019 [0.998–1.032] (6) | 1.000 [0.984–1.007] (6) |
| H = 0, C = 50, 8,0 (master's second build: 1.010) | 0.998 [0.987–1.013] (6) | 1.000 [0.990–1.007] (6) |
| H = 0, C = 500, 8,0 (master's second build: 1.011) | 0.997 [0.992–1.006] (6) | 1.002 [0.998–1.005] (6) |

