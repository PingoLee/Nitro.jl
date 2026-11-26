# The second layout draw (#618, session 9, 2026-11-26)

Session 7's comparison block (`../candidate-v4-clock-compare-20261126/`) read two lines it could not attribute to code:
- with every spawn marked at 8,1, v4 was 1.9% slower than v3 in every round;
- with nothing marked, v4 and v3 were 2% apart on `fib_fine`, on a path where their native code is identical.

One build of each version is one layout draw. This block adds a second binary of each version: its validation build with the switch off. With the switch off, a validation build compiles the compared functions to the same code as its version. It decides nothing, since v4 is adopted either way. It says what may be claimed about the two lines.

**Gate, first** (`native_code_gate.sh` with `GATE_EXTRA=--fair`, so `fair_deletemin` is compared too; results in `~/app/julia-618-master/results/s9-gate/`):
- v3 against v3-validate-off: 13 of 13 functions IDENTICAL;
- v4 against v4-validate-off: 13 of 13 functions IDENTICAL.

**The block** is `candidate_evidence.sh` with `STEPS="prep pfib81 arm"`, 10 rounds, a fresh process a round, the columns rotated, after one throwaway slot. Its slots are as follows (`builds.tsv`):

| slot | build | commit |
|---|---|---|
| control | master (`pin-control`) | `419aba7972` |
| control2 | v3 | `2db177599e` |
| candidate | v4 | `1bffccdc2f` |
| bypass | v3-validate-off | `06d4f771fa*` |
| timens | v4-validate-off | `bc7af35ce6*` |

```
OUT=<this directory> TIMENS=<bin>/julia-v4-validate-off STEPS="prep pfib81 arm" PFIB_ROUNDS=10 ARM_ROUNDS=10 \
  PFIB_COLS="ctl:control:none a3:control2:all a4:candidate:all a3o:bypass:all a4o:timens:all" \
  ARM_COLS="A%control N-none%control2 N-none%candidate N-none%bypass N-none%timens" \
  bench/julia/candidate_evidence.sh <bin>/julia-pin-control <bin>/julia-v3 <bin>/julia-v4 <bin>/julia-v3-validate-off
```

The `bypass` and `timens` slots hold the validation builds here, not a bypass or a timer build. The arm step's `N-none` rows are `fib_fine` with nothing marked and nothing ever marked.

**The reading** (`layout_draw_report.jl <this directory>`, output in `summary.txt`) was fixed before the block ran. A line reads THE SAME SIGN IN BOTH PAIRS when the medians of v4/v3 and of v4-validate-off/v3-validate-off are both at least 1.01, or both at most 0.99. Anything else reads NOT REPEATED.

| line (speed against master) | v3 | v4 | v3-off | v4-off | v4/v3 | v4-off/v3-off | reading |
|---|---|---|---|---|---|---|---|
| pfib(25), every spawn marked, 8,1 | 0.387 | 0.391 | 0.384 | 0.390 | 1.010 (above 1 in 10 of 10) | 1.017 (7 of 10) | THE SAME SIGN IN BOTH PAIRS |
| `fib_fine`, nothing marked, 8,1 | 0.986 | 0.978 | 0.976 | 0.996 | 0.992 (3 of 10) | 1.020 (9 of 10) | NOT REPEATED |

- **Every spawn marked:** v4 is faster than v3 in both pairs, by about 1% and 1.7%. Session 7's 1.9% loss did not come back with either pair. The v4/v3 median is 1.0102, just over the 1.01 line.
- **Nothing marked:** the two pairs have the same native code. They read 0.8% and 2.0% apart, in opposite directions. That spread is how far two binaries of the same code can read apart on this line.

The prep step wrote package caches into `depot-v3-validate-off` (its first use with these packages). Prep is untimed, and no timed step wrote a cache file.
