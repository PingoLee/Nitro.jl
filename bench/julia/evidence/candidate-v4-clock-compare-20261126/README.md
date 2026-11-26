# The candidate's fourth version against its third: the comparison block (#618, session 7)

The block that decided whether v4 (v3 with the clock read only when its value is used) replaced v3 as the candidate.
Rows f, g and h on v2, v3 and v4 in one block, with master (`pin-control`, `419aba7972`) as the reference. 12 rounds
per row, columns rotated, a fresh process per round, one throwaway slot, behind `quiet.sh`, with the ps check and the
cache-write check around every step.

    ~/app/julia-618-master/compare_s7.sh, i.e.:
    OUT=… TIMENS=bin/julia-v2 STEPS="prep pfib2 pfib81 spawnpath arm" PFIB_ROUNDS=12 SPAWN_ROUNDS=12 ARM_ROUNDS=12 \
      PFIB_COLS="ctl:control:none r2:timens:root r3:bypass:root r4:candidate:root a2:timens:all a3:bypass:all a4:candidate:all" \
      SPAWN_COLS="A%control N%timens N%bypass N%candidate" \
      ARM_COLS="A%control N-none%timens N-arm%timens N-none%bypass N-arm%bypass N-none%candidate N-arm%candidate" \
      bench/julia/candidate_evidence.sh bin/julia-pin-control bin/julia-pin-control2 bin/julia-v4 bin/julia-v3

The slots are **candidate = v4, bypass = v3, timens = v2** (see `builds.tsv`). `summary.txt` is
`julia bench/julia/clock_compare_report.jl <this directory>`. Every ratio is a speed (above 1 is faster).

The reading of each line was fixed before the block ran: BETTER if the median of v4/v3 is at least 1.015 and v4/v3
is above 1 in at least 10 of 12 rounds; WORSE if the median is at most 0.985 and v4/v3 is below 1 in at least 10 of 12;
SAME otherwise. v4 was to be adopted only if a deciding line (f root-marked at either layout, or h) read BETTER and
no line of f, g or h read WORSE.

**Result: v3 is kept.** f root-marked reads BETTER at both layouts (v4/v3 1.044 and 1.018, 12 of 12), and so does h
(1.024, 10 of 12). But f with every spawn marked at 8,1 reads WORSE (0.981, below 1 in 12 of 12), while the same
line at 2 threads reads BETTER (1.023). Row g reads SAME at C = 50 and 500.
