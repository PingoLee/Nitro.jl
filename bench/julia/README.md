# bench/julia: the native mark, a local Julia experiment (#618)

`native-mark-v1.13.4.patch` is a change to Julia itself: the opt-in mark of #618 (M-gc-r2 with the
listener marked, the design the runtime patch in `bench/tasks/multiq_variant.jl` measured) written
inside `Base.Partr`. It applies to the tag `v1.13.4` of JuliaLang/julia. **It is a local
experiment, measured in #618, and it is not proposed to Julia.**

- sha256: `ee435ce95b6149c59c91a7acf62a0bd553b9ff21ba322b26d56b123519d0d3e0`
- made with `git diff v1.13.4 nitro-618-native-mark` in a local checkout

## What it changes

| File | What |
|---|---|
| `base/partr.jl` | stock's three entry points renamed `stock_multiq_*`; the R heaps (a renamed copy of stock's four heap functions); the rings, the pool flag, the per-thread accounts, the class rule, the group pop with the clock at every pop, the one-time init; every validation counter and assert behind `@sched_validate` |
| `base/threadingconstructs.jl` | `Threads.@spawn [pool] fair=<Bool> expr` and `Threads._spawn_set_fair(t, fair)` |
| `src/julia_threads.h` | `pad0[0]` of `jl_task_t` becomes `_Atomic(uint8_t) sched_class` (size and layout unchanged) |
| `src/jltypes.c` | the Julia field `pad00` becomes the atomic `sched_class` |
| `src/task.c` | `jl_new_task` zeroes it (the allocation is not zeroed) |
| `base/boot.jl`, `test/core.jl` | the field list in the comment, and the test's table of atomic `Task` fields |

With nothing marked (read in the optimized code of the mark build): `multiq_deletemin` inlines into
`trypoptask` as one load of the pool flag and a direct call of stock's pop, the same call depth as
stock; `multiq_insert` is two loads (the task's class byte and the flag) and then stock's insert
behind one more call, since `enq_work` does not inline it in either build; `multiq_check_empty` is
stock's check, inlined, and one load of the flag once stock's heaps are empty.

## Building

Three trees of the same tag, each its own `git worktree`, with one `Make.user` copied byte for byte:

```make
override CC := /usr/bin/gcc
override CXX := /usr/bin/g++
JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

The target string is the official 1.13.4 binary's own (read from its `sys.so`), so the control is as
close as a source build gets to the binary the runtime patch ran on.

- **control**: the tag untouched;
- **mark**: the tag plus this patch;
- **mark-validate**: the patch with `const SCHED_VALIDATE = true` in `base/partr.jl`, the only line
  that differs. It compiles in the counters, the asserts and the negative controls
  (`JULIA_SCHED_NEGATIVE=blind|stall|rblind`); the timed build has none of them.

`make -j12` takes about 16 minutes per tree on the bench box.

Give each build its own first depot, so that no build's precompile cache evicts another's:
`JULIA_DEPOT_PATH="<own depot>:$HOME/.julia:"` (the shared depot second, for packages and registries).

## Using it

- `JULIA_SCHED_FAIR_WEIGHT` (`1/4`, `1/2` or `3/4`, default `1/2`): the request side's share of a
  thread's time while both sides have work, read once by the first marked spawn.
- The harness's native mode: `VARIANT=N` (handlers and clients marked, as M-gc-r2 marks them), `N-h`
  (handlers only), `N-none` (nothing marked) in `bench/tasks/` and `bench/socket/server.jl`;
  `bench/tasks/rounds_fifo.sh PROFILE=native` with `JLS="control=… mark=… official=…"` interleaves
  the builds in one block. The runtime patch refuses to load on a build that has the mark.
- `native_measure.sh`: the measurement session as one detached driver: validation and smoke, then
  every timed block in order, with a `ps` check before each gated block and a check after each
  block that no build wrote a cache file during it. It stops on any failed check. `N25` and `N75`
  are N at the weights 1/4 and 3/4.
- `native-mark-all-switch.patch` (`git diff nitro-618-native-mark-validate nitro-618-native-mark-all`):
  a throwaway build for Julia's own tests, never timed. On top of mark-validate, `JULIA_SCHED_MARK_ALL`
  (read once by `Base.__init__`) makes every `@spawn` carry the mark (`spawn`) or classes every task's
  first `:default` enqueue as a marked root (`insert`); with `JULIA_SCHED_MARK_ALL_LOG=<dir>` every
  process writes its validation counters at exit, so a test run shows which processes ran with the
  switch on. `mark_all_checks.jl` prints, per spawn path, what each mode marks. `battery.sh` is the
  session that uses it (the maintainer battery of #618), and `battery_report.jl <OUT>` its report: the
  columns keyed by build (m1 and m2 share a commit), the test counts per column, and the exit logs
  per test set (a runner worker is attributed by its exit time, so that attribution is inferred).
- `native_checks.jl`: the port's delicate points (the sysimage's state, the zeroed byte, the option,
  the `:interactive` and sticky rules, one-thread pools, no queue keeping a task alive), at `8,1`,
  `8,2` and `1`.
- `native-mark-bypass.patch` (`git diff nitro-618-native-mark nitro-618-native-mark-bypass`, sha256
  `56304907f6cd518646a151313afba44bd27e951047096d7d5a4c0efda92e6dc0`): the bypass control of #618
  (agent-config #82 Idea 13), never proposed anywhere. On top of the mark, `multiq_insert`,
  `multiq_deletemin` and `multiq_check_empty` are stock's own bodies under the tag's names, so the
  scheduler reaches only them; the mark's wrappers are kept as `mark_multiq_*`, unreachable, and
  `contrib/generate_precompile.jl` compiles them into the image. Same C runtime as the mark build,
  the mark's code in the sysimage, and no new path: built like the others (its own tree, the same
  `Make.user`, its own first depot). `bypass.sh` is the session that uses it, four columns (ctl, m1,
  m2, bypass) in the cells where the mark builds stood off the control at 2 and 4 threads, with
  `bypass_report.jl <OUT>` its report. One bypass build is one layout draw, so where a cell reads
  as the path (the bypass with the control), the driver builds the same commit again in a second
  tree (bp2; an untracked file marks it dirty, which Julia reads at run time, so the image comes from
  the same sources) and reruns that cell with ctl, m2, bp and bp2; "the path" needs both. The same
  driver runs `../tasks/wake_window.jl`, the repro aimed at the lost-wakeup window, read by
  `window_report.jl <dir>`, and question 3 (JuliaLang/julia#62285's two backends against the
  mark, read only within each tree), read by `q3_report.jl <OUT> <fairness tsv>...`.
- `native-mark-nopass.patch` (`git diff nitro-618-native-mark-validate nitro-618-native-mark-validate-nopass`,
  sha256 `a2dac6f686b0be494fdd4027a43d3c91e21deea3a90c6aed1be1b0ed14b99cf4`): the ring control of #618 (agent-config #82
  Idea 14), a throwaway build never timed. On top of mark-validate, `JULIA_SCHED_NOPASS=1` (read by `fair_init!`) makes the
  ring pop give up after its four samples instead of passing over every ring; with `JULIA_SCHED_NEGATIVE=blind` as well the
  ring side has neither of its two layers (the empty check and a pop that cannot miss). `slim.sh` is the session that uses
  it (step `ringA`, `../tasks/wake_window.jl` in ring mode, read by `window_report.jl`), and the same driver times the slim
  candidates of the unmarked path (six columns: ctl, m2, bp, bp2, s1, s2), read by `slim_report.jl <OUT>`. The candidates
  are local branches on the mark, never proposed anywhere: s1 (`nitro-618-native-mark-slim1`, 4667d170bd) inlines
  `multiq_insert` into `enq_work`; s2 (`nitro-618-native-mark-slim2`, b304809bc9) adds the flag tested before the task's
  class, set by `_spawn_set_fair` at the first mark that will reach the multiqueue, and the empty check's flag-on part out
  of line. Neither won on 2026-11-21 (#618), so no slim patch file is kept; the measured patch stays the record.
- `perf_unmarked.sh` (agent-config #82 Idea 15): hardware counters on `../tasks/spawnwait_fixed.jl`, SpawnWait's body as a
  fixed loop, across the six builds of `slim.sh` (ctl, m2, bp, bp2, s1, s2) at `2,1` and `4,1`; diagnosis, not a timed
  comparison. `perf stat --per-thread` attached after the warm-up (the loop's `ATTACH` handshake), every counter a
  difference between a run at N and one at 2N, three event groups of at most five hardware events (the NMI watchdog holds
  one of Zen 3's six counters); `MODE=who` (which thread runs each child), `perf record` attached for the loop only,
  `MODE=split` (four stamps an operation: pickup, run, wake, and the median of 70-op block means that tasks.jl's
  BenchmarkTools row reports) and `MODE=idle` with `JULIA_THREAD_SLEEP_THRESHOLD=infinite` (the poll turn: instructions
  per turn from a hardware-breakpoint count of the build's own `multiq_deletemin` clone). Needs
  `kernel.perf_event_paranoid` at 1 or below. `perf_report.jl <OUT>` is its report.
- `slim2.sh` (agent-config #82 Idea 16): slim candidate s2 on two builds, and its validation if it stands. A second build
  of s2's commit (s2b, its tree marked dirty by an untracked file, as bp2's), read by `slim_report.jl` as its `w2` column
  (`SLIM_DIRS` picks the step directories); the cells with ctl, m2, bp, bp2, s2 and s2b, the split loop and the poll turn
  (`perf_unmarked.sh` a5 and a6, `PU_BUILDS`), then `slim2_decide.jl`: s2 stands if both its builds stand with the bypass
  builds wherever m2 is off both and have their pickup within 5 ns, and the result is a draw if the two s2 builds sit
  further apart than the two bypass builds. Part B (the validate pass, `native_checks.jl` and `slim2_corners.jl`'s three
  corners, the lost-wakeup windows, Julia's tests, the pass cells, the mark-all build with every spawn marked, the sets
  of 2026-11-20 that ran in one-thread workers, with `--threads=4,1`) skips itself unless part A says s2 stands.
  `slim2_corners.jl` checks, on a validation build, a task that gets a class while nothing has armed s2's pool flag (a
  class set by hand, a mark while sticky, a mark for `:interactive`): whether it is lost, where it sits, and its order.
  On 2026-11-22 the two s2 builds disagreed (s2b slower than s2 in 12 of 12 rounds at `2,1`): s2's first result was a
  layout draw, so no slim patch file is kept.

## The port to master (#618, agent-config #82 Idea 17)

`native-mark-master.patch` is the same design written against JuliaLang/julia `master` at
**`4b0df1484a03216658189c3a94623a5ebe028214`** (2026-11-22, `1.15.0-DEV`): `git diff 4b0df1484a
nitro-618-native-mark-master` in the local clone. `native-mark-master-inline.patch` is commit 2 on top
of it (`git diff nitro-618-native-mark-master nitro-618-native-mark-master-inline`): the tag's s1, the
unmarked insert inlined into `enq_work`, no change of behaviour. Local experiments, not proposed to
Julia, not stacked on any open PR.

- sha256 `native-mark-master.patch`: `46441f37745139f41edf752a929b20db28adaaf8ed2ed38b40f112f538fc4106` (7 files, +982 −10; the tag's was +961 −10)
- sha256 `native-mark-master-inline.patch`: `8f6983bbc338370fb7d44cf670387d0e4d04e380c6c8a0dbabc56fe909229eb2`

What master forced, against the tag's patch (everything else moved as it is):

| Where | What and why |
|---|---|
| `base/partr.jl`, the R heaps | regenerated from master's four heap functions (`r_heaps.jl gen`) and proved equal to them up to the renaming (`r_heaps.jl check`, token for token): master's pop now loops and yields the OS thread on a task pinned to another thread, and a three-way merge would have kept the tag's pop |
| `base/partr.jl`, `f_pop!` | when every scanned ring entry is pinned elsewhere, `yield_os_thread()` after waking the owners, as master's pop does |
| `base/partr.jl` | `Threads.maxthreadid()` (master dropped the import from `Partr`), `Base.unsetindex!` (renamed from `_unsetindex!`) |
| `base/partr.jl`, validation only | counters `oyields` (ring pops that yielded the OS thread) and `stale` (pops that returned a task no longer runnable: master's `trypoptask` discards it and pops again) |
| `src/julia_threads.h`, `src/jltypes.c` | the cancellation work took two of the three padding bytes: `sched_class` takes `pad02`, the last one, which leaves `jl_task_t`'s first cache line with no padding; its atomic bit moves to 13 (field 14) |
| `src/task.c` | zeroed in `jl_new_task` and in `jl_init_root_task` (already zero there by a `memset`; written as master writes `preempt_request`) |
| `base/boot.jl`, `test/core.jl` | the field comment and the atomic-field table, at master's lines |

Trees, under `~/app/julia-618-master/` (worktrees of the same clone, the same `Make.user` as the tag's,
`build.sh <tree>`, wrappers `bin/julia-<tree>`, a first depot each): `control` (master untouched),
`mark`, `mark-validate` (`SCHED_VALIDATE = true`, one line), `mark-inline`. master builds in about 12
minutes a tree on the bench box.

- `r_heaps.jl gen <base partr.jl>` / `check <base partr.jl> <branch partr.jl>`: rerun at every rebase.
  On master, run the check with a master build (its parser reads `*%`).
- `master_checks.jl`: the points master adds (the pinned ring entry, the stale pop, cancellation of a
  marked root in its ring, of request work in flight and of a `@sync`'s marked children, the class rule
  under master's scopes, `enq_work`'s early returns), on the validation build at `8,1` and `8,2`; with
  `abandon N`, forcible abandonments (marked victims on a mark build, unmarked on the control).
- `pilot_master.sh`: the port's pilot as one quiet block (the starved cell with `:interactive` clients,
  the mixed cell, `fib_fine` alone and the H = 0 cells with nothing marked, every build against
  master's control); `STEPS` and `UNMARKED` select the cells and the columns, `PILOT_OUT` the directory.
- `unmarked_code.jl`: the unmarked insert, pop and empty check as one build compiles them
  (instructions, calls and their targets, frame, safepoint polls), read on control, mark and mark-inline.
- `native_checks.jl`'s last check looks in every ring and R-heap slot for the finished tasks: on master a
  task the main task fetched can stay reachable after GC on the control too, so reachability is asserted
  only before 1.15.

### Session 2: the measurement on master, with JuliaLang/julia#62285 in the same blocks

Agent-config #82 Idea 17, session 2. Local experiments, not proposed to Julia. Four more trees under
`~/app/julia-618-master/`, each built like the others:
- `control2`: the pinned commit again, with an untracked marker file. Julia reports `4b0df1484a*`,
  and the sources are identical.
- `mark-bypass`: `native-mark-master-bypass.patch` on the mark (sha256
  `caf29ef454584155724a70bf6753bbbd3cefe97f9ae962fe523e6be53a496f50`). It is the tag's bypass
  control ported by hand, since the tag's patch does not apply to master's pop.
  - Master's three entry points are stock's own bodies again, and the scheduler reaches only them.
  - The mark's wrappers are kept as `mark_multiq_*`, unreachable, and compiled into the image by
    three lines in `contrib/generate_precompile.jl`.
  - `const stock_multiq_* = multiq_*` keeps the mark's code calling stock.
- `mark-all`: `native-mark-master-all-switch.patch` on mark-validate (sha256
  `dd07d1e8fb269808b78fdf8ad5bc8914b5de027005591b4d18be6e0a295d2cfe`). It is the tag's
  `JULIA_SCHED_MARK_ALL=spawn|insert` switch.
  - The `Base.__init__` hook is placed by hand.
  - The fallback log directory is `~/app/julia-618-master/mark-all-log/current`.
  - The exit log gains a `stale` column after `f_again`.
  - Never timed.
- `mark-inline-validate`: the local branch `nitro-618-native-mark-master-inline-validate`, which is
  `native-mark-master-inline.patch` with `SCHED_VALIDATE = true` (one line). Never timed.

**Packages.** The four timed trees (control and mark here; #62285's ws and base,
`1.14.0-DEV.2682`) load the same registry package versions, from
`~/app/julia-618-master/envs/{server,micro}-{master,july}`. The pins:
- server: HTTP 2.15.3, Reseau 1.7.1, JSON 1.13.4, PrecompileTools 1.3.4;
- micro: BenchmarkTools 1.8.0, JSON 1.13.4, PrecompileTools 1.3.4.

**The scripts.**
- `master_measure.sh`: the session as one detached driver. Its header lists the steps of parts A–E
  and the cut order, with the ps check before each step and the cache-write check after each.
  `SMOKE=1` runs every step once, short and ungated.
  - The ps check, as the maintainer asked for this run, stops a julia, oha or go-server process that
    is not the driver's own. "Own" means the driver's pid (`S2_DRIVER_PID`, exported to its `--run`
    children) is among the process's ancestors. It logs the pid, start time, parent, working
    directory and command line, sends SIGTERM, waits 10 s, sends SIGKILL, and the step goes on.
    No other process is ever signalled. A pid whose start time changed (reused) is skipped.
- `master_measure_report.jl <results dir> [<E2 dir>]`: the report of every part, with part C's
  table for the maintainer. Stdlib only.
- `abandon_runs.sh`: part E2. It runs `master_checks.jl abandon N` as many times as fit in a budget,
  alternating the builds. On a hang, before the kill, it saves the threads' states and wait
  channels and Julia's own reports (`SIGUSR1` with Profile loaded, then `SIGQUIT`).
- Two harness additions in `../tasks/`:
  - `VARIANT=N-arm` (`multiq_variant.jl`): nothing marked, but one marked task runs at load, so the
    pool flag is set for the whole process.
  - `MICRO_PROJECTS="<label>=<env>"` (`rounds_fifo.sh`): a column's tasks.jl runs in its own
    environment.
- `SESSION=3` (agent-config #82 Idea 19): master at #62285's merge-base `6ac8c4f030`, built twice under
  `~/app/julia-618-master/` (`july` with the master trees' multi-target `Make.user`, `july-n` with
  `base`'s native one), timed beside `base`, `control` and `control2` so that base/july-n reads the
  branch, control/july reads master and july-n/july reads the build configuration (an empty
  `JULIA_CPU_TARGET` sets `MARCH=native`, so the C runtime differs as well as the sysimage). Part B is
  `perf_unmarked.sh` `a1g1` at `8,1`, which now takes absolute wrapper and depot paths in `PU_BUILDS`
  (`perf_report.jl`: `PU_REPORT_LAYOUTS`), and whose cache check reads `compiled/` only. The report's
  section S3 gives every ratio as a speed. The driver logs, per `gated` block and around `jperf`, which
  JIT object caches (`objcache*/data.mdb`, Julia 1.14 and later) changed; blocks `rounds_fifo.sh` gates
  itself are not covered.

### `SESSION=4`: JuliaLang/julia#62284 as it is today (#618, agent-config #82 Idea 24)

On 2026-11-23 the gain of #62285's branch under partr and its stall were put down to "the spinner series, #62284". What was measured was the July version of that series, inside #62285's branch, and #62284 was rewritten afterwards. `SESSION=4` measures the PR as it is: its head **`293a8f6a7d`** (`w84`) against its merge-base with master **`35e14589f4`** (`w84-base`, untouched). Both are built under `~/app/julia-618-master/` with the master trees' multi-target `Make.user`, as worktrees of the clone, and timed beside `control` and `control2`. Nothing is marked anywhere. Local only: nothing was posted to, or drafted for, JuliaLang.

- **Builds.** Both report `1.14.0-DEV` (master moved to 1.15 after the merge-base) and load `envs/{micro,server}-july` with the same package versions as the other trees. The `w84` build reports `293a8f6a7d*`: `version_git.sh` saw an uncommitted file during the build, although the tree was clean at its start and is clean now. The report maps both spellings to `w84`.
- **Steps.**
  - `wstall`, part A, untimed: `bench/tasks/stall.sh` with the real binaries. `base` (#62285's partr build, the positive control) runs first, then `w84`, `w84-base` and `control`, interleaved for 10 runs; then 10 more runs of the three. A run on `w84` that is not ok adds `W84_MORE` runs of `w84` alone.
  - `wtasks`, `wspawn`, `wpool81` and `wpool80`: SpawnWait; the spawn path at H = 0, C = 50 and 500, `:interactive`, 8,1; and the Channel pool at C = 500. Each runs on the four columns, 12 rotated rounds.
  - `wperf`: `perf_unmarked.sh a1g1` on `w84-base` and `w84`.
  - `wplain81`: `/plaintext` under oha, 6 rounds.
  - Cut order: `wplain81`, `wperf`, `wpool80`.
- **Pool steps.** `pool_rounds` takes `POOL_CELLS`, so the pool's two layouts can be separate steps.
- **Report:** `master_measure_report.jl <OUT>`, section S4.
  - It gives every ratio as a speed, with the bar fixed before the run: w84/w84-base is read only beyond 5% and beyond 3 × |control2/control − 1|.
  - Each cell reads A GAIN, A LOSS or NOT READABLE, with the July version's ratio beside it (another day, another pair of builds, not rerun).
- **Results** (2026-11-26, local under `~/app/julia-618-master/results/s4`; the #618 comment of that day has the tables):
  - Part A: the positive control stalled in 2 of 10 runs, and `w84`, `w84-base` and `control` passed 20 of 20 each.
  - Part B: w84/w84-base reads A GAIN in every cell.
    - SpawnWait 1.58×; the `8,1` spawn path 1.46× and 1.45×.
    - The pool 1.15× at `8,1` and 1.18× at `8,0`; `/plaintext` at `8,1` 1.06×, with p99 12.5 ms against 13.4.
  - On SpawnWait, the default threads run 3.9× fewer user instructions per operation and sleep about 20× less often.

### `SESSION=5`: the starved cell on JuliaLang/julia#62284's head (#618, session 9)

The stock starved cell runs on `w84`, `w84-base` and `control`: 500 closed-loop clients on `:interactive`, each spawning a 2 ms task on `:default`; 8,1; 8 s; nothing marked. It runs 5 rotated rounds, a fresh process a round, after one throwaway slot (step `wstarved`, through `step_starved`). Step `wmwe` (cuttable) then runs `candidate/mwe.jl` once on each build.

The report is section S5 of `master_measure_report.jl <OUT>`: p99, the least-served client and tasks/s. A build reads THE STARVATION HOLDS when its p99 is above 1,000 ms in every round; otherwise the report says what it read. Local only, as for S3 and S4, and nothing was posted to, or drafted for, JuliaLang.

**Results** (2026-11-26, under `~/app/julia-618-master/results/s5`):
- **The starvation holds on all three.** `w84` reads p99 3112 ms [3068–3270], `w84-base` 3163 [2666–3442] and `control` 3124 [2811–3412]; the least-served client finishes 1 task on each.
- `mwe.jl` gives p99 3138 ms on `w84`, 2878 on `w84-base` and 3279 on `control`, with a least-served client of 1, 1 and 2.
- Inferred, not measured: #62284's two commits change when threads wake and where they park, not which waiting task a pop takes, which fits the cell reading the same on all three builds.

## The PR candidate (#618, session 4)

The measured design in the form a reviewer of Julia would receive it: the port's two commits rebased on
JuliaLang/julia `master` at **`419aba7972bfcb5f18bf8514fe7c86babdb1fa29`** (2026-11-24), with every line
of validation code taken out, tests in Julia's own `test/`, the experimental marking and the
environment variable's manual entry. Local only: nothing here was pushed to, or proposed on, JuliaLang.

| Patch | sha256 | What |
|---|---|---|
| `candidate/0001-*.patch` | `56da7f51c27df7c42dc2541104701defd79dc44a3c489ef68df6bdc777c2e7bc` | commit 1, the measured design, tests, NEWS, manual |
| `candidate/0002-*.patch` | `e075ff604c476aab24b8e59cd15536d0aed9c9e7f98988bd0f834ec6c56a77a9` | commit 2, the unmarked insert inlined into `enq_work` |
| `candidate/validate.patch` | `70dca07e2c7caa1a7d1fec924f556103cc4f7925b5e504644de5af402518e19e` | the validation, put back on top (additions only, switch on) |

`git am` the two `000*` files on `419aba7972` to get the candidate; add `validate.patch` with `git apply`
for the validation build. The commit messages are kept in the series.

**What differs from `native-mark-master.patch` and why.**
- Nothing under the patch moved between `4b0df1484a` and the pin: `git diff 4b0df1484a 419aba7972` is
  empty over `base/partr.jl`, `base/task.jl`, `base/threadingconstructs.jl`, `base/boot.jl`,
  `src/julia_threads.h`, `src/jltypes.c`, `src/task.c` and `src/scheduler.c`. The cherry-pick applied
  without a conflict (`test/core.jl` merged at an offset), and `jl_task_t`'s last padding byte in the
  first cache line (offset 63) was still free.
- The R heaps regenerated from the pin's four functions are text-identical to the port's;
  `r_heaps.jl check` passes on the candidate and fails, as it must, on the tag's branch (both pops).
- The validation is gone: the `SCHED_VALIDATE` switch and its macro, the counters, the order assert,
  the stall detector, the three planted errors, the probe helpers, the queue-depth probes
  (`f_queued`, `r_queued`, `fair_on`) and the unread `fp.tsc`. `fparams` loses `neg` and `tsc`.
- Comments that named this repository or the experiment are rewritten. The `fair` keyword's docstring
  and the manual entry carry Julia's experimental warning ("This interface is experimental and
  subject to change or removal without notice.", as `@opaque` and `Base.Experimental` mark theirs) and
  a `!!! compat "Julia 1.15"`. NEWS.md has an entry under *Multi-threading changes*.
- Tests: a testset at the end of `test/threads_exec.jl` (the keyword, the class each task gets, every
  marked task run once, cancellation of marked work in four forms), run by `threads.jl` at five thread
  layouts, and the atomic-field line of `test/core.jl`.

**Branches and trees** (local clone `~/app/julia-62285/src`, push URL `DISABLED`; trees under
`~/app/julia-618-master/`, the master trees' `Make.user`, `build.sh <tree>`, a wrapper and a first depot
each): `nitro-618-fair-candidate` (tree `candidate`), `nitro-618-fair-candidate-validate` (tree
`candidate-validate`), `validate-off` (the validation branch with the switch set back to false,
uncommitted: it compiles the three entry points to the candidate's code), and the pin untouched, built
twice (`pin-control`, `pin-control2` with an untracked marker; it reports `419aba7972*`).

**Which checks run where.** On `candidate-validate`: `rounds_fifo.sh PROFILE=native VALIDATE=1` with
its three negative controls, `native_checks.jl` (8,1, 8,2, 1), `master_checks.jl` (8,1, 8,2),
`wake_window.jl` ring and wake at 2,1 with the rblind positive control. On `candidate`: the checks
that need no counter (`native_checks.jl` and `master_checks.jl` now run on a build without the
validation and skip what reads the counters), Julia's tests, and the new testset alone 20 times at
each layout. The bench scripts read `SCHED_VALIDATE` and the depth probes behind `isdefined` now.

### The evidence, regenerable

`candidate_evidence.sh <master> <master, second build> <this PR>` regenerates every number the PR
description quotes, from any three builds: the claims table's rows a–i (in its header), the standalone
reproducers in `candidate/` and the description's reproducer, behind `quiet.sh`, with the ps check
and the cache-write check around every step. It writes `raw/` (the per-round TSVs), `environment.md`
and `results.md`; `results.md` is written by `candidate_evidence_report.jl`, never by hand, and gives
each row as a claim, the command, a table of speeds (above 1 is faster) and the criterion with PASS or
FAIL. The reproducers in `candidate/` need only the standard library and run on any build (a build
without the keyword says so): `julia --threads=8,1 candidate/starved.jl [fair]`, `fib_fine.jl`,
`armed.jl [armed]`, `julia --threads=2 candidate/pfib.jl [none|root|all]`,
`julia --threads=8,0 candidate/spawn_path.jl [plain|fair] [clients]`. This session's run is in
`evidence/candidate-20261124/` (run with `OUT=` there; the default output under `bench/results/` is ignored by git). In the committed copy, absolute home paths read `~` and the test logs' host name reads `<host>`; nothing else was edited.

## The PR candidate, second version (#618, session 5)

The candidate of 2026-11-24 with what a first read of the scheduler code would reject fixed where the fix is small and can be checked. Same base, `419aba7972`, and same controls (`pin-control`, `pin-control2`). Local only: nothing was pushed to, or proposed on, JuliaLang.

| File in `candidate-v2/` | sha256 | What |
|---|---|---|
| `0001-*.patch` | `bce0647eb49d5602e8c99f813a4939e62cf5b1790e260a5555c1c7de0c23c1a3` | commit 1: the design with changes 1–4 and 6, its tests, NEWS, the manual |
| `0002-*.patch` | `74c5931ac931f871da5b9f768c1f4cd40f121d363df453972c9ef3a9f2390ee5` | commit 2: the unmarked insert inlined into `enq_work` (unchanged) |
| `validate.patch` | `96525fec25359a05f7581a0f6a60732b06e274fd7bb409dc2b0b5841b1f67ad5` | the validation, additions only, switch on |
| `bypass.patch` | `1b56e5e05d56b94c32e0ec394d5d9a0e6756d377becaaba6752fd9b7d271a609` | the bypass control on v2 (stock's entry points under master's names; the mark's compiled in, unreachable) |
| `timens.patch` | `1ebe38ee94ec6ffd155e71a7e9628b9dcd776af00205ab0b3c0c1f16f936e943` | variant, not adopted: `time_ns()` as the clock everywhere |
| `attempt-r-heaps-inline-bodies.patch` | `04eb755b905a9dbe6bb46a8720def6b532e5496df33d80864b65e22dc4711870` | change 5 as specified (shared `@inline` bodies): fails the gate, not applied |
| `attempt-r-heaps-eval-loop.patch` | `869e08d9a302d7c1b4c33d7fc81b76c600c660743a4ff0477eeef8c882490849` | change 5 another way (one source, an `@eval` loop over both heap sets): passes the gate, not applied |

`git am 0001-*.patch 0002-*.patch` on `419aba7972` gives v2; `git apply` any of the others on top of it.

**What changed from the candidate of 2026-11-24, change by change, with its check:**

1. **`f_pop!` woke only owners with a thread id under 64.**
   - Now each passed-over owner sets a bit in a per-thread mask. The mask is a `Vector{UInt64}` in the thread's accounts, sized from `maxthreadid()` when the accounts are, and regrown in `ring_pop!`, outside every lock, if threads were added.
   - The pop ORs bits under the ring's lock and wakes the owners after unlocking. It allocates nothing, and it never calls the runtime's wake under the lock. An owner past the mask makes it wake every thread past it.
   - Check: `v2_checks.jl wake64 ring` at `--threads=72` (correctness, never timed), with a marked root pinned to thread 73, asleep. The task is put in a ring with `Partr.multiq_insert` (as `enq_work` does, but without its direct wake of a pinned task's owner, #58689), and one other `:default` thread is woken.
     - The candidate's validation build aborts in its stall detector, three runs of three: thread 2 passed the task over 10⁶ times while owner 73 made no pop.
     - v2 runs it once, on its owner, in 2–5 ms.
     - The forms `busy` and `sleep` pass on both builds. `enq_work` wakes the owner itself in both, so they cannot test this fix.
2. **The ring's head stamp is atomic.**
   - `fqueue.hstamp` is `@atomic`, `typemax(UInt64)` when the ring is empty, and written under the lock by every push, remove and grow. `ring_head` reads only it.
   - Fields read outside their lock now:
     - `fqueue.n` and `fqueue.hstamp`, which are atomic;
     - `rings[tp]` and `sstates[1]`, the same unlocked read of a vector element replaced whole under its lock that stock makes of `heaps[tp]`.
   - Nothing else is read unlocked. The ring pick went from 133 to 71 instructions.
3. **`fair_init!` holds no lock across its 10 ms calibration,** and the calibration loop has a safepoint. Check: `v2_checks.jl init2`, two tasks marking at once in a fresh process: both return, with the parameters set.
4. **The words.** NEWS.md and the `fair` docstring say "start in approximately the order they were spawned".
5. **The R heaps without the copy: not applied.**
   - The prompt's form failed its gate: one `@inline` body for each of the four heap functions, with thin callers for stock and the R side. Stock's and the R side's insert, check and size compile to the candidate's native code. Both pops do not: their GC root slots are assigned in another order, and three pairs of 8-byte zero stores become 16-byte vector stores. The frame size and the instruction count are unchanged.
   - So the copy stays, `r_heaps.jl` still applies to this branch (its check passes on v2), and the attempt is `attempt-r-heaps-inline-bodies.patch`.
   - A second form passes the gate on all twelve functions and is offered as `attempt-r-heaps-eval-loop.patch`: stock's four functions written once in an `@eval` loop over both heap sets.
6. **`f_lock!` is gone** (`lock(q.lock)` at both sites; the validation counts ring locks with a hook before each). The ring helpers are `ring_*`, so `r_` now means the R heaps only.

On the final builds, v2 compiles all twelve compared functions (`enq_work`, `trypoptask`, `multiq_insert`, `multiq_check_empty`, `multiq_size`, stock's insert, pop and check, and the R side's four) to the candidate's native code, and `v2-validate-off` compiles them to v2's. `native_code_gate.sh <julia A> <julia B>` is the gate: it runs `unmarked_code.jl --full --heaps` on both builds, cuts the output into one block per function, normalises addresses and symbol suffixes, and says IDENTICAL or DIFFERS for each. `v2_checks.jl` holds the probes of changes 1 and 3.

**Builds and trees** under `~/app/julia-618-master/`:
- `v2` and `v2-validate`: the local branches `nitro-618-fair-candidate-v2` and `…-v2-validate`;
- `v2-validate-off`: the validation branch with the switch false;
- `v2-bypass` and `v2-timens`: the local branches `…-v2-bypass` and `…-v2-timens`.

**Unchanged, and still on the reviewer's list:** the paddings, the constants, the environment variable read in Base, the pool flag that is never cleared, the class names, the inconsistency of a one-thread `:interactive` pool, and the untested paths.

**The evidence of v2** is in `evidence/candidate-v2-20261124/`. It ran `candidate_evidence.sh pin-control pin-control2 v2 v2-bypass` with `TIMENS=v2-timens`.
- The bypass is a fourth column in row e and in row f's unmarked line.
- Row e reads, per cell:
  - **LAYOUT** if v2 is within the floor of master's second build, or if the bypass stands with v2;
  - **THE PATH** if the bypass stands with both master builds while v2 is slower than all three in 10 of 12 rounds, with its size in ns an operation;
  - **NOT SEPARABLE** otherwise.
- Row d's bar is p99 ≤ 150 ms in every round and a median throughput ≥ 0.98, beside master's own spread between rounds. The bar of 2026-11-24 asked 0.98 in every round, tighter than two runs of master agree.
- Each row with a standalone reproducer sets the reproducer's number beside the harness's.
- The time_ns variant has its own steps (`t*`, cut first under `DEADLINE`) and its own section.
- In the committed copy, home paths read `~` and the test logs' host name reads `<host>`.

## The PR candidate, third version (#618, session 6)

v2 with the maintainer's two decisions of 2026-11-25 applied, checked and measured whole again. Same base, `419aba7972`, and same controls (`pin-control`, `pin-control2`). Local only: nothing was pushed to, or proposed on, JuliaLang.

| File in `candidate-v3/` | sha256 | What |
|---|---|---|
| `0001-*.patch` | `e175b765f59c63e531db88083ef00a6376d8d41c89383f801dfad71bf089af56` | commit 1: the design with both changes, its tests, NEWS, the manual |
| `0002-*.patch` | `5c9a6b740df370858a8c83f64c0e7ebd9b5ac503690d62445aeb701cb7870868` | commit 2: the unmarked insert inlined into `enq_work` (unchanged) |
| `validate.patch` | `ee4d8a912f611535e13de40869a9410927925c05caf7f61a8f6251de49fa446f` | the validation, additions only (286 lines), switch on |
| `bypass.patch` | `3f278e0c27192db89dff0e58abe18fe621a23826b1ff2d2c165c3c20c3136435` | the bypass control on v3: stock's four heap functions in master's text under master's names; the mark's entry points compiled in, unreachable |

`git am 0001-*.patch 0002-*.patch` on `419aba7972` gives v3; `git apply` either of the others on top of it.

**What changed from v2, and why:**

1. **`time_ns()` is the clock, on every platform** (the maintainer's decision; v2's `timens.patch` measured it at 1.4–1.6 points on the marked spawn path and nothing else). The cycle counter, the 10 ms calibration, the architecture branch and the second `DEFAULT_CAP` are gone: one cap, `10_000_000` ns. `fair_init!` now only reads `JULIA_SCHED_FAIR_WEIGHT` and publishes it, under its lock, so that the weight is published once; `fp.cap` is written only by its constructor. The first marked spawn returns in under 0.01 ms (v2: about 10 ms). The `fparams` comment and `_spawn_set_fair`'s docstring no longer mention a calibration; NEWS and the manual entry never named the clock.
2. **The R heaps share stock's heap functions** (the maintainer's decision; v2's `attempt-r-heaps-inline-bodies.patch`). Each of stock's four heap functions is one `@inline` body taking the heap vector (and its lock, or its size function); stock's and the R side's are thin callers. The copy is gone (+19 −168 on v2), so **`r_heaps.jl` is not needed for this branch** (kept for the earlier ones).
   - `native_code_gate.sh` is now a report, not the gate: ten of the twelve compared functions compile to v2's native code. Both pops differ, in the same way: the GC root slots (`[rbp-48/56/64]`) are assigned in another order, three pairs of 8-byte zero stores become one `vxorps` and one 16-byte `vmovaps`, and the last alignment `nop` differs. The frame and the instruction count (464) are unchanged.
   - The question "what does code that marks nothing pay for this" is asked by measurement instead: row e, with a bypass that carries **master's text** for stock's four functions, so that the bypass standing with v3 cannot hide a cost of the shared bodies.
   - The image does not shrink. The `_multiq_*` bodies are also compiled standalone into it, while their callers inline them: `sys.so` is 46 KB larger than v2's (`.text` +19 KB).

v3's diff against `419aba7972` is +770 −12 lines (v2: +938 −10).

**Checks** (as for v2; on `v3-validate` unless said):
- the diff from v3 to v3-validate only adds lines (286), and `v3-validate-off` compiles all twelve compared functions to v3's code;
- `rounds_fifo.sh PROFILE=native VALIDATE=1` is clean, and its six negative controls fail;
- `native_checks.jl` and `master_checks.jl` pass;
- `v2_checks.jl wake64 ring` at `--threads=72` and `init2` pass;
- `wake_window.jl` ring and wake at 2,1 report 0 stuck in 19.4 M and 18.6 M rounds, and the R-side positive control 34 stuck;
- the new testset passes 20 of 20 runs at five layouts, and `make check-whitespace` is clean.

The credited share reads 50.0% at w = 1/2 on the new clock. No assert of the validation assumed cycle units: its clock sums are named `f_cyc`/`l_cyc` but are only summed, and the harness converts them through `fp.cap / 10`. The bypass's four heap entry points compile to master's own code.

**The evidence of v3** is in `evidence/candidate-v3-20261125/`. It ran `candidate_evidence.sh pin-control pin-control2 v3 v3-bypass` with `CE_PREV` pointing at v2's run, so `results.md` ends with a "v2 against v3" table of the two runs' medians.
- Row f's unmarked floor is now one-sided: only slower than master by more than the floor fails. Row h is a stated cost with no bar, printed beside the earlier readings.
- Every cell of row e reads LAYOUT, and row f's unmarked line is within its floor, so the `@eval` fallback was not needed.
- **Row f's root-marked line fails its 0.90 bar** (0.886 at 2 threads, 0.889 at 8,1). Row h reads 6.1%, and the marked spawn path 0.82.

**Which change moved the marked rows:** `evidence/candidate-v3-clock-diag-20261125/` (its README; `clock_diag_report.jl`). It is not in the prompt, and not in the evidence directory. It measured rows f and h on v2, v2-timens and v3 in one block, with existing builds, `PFIB_COLS` and `ARM_COLS` (column overrides added to `candidate_evidence.sh`; the defaults are unchanged).
- **The clock moved them.** `time_ns()` costs the root-marked pfib(25) 4.5 points at 2 threads and 2.4 at 8,1, and work after one marked task 2.6 points.
- The shared bodies add at most about a point, within the spread.

**Builds and trees** under `~/app/julia-618-master/`: `v3`, `v3-validate` (the local branches `nitro-618-fair-candidate-v3` and `…-v3-validate`), `v3-validate-off` (switch false) and `v3-bypass` (`…-v3-bypass`). Notes are in `notes-s6.md`, the checks in `results/s6-checks/`.

## The PR candidate, fourth version (#618, session 7)

v3 with one clock read removed: in `fair_deletemin` the clock is read only when its value is used. Same base, `419aba7972`, and same controls (`pin-control`, `pin-control2`). Local only: nothing was pushed to, or proposed on, JuliaLang. **v4 is the candidate: adopted by the maintainer on 2026-11-26 over the block's rule** (session 7's block kept v3, below). His reasons:

1. with nothing marked, on a path where v3 and v4 have identical native code in all twelve compared functions, v4 read 0.988 of `master` and v3 1.008. The block itself shows a 2% difference between these two builds that is not code, so 1.9% on another line cannot be read as code;
2. the vetoing line is the misuse of the mark, already at 0.39× of `master` (0.391 → 0.385);
3. the WORSE threshold (1.5%) sat inside that range, and "below 1 in 10 of 12 rounds" is what one layout draw gives;
4. the account is proved identical, and not reading a clock whose value is unused is the code a reviewer would ask for.

**What changed from v3, and why.** v3 read `time_ns()` at every pop while the pool flag was set. The value was used in two cases only: to close the interval the previous pop opened (`s.k != 0`: that pop found both sides with work), or to open one at this pop (both sides have work now). Otherwise it was stored in `s.stamp` and never read before the next store. v4 reads it only in those two cases:

```julia
both = lw && (rr || rf)
if s.k != 0 || both
    now = s_stamp()
    if s.last != 0 && s.k != 0
        # the credit, unchanged
    end
    s.stamp = now
end
s.k = both ? 1 : 0
```

No account changes. The rows that paid the clock most, pfib(25) with the root marked and unmarked work after one marked task, mostly pop with one side empty, so v4 reads no clock there at all. The block comment, the comment above the read and the `stamp` field's comment now say when the clock is read. NEWS, the docstring and the manual never named the clock, and are unchanged.

**The equivalence, off the scheduler, before any build:** `clock_read_equiv.jl` holds v3's and v4's account updates as two pure functions over the same state (`bal`, `stamp`, `last`, `k`) and the same inputs: the three emptiness flags, a clock value, and the pop's outcome, turned into a side by each rule's own `rfirst`.
- 10^6 random pop sequences (24.5 M pops) cover all eight flag combinations, empty returns, clock steps above the cap, the balance at its limit and the three weights, at the real cap and at a small one.
- At every step the two rules give the same balance, the same choice (`rfirst`), the same `last` and the same `k`. The stamps differ at 9.45 M steps, and at none of them does the next pop read the stamp.
- **The negative control** is a rule that reads the clock only when both sides have work now (the `s.k != 0` arm dropped). It fails at the fifth pop of the first sequence: a pop with nothing anywhere, after a pop that found both sides with work, must close that pop's interval, and the control never does.

| File in `candidate-v4/` | sha256 | What |
|---|---|---|
| `0001-*.patch` | `4e583f486a83bab0330bdb8956a7b6ffac5dc8a339b47b855695fc94577e0699` | commit 1 (`46552a2c20`): the design with the clock read only when used, its tests, NEWS, the manual |
| `0002-*.patch` | `ae5aa976327be70ab08fefd2e78ce51a3566afebe27332abcd5a2a61d04c06b7` | commit 2 (`1bffccdc2f`): the unmarked insert inlined into `enq_work` (unchanged) |
| `validate.patch` | `0ed5a4f85b37050e0a69b52d358c5f2c105e257258a9c3e01a6280915ccc543d` | the validation (`bc7af35ce6`), additions only (286 lines), switch on |
| `bypass.patch` | `150ac25c796bd76f1e37089fe335b6916c10dcc9f528a86e3ef98a55e064ff73` | the bypass control on v4 (`1c676fcdb3`): stock's four heap functions in master's text under master's names |
| `attempt-clock-read-when-used.patch` | `7c694b78799263c4ad11f163a851fa35a6f196f45c6caae675b1939900fb9589` | v3 → v4, on top of `candidate-v3/0001` + `0002` (`git apply` gives v4; +26 −21, `base/partr.jl` only) |

`git am 0001-*.patch 0002-*.patch` on `419aba7972` gives v4 (checked: the diff against `nitro-618-fair-candidate-v4` is empty); `git apply` either of the other two on top of it.

**The block's rule kept v3** (it was overridden, above) (`evidence/candidate-v4-clock-compare-20261126/`, its README; `clock_compare_report.jl`). Rows f, g and h ran on v2, v3 and v4 in one block, 12 rounds each, with master as the reference. A line reads BETTER if the median of v4/v3 is at least 1.015 and v4/v3 is above 1 in at least 10 of 12 rounds, and WORSE if the median is at most 0.985 and v4/v3 is below 1 in at least 10 of 12. v4 was to be adopted only if a deciding line read BETTER and no line of f, g or h read WORSE.

| line (speed against master) | v2 | v3 | v4 | v4/v3 | reading |
|---|---|---|---|---|---|
| f pfib(25) root marked, 2 threads | 0.937 | 0.895 | 0.937 | 1.044, 12 of 12 above | BETTER |
| f root marked, 8,1 | 0.902 | 0.884 | 0.898 | 1.018, 12 of 12 above | BETTER |
| f every spawn marked, 2 threads | 0.431 | 0.410 | 0.420 | 1.023, 11 of 12 above | BETTER |
| f every spawn marked, 8,1 | 0.392 | 0.391 | 0.385 | 0.981, 12 of 12 below | **WORSE** |
| g everything marked, C = 50 / 500 | 0.850 / 0.841 | 0.824 / 0.822 | 0.825 / 0.823 | 1.002 / 1.006 | SAME |
| h after one marked task, against never marked | 0.962 | 0.945 | 0.968 | 1.024, 10 of 12 above | BETTER |

- The removed read was worth what the diagnostic of session 6 put on the clock: root-marked pfib(25) returns to v2's speed at 2 threads (0.937), and the cost after one marked task falls from 5.5% to 3.2%.
- At 8,1 with every spawn marked, v4 is 1.9% slower than v3, in every round, and at 2 threads the same line is 2.3% faster. With every spawn marked, stock's heaps are almost always empty, so v4 skips nearly every read there. Not separated (inferred): `fair_deletemin`'s own code changed, and one build of each version is one layout draw, which can repeat a difference in every round.
- The checks are those of v3, all green on `v4-validate` and `v4`.
  - `native_code_gate.sh` reports the twelve compared functions identical to v3's, since the change is inside the `@noinline` `fair_deletemin`.
  - The credited share reads 25.3 / 50.0 / 74.8% at w = 1/4, 1/2, 3/4.
  - Julia's seven test sets give master's counts (7,357,256 passed, 12 broken).
- The validation needed no clock read of its own. Its sums take the interval from the credit arm, which v4 still reads, and its run sums from `v_gcount`'s own read.

**Trees** under `~/app/julia-618-master/`: `v4`, `v4-validate`, `v4-validate-off` and `v4-bypass`, with the local branches `nitro-618-fair-candidate-v4` (`46552a2c20`, `1bffccdc2f`), `…-v4-validate` (`bc7af35ce6`) and `…-v4-bypass` (`1c676fcdb3`). Notes are in `notes-s7.md`, the checks in `results/s7-checks/`. `candidate_evidence.sh` gained `SPAWN_COLS`, a column override for row g (the default is unchanged).

### The evidence of v4 (#618, session 9)

`evidence/candidate-v4-20261126/` ran `candidate_evidence.sh pin-control pin-control2 v4 v4-bypass` with `CE_PREV` pointing at v3's run, so `results.md` ends with a "v3 against v4" table of the two runs' medians. The trees were not rebuilt: each wrapper reports the branch commit (`1bffccdc2f`, `bc7af35ce6`, `bc7af35ce6*` with the switch off, `1c676fcdb3`). Session 7's checks were not rerun.

The report's bars changed before the run, and nowhere else:
- **Row e** has one rule. A cell is WITHIN THE FLOOR when |this PR/master − 1| ≤ max(|second build/master − 1|, 0.5%). Otherwise it reads OUTSIDE THE FLOOR, with its size, this PR against the bypass, and the rounds on each side of 1. No verdict about the path is drawn from one build of each.
- **Row f**: only the unmarked line has a bar (one-sided, as for v3). The root-marked and every-spawn lines are stated costs.
- **Row h** is a stated cost given three ways (never marked against master, after one marked task against master, the second against the first), beside the earlier readings.
- A row outside its bar prints **RESULT** (outside its bar), where it used to print FAIL.

Results:
- Rows a, b, c, d, g and i pass as v3's did. The starved cell's p99 is 3234 → 151.0 ms with the least-served client 1 → 60; the server is at 1.018× (8,1) and 1.014× (8,0) of master's throughput; Julia's seven test sets give master's counts.
- **Row e: every cell WITHIN THE FLOOR.** `fib_fine` reads −1.34% against a floor of ±1.60%; the spawn path at H = 0 reads −0.43% and −0.35% against ±0.95% and ±0.96%.
- **Row f's unmarked line is a RESULT.** It is slower than its one-sided floor at both layouts: −1.01% against −0.50% at 2 threads, −1.37% against −1.20% at 8,1. The bypass (stock's entry points, the same binary) reads 0.985 and 0.987 there. The stated costs are 0.925 / 0.898 with the root marked and 0.421 / 0.387 with every spawn marked.
- **Row h**: 1.8% never marked against master, 5.5% after one marked task against master, and 3.4% for the second against the first.

**The series on JuliaLang/julia#62284's head** (read, not built): `git am -3` of `0001` on `293a8f6a7d` stops on one conflict hunk in each of `NEWS.md`, `base/partr.jl` and `test/threads_exec.jl`. #62284 touches none of these three files, so the conflicts come from master's drift only (`partr.jl`'s is master's `yield_os_thread` in the context).

**The second layout draw** (`evidence/candidate-v4-layout-draw-20261126/`, its README; `layout_draw_report.jl`). It reruns the two lines session 7's block could not read on v3 and v4. Each version also gets a second binary, its validation build with the switch off, which the gate shows compiles to the same code. The reading was fixed before the block: THE SAME SIGN IN BOTH PAIRS, or NOT REPEATED. It decides nothing.
- pfib(25) with every spawn marked at 8,1 reads THE SAME SIGN IN BOTH PAIRS: v4/v3 is 1.010 and v4-off/v3-off 1.017, so v4 is faster in both pairs. Session 7's 1.9% loss did not repeat.
- `fib_fine` with nothing marked reads NOT REPEATED: v4/v3 0.992 and v4-off/v3-off 1.020. Two pairs with the same code differ by 2.8 points on this line.

**Harness pieces added:**
- `layout_draw_report.jl <dir>` is the second draw's report.
- `unmarked_code.jl --fair` adds `Partr.fair_deletemin()` to the compared functions.
- `native_code_gate.sh` passes `GATE_EXTRA` on to it. The default set is unchanged.
- Gate results (`~/app/julia-618-master/results/s9-gate/`): v3 against v3-validate-off and v4 against v4-validate-off, 13 of 13 functions IDENTICAL each.

Notes are in `notes-s9.md`.

## The PR candidate, fifth version (#618, session 10)

v4 with five changes, all outside the unmarked path, from an outside review of v4's patch that the maintainer read on 2026-11-27. Same base, `419aba7972`, and same controls (`pin-control`, `pin-control2`). Local only: nothing was pushed to, or proposed on, JuliaLang. The weight's shell is **internal**. The launcher carried both choices, and the prompt's default for no choice is `internal` (recorded as decided without the maintainer).

**The five changes, each with where it came from and its test:**

- **A. `fair=false` opts out.** From the review: `fair=false` wrote nothing, so `fair_descendant` made R every unclassed task whose first enqueue was made by a classed task. A background loop that a marked request starts lazily was R for the life of the process, with its children, and the request side serves the R heaps before the rings. Now an explicit `fair=` that evaluates to false writes a third class, `C_STOCK = 0x03`; an absent keyword still writes nothing. At the task's first enqueue the insert takes stock's path and clears the class, so the task's own children are stock's unless marked. `fair_descendant` counts only F and R, so a task that still holds `C_STOCK` (a pool of one thread never reaches the multiqueue) classes nobody. The value never reaches the rings, the R heaps or the time share. **Tests:** the testset's `fair=false` set has three cases. Under a marked root, the opted-out task and its child have no class, while a plain sibling is R. Kept alive past its root, the task spawns again with no class. In a child process where nothing was ever marked, it gets no class and the flag stays unset. Also `native_checks.jl`'s v5 opt-out line (the `opt_out` counter) and `optout_check.jl` (below).
- **B. The keyword's position.** From the review: `@spawn fair=true :default f()` ended in "wrong number of arguments". `fair=` is now accepted right before or right after the pool argument. Anywhere else (twice, or with a stray argument) is an `ArgumentError` that names the two accepted forms. The last argument is always the expression. **Tests:** the testset's `keyword` set: both positions, four rejected forms, and `fair=y` with a variable.
- **C. A mark outside `:default` does nothing, at the spawn.** From the review: `_spawn_set_fair` wrote the class whatever the pool. On `8,1` a marked `:interactive` task kept it and its `:default` children became R; on `8,2` the insert cleared it and they did not. `_spawn_set_fair` now reads the task's pool (set on the line before in the macro) and writes a class only for `:default`, for `true` and `false` alike. A task built by hand whose pool is set after the call keeps what the call wrote. That is nothing if its pool was not `:default` then. Otherwise it is a class that the insert clears, as before, if the task is in another pool at its first enqueue. **Tests:** the testset's `a mark outside :default` set (one rule at every layout, plus a hand-built task), and `native_checks.jl` at `8,1`, `8,2` and `1`.
- **D. The conversion.** Found by the review, never seen (the box is 64-bit): `d = now > s.stamp ? Int(now - s.stamp) : 0` converts before it clamps. Where `Int` is `Int32`, an interval over 2.147 s throws `InexactError` inside the scheduler's pop. The interval is now clamped to the cap in `UInt64` and converted after. **Test:** proof 2 in `weight_equiv.jl` (no 32-bit build: the box has no multilib toolchain).
- **E. The weight.** From the review, v4's weight had four problems:
  - it was in quarters;
  - `JULIA_SCHED_FAIR_WEIGHT` was read by the first marked spawn, so a bad value let a server start and failed its first marked request;
  - that first call fixed the weight for the process, although `fp.w4` was an atomic field read at every credited interval;
  - `get(ENV, …)`, a lock and a `throw` sat behind every `@spawn fair=expr`.

  Now the weight is an integer in thousandths (500 by default), and the account, the interval and the cap are `Int64` on every platform. The balance's bound is rescaled with it (500 caps), so that at 1/4, 1/2 and 3/4 every balance is v4's times 250 and every choice is v4's. The internal shell has no environment variable. `fair_init!`, its lock and the `inited` field are gone, and `_spawn_set_fair` only validates and writes the byte. `Base.Partr.set_fair_weight!(w::Real)` validates `0 < w < 1` (and that it rounds to 1–999 thousandths) and stores it; it may be called at any time. The manual's entry and the variable's name in NEWS, the docstrings, the block comment and the commit message are gone, and the `fair` docstring says the share is one half. The pop's arithmetic gains no branch. **Tests:** proof 1 in `weight_equiv.jl`; the testset's `the weight` set (rejects 0, 1, NaN, −0.5, 0.0004, a string and a complex; accepts 0.1, 0.9 and 1//4); the credited share at five weights (below).

**Before any build, two proofs** (`weight_equiv.jl`, beside `clock_read_equiv.jl`, off the scheduler; its output is `evidence/candidate-v5-20261127/weight_equiv.out`):
1. **v4's account update against v5's**, as two pure functions over the same inputs: the three emptiness flags, a clock value and the pop's outcome. The run covers 10^6 random pop sequences (24.5 M pops) at 1/4, 1/2 and 3/4, at the real cap and at a small one. At every step the choice, `last`, `k` and the stamp are the same, and v5's balance is exactly 250 times v4's. All eight flag combinations occur, with 2.27 M pops at the balance's limit and 6.1 M clock steps above the cap. **The negative control**, v5's rule with the bound left at v4's two caps, fails at the fourth pop of the first sequence.
2. **v5's update with every integer typed as a 32-bit build types it** (`Int32` where the patch says `Int`, `Int64` where it says `Int64`), every operation checked: 13.8 M updates. They cover every weight from 1 to 999 against 17 edge intervals from 0 to 2^63 ns, from 8 stamps, forwards and backwards, at 7 balances, then 10^7 random cases with log-uniform intervals. There is no `InexactError` and no overflow. **The negative control**, v4's `Int(now - s.stamp)` with `Int = Int32`, throws `InexactError` from 2^31 ns, and not at or below 2^31 − 1.

A 32-bit build was not possible on this box in under 30 minutes: there is no multilib `gcc` and no i386 libc headers, and installing them needs root. It was not tried: **32-bit is reasoned and modelled, not run.**

**Change D, the sweep** (v5 with the validation). The clock is read at three sites:
- the ring stamps stay `UInt64` and are only compared;
- the credit's interval is clamped in `UInt64`, then converted;
- the validation's run sums: `vstamp` is now `UInt64` (it was `s_stamp() % Int`, a truncation to `Int32` on a 32-bit build), the difference is clamped to `typemax(Int64)` in `UInt64` and converted, and the sums of clock differences are `Int64`.

No other conversion in the patch touches a clock value.

| File in `candidate-v5/` | sha256 | What |
|---|---|---|
| `0001-*.patch` | `6e4d76c76b6126b6142b32e04c1fbf518b379b56f09f40ab0b157bc56d33b637` | commit 1 (`af0914a825`): the design with the five changes, its tests, NEWS (no manual entry) |
| `0002-*.patch` | `5bb4d655774ad19a02227bf22e8deed4a6768ea742e345beac1a7f9ca4a81b31` | commit 2 (`28bdb56e6b`): the unmarked insert inlined into `enq_work` (unchanged) |
| `validate.patch` | `5ae89f4a5a8bee93f73b14607055863110dfe922b750a656edb252ecf99a2954` | the validation (`47e50381d6`), additions only (302 lines), switch on |
| `bypass.patch` | `11f849a14a03f31fdd217f557154f39ea90e8191d94fb868ae336c2c2f4bf73a` | the bypass control on v5 (`0871cde5b4`): v4's, applied unchanged |

`git am 0001-*.patch 0002-*.patch` on `419aba7972` gives v5 (checked: the diff against `nitro-618-fair-candidate-v5` is empty); `git apply` either of the others on top of it.

**The validation** is v4's, re-applied, with three differences, all additions to v5:
- the planted error and the clocksource are read once by `validate_init!`, in place of `fair_init!`; the first `Threads._spawn_set_fair` calls it, or a harness at load;
- a counter of opted-out first enqueues, `opt_out`, is added;
- the clock sums and `vstamp` are 64-bit (change D).

**Checks** (as for v4; on `v5-validate` unless said; `~/app/julia-618-master/results/s10-checks/`):
- the diff from v5 to v5-validate only adds lines (302), and `v5-validate-off` compiles all 13 compared functions (`fair_deletemin` included) to v5's code;
- `native_code_gate.sh` (a report): the twelve functions of the unmarked path compile to v4's code; `fair_deletemin` does not (477 lines against v4's 494);
- `rounds_fifo.sh PROFILE=native VALIDATE=1` is clean, and its six negative controls fail;
- `native_checks.jl` passes at 8,1, 8,2 and 1 on both builds, and `master_checks.jl` passes at 8,1 and 8,2. `native_checks.jl` now branches on `C_STOCK`. On v5, a marked `:interactive` task has no class at every layout, a hand-built task made in the `:interactive` main task gets no class, and the opt-out under a marked root is counted. Its first run failed on that hand-built task: the check's expectation, not the patch;
- `v2_checks.jl wake64` (ring ×3, busy, sleep) at `--threads=72` passes; `init2` is gone with `fair_init!`;
- `wake_window.jl` ring and wake at 2,1 report 0 stuck in 19.4 M and 18.5 M rounds, and the R-side positive control 21 stuck;
- Julia's seven test sets give master's counts on v5 (7,357,256 passed, 12 broken);
- the testset passes 20 of 20 runs at threads.jl's five layouts, and `make check-whitespace` is clean;
- the credited share (plain / inner) reads 10.2 / 10.2, 25.3 / 25.2, 50.0 / 50.0, 74.8 / 74.7 and 89.9 / 89.8% at 0.1, 0.25, 0.5, 0.75 and 0.9 (v4: 25.3, 50.0, 74.8);
- **the check for change A** (`optout_check.jl`, quiet-gated, 8,1). A marked root starts a background loop with `fair=false` (a 1 ms child, then 1 ms of sleep) beside the starved cell's 500 marked clients. All 1,229 of the loop's children ran with no class. The R heaps took nothing (`r_first` 0, `r_again` 0), stock took the 1,229 (`l_first`), `opt_out` read 1, and the cell's p99 was 154.5 ms. **The positive control**, the keyword left out, sent all 1,242 children to the R heaps (`r_first` 1,243, `desc` 1,243). At this load the p99 does not tell the two apart (154.8 ms); the classes and the counters do.

The harness sets the weight through `Base.Partr.set_fair_weight!` where it exists (`NATIVE_SETW` in `multiq_variant.jl`; `GROUP_W`, a fraction, beside `GROUP_W4`), so the older builds still run. `N10` and `N90` are the share's two new weights, v5 only.

**The comparison block** (`evidence/candidate-v5-compare-20261127/`, its README; `compare_v5_report.jl`) ran rows f, g and h on v4 and v5, with master as the reference. It used 12 rounds, rotated columns, a fresh process a round and one throwaway slot. One yardstick line was added: `fib_fine` at 8,1 with nothing marked, on v5 and on `v5-validate-off` (the same code in two binaries). **It decides nothing.** Every ratio is a speed.

| line (speed against master) | v4 | v5 | v5/v4 (rounds above 1) |
|---|---|---|---|
| f pfib(25) root marked, 2 threads / 8,1 | 0.930 / 0.902 | 0.944 / 0.916 | 1.014 (12 of 12) / 1.012 (11) |
| f every spawn marked, 2 threads / 8,1 | 0.426 / 0.387 | 0.430 / 0.394 | 1.012 (10) / 1.016 (12) |
| g everything marked, C = 50 / 500 | 0.836 / 0.834 | 0.840 / 0.836 | 1.008 (11) / 1.005 (10) |
| h after one marked task, against master | 0.945 | 0.965 | 1.023 (11) |
| h after one marked task, against never marked | 0.963 | 0.975 | 1.020 (9) |

The yardstick's two readings are 0.991 and 0.988, 0.3 points apart. Every line differs from v4 by more than that, all in v5's favour (0.52% to 2.33%). The cause was not separated. `fair_deletemin`'s code changed (477 lines against 494), and one build of each is one layout draw: session 9 read 2.8 points between two pairs of identical code on `fib_fine`.

**Builds and trees** under `~/app/julia-618-master/`: `v5`, `v5-validate`, `v5-validate-off` (switch false) and `v5-bypass`, with the local branches `nitro-618-fair-candidate-v5` (`af0914a825`, `28bdb56e6b`), `…-v5-validate` (`47e50381d6`) and `…-v5-bypass` (`0871cde5b4`); same `Make.user`, own wrappers and depots. Notes are in `notes-s10.md`, the checks in `results/s10-checks/` (`checks_s10.sh`).

**Harness pieces added:**
- `weight_equiv.jl`, the two proofs, and `optout_check.jl`, the check for change A (both above).
- `compare_v5_report.jl`, the comparison block's report.
- `native_checks.jl` branches on `Base.Partr.C_STOCK` (v5).
- `multiq_variant.jl` sets the weight through `set_fair_weight!` where it exists and adds `N10` and `N90`. `server.jl` writes `group_w`, and `group_report.jl` reads it.
- `candidate_evidence_report.jl`: the least floor is 2.0% (row e and row f's unmarked line, one rule, two-sided), and row h lists v4's evidence among the earlier readings.

### The evidence of v5 (#618, session 10)

`evidence/candidate-v5-20261127/` ran `candidate_evidence.sh pin-control pin-control2 v5 v5-bypass` with `CE_PREV` pointing at v4's run, so `results.md` ends with a "v4 against v5" table of the two runs' medians. The bars changed before the run in one place: row e and row f's unmarked line share **one rule**, WITHIN THE FLOOR when this PR differs from master by no more than the larger of master's second build's distance and 2.0% (what two binaries of identical code read apart on these cells), otherwise OUTSIDE THE FLOOR, with its size and against the bypass.

**The run is in two sittings.** The Claude Code session ended at 03:59 while the driver was in step `spawnpath`, and the driver died with it. Steps `prep` to `pfib81` (rows a to f) had finished, every one exit 0 and with no cache write. The run resumed at 18:48 with `FROM=spawnpath` into the same directory, detached this time, and ran rows g, h and i, the reproducers and the report. The partial `spawnpath` files were set aside unused. Every row is paired within its own step (master's rounds beside the build's), so no row mixes the two sittings.

- **Rows a, b, c, d, g and i pass.** The starved cell's p99 is 3086 → 151.0 ms, and the least-served client 1 → 60. Beside the fork-join, p99 is 329.0 / 325.4 ms with compute at 0.545 / 0.541. The server reads 114.1 ms at 1.021× (8,1) and 110.9 ms at 0.994× (8,0). Everything marked is 0.844× / 0.839×. Julia's seven test sets give master's counts.
- **Row e: every cell WITHIN THE FLOOR.** `fib_fine` reads −0.57%, and the spawn path at H = 0 reads +0.40% and +0.10%, each against ±2.00%. Master's second build reads −0.07%, +0.22% and +0.07%.
- **Row f's unmarked line is WITHIN THE FLOOR**: +0.03% at 2 threads and +0.36% at 8,1. The bypass reads 0.986 and 0.985. The stated costs are 0.942 / 0.911 with the root marked and 0.428 / 0.396 with every spawn marked.
- **Row h**, a stated cost: 0.4% never marked against master; 4.0% after one marked task against master; 3.4% for the second against the first (the reproducer reads 2.6%).
