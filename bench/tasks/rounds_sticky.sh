#!/usr/bin/env bash
# #618, variant S (sticky round-robin) and P (priority as arrival sequence): the rounds driver.
# A round is one quiet block (bench/socket/quiet.sh) running spawn_order.sh over every build and
# layout with modes spawn, sticky, pool and priority (the last one gated by the P microbench inside
# spawn_order.jl) over the fairness cells (C = 500, H = 2 ms, plain, hetero and inner) and the cost
# cells (H = 0, C = 50 and 500). The build order and the mode order alternate from round to round,
# so the series interleave across rounds. A block whose gate fails (quiet.sh exit 3) or that a
# foreign process stopped (exit 4) is retried, RETRIES times at most, each attempt into its own TSV;
# only a finished attempt is renamed into place, so <OUT>/spawn-r<N>.tsv hold complete rounds only.
#
# Usage: bench/tasks/rounds_sticky.sh [rounds]
#   CHANNELS      juliaup channels or julia binaries, "1.12 1.13.2 nightly"
#   LAYOUTS       "8,1 8,0"
#   MODES         "spawn sticky pool priority"
#   CELLS         "500:2 500:2:hetero 500:2:inner 50:0 500:0"; D=8 s each
#   OUT           results directory (default bench/results/sticky)
#   ROUNDS        3 (or the argument)
#   RETRIES       2
#   TIMEOUT_S     per spawn_order.jl process (1800 s)
#   VALIDATE=1    one short validation pass instead, not behind the gate: D=1, cells
#                 "50:0.2 500:2 500:2:hetero 500:2:inner", into <OUT>/validate-spawn.tsv
#   QUIET_LOAD, QUIET_WAIT_S, SAMPLE_S  pass through to quiet.sh
# Afterwards: julia bench/tasks/aggregate_sticky.jl <OUT>/spawn-r*.tsv
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ROUNDS="${1:-${ROUNDS:-3}}"
OUT="${OUT:-$ROOT/bench/results/sticky}"
CHANNELS="${CHANNELS:-1.12 1.13.2 nightly}"
LAYOUTS="${LAYOUTS:-8,1 8,0}"
MODES="${MODES:-spawn sticky pool priority}"
CELLS="${CELLS:-500:2 500:2:hetero 500:2:inner 50:0 500:0}"
RETRIES="${RETRIES:-2}"
VALIDATE="${VALIDATE:-0}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
mkdir -p "$OUT"
export QUIET_LOAD="${QUIET_LOAD:-0.5}" QUIET_WAIT_S="${QUIET_WAIT_S:-1800}" SAMPLE_S="${SAMPLE_S:-5}"

log() { echo "[$(date +%H:%M:%S)] rounds_sticky: $*"; }
reverse() { local r=""; for w in $1; do r="$w${r:+ $r}"; done; echo "$r"; }

# One block: run "$@" behind quiet.sh (or directly under VALIDATE), retrying a gate failure or a
# stopped block. Returns the command's status; a gate that never passes is 3.
block() {
  local label="$1" file="$2"; shift 2
  local attempt=1 rc
  while :; do
    if [ "$VALIDATE" = 1 ]; then "$@"; rc=$?
    else "$ROOT/bench/socket/quiet.sh" "$label" "$@"; rc=$?
    fi
    [ "$rc" = 3 ] || [ "$rc" = 4 ] || return "$rc"
    [ "$attempt" -le "$RETRIES" ] || { log "$label: giving up after $attempt attempts (status $rc)"; return "$rc"; }
    log "$label: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    rm -f "$file"
  done
}

if [ "$VALIDATE" = 1 ]; then
  log "validation pass (not timed, no gate): channels [$CHANNELS] layouts [$LAYOUTS] modes [$MODES]"
  block validate "$OUT/validate-spawn.tsv" env VALIDATE=1 D=1 CELLS="50:0.2 500:2 500:2:hetero 500:2:inner" \
    MODES="$MODES" ROUND=0 CHANNELS="$CHANNELS" LAYOUTS="$LAYOUTS" VARIANTS=A TIMEOUT_S="$TIMEOUT_S" \
    "$HERE/spawn_order.sh" 0 "$OUT/validate-spawn.tsv"
  rc=$?
  log "validation pass done (status $rc): $OUT/validate-spawn.tsv"
  exit "$rc"
fi

status=0
log "$ROUNDS rounds: channels [$CHANNELS] layouts [$LAYOUTS] modes [$MODES] cells [$CELLS] -> $OUT"
for r in $(seq 1 "$ROUNDS"); do
  if [ $((r % 2)) = 1 ]; then channels="$CHANNELS"; modes="$MODES"
  else channels="$(reverse "$CHANNELS")"; modes="$(reverse "$MODES")"; fi
  stamp="$(date +%Y%m%d-%H%M%S)"
  spawn="$OUT/attempt-spawn-r$r-$stamp.tsv"
  if block "sticky-r$r" "$spawn" env D=8 CELLS="$CELLS" MODES="$modes" ROUND="$r" CHANNELS="$channels" \
       LAYOUTS="$LAYOUTS" VARIANTS=A TIMEOUT_S="$TIMEOUT_S" "$HERE/spawn_order.sh" "$r" "$spawn"; then
    mv "$spawn" "$OUT/spawn-r$r.tsv"
    log "round $r done (builds $channels; modes $modes)"
  else
    log "round $r FAILED; its attempt file stays in $OUT"; status=1
  fi
done
log "all rounds done (status $status); next: julia $HERE/aggregate_sticky.jl $OUT/spawn-r*.tsv"
exit "$status"
