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
