# Measurements of the fair class: master against this PR

Every ratio is a **speed** against its reference: above 1 is faster. Cells show median [min–max] (rounds).
Each column is a fresh process every round, the columns rotated, after one throwaway slot. "master" is the base commit, "master, second build" the same commit built again (the floor), "this PR" the base with the patch, "the bypass" this PR with stock's entry points under master's names and the patch's code compiled in but unreachable. Machine and builds: `environment.md`; raw data: `raw/`.

## a, b. Closed-loop clients starved by newer work, and the mark

**Claim.** 500 clients on `:interactive` each spawn a 2 ms task on `:default` (8 threads) and wait for it, for 8 s. On master the oldest clients starve (a); with each client's task marked (`fair=true`) every client is served and the tail is gone (b). A fair wait is 500 × 2 ms / 8 = 125 ms.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step starved)

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 3234 [2806–3600] (5) | 151.0 [150.9–152.0] (5) |
| least-served client (tasks in 8 s) | 1 [1–1] (5) | 60 [60–60] (5) |
| tasks/s | 3773 [3772–3775] (5) | 3773 [3772–3774] (5) |

Criterion a: master's p99 above 1,000 ms in every round: **PASS**.  Criterion b: this PR's p99 at most 200 ms and every client served, in every round: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| master, p99 (ms) | 3234 | 3096 |
| this PR marked, p99 (ms) | 151.0 | 153.0 |
| this PR marked, least-served client | 60 | 60 |

The same cell: the reproducer keeps only the latencies, where the harness also records each request's timings and checks every task; stock's tail varies by hundreds of ms between runs in both.


## c. Beside unmarked compute, both sides advance

**Claim.** The starved cell while an unmarked fork-join (`fib_fine`, pfib(42) cut at 12) runs on `:default`. With the clients' tasks marked, both advance: the clients' p99 stays bounded and the compute keeps a share of the machine. Compute speed = its wall time alone / its wall time during the cell.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step mixed)

Shape **plain**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 6582 [5496–7677] (5) | 329.1 [327.1–332.6] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–28] (5) |
| compute speed (alone = 1) | 0.093 [0.092–0.095] (2); did not finish in 3 of 5 rounds | 0.549 [0.548–0.560] (5) |

Shape **inner**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 4033 [2721–4863] (5) | 327.4 [322.0–329.0] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–29] (5) |
| compute speed (alone = 1) | 0.097 [0.095–0.100] (2); did not finish in 3 of 5 rounds | 0.548 [0.540–0.558] (5) |

Criterion c: this PR's p99 at most 600 ms and the compute at 0.40 or better, in every round of both shapes: **PASS**.

## d. Behind a real HTTP server

**Claim.** An HTTP.jl server whose handler does 2 ms of compute (`/aggregate`), 500 connections from a closed-loop load generator on other CPUs, 8 s a round, a fresh server each round. With the accepted connections' tasks marked, the tail stays bounded at about the same throughput.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step cell81, cell80)

At **8,1**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 2292 [2110–2454] (5) | 114.1 [113.1–114.4] (5) |
| requests/s | 4874 [4804–4945] (5) | 4960 [4934–4963] (5) |
| throughput speed (master = 1) | 1 | 1.018 [1.001–1.032] (5) |

At **8,0**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 1927 [1895–2208] (5) | 111.4 [111.2–111.7] (5) |
| requests/s | 5033 [5024–5039] (5) | 5099 [5073–5110] (5) |
| throughput speed (master = 1) | 1 | 1.014 [1.008–1.016] (5) |

Criterion d: this PR's p99 at most 150 ms in every round, and its median throughput 0.98 of master's or better, at each layout: **PASS**. (8,1: master's requests/s spread 2.9% between its own rounds; 8,0: master's requests/s spread 0.3% between its own rounds.)

## e. Code that marks nothing pays nothing measurable

**Claim.** With nothing marked, this PR's speed against master lies within the distance between two builds of master itself (0.5% at least). WITHIN THE FLOOR, or OUTSIDE THE FLOOR with its size, this PR against the bypass (this PR's binary with stock's entry points) and the rounds on each side. One build of each is one layout draw: no verdict about the path is drawn from it.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step floorfib, floorh0)

| cell | master, second build | this PR |
|---|---|---|
| fib_fine, 8,1 | 0.984 [0.972–1.008] (12) | 0.987 [0.964–1.017] (12) |
| spawn path, H = 0, C = 50, 8,0 | 1.010 [1.002–1.013] (12) | 0.996 [0.987–1.003] (12) |
| spawn path, H = 0, C = 500, 8,0 | 1.010 [1.003–1.013] (12) | 0.996 [0.992–1.002] (12) |

| cell | the bypass | this PR against the bypass |
|---|---|---|
| fib_fine, 8,1 | 0.994 [0.964–1.011] (12) | 0.994 [0.971–1.055] (12) |
| spawn path, H = 0, C = 50, 8,0 | 1.003 [0.990–1.011] (12) | 0.992 [0.987–1.004] (12) |
| spawn path, H = 0, C = 500, 8,0 | 1.001 [0.998–1.009] (12) | 0.995 [0.988–1.003] (12) |

- fib_fine, 8,1: WITHIN THE FLOOR: this PR -1.34% against master, the floor ±1.60% (master's second build -1.60%).
- spawn path, H = 0, C = 50, 8,0: WITHIN THE FLOOR: this PR -0.43% against master, the floor ±0.95% (master's second build +0.95%).
- spawn path, H = 0, C = 500, 8,0: WITHIN THE FLOOR: this PR -0.35% against master, the floor ±0.96% (master's second build +0.96%).

Criterion e: every cell WITHIN THE FLOOR: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| fib_fine, this PR against master | 0.987 | 0.984 |

The same pfib(42) cut at 12 in both; the reproducer has 3 rounds and no harness counters, so a difference of a point is within its spread.


## f. The benchmark of JuliaLang/julia#35589

**Claim.** `pfib(25)` as posted in that PR's thread, from one root spawned on `:default`: unmarked, with the root marked, and with every spawn marked. Speed against master's unmarked run.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step pfib2, pfib81)

| speed against master, unmarked | --threads=2 | 8,1 |
|---|---|---|
| this PR, unmarked | 0.990 [0.983–0.997] (6) | 0.986 [0.976–1.006] (6) |
| master, second build | 1.001 [0.998–1.019] (6) | 1.012 [0.995–1.022] (6) |
| the bypass, unmarked | 0.985 [0.981–1.001] (6) | 0.987 [0.969–1.010] (6) |
| this PR, root marked | 0.925 [0.914–0.944] (6) | 0.898 [0.885–0.904] (6) |
| this PR, every spawn marked | 0.421 [0.418–0.427] (6) | 0.387 [0.382–0.391] (6) |

Criterion f: unmarked not slower than master by more than the floor (one-sided: max(|second build − 1|, 0.5%)). The root-marked and every-spawn-marked lines are STATED COSTS, with no bar. --threads=2: unmarked slower than the floor (-1.01% against −0.50%), the bypass at 0.985; root marked 0.925, every spawn marked 0.421 (stated costs); 8,1: unmarked slower than the floor (-1.37% against −1.20%), the bypass at 0.987; root marked 0.898, every spawn marked 0.387 (stated costs). Overall: **RESULT** (outside its bar).

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| unmarked, --threads=2 | 0.990 | 0.986 |
| root marked | 0.925 | 0.919 |
| every spawn marked | 0.421 | 0.428 |

The same program; the harness times it with BenchmarkTools for 4 s, the reproducer with its own loop for 4 s.


## g. The cost with everything marked

**Claim.** The spawn path itself (closed-loop clients on `:default` spawning tasks, 8,0), with the clients and every task they spawn marked. Speed against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step spawnpath)

| cell | master, requests/s | this PR marked, speed |
|---|---|---|
| C = 50 | 3127750 [3117792–3155176] (6) | 0.835 [0.831–0.842] (6) |
| C = 500 | 3239810 [3229040–3255794] (6) | 0.830 [0.825–0.842] (6) |

Criterion g: speed 0.80 or better in every round: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| C = 50, this PR marked against master | 0.835 | 0.789 |
| C = 500, this PR marked against master | 0.830 | 0.796 |

The harness's handler also stamps and records each request, so the scheduler's share of a request is smaller there; the reproducer's tasks do nothing but notify, so the mark's fixed cost weighs more.


## h. What unmarked code pays once a program has marked something

**Claim.** `fib_fine` at 8,1 with nothing marked, in a process that first ran one task with `fair=true` (the scheduler's pool flag is then set for good), against the same build with nothing ever marked, and against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step arm)

|  | against this PR, never marked | against master |
|---|---|---|
| this PR, never marked | 1 | 0.982 [0.960–1.012] (6) |
| this PR, after one marked task | 0.966 [0.929–0.987] (6) | 0.945 [0.933–0.975] (6) |

Row h is a stated cost, with no bar, given three ways (a cost is 1 − speed; a negative cost is faster):

- this PR never marked, against master: 1.8% (rounds -1.2% to 4.0%);
- this PR after one marked task, against master: 5.5% (rounds 2.5% to 6.7%);
- the second against the first (after one marked task, against the same build never marked): 3.4% (rounds 1.3% to 7.1%).

Earlier readings of the second against the first: 2.6% (2026-11-22/23, on master's port), 3.1% (the candidate, 2026-11-24), 4.0% (v2, 2026-11-25), 6.1% (v3, 2026-11-25); session 7's comparison block (2026-11-26) read v4 at 3.2% against its own build never marked and 3.8% against master.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| after one marked task, against never marked | 0.966 | 0.971 |

The same work; the reproducer arms the flag by one `fair=true` spawn in the measured process, the harness by one marked task at load, and its 3 rounds spread wider.


## i. Julia's tests

**Claim.** The test sets the change touches, on master and on this PR, nothing marked: the same counts. The new tests run inside `threads_exec.jl`, which `threads` runs in a subprocess at five thread layouts; their own assertions are not in these totals.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step tests)

| build | core, threads, channels, channel_threadpool, threadpool_use, threadpool_latency, cancellation | result |
|---|---|---|
| master | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |
| this PR | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |


## v3 against v4, row by row

Medians of each run (`candidate-v3-20261125` and this one). **They are different runs**, on different days, each against its own rounds of master: a difference here is between runs, not a measurement of one build against another.

| row | measure | v3 | v4 |
|---|---|---|---|
| a | master p99 (ms) | 3008 | 3234 |
| b | marked p99 (ms) | 151.0 | 151.0 |
| b | least-served client | 60 | 60 |
| c | plain p99 (ms) | 325.6 | 329.1 |
| c | plain compute speed | 0.565 | 0.549 |
| c | inner p99 (ms) | 325.0 | 327.4 |
| c | inner compute speed | 0.548 | 0.548 |
| d | 8,1 p99 (ms) | 115.9 | 114.1 |
| d | 8,1 throughput speed | 0.993 | 1.018 |
| d | 8,0 p99 (ms) | 112.8 | 111.4 |
| d | 8,0 throughput speed | 0.989 | 1.014 |
| e | fib_fine, 8,1: unmarked against master | 0.996 | 0.987 |
| e | fib_fine, 8,1: master's second build | 1.002 | 0.984 |
| e | fib_fine, 8,1: unmarked against the bypass | 1.002 | 0.994 |
| e | H = 0, C = 50, 8,0: unmarked against master | 0.994 | 0.996 |
| e | H = 0, C = 50, 8,0: master's second build | 1.011 | 1.010 |
| e | H = 0, C = 50, 8,0: unmarked against the bypass | 0.988 | 0.992 |
| e | H = 0, C = 500, 8,0: unmarked against master | 0.994 | 0.996 |
| e | H = 0, C = 500, 8,0: master's second build | 1.006 | 1.010 |
| e | H = 0, C = 500, 8,0: unmarked against the bypass | 0.992 | 0.995 |
| f | --threads=2 unmarked | 0.999 | 0.990 |
| f | --threads=2 root marked | 0.886 | 0.925 |
| f | --threads=2 every spawn marked | 0.404 | 0.421 |
| f | 8,1 unmarked | 0.997 | 0.986 |
| f | 8,1 root marked | 0.889 | 0.898 |
| f | 8,1 every spawn marked | 0.396 | 0.387 |
| g | C = 50 marked | 0.819 | 0.835 |
| g | C = 500 marked | 0.816 | 0.830 |
| h | never marked, against master | 0.995 | 0.982 |
| h | after one marked task, against never marked | 0.939 | 0.966 |
| h | after one marked task, against master | 0.934 | 0.945 |


## Standalone reproducers

Single files in `bench/julia/candidate/`, standard library only, each run as `julia --threads=<layout> <file>.jl [args]` on both builds, a fresh process a round, pinned as the cells. A marked mode on master prints that the keyword is not there.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step repro, repro_gh)

| reproducer (row) | master | this PR |
|---|---|---|
| `starved.jl` p99 (ms), stock order (a) | 3096 [2720–3179] (3) | 2807 [2714–3055] (3) |
| `starved.jl fair` p99 (ms), marked (b) | not supported | 153.0 [151.0–153.0] (3) |
| `starved.jl fair` least-served client (b) | not supported | 60 [60–60] (3) |
| `fib_fine.jl` median wall (s) (e) | 0.7825 [0.7796–0.8103] (3) | 0.7951 [0.7869–0.7999] (3) |
| `pfib.jl none` at --threads=2, median (s) (f) | 0.0569 [0.0566–0.0569] (3) | 0.0577 [0.0571–0.0579] (3) |
| `pfib.jl root`, median (s) (f) | not supported | 0.0619 [0.0612–0.0619] (3) |
| `pfib.jl all`, median (s) (f) | not supported | 0.1330 [0.1320–0.1336] (3) |
| `spawn_path.jl plain 50` requests/s (g) | 3846258 [3821707–3860610] (3) | 3806803 [3805732–3826866] (3) |
| `spawn_path.jl fair 50` requests/s (g) | not supported | 3036452 [3022172–3054231] (3) |
| `spawn_path.jl plain 500` requests/s (g) | 3858496 [3855639–3867913] (3) | 3835372 [3808129–3838491] (3) |
| `spawn_path.jl fair 500` requests/s (g) | not supported | 3071309 [3061109–3091364] (3) |
| `armed.jl` median wall (s), never marked (h) | 0.7976 [0.7958–0.8047] (3) | 0.8001 [0.7930–0.8034] (3) |
| `armed.jl armed` median wall (s), one task marked first (h) | not supported | 0.8236 [0.8190–0.8335] (3) |


## The description's reproducer

`bench/julia/candidate/mwe.jl` at `--threads=8,1`: once on master as it is, once on this PR with the client's spawn marked (`fair=true`).

master:

```
1.15.0-DEV.974  threads 8,1  tasks/s 3822  fair wait ≈ 125.0 ms
latency ms: p50 15.0  p99 3032.0  max 8052.4
tasks per client: min 1  median 58  max 184
```

this PR, `fair=true`:

```
1.15.0-DEV.976  threads 8,1  tasks/s 3801  fair wait ≈ 125.0 ms
latency ms: p50 131.0  p99 161.0  max 203.1
tasks per client: min 59  median 61  max 63
```

