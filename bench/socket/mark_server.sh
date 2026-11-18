#!/usr/bin/env bash
# #618, the mark in a real server: does one mark on the request task remove the original tail
# through HTTP.jl? Every block is one bench/socket/quiet.sh run of fairness.sh (the server cells)
# or of the reduced harness (cells 5 and 6), on the CPUs fairness.sh uses: servers on
# 0-3,6-9, the client on 4,5,10,11.
#
#   pilot     the gate: cell 1 at 8,1, one round, for go, bare_spawn with no VARIANT (the variant
#             file never included), bare_spawn under A, bare_marked under A (bare_spawn's own code
#             by construction), bare_spawn under M-none and bare_marked under M-g-r2
#   cell1 L   /aggregate?n=100000&op=groupby, c = 500, PROBE=1, at layout L: go, nitro (no
#             VARIANT), bare_spawn with no VARIANT, bare_spawn and bare_pool under $A, bare_spawn under
#             M-none, bare_marked under M-l-r2, M-g-r2 and C
#   cell2 L   /plaintext, c = 500, no probe, oha's throughput beside the client's (OHA=1): the same
#             servers
#   cell3     /sleep?ms=2 at 8,1, PROBE=1: bare_spawn and bare_pool under $A, bare_marked under
#             M-l-r2 and M-g-r2 (a handler that waits instead of computing)
#   cell4     /aggregate at 8,1, PROBE=1, MIX=1: unmarked fib_fine runs loop on :default during each
#             server's window (bench/tasks/mixed_cell.jl's load, in the server): bare_spawn with no
#             VARIANT, bare_pool under $A, bare_marked under M-l-r2 and M-g-r2
#   cell5     the reduced harness, requests in flight (INFLIGHT=1), one round at 8,1: spawn_order.jl
#             500:2:inner with :interactive clients, and mixed_cell.jl SHAPE=inner, for A, M-l-r2,
#             M-it-r2 and M-g-r2
#   cell6     the same with the fork-join inside one of 20 semaphore slots (shape inner20)
#   both L, both4 L, both2, bothv L   the two fixes of the `8,0` diagnostic together (agent-config #82
#             Idea 8): bare_marked_listen under M-gc-r2; see the blocks below
#
# A defaults to `@A` (bare_spawn under VARIANT=A, the variant file included); A=none runs the
# no-include process instead, for when the pilot shows the include itself costs something.
# ROUNDS (default 3) and DUR (default 8s) set the server cells; D (default 8) the harness cells.
# fairness.sh writes bench/results/fairness-<stamp>.tsv and its raw directory; the harness cells
# write bench/results/618-mark/<cell>-{spawn,mixed}-<variant>.tsv. Each block's stdout goes to
# bench/results/618-mark/<block>.log.
#
# Usage: PATH=<go on it>:$PATH bench/socket/mark_server.sh <block> [layout]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BLOCK="$1"; LAYOUT="${2:-8,1}"
ROUNDS="${ROUNDS:-3}"; DUR="${DUR:-8s}"; D="${D:-8}"
A_SUFFIX="@A"; [ "${A:-@A}" = none ] && A_SUFFIX=""
MARK_OUT="$ROOT/bench/results/618-mark"; mkdir -p "$MARK_OUT"   # quiet.sh sets its own OUT
AGG="/aggregate?n=100000&op=groupby"
CPUS="0,1,2,3,6,7,8,9"

servers() {   # the Julia servers of cells 1 and 2 at layout $1, go first
  local l="$1"
  echo "go nitro@$l bare_spawn@$l bare_spawn@$l$A_SUFFIX bare_pool@$l$A_SUFFIX bare_spawn@$l@M-none bare_marked@$l@M-l-r2 bare_marked@$l@M-g-r2 bare_marked@$l@C"
}

harness() {   # cell label, shape
  local cell="$1" shape="$2" v
  for v in A M-l-r2 M-it-r2 M-g-r2; do
    VARIANT="$v" INFLIGHT=1 D="$D" CELLS="500:2:$shape" MODES=spawn CLIENTS=interactive ROUND=1 \
      timeout -s KILL 900 taskset -c "$CPUS" julia --threads=8,1 "$ROOT/bench/tasks/spawn_order.jl" \
      > "$MARK_OUT/$cell-spawn-$v.tsv" || return 1
    VARIANT="$v" INFLIGHT=1 D="$D" SHAPE="$shape" ROUND=1 \
      timeout -s KILL 900 taskset -c "$CPUS" julia --threads=8,1 "$ROOT/bench/tasks/mixed_cell.jl" \
      > "$MARK_OUT/$cell-mixed-$v.tsv" || return 1
  done
}

case "$BLOCK" in
  pilot)
    "$HERE/quiet.sh" 618mark-pilot env PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "go bare_spawn@8,1 bare_spawn@8,1@A bare_marked@8,1@A bare_spawn@8,1@M-none bare_marked@8,1@M-g-r2" 1 "$DUR" ;;
  cell1)
    "$HERE/quiet.sh" "618mark-cell1-${LAYOUT/,/_}" env PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "$(servers "$LAYOUT")" "$ROUNDS" "$DUR" ;;
  cell2)
    "$HERE/quiet.sh" "618mark-cell2-${LAYOUT/,/_}" env OHA=1 PROBE=0 ROUTE="/plaintext" "$HERE/fairness.sh" \
      "$(servers "$LAYOUT")" "$ROUNDS" "$DUR" ;;
  cell3)
    "$HERE/quiet.sh" 618mark-cell3 env PROBE=1 ROUTE="/sleep?ms=2" "$HERE/fairness.sh" \
      "bare_spawn@8,1$A_SUFFIX bare_pool@8,1$A_SUFFIX bare_marked@8,1@M-l-r2 bare_marked@8,1@M-g-r2" "$ROUNDS" "$DUR" ;;
  cell4)
    "$HERE/quiet.sh" 618mark-cell4 env MIX=1 PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_spawn@8,1 bare_pool@8,1$A_SUFFIX bare_marked@8,1@M-l-r2 bare_marked@8,1@M-g-r2" "$ROUNDS" "$DUR" ;;
  # The `8,0` diagnostic (#618, agent-config #82 Idea 7). diag80: cell 1 at 8,0, A and bare_marked
  # under M-l-r2, M-g0-r2 (the accounts off: L always first), M-g25-r2, M-g-r2 and M-g75-r2.
  # diag80v: one VALIDATE round of each -g variant (group_report.jl <raw dir> reads its /mq files).
  diag80)
    "$HERE/quiet.sh" 618diag-80 env PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_spawn@8,0 bare_marked@8,0@M-l-r2 bare_marked@8,0@M-g0-r2 bare_marked@8,0@M-g25-r2 bare_marked@8,0@M-g-r2 bare_marked@8,0@M-g75-r2" "$ROUNDS" "$DUR" ;;
  diag80v)
    "$HERE/quiet.sh" 618diag-80v env VALIDATE=1 PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_marked@8,0@M-g0-r2 bare_marked@8,0@M-g25-r2 bare_marked@8,0@M-g-r2 bare_marked@8,0@M-g75-r2" 1 "$DUR" ;;
  # The listener's mark: A, bare_marked and bare_marked_listen under M-g-r2, and bare_marked under M-gc-r2. listen: cell 1 at the
  # layout; listen4: cell 4 (MIX=1) at 8,0; listen2: cell 2 (/plaintext) at 8,0; listenv: one
  # VALIDATE round of bare_marked_listen (and bare_marked beside it) at the layout.
  listen)
    "$HERE/quiet.sh" "618listen-cell1-${LAYOUT/,/_}" env PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_spawn@$LAYOUT bare_marked@$LAYOUT@M-g-r2 bare_marked_listen@$LAYOUT@M-g-r2 bare_marked@$LAYOUT@M-gc-r2" "$ROUNDS" "$DUR" ;;
  listen4)
    "$HERE/quiet.sh" 618listen-cell4-8_0 env MIX=1 PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_spawn@8,0 bare_marked@8,0@M-g-r2 bare_marked_listen@8,0@M-g-r2 bare_marked@8,0@M-gc-r2" "$ROUNDS" "$DUR" ;;
  listen2)
    "$HERE/quiet.sh" 618listen-cell2-8_0 env OHA=1 PROBE=0 ROUTE="/plaintext" "$HERE/fairness.sh" \
      "bare_spawn@8,0 bare_marked@8,0@M-g-r2 bare_marked_listen@8,0@M-g-r2 bare_marked@8,0@M-gc-r2" "$ROUNDS" "$DUR" ;;
  listenv)
    "$HERE/quiet.sh" "618listen-v-${LAYOUT/,/_}" env VALIDATE=1 PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_marked@$LAYOUT@M-g-r2 bare_marked_listen@$LAYOUT@M-g-r2 bare_marked@$LAYOUT@M-gc-r2" 1 "$DUR" ;;
  # The two fixes together (#618, agent-config #82 Idea 8): bare_marked_listen under M-gc-r2, beside A
  # (no VARIANT), bare_marked under M-gc-r2 and bare_marked_listen under M-g-r2. both: cell 1 at the
  # layout; both4: cell 4 (MIX=1) at the layout; both2: /plaintext at 8,0 with oha after the client in
  # every window (OHA=1), bare_spawn under M-none added; bothv: one VALIDATE round at the layout.
  both)
    "$HERE/quiet.sh" "618both-cell1-${LAYOUT/,/_}" env PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_spawn@$LAYOUT bare_marked@$LAYOUT@M-gc-r2 bare_marked_listen@$LAYOUT@M-g-r2 bare_marked_listen@$LAYOUT@M-gc-r2" "$ROUNDS" "$DUR" ;;
  both4)
    "$HERE/quiet.sh" "618both-cell4-${LAYOUT/,/_}" env MIX=1 PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_spawn@$LAYOUT bare_marked@$LAYOUT@M-gc-r2 bare_marked_listen@$LAYOUT@M-g-r2 bare_marked_listen@$LAYOUT@M-gc-r2" "$ROUNDS" "$DUR" ;;
  both2)
    "$HERE/quiet.sh" 618both-cell2-8_0 env OHA=1 PROBE=0 ROUTE="/plaintext" "$HERE/fairness.sh" \
      "bare_spawn@8,0 bare_spawn@8,0@M-none bare_marked@8,0@M-gc-r2 bare_marked_listen@8,0@M-g-r2 bare_marked_listen@8,0@M-gc-r2" "$ROUNDS" "$DUR" ;;
  bothv)
    "$HERE/quiet.sh" "618both-v-${LAYOUT/,/_}" env VALIDATE=1 PROBE=1 ROUTE="$AGG" "$HERE/fairness.sh" \
      "bare_marked@$LAYOUT@M-gc-r2 bare_marked_listen@$LAYOUT@M-g-r2 bare_marked_listen@$LAYOUT@M-gc-r2" 1 "$DUR" ;;
  cell5|cell6)
    shape=inner; [ "$BLOCK" = cell6 ] && shape=inner20
    export -f harness; export MARK_OUT D CPUS ROOT
    "$HERE/quiet.sh" "618mark-$BLOCK" bash -c "harness $BLOCK $shape" ;;
  *) echo "mark_server.sh: unknown block $BLOCK" >&2; exit 2 ;;
esac 2>&1 | tee "$MARK_OUT/$BLOCK${2:+-${LAYOUT/,/_}}.log"
