#!/usr/bin/env bash
# #618 x JuliaLang/julia#62285: the E comment's rounds on two source builds of the PR's head, WS
# (JULIA_SCHEDULER=workstealing) and BASE (partr). A round is a cost block (spawn_order.sh: the
# fairness and throughput cells, then tasks.jl's micro and queued rows) and a nesting block
# (nested.sh), each behind bench/socket/quiet.sh. The builds interleave inside a block (CHANNELS is
# the scripts' outer loop; its order alternates from round to round) and across rounds. A block whose
# gate fails (quiet.sh exit 3) or that a foreign process stopped (exit 4) is retried, RETRIES times at
# most, each attempt into its own TSV; only a finished attempt is renamed into place, so
# <OUT>/{spawn,micro,nested}-r<N>.tsv hold complete rounds only. A block that finished with a process
# killed by its timeout (the scripts' exit 2; the kill is a row in the TSV) counts as finished: the
# WS build stalls intermittently in tasks.jl's queued rows (part 1's validation), which is a result
# to record per round, not a reason to lose the round.
#
# Usage: WS=<julia binary> BASE=<julia binary> MICRO_PROJECT=<env with BenchmarkTools> \
#          bench/tasks/rounds_62285.sh [rounds]
#   OUT           results directory (default bench/results/62285)
#   ROUNDS        3 (or the argument)
#   LAYOUTS       "8,1 8,0"
#   BLOCKS        "cost nesting": which blocks a round runs
#   CELLS         spawn_order.jl cells, "50:0 500:0 500:2" (C:H ms); D=8 s each
#   TIMEOUT_S     per process (spawn_order.sh 900 s, nested.sh 600 s)
#   MICRO_TIMEOUT_S  per tasks.jl process (240 s: its rows take under a minute, a stall is a stall)
#   RETRIES       2
#   VALIDATE=1    one short validation pass instead, not behind the gate: D=1, cells "50:0.2 500:2",
#                 fib_fine at 36:12, RUNS=1, into <OUT>/validate-{spawn,micro,nested}.tsv
#   QUIET_LOAD, QUIET_WAIT_S, SAMPLE_S  pass through to quiet.sh
# Afterwards: julia bench/tasks/aggregate_62285.jl <OUT>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
: "${WS:?WS=<julia binary of the workstealing build>}"
: "${BASE:?BASE=<julia binary of the partr build>}"
: "${MICRO_PROJECT:?MICRO_PROJECT=<environment with BenchmarkTools>}"
ROUNDS="${1:-${ROUNDS:-3}}"
OUT="${OUT:-$ROOT/bench/results/62285}"
LAYOUTS="${LAYOUTS:-8,1 8,0}"
BLOCKS="${BLOCKS:-cost nesting}"
CELLS="${CELLS:-50:0 500:0 500:2}"
RETRIES="${RETRIES:-2}"
VALIDATE="${VALIDATE:-0}"
mkdir -p "$OUT"
for jl in "$WS" "$BASE"; do
  [ -x "$jl" ] || { echo "rounds_62285: $jl is not an executable" >&2; exit 1; }
done
export QUIET_LOAD="${QUIET_LOAD:-0.5}" QUIET_WAIT_S="${QUIET_WAIT_S:-1800}" SAMPLE_S="${SAMPLE_S:-5}"

log() { echo "[$(date +%H:%M:%S)] rounds_62285: $*"; }

# One block: run "$@" behind quiet.sh (or directly under VALIDATE), retrying a gate failure or a
# stopped block. Returns the command's status; a gate that never passes is 3.
block() {
  local label="$1"; shift
  local attempt=1 rc
  while :; do
    if [ "$VALIDATE" = 1 ]; then "$@"; rc=$?
    else "$ROOT/bench/socket/quiet.sh" "$label" "$@"; rc=$?
    fi
    [ "$rc" = 2 ] && { log "$label: finished with a process killed by its timeout (recorded in the TSV)"; return 0; }
    [ "$rc" = 3 ] || [ "$rc" = 4 ] || return "$rc"
    [ "$attempt" -le "$RETRIES" ] || { log "$label: giving up after $attempt attempts (status $rc)"; return "$rc"; }
    log "$label: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    rm -f "${ATTEMPT_FILES[@]}"
  done
}

cost_block() {   # round, spawn tsv, micro tsv
  local r="$1" spawn="$2" micro="$3" channels="$4"
  ATTEMPT_FILES=("$spawn" "$micro")
  if [ "$VALIDATE" = 1 ]; then
    block "cost-r$r" env VALIDATE=1 D=1 CELLS="50:0.2 500:2" ROUND="$r" CHANNELS="$channels" LAYOUTS="$LAYOUTS" \
      VARIANTS=A MICRO_OUT="$micro" MICRO_WHAT="micro queued" MICRO_PROJECT="$MICRO_PROJECT" \
      FAN_OUT_NS="1000 10000" TIMEOUT_S="${TIMEOUT_S:-900}" MICRO_TIMEOUT_S="${MICRO_TIMEOUT_S:-240}" "$HERE/spawn_order.sh" "$r" "$spawn"
  else
    block "cost-r$r" env D=8 CELLS="$CELLS" ROUND="$r" CHANNELS="$channels" LAYOUTS="$LAYOUTS" \
      VARIANTS=A MICRO_OUT="$micro" MICRO_WHAT="micro queued" MICRO_PROJECT="$MICRO_PROJECT" \
      FAN_OUT_NS="1000 10000" TIMEOUT_S="${TIMEOUT_S:-900}" MICRO_TIMEOUT_S="${MICRO_TIMEOUT_S:-240}" "$HERE/spawn_order.sh" "$r" "$spawn"
  fi
}

nesting_block() {   # round, nested tsv
  local r="$1" nested="$2" channels="$3"
  ATTEMPT_FILES=("$nested")
  if [ "$VALIDATE" = 1 ]; then
    block "nesting-r$r" env VALIDATE=1 FIB_FINE=36:12 ROUND="$r" CHANNELS="$channels" LAYOUTS="$LAYOUTS" \
      VARIANTS=A SKIP= TIMEOUT_S="${TIMEOUT_S:-600}" "$HERE/nested.sh" "$r" "$nested"
  else
    block "nesting-r$r" env ROUND="$r" CHANNELS="$channels" LAYOUTS="$LAYOUTS" \
      VARIANTS=A SKIP= TIMEOUT_S="${TIMEOUT_S:-600}" "$HERE/nested.sh" "$r" "$nested"
  fi
}

status=0
if [ "$VALIDATE" = 1 ]; then
  log "validation pass (not timed, no gate): WS=$WS BASE=$BASE layouts [$LAYOUTS]"
  case " $BLOCKS " in *" cost "*) cost_block 0 "$OUT/validate-spawn.tsv" "$OUT/validate-micro.tsv" "$WS $BASE" || status=1 ;; esac
  case " $BLOCKS " in *" nesting "*) nesting_block 0 "$OUT/validate-nested.tsv" "$WS $BASE" || status=1 ;; esac
  log "validation pass done (status $status): $OUT/validate-{spawn,micro,nested}.tsv"
  exit "$status"
fi

log "$ROUNDS rounds: WS=$WS BASE=$BASE layouts [$LAYOUTS] cells [$CELLS] -> $OUT"
for r in $(seq 1 "$ROUNDS"); do
  if [ $((r % 2)) = 1 ]; then channels="$WS $BASE"; else channels="$BASE $WS"; fi
  for kind in $BLOCKS; do
    stamp="$(date +%Y%m%d-%H%M%S)"
    if [ "$kind" = cost ]; then
      spawn="$OUT/attempt-spawn-r$r-$stamp.tsv" micro="$OUT/attempt-micro-r$r-$stamp.tsv"
      if cost_block "$r" "$spawn" "$micro" "$channels"; then
        mv "$spawn" "$OUT/spawn-r$r.tsv"; mv "$micro" "$OUT/micro-r$r.tsv"
        log "round $r cost block done"
      else
        log "round $r cost block FAILED; its attempt files stay in $OUT"; status=1
      fi
    else
      nested="$OUT/attempt-nested-r$r-$stamp.tsv"
      if nesting_block "$r" "$nested" "$channels"; then
        mv "$nested" "$OUT/nested-r$r.tsv"
        log "round $r nesting block done"
      else
        log "round $r nesting block FAILED; its attempt file stays in $OUT"; status=1
      fi
    fi
  done
done
log "all rounds done (status $status); next: julia $HERE/aggregate_62285.jl $OUT"
exit "$status"
