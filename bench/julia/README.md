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
