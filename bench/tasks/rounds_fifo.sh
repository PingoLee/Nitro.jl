#!/usr/bin/env bash
# #618, variants M and O (multiq_variant.jl): a FIFO queue beside stock's heaps for the tasks a
# program marks (M) or the tasks that cross pools (O), against A, A0 and C, on one build. Every
# block is one bench/socket/quiet.sh run; variants are the innermost loop, and their order is
# reversed in even rounds. A block whose gate fails (quiet.sh exit 3) or that a foreign process
# stopped (exit 4) is retried, RETRIES times at most, each attempt into its own files; only a
# finished attempt is renamed into place, so <OUT>/<block>-*-r<N>.tsv hold complete blocks only.
#
#   cost      spawn_order.jl H = 0, C = 50 and 500, clients on :interactive at 8,1 and on :default at
#             8,1 and 8,0; tasks.jl micro (FanOut 1000/10000) and queued, both layouts.
#             Variants: A A0 C M-none M-f M-l O-f O-l
#   fairness  the starved cell (C = 500, H = 2 ms, D = 8 s) in the same three client/layout cells,
#             with `pool` under A as the reference. Variants: A A0 C M-none M-f M-l, plus M-h-f and
#             M-h-l with :default clients, plus O-f and O-l (with :interactive clients at 8,1; with
#             :default clients at 8,0, where nothing crosses pools, and at 8,1, where the main task
#             spawns the clients from :interactive, so O makes the clients F and not the handlers)
#   shapes    500:2:inner, 500:2:hetero and 500:2:io, clients on :interactive at 8,1.
#             Variants: A C M-none M-f M-l
#   nesting   nested.sh's five workloads, both layouts. Variants: A A0 C M-none M-f M-l O-f O-l
#   markall   optional: fib_fine with every spawn marked (MARK_ALL=1) under M-f and M-l, A beside
#   pilot     the gate before the rounds: at 8,1 the starved cell with both client pools and
#             fib_fine, variants A M-none M-f M-l, one block
#
# Usage: JL=<julia binary> MICRO_PROJECT=<env with BenchmarkTools> bench/tasks/rounds_fifo.sh [rounds]
#   OUT           results directory (default bench/results/618-fifo)
#   ROUNDS        3 (or the argument)
#   BLOCKS        "cost fairness shapes nesting": which blocks a round runs ("pilot" and "markall"
#                 are run on their own: BLOCKS=pilot ROUNDS=1)
#   CPUS          0,1,2,3,6,7,8,9, as spawn_order.sh
#   RETRIES       2
#   VALIDATE=1    one validation pass instead, not behind the gate and not timed: every layout x
#                 client pool x variant at D = 1 s over all four shapes, tasks.jl's rows, nested.jl
#                 at FIB_FINE=36:12 and RUNS=1 (MARK_ALL too), and the two negative controls
#                 (M_NEGATIVE=blind fails the check_empty probe, M_NEGATIVE=stall trips the stall
#                 check), into <OUT>/validate-*.tsv and <OUT>/validate.log; NEG_ONLY=1 runs only
#                 the negative controls
#   QUIET_LOAD, QUIET_WAIT_S, SAMPLE_S  pass through to quiet.sh
# Afterwards: julia bench/tasks/aggregate_fifo.jl <OUT>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
: "${JL:?JL=<julia binary>}"
: "${MICRO_PROJECT:?MICRO_PROJECT=<environment with BenchmarkTools>}"
ROUNDS="${1:-${ROUNDS:-3}}"
OUT="${OUT:-$ROOT/bench/results/618-fifo}"
BLOCKS="${BLOCKS:-cost fairness shapes nesting}"
CPUS="${CPUS:-0,1,2,3,6,7,8,9}"
RETRIES="${RETRIES:-2}"
VALIDATE="${VALIDATE:-0}"
mkdir -p "$OUT"
[ -x "$JL" ] || { echo "rounds_fifo: $JL is not an executable" >&2; exit 1; }
export QUIET_LOAD="${QUIET_LOAD:-0.5}" QUIET_WAIT_S="${QUIET_WAIT_S:-1800}" SAMPLE_S="${SAMPLE_S:-5}"
VER="$("$JL" -e 'print(VERSION)')"

log() { echo "[$(date +%H:%M:%S)] rounds_fifo: $*"; }

# The variants of each cell. ROUND_ORDER reverses them in even rounds.
COST_V="A A0 C M-none M-f M-l O-f O-l"
FAIR_I81_V="A A0 C M-none M-f M-l O-f O-l"          # :interactive clients, 8,1
FAIR_D_V="A A0 C M-none M-f M-l M-h-f M-h-l O-f O-l"  # :default clients, 8,1 and 8,0
SHAPE_V="A C M-none M-f M-l"
NEST_V="A A0 C M-none M-f M-l O-f O-l"
PILOT_V="A M-none M-f M-l"
ordered() {   # round, variants...
  local r="$1"; shift
  if [ $((r % 2)) = 0 ]; then printf '%s\n' "$@" | tac | tr '\n' ' '; else echo "$*"; fi
}

# One spawn_order.jl process: round, tsv, layout, clients, variant, cells, mode, D.
spawn() {
  local r="$1" tsv="$2" layout="$3" clients="$4" variant="$5" cells="$6" mode="${7:-spawn}" d="${8:-8}"
  local header=0; [ -s "$tsv" ] && header=1
  env ROUND="$r" NOHEADER="$header" VARIANT="$variant" CELLS="$cells" MODES="$mode" CLIENTS="$clients" D="$d" \
    timeout -s KILL "${TIMEOUT_S:-900}" taskset -c "$CPUS" "$JL" --threads="$layout" \
    "$HERE/spawn_order.jl" >>"$tsv" ||
    { echo "rounds_fifo: spawn_order $layout $clients VARIANT=$variant CELLS=$cells failed or timed out" >&2; return 1; }
}

# One tasks.jl process: round, tsv, layout, variant.
micro() {
  local r="$1" tsv="$2" layout="$3" variant="$4"
  VARIANT="$variant" FAN_OUT_NS="1000 10000" timeout -s KILL "${MICRO_TIMEOUT_S:-240}" taskset -c "$CPUS" "$JL" \
    --project="$MICRO_PROJECT" --threads="$layout" "$HERE/tasks.jl" micro queued |
    sed "s|^|$r\t$VER\t$layout\t$variant\t|" >>"$tsv"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" = 0 ] || { echo "rounds_fifo: tasks.jl $layout VARIANT=$variant failed ($rc)" >&2; return 1; }
}

# The three client/layout cells of cost and fairness: "layout clients".
CLIENT_CELLS=("8,1 interactive" "8,1 default" "8,0 default")

cost_block() {   # round, spawn tsv, micro tsv
  local r="$1" tsv="$2" mtsv="$3" cells="50:0 500:0" d=8 cc layout clients v
  [ "$VALIDATE" = 1 ] && d=1
  for cc in "${CLIENT_CELLS[@]}"; do
    read -r layout clients <<<"$cc"
    for v in $(ordered "$r" $COST_V); do spawn "$r" "$tsv" "$layout" "$clients" "$v" "$cells" spawn "$d" || return 1; done
  done
  for layout in 8,1 8,0; do
    for v in $(ordered "$r" $COST_V); do micro "$r" "$mtsv" "$layout" "$v" || return 1; done
  done
}

fairness_block() {   # round, spawn tsv
  local r="$1" tsv="$2" cells="500:2" d=8 cc layout clients v vs
  [ "$VALIDATE" = 1 ] && { cells="50:0.2 500:2 500:2:inner 500:2:hetero 500:2:io"; d=1; }
  for cc in "${CLIENT_CELLS[@]}"; do
    read -r layout clients <<<"$cc"
    if [ "$clients" = interactive ]; then vs="$FAIR_I81_V"; else vs="$FAIR_D_V"; fi
    spawn "$r" "$tsv" "$layout" "$clients" A "$cells" pool "$d" || return 1
    for v in $(ordered "$r" $vs); do spawn "$r" "$tsv" "$layout" "$clients" "$v" "$cells" spawn "$d" || return 1; done
  done
}

shapes_block() {   # round, spawn tsv
  local r="$1" tsv="$2" v
  for v in $(ordered "$r" $SHAPE_V); do
    spawn "$r" "$tsv" 8,1 interactive "$v" "500:2:inner 500:2:hetero 500:2:io" || return 1
  done
}

nesting_block() {   # round, nested tsv, variants, extra env...
  local r="$1" tsv="$2" vs="$3"; shift 3
  env "$@" ROUND="$r" CHANNELS="$JL" LAYOUTS="${NEST_LAYOUTS:-8,1 8,0}" VARIANTS="$(ordered "$r" $vs)" SKIP= \
    CPUS="$CPUS" TIMEOUT_S="${TIMEOUT_S:-600}" "$HERE/nested.sh" "$r" "$tsv"
}

pilot_block() {   # spawn tsv, nested tsv
  local tsv="$1" ntsv="$2" v
  for clients in interactive default; do
    for v in $PILOT_V; do spawn 0 "$tsv" 8,1 "$clients" "$v" "500:2" || return 1; done
  done
  NEST_LAYOUTS=8,1 nesting_block 0 "$ntsv" "$PILOT_V" WORKLOADS=fib_fine
}

markall_block() {   # nested tsv
  NEST_LAYOUTS="8,1 8,0" nesting_block 1 "$1" "A M-f M-l" WORKLOADS=fib_fine MARK_ALL=1
}

# One block behind quiet.sh, retrying a gate failure or a stopped block. nested.sh's exit 2 (a
# process killed by its timeout, recorded in the TSV) counts as finished.
block() {   # label, files..., --, function args...
  local label="$1"; shift
  local files=()
  while [ "$1" != -- ]; do files+=("$1"); shift; done; shift
  local attempt=1 rc
  while :; do
    "$ROOT/bench/socket/quiet.sh" "$label" "$@"; rc=$?
    [ "$rc" = 2 ] && { log "$label: finished with a process killed by its timeout (recorded in the TSV)"; return 0; }
    [ "$rc" = 3 ] || [ "$rc" = 4 ] || return "$rc"
    [ "$attempt" -le "$RETRIES" ] || { log "$label: giving up after $attempt attempts (status $rc)"; return "$rc"; }
    log "$label: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    rm -f "${files[@]}"
  done
}

# quiet.sh runs a command, so the block functions are reached through this script itself.
if [ "${1:-}" = --run ]; then shift; "$@"; exit $?; fi
SELF=("$0" --run)

if [ "$VALIDATE" = 1 ]; then
  export VALIDATE
  status=0
  vlog="$OUT/validate.log"
  if [ "${NEG_ONLY:-0}" = 1 ]; then
    log "negative controls only, stderr appended to $vlog"
  else
    : >"$vlog"
    log "validation pass (not timed, no gate): $JL ($VER) -> $OUT/validate-*.tsv, stderr in $vlog"
    rm -f "$OUT"/validate-*.tsv
    {
      cost_block 1 "$OUT/validate-cost-spawn.tsv" "$OUT/validate-micro.tsv" &&
      fairness_block 1 "$OUT/validate-fairness-spawn.tsv" &&
      nesting_block 1 "$OUT/validate-nested.tsv" "$NEST_V" FIB_FINE=36:12 &&
      NEST_LAYOUTS="8,1 8,0" nesting_block 1 "$OUT/validate-markall.tsv" "M-f M-l" WORKLOADS=fib_fine FIB_FINE=36:12 MARK_ALL=1
    } 2>>"$vlog" || status=1
  fi
  # The negative controls must fail, each with its own message:
  #   blind  a check_empty blind to the F queue says empty with a task queued (probe 2 fails);
  #   stall  an F task pinned to a thread that never pops trips f_pop!'s stall check (abort, 134).
  nlog="$OUT/negative-control.err"
  for control in "blind:says empty while the F queue holds a task" "stall:made no pop meanwhile"; do
    name="${control%%:*}" msg="${control#*:}"
    for layout in 8,1 8,0; do
      : >"$nlog"
      if env VALIDATE=1 VARIANT=M-f M_NEGATIVE="$name" CELLS=50:0.2 MODES=spawn D=1 timeout -s KILL 300 \
           taskset -c "$CPUS" "$JL" --threads="$layout" "$HERE/spawn_order.jl" >/dev/null 2>"$nlog"; then
        log "NEGATIVE CONTROL $name at $layout passed, and it must fail"; status=1
      elif grep -q "$msg" "$nlog"; then
        log "negative control $name at $layout failed as it must: $(grep -m1 "$msg" "$nlog" | cut -c1-160)"
      else
        log "negative control $name at $layout failed for another reason; see $vlog"; status=1
      fi
      { echo "--- negative control $name at $layout"; cat "$nlog"; } >>"$vlog"
    done
  done
  rm -f "$nlog"
  log "validation pass done (status $status)"
  exit "$status"
fi

status=0
for r in $(seq 1 "$ROUNDS"); do
  for kind in $BLOCKS; do
    stamp="$(date +%Y%m%d-%H%M%S)"
    case "$kind" in
      cost)
        a="$OUT/attempt-cost-spawn-r$r-$stamp.tsv" b="$OUT/attempt-micro-r$r-$stamp.tsv"
        if block "cost-r$r" "$a" "$b" -- "${SELF[@]}" cost_block "$r" "$a" "$b"; then
          mv "$a" "$OUT/cost-spawn-r$r.tsv"; mv "$b" "$OUT/micro-r$r.tsv"; log "round $r cost done"
        else log "round $r cost FAILED"; status=1; fi ;;
      fairness|shapes)
        a="$OUT/attempt-$kind-spawn-r$r-$stamp.tsv"
        if block "$kind-r$r" "$a" -- "${SELF[@]}" "${kind}_block" "$r" "$a"; then
          mv "$a" "$OUT/$kind-spawn-r$r.tsv"; log "round $r $kind done"
        else log "round $r $kind FAILED"; status=1; fi ;;
      nesting)
        a="$OUT/attempt-nested-r$r-$stamp.tsv"
        if block "nesting-r$r" "$a" -- "${SELF[@]}" nesting_block "$r" "$a" "$NEST_V"; then
          mv "$a" "$OUT/nested-r$r.tsv"; log "round $r nesting done"
        else log "round $r nesting FAILED"; status=1; fi ;;
      pilot)
        a="$OUT/attempt-pilot-spawn-$stamp.tsv" b="$OUT/attempt-pilot-nested-$stamp.tsv"
        if block "pilot" "$a" "$b" -- "${SELF[@]}" pilot_block "$a" "$b"; then
          mv "$a" "$OUT/pilot-spawn.tsv"; mv "$b" "$OUT/pilot-nested.tsv"; log "pilot done"
        else log "pilot FAILED"; status=1; fi ;;
      markall)
        a="$OUT/attempt-markall-$stamp.tsv"
        if block "markall" "$a" -- "${SELF[@]}" markall_block "$a"; then
          mv "$a" "$OUT/markall-nested.tsv"; log "markall done"
        else log "markall FAILED"; status=1; fi ;;
      *) echo "rounds_fifo: unknown block $kind" >&2; exit 1 ;;
    esac
  done
done
log "done (status $status); next: julia $HERE/aggregate_fifo.jl $OUT"
exit "$status"
