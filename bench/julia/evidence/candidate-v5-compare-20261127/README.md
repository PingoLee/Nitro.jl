# The comparison block of v5 (#618, session 10, 2026-11-27)

v4 and v5 in one block, master as the reference, with one yardstick line. **It decides nothing.** v5 is the candidate if proof 1 held and no check lost a task (both did and none did): its changes are semantics and a bug, not speed. A line that differs from v4 by more than the yardstick's two readings differ from each other is reported as such, with its size.

**The block** is `candidate_evidence.sh` with `STEPS="prep pfib2 pfib81 spawnpath arm"`, 12 rounds a row, a fresh process a round, the columns rotated, after one throwaway slot. Its slots (`builds.tsv`):

| slot | build | commit |
|---|---|---|
| control | master (`pin-control`) | `419aba7972` |
| control2 | master, second build (`pin-control2`; no column reads it) | `419aba7972*` |
| candidate | v5 | `28bdb56e6b` |
| bypass | v4 | `1bffccdc2f` |
| timens | v5-validate-off | `47e50381d6*` |

```
OUT=<this directory> TIMENS=<bin>/julia-v5-validate-off STEPS="prep pfib2 pfib81 spawnpath arm" \
  PFIB_ROUNDS=12 SPAWN_ROUNDS=12 ARM_ROUNDS=12 \
  PFIB_COLS="ctl:control:none r4:bypass:root r5:candidate:root a4:bypass:all a5:candidate:all" \
  SPAWN_COLS="A%control N%bypass N%candidate" \
  ARM_COLS="A%control N-none%bypass N-arm%bypass N-none%candidate N-arm%candidate N-none%timens" \
  bench/julia/candidate_evidence.sh <bin>/julia-pin-control <bin>/julia-pin-control2 <bin>/julia-v5 <bin>/julia-v4
```

The `bypass` slot holds v4 and the `timens` slot v5's validation build with the switch off, not a bypass or a timer build. `native_code_gate.sh` finds the switch-off build's 13 compared functions (`fair_deletemin` included) IDENTICAL to v5's, so **the yardstick** (row h's `N-none` column on v5 and on `timens`: `fib_fine` at 8,1, nothing marked) is the same code in two binaries. The report is `compare_v5_report.jl`, in `summary.txt`. Every ratio is a speed: above 1 is faster.

| line (speed against master) | v4 | v5 | v5/v4, median (rounds above 1) |
|---|---|---|---|
| f pfib(25) root marked, 2 threads | 0.930 | 0.944 | 1.014 (12 of 12) |
| f every spawn marked, 2 threads | 0.426 | 0.430 | 1.012 (10 of 12) |
| f root marked, 8,1 | 0.902 | 0.916 | 1.012 (11 of 12) |
| f every spawn marked, 8,1 | 0.387 | 0.394 | 1.016 (12 of 12) |
| g everything marked, C = 50, 8,0 | 0.836 | 0.840 | 1.008 (11 of 12) |
| g everything marked, C = 500, 8,0 | 0.834 | 0.836 | 1.005 (10 of 12) |
| h after one marked task, against master | 0.945 | 0.965 | 1.023 (11 of 12) |
| h after one marked task, against the same build never marked | 0.963 | 0.975 | 1.020 (9 of 12) |

**The yardstick:** v5 reads 0.991 and v5-validate-off 0.988 against master, 0.3 points apart (v5 over v5-validate-off per round: 0.965 to 1.023, median 0.999).

**Read as the prompt fixed it:** every line differs from v4 by more than the yardstick, all in v5's favour, by 0.52% (g, C = 500) to 2.33% (h against master). One line moves by more than 2%. Not separated: `fair_deletemin`'s code changed (477 lines against v4's 494), and one build of each version is one layout draw. Session 9's second draw read two pairs of identical code 2.8 points apart on `fib_fine`, so a yardstick of 0.3 points is one draw's distance, not a bound.
