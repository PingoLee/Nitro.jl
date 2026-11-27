# Measurements of the fair class: master against this PR

Every ratio is a **speed** against its reference: above 1 is faster. Cells show median [min–max] (rounds).
Each column is a fresh process every round, the columns rotated, after one throwaway slot. "master" is the base commit, "master, second build" the same commit built again (the floor), "this PR" the base with the patch, "the bypass" this PR with stock's entry points under master's names and the patch's code compiled in but unreachable. Machine and builds: `environment.md`; raw data: `raw/`.

## a, b. Closed-loop clients starved by newer work, and the mark

**Claim.** 500 clients on `:interactive` each spawn a 2 ms task on `:default` (8 threads) and wait for it, for 8 s. On master the oldest clients starve (a); with each client's task marked (`fair=true`) every client is served and the tail is gone (b). A fair wait is 500 × 2 ms / 8 = 125 ms.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step starved)

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 3086 [2829–3365] (5) | 151.0 [151.0–152.0] (5) |
| least-served client (tasks in 8 s) | 1 [1–1] (5) | 60 [60–60] (5) |
| tasks/s | 3773 [3772–3773] (5) | 3773 [3772–3773] (5) |

Criterion a: master's p99 above 1,000 ms in every round: **PASS**.  Criterion b: this PR's p99 at most 200 ms and every client served, in every round: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| master, p99 (ms) | 3086 | 2791 |
| this PR marked, p99 (ms) | 151.0 | 153.0 |
| this PR marked, least-served client | 60 | 60 |

The same cell: the reproducer keeps only the latencies, where the harness also records each request's timings and checks every task; stock's tail varies by hundreds of ms between runs in both.


## c. Beside unmarked compute, both sides advance

**Claim.** The starved cell while an unmarked fork-join (`fib_fine`, pfib(42) cut at 12) runs on `:default`. With the clients' tasks marked, both advance: the clients' p99 stays bounded and the compute keeps a share of the machine. Compute speed = its wall time alone / its wall time during the cell.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step mixed)

Shape **plain**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 6737 [6551–8142] (5) | 329.0 [325.1–332.6] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–28] (5) |
| compute speed (alone = 1) | 0.092 [0.092–0.094] (3); did not finish in 2 of 5 rounds | 0.545 [0.531–0.557] (5) |

Shape **inner**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 4193 [3291–5440] (5) | 325.4 [323.8–329.0] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–28] (5) |
| compute speed (alone = 1) | 0.100 [0.100–0.103] (4); did not finish in 1 of 5 rounds | 0.541 [0.534–0.543] (5) |

Criterion c: this PR's p99 at most 600 ms and the compute at 0.40 or better, in every round of both shapes: **PASS**.

## d. Behind a real HTTP server

**Claim.** An HTTP.jl server whose handler does 2 ms of compute (`/aggregate`), 500 connections from a closed-loop load generator on other CPUs, 8 s a round, a fresh server each round. With the accepted connections' tasks marked, the tail stays bounded at about the same throughput.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step cell81, cell80)

At **8,1**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 2234 [1984–2444] (5) | 114.1 [113.7–114.4] (5) |
| requests/s | 4861 [4840–4955] (5) | 4961 [4949–4968] (5) |
| throughput speed (master = 1) | 1 | 1.021 [0.999–1.023] (5) |

At **8,0**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 1934 [1866–2018] (5) | 110.9 [110.2–111.5] (5) |
| requests/s | 5140 [5058–5151] (5) | 5105 [5087–5111] (5) |
| throughput speed (master = 1) | 1 | 0.994 [0.991–1.007] (5) |

Criterion d: this PR's p99 at most 150 ms in every round, and its median throughput 0.98 of master's or better, at each layout: **PASS**. (8,1: master's requests/s spread 2.4% between its own rounds; 8,0: master's requests/s spread 1.8% between its own rounds.)

## e. Code that marks nothing pays nothing measurable

**Claim.** With nothing marked, this PR's speed against master lies within the distance between two builds of master itself (2.0% at least: what two binaries of identical code read apart on these cells). WITHIN THE FLOOR, or OUTSIDE THE FLOOR with its size, this PR against the bypass (this PR's binary with stock's entry points) and the rounds on each side. One build of each is one layout draw: no verdict about the path is drawn from it.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step floorfib, floorh0)

| cell | master, second build | this PR |
|---|---|---|
| fib_fine, 8,1 | 0.999 [0.986–1.018] (12) | 0.994 [0.968–1.008] (12) |
| spawn path, H = 0, C = 50, 8,0 | 1.002 [0.995–1.008] (12) | 1.004 [0.995–1.010] (12) |
| spawn path, H = 0, C = 500, 8,0 | 1.001 [0.994–1.007] (12) | 1.001 [0.992–1.008] (12) |

| cell | the bypass | this PR against the bypass |
|---|---|---|
| fib_fine, 8,1 | 0.997 [0.976–1.003] (12) | 0.996 [0.968–1.026] (12) |
| spawn path, H = 0, C = 50, 8,0 | 0.986 [0.978–0.995] (12) | 1.020 [1.005–1.025] (12) |
| spawn path, H = 0, C = 500, 8,0 | 0.988 [0.979–0.992] (12) | 1.013 [1.007–1.018] (12) |

- fib_fine, 8,1: WITHIN THE FLOOR: this PR -0.57% against master, the floor ±2.00% (master's second build -0.07%).
- spawn path, H = 0, C = 50, 8,0: WITHIN THE FLOOR: this PR +0.40% against master, the floor ±2.00% (master's second build +0.22%).
- spawn path, H = 0, C = 500, 8,0: WITHIN THE FLOOR: this PR +0.10% against master, the floor ±2.00% (master's second build +0.07%).

Criterion e: every cell WITHIN THE FLOOR: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| fib_fine, this PR against master | 0.994 | 0.984 |

The same pfib(42) cut at 12 in both; the reproducer has 3 rounds and no harness counters, so a difference of a point is within its spread.


## f. The benchmark of JuliaLang/julia#35589

**Claim.** `pfib(25)` as posted in that PR's thread, from one root spawned on `:default`: unmarked, with the root marked, and with every spawn marked. Speed against master's unmarked run.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step pfib2, pfib81)

| speed against master, unmarked | --threads=2 | 8,1 |
|---|---|---|
| this PR, unmarked | 1.000 [0.988–1.013] (6) | 1.004 [0.995–1.019] (6) |
| master, second build | 0.999 [0.993–1.009] (6) | 1.005 [0.987–1.023] (6) |
| the bypass, unmarked | 0.986 [0.980–0.999] (6) | 0.985 [0.975–0.991] (6) |
| this PR, root marked | 0.942 [0.932–0.956] (6) | 0.911 [0.906–0.921] (6) |
| this PR, every spawn marked | 0.428 [0.422–0.438] (6) | 0.396 [0.387–0.403] (6) |

Criterion f: unmarked WITHIN THE FLOOR (one rule, as row e: |this PR − master| ≤ max(|second build − 1|, 2.0%)). The root-marked and every-spawn-marked lines are STATED COSTS, with no bar. --threads=2: unmarked WITHIN THE FLOOR (+0.03% against master, floor ±2.00%), the bypass at 0.986; root marked 0.942, every spawn marked 0.428 (stated costs); 8,1: unmarked WITHIN THE FLOOR (+0.36% against master, floor ±2.00%), the bypass at 0.985; root marked 0.911, every spawn marked 0.396 (stated costs). Overall: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| unmarked, --threads=2 | 1.000 | 0.989 |
| root marked | 0.942 | 0.929 |
| every spawn marked | 0.428 | 0.424 |

The same program; the harness times it with BenchmarkTools for 4 s, the reproducer with its own loop for 4 s.


## g. The cost with everything marked

**Claim.** The spawn path itself (closed-loop clients on `:default` spawning tasks, 8,0), with the clients and every task they spawn marked. Speed against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step spawnpath)

| cell | master, requests/s | this PR marked, speed |
|---|---|---|
| C = 50 | 3142256 [3127482–3160425] (6) | 0.844 [0.840–0.849] (6) |
| C = 500 | 3248182 [3225913–3251799] (6) | 0.839 [0.833–0.844] (6) |

Criterion g: speed 0.80 or better in every round: **PASS**.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| C = 50, this PR marked against master | 0.844 | 0.809 |
| C = 500, this PR marked against master | 0.839 | 0.813 |

The harness's handler also stamps and records each request, so the scheduler's share of a request is smaller there; the reproducer's tasks do nothing but notify, so the mark's fixed cost weighs more.


## h. What unmarked code pays once a program has marked something

**Claim.** `fib_fine` at 8,1 with nothing marked, in a process that first ran one task with `fair=true` (the scheduler's pool flag is then set for good), against the same build with nothing ever marked, and against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step arm)

|  | against this PR, never marked | against master |
|---|---|---|
| this PR, never marked | 1 | 0.996 [0.963–1.007] (6) |
| this PR, after one marked task | 0.966 [0.950–0.985] (6) | 0.960 [0.946–0.967] (6) |

Row h is a stated cost, with no bar, given three ways (a cost is 1 − speed; a negative cost is faster):

- this PR never marked, against master: 0.4% (rounds -0.7% to 3.7%);
- this PR after one marked task, against master: 4.0% (rounds 3.3% to 5.4%);
- the second against the first (after one marked task, against the same build never marked): 3.4% (rounds 1.5% to 5.0%).

Earlier readings of the second against the first: 2.6% (2026-11-22/23, on master's port), 3.1% (the candidate, 2026-11-24), 4.0% (v2, 2026-11-25), 6.1% (v3, 2026-11-25); session 7's comparison block (2026-11-26) read v4 at 3.2% against its own build never marked and 3.8% against master; v4's evidence (2026-11-26) read 3.4%, and 5.5% after one marked task against master.

Standalone reproducer beside the harness (medians; the reproducer's rounds are its own):

|  | harness | reproducer |
|---|---|---|
| after one marked task, against never marked | 0.966 | 0.974 |

The same work; the reproducer arms the flag by one `fair=true` spawn in the measured process, the harness by one marked task at load, and its 3 rounds spread wider.


## i. Julia's tests

**Claim.** The test sets the change touches, on master and on this PR, nothing marked: the same counts. The new tests run inside `threads_exec.jl`, which `threads` runs in a subprocess at five thread layouts; their own assertions are not in these totals.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step tests)

| build | core, threads, channels, channel_threadpool, threadpool_use, threadpool_latency, cancellation | result |
|---|---|---|
| master | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |
| this PR | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |


## v4 against v5, row by row

Medians of each run (`candidate-v4-20261126` and this one). **They are different runs**, on different days, each against its own rounds of master: a difference here is between runs, not a measurement of one build against another.

| row | measure | v4 | v5 |
|---|---|---|---|
| a | master p99 (ms) | 3234 | 3086 |
| b | marked p99 (ms) | 151.0 | 151.0 |
| b | least-served client | 60 | 60 |
| c | plain p99 (ms) | 329.1 | 329.0 |
| c | plain compute speed | 0.549 | 0.545 |
| c | inner p99 (ms) | 327.4 | 325.4 |
| c | inner compute speed | 0.548 | 0.541 |
| d | 8,1 p99 (ms) | 114.1 | 114.1 |
| d | 8,1 throughput speed | 1.018 | 1.021 |
| d | 8,0 p99 (ms) | 111.4 | 110.9 |
| d | 8,0 throughput speed | 1.014 | 0.994 |
| e | fib_fine, 8,1: unmarked against master | 0.987 | 0.994 |
| e | fib_fine, 8,1: master's second build | 0.984 | 0.999 |
| e | fib_fine, 8,1: unmarked against the bypass | 0.994 | 0.996 |
| e | H = 0, C = 50, 8,0: unmarked against master | 0.996 | 1.004 |
| e | H = 0, C = 50, 8,0: master's second build | 1.010 | 1.002 |
| e | H = 0, C = 50, 8,0: unmarked against the bypass | 0.992 | 1.020 |
| e | H = 0, C = 500, 8,0: unmarked against master | 0.996 | 1.001 |
| e | H = 0, C = 500, 8,0: master's second build | 1.010 | 1.001 |
| e | H = 0, C = 500, 8,0: unmarked against the bypass | 0.995 | 1.013 |
| f | --threads=2 unmarked | 0.990 | 1.000 |
| f | --threads=2 root marked | 0.925 | 0.942 |
| f | --threads=2 every spawn marked | 0.421 | 0.428 |
| f | 8,1 unmarked | 0.986 | 1.004 |
| f | 8,1 root marked | 0.898 | 0.911 |
| f | 8,1 every spawn marked | 0.387 | 0.396 |
| g | C = 50 marked | 0.835 | 0.844 |
| g | C = 500 marked | 0.830 | 0.839 |
| h | never marked, against master | 0.982 | 0.996 |
| h | after one marked task, against never marked | 0.966 | 0.966 |
| h | after one marked task, against master | 0.945 | 0.960 |


## Standalone reproducers

Single files in `bench/julia/candidate/`, standard library only, each run as `julia --threads=<layout> <file>.jl [args]` on both builds, a fresh process a round, pinned as the cells. A marked mode on master prints that the keyword is not there.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR> [<bypass>]` (step repro, repro_gh)

| reproducer (row) | master | this PR |
|---|---|---|
| `starved.jl` p99 (ms), stock order (a) | 2791 [2641–3354] (3) | 2766 [2731–3275] (3) |
| `starved.jl fair` p99 (ms), marked (b) | not supported | 153.0 [151.9–153.1] (3) |
| `starved.jl fair` least-served client (b) | not supported | 60 [59–60] (3) |
| `fib_fine.jl` median wall (s) (e) | 0.7927 [0.7895–0.7963] (3) | 0.8057 [0.7957–0.8115] (3) |
| `pfib.jl none` at --threads=2, median (s) (f) | 0.0566 [0.0565–0.0566] (3) | 0.0573 [0.0572–0.0577] (3) |
| `pfib.jl root`, median (s) (f) | not supported | 0.0609 [0.0609–0.0614] (3) |
| `pfib.jl all`, median (s) (f) | not supported | 0.1336 [0.1329–0.1354] (3) |
| `spawn_path.jl plain 50` requests/s (g) | 3841141 [3835704–3856876] (3) | 3820010 [3772876–3824919] (3) |
| `spawn_path.jl fair 50` requests/s (g) | not supported | 3109345 [3105858–3141072] (3) |
| `spawn_path.jl plain 500` requests/s (g) | 3853818 [3852378–3875422] (3) | 3830636 [3823093–3836346] (3) |
| `spawn_path.jl fair 500` requests/s (g) | not supported | 3134690 [3129537–3145852] (3) |
| `armed.jl` median wall (s), never marked (h) | 0.7938 [0.7903–0.7946] (3) | 0.8103 [0.8035–0.8133] (3) |
| `armed.jl armed` median wall (s), one task marked first (h) | not supported | 0.8323 [0.8267–0.8375] (3) |


## The description's reproducer

`bench/julia/candidate/mwe.jl` at `--threads=8,1`: once on master as it is, once on this PR with the client's spawn marked (`fair=true`).

master:

```
1.15.0-DEV.974  threads 8,1  tasks/s 3802  fair wait ≈ 125.0 ms
latency ms: p50 15.0  p99 2695.0  max 8011.2
tasks per client: min 1  median 60  max 181
```

this PR, `fair=true`:

```
1.15.0-DEV.976  threads 8,1  tasks/s 3804  fair wait ≈ 125.0 ms
latency ms: p50 131.1  p99 159.9  max 183.0
tasks per client: min 59  median 61  max 63
```

