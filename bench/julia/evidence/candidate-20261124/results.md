# Measurements of the fair class: master against this PR

Every ratio is a **speed** against its reference: above 1 is faster. Cells show median [min–max] (rounds).
Each column is a fresh process every round, the columns rotated, after one throwaway slot. "master" is the base commit, "master, second build" the same commit built again (the floor), "this PR" the base with the patch. Machine and builds: `environment.md`; raw data: `raw/`.

## a, b. Closed-loop clients starved by newer work, and the mark

**Claim.** 500 clients on `:interactive` each spawn a 2 ms task on `:default` (8 threads) and wait for it, for 8 s. On master the oldest clients starve (a); with each client's task marked (`fair=true`) every client is served and the tail is gone (b). A fair wait is 500 × 2 ms / 8 = 125 ms.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step starved)

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 3133 [2971–3307] (5) | 151.0 [150.9–151.8] (5) |
| least-served client (tasks in 8 s) | 1 [1–1] (5) | 60 [60–60] (5) |
| tasks/s | 3773 [3772–3773] (5) | 3773 [3772–3773] (5) |

Criterion a: master's p99 above 1,000 ms in every round: **PASS**.  Criterion b: this PR's p99 at most 200 ms and every client served, in every round: **PASS**.

## c. Beside unmarked compute, both sides advance

**Claim.** The starved cell while an unmarked fork-join (`fib_fine`, pfib(42) cut at 12) runs on `:default`. With the clients' tasks marked, both advance: the clients' p99 stays bounded and the compute keeps a share of the machine. Compute speed = its wall time alone / its wall time during the cell.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step mixed)

Shape **plain**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 5640 [4424–8085] (5) | 329.0 [327.6–330.3] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–28] (5) |
| compute speed (alone = 1) | 0.096 [0.094–0.097] (2); did not finish in 3 of 5 rounds | 0.559 [0.556–0.568] (5) |

Shape **inner**:

|  | master | this PR, marked |
|---|---|---|
| clients' p99 latency (ms) | 3778 [3306–4449] (5) | 325.0 [320.2–326.5] (5) |
| least-served client | 1 [1–1] (5) | 28 [28–29] (5) |
| compute speed (alone = 1) | 0.098 [0.098–0.099] (3); did not finish in 2 of 5 rounds | 0.553 [0.548–0.561] (5) |

Criterion c: this PR's p99 at most 600 ms and the compute at 0.40 or better, in every round of both shapes: **PASS**.

## d. Behind a real HTTP server

**Claim.** An HTTP.jl server whose handler does 2 ms of compute (`/aggregate`), 500 connections from a closed-loop load generator on other CPUs, 8 s a round, a fresh server each round. With the accepted connections' tasks marked, the tail stays bounded at the same throughput.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step cell81, cell80)

At **8,1**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 2359 [2173–2411] (5) | 116.6 [116.2–117.5] (5) |
| requests/s | 4905 [4886–4957] (5) | 4849 [4840–4858] (5) |
| throughput speed (master = 1) | 1 | 0.990 [0.977–0.992] (5) |

At **8,0**:

|  | master | this PR, marked |
|---|---|---|
| p99 latency (ms) | 1907 [1641–2030] (5) | 112.2 [110.3–112.7] (5) |
| requests/s | 5126 [5125–5139] (5) | 5037 [5016–5091] (5) |
| throughput speed (master = 1) | 1 | 0.983 [0.977–0.993] (5) |

Criterion d: this PR's p99 at most 150 ms and throughput at 0.98 or better, in every round at each layout measured: **FAIL**.

## e. Code that marks nothing pays nothing measurable

**Claim.** With nothing marked, this PR's speed against master lies within the distance between two builds of master itself. LAYOUT means it does: the difference cannot be told from a second build of the same source.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step floorfib, floorh0)

| cell | master, second build | this PR |
|---|---|---|
| fib_fine, 8,1 | 1.002 [0.975–1.028] (12) | 0.986 [0.972–1.007] (12) |
| spawn path, H = 0, C = 50, 8,0 | 0.998 [0.980–1.004] (12) | 0.995 [0.988–1.004] (12) |
| spawn path, H = 0, C = 500, 8,0 | 0.998 [0.989–1.003] (12) | 0.991 [0.984–0.996] (12) |

Criterion e: fib_fine: outside the floor: -1.42% against ±0.50%; C = 50: outside the floor: -0.52% against ±0.50%; C = 500: outside the floor: -0.94% against ±0.50%. Overall: **FAIL**.

## f. The benchmark of JuliaLang/julia#35589

**Claim.** `pfib(25)` as posted in that PR's thread, from one root spawned on `:default`: unmarked, with the root marked, and with every spawn marked. Speed against master's unmarked run.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step pfib2, pfib81)

| speed against master, unmarked | --threads=2 | 8,1 |
|---|---|---|
| this PR, unmarked | 0.996 [0.989–1.002] (6) | 0.989 [0.979–1.006] (6) |
| master, second build | 1.006 [1.003–1.008] (6) | 1.003 [0.989–1.019] (6) |
| this PR, root marked | 0.919 [0.915–0.925] (6) | 0.898 [0.890–0.918] (6) |
| this PR, every spawn marked | 0.424 [0.415–0.433] (6) | 0.391 [0.386–0.399] (6) |

Criterion f: unmarked within the floor as in e, and the root marked at 0.90 or better in every round; every spawn marked is reported with no bar. --threads=2: unmarked LAYOUT, root marked **PASS**; 8,1: unmarked outside the floor (-1.07% against ±0.50%), root marked **FAIL**. Overall: **FAIL**.

## g. The cost with everything marked

**Claim.** The spawn path itself (closed-loop clients on `:default` spawning tasks that do no work, 8,0), with the clients and every task they spawn marked. Speed against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step spawnpath)

| cell | master, requests/s | this PR marked, speed |
|---|---|---|
| C = 50 | 3147226 [3129355–3175449] (6) | 0.851 [0.845–0.863] (6) |
| C = 500 | 3252579 [3239344–3277183] (6) | 0.846 [0.839–0.852] (6) |

Criterion g: speed 0.80 or better in every round: **PASS**.

## h. What unmarked code pays once a program has marked something

**Claim.** `fib_fine` at 8,1 with nothing marked, in a process that first ran one task with `fair=true` (the scheduler's pool flag is then set for good), against the same build with nothing ever marked, and against master.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step arm)

|  | against this PR, never marked | against master |
|---|---|---|
| this PR, never marked | 1 | 0.977 [0.971–0.997] (6) |
| this PR, after one marked task | 0.969 [0.960–0.975] (6) | 0.945 [0.934–0.972] (6) |

Criterion h: after one marked task, speed 0.965 or better against the same build never marked, in every round: **FAIL**.

## i. Julia's tests

**Claim.** The test sets the change touches, on master and on this PR, nothing marked: the same counts. The new tests run inside `threads_exec.jl`, which `threads` runs in a subprocess at five thread layouts; their own assertions are not in these totals.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step tests)

| build | core, threads, channels, channel_threadpool, threadpool_use, threadpool_latency, cancellation | result |
|---|---|---|
| master | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |
| this PR | 7357256 passed, 12 broken, 0 failed, 0 errors | SUCCESS |


## Standalone reproducers

Single files in `bench/julia/candidate/`, standard library only, each run as `julia --threads=<layout> <file>.jl [args]` on both builds, a fresh process a round, pinned as the cells. A marked mode on master prints that the keyword is not there. Their numbers are their own: the harness's cells above add per-request bookkeeping, so compare each reproducer's two columns with each other, and its ratio with the row's.

Reproduce: `bench/julia/candidate_evidence.sh <master> <master, second build> <this PR>` (step repro, repro_gh)

| reproducer (row) | master | this PR |
|---|---|---|
| `starved.jl` p99 (ms), stock order (a) | 2888 [2419–3023] (3) | 3019 [2741–3447] (3) |
| `starved.jl fair` p99 (ms), marked (b) | not supported | 153.0 [152.3–166.0] (3) |
| `starved.jl fair` least-served client (b) | not supported | 60 [60–60] (3) |
| `fib_fine.jl` median wall (s) (e) | 0.7858 [0.7846–0.7954] (3) | 0.7931 [0.7919–0.8040] (3) |
| `pfib.jl none` at --threads=2, median (s) (f) | 0.0568 [0.0567–0.0572] (3) | 0.0572 [0.0572–0.0573] (3) |
| `pfib.jl root`, median (s) (f) | not supported | 0.0615 [0.0612–0.0619] (3) |
| `pfib.jl all`, median (s) (f) | not supported | 0.1332 [0.1317–0.1354] (3) |
| `spawn_path.jl plain 50` requests/s (g) | 3848684 [3838963–3879271] (3) | 3805426 [3804397–3818025] (3) |
| `spawn_path.jl fair 50` requests/s (g) | not supported | 3071715 [3065159–3083321] (3) |
| `spawn_path.jl plain 500` requests/s (g) | 3869007 [3863496–3886469] (3) | 3802086 [3792353–3833861] (3) |
| `spawn_path.jl fair 500` requests/s (g) | not supported | 3129205 [3104588–3132196] (3) |
| `armed.jl` median wall (s), never marked (h) | 0.7885 [0.7823–0.7911] (3) | 0.7931 [0.7863–0.7933] (3) |
| `armed.jl armed` median wall (s), one task marked first (h) | not supported | 0.8338 [0.8328–0.8396] (3) |


## The description's reproducer

`bench/julia/candidate/mwe.jl` at `--threads=8,1`: once on master as it is, once on this PR with the client's spawn marked (`fair=true`).

master:

```
1.15.0-DEV.974  threads 8,1  tasks/s 3820  fair wait ≈ 125.0 ms
latency ms: p50 15.0  p99 2708.0  max 8069.5
tasks per client: min 1  median 56  max 185
```

this PR, `fair=true`:

```
1.15.0-DEV.976  threads 8,1  tasks/s 3798  fair wait ≈ 125.0 ms
latency ms: p50 132.0  p99 151.0  max 170.9
tasks per client: min 59  median 61  max 62
```

