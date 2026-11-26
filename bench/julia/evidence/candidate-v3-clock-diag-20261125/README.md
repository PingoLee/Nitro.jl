# Which of v3's two changes moved its marked rows (#618, session 6)

Not part of the evidence directory beside it, and not asked by the session's prompt: added after the timed run, because
rows f (root marked) and h moved between v2 and v3 and both changes touch only marked paths. Rows f and h on three
existing builds in one block: v2 (the cycle counter, the R heaps a copy), v2-timens (`time_ns()`, the copy: v2's R heap
code) and v3 (`time_ns()`, the shared bodies).

    OUT=… TIMENS=bin/julia-v2-timens STEPS="pfib2 pfib81 arm" \
      PFIB_COLS="ctl:control:none r2:bypass:root rt:timens:root r3:candidate:root a2:bypass:all at:timens:all a3:candidate:all" \
      ARM_COLS="A%control N-none%bypass N-arm%bypass N-none%timens N-arm%timens N-none%candidate N-arm%candidate" \
      bench/julia/candidate_evidence.sh bin/julia-pin-control bin/julia-pin-control2 bin/julia-v3 bin/julia-v2

The **bypass** slot holds **v2** here (see `builds.tsv`). `summary.txt` is `julia bench/julia/clock_diag_report.jl <this
directory>`. Reading: the clock moves the marked rows (root-marked pfib 0.930 → 0.885 at 2 threads, 0.915 → 0.891 at
8,1; after one marked task 0.971 → 0.945); the shared bodies add at most about a point, within the spread.
