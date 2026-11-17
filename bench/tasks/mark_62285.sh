#!/usr/bin/env bash
# #618, the stall repro's part 2: JuliaLang/julia#62285 and the mark in the same blocks. Four columns,
# interleaved in every block (the column order reversed in even rounds): the PR's head built with the
# work-stealing backend (WS) and with partr, both running the harness unpatched (VARIANT=A), and a
# released build under A and under M-g-r2 (the marks each cell used on 2026-11-17: M marks handlers
# and clients). Every block is one bench/socket/quiet.sh run.
#
#   harness   at 8,1, clients on :interactive: spawn_order.jl's starved cell (500:2), 500:2:inner and
#             500:2:io; the starved cell at 8,0 with :default clients; mixed_cell.jl (fib_fine looping
#             beside the starved cell) and its inner shape (SHAPE=inner); nested.sh's fib_fine alone
#   pool      the Channel pool cell of October: spawn_order.jl MODES=pool at H = 0, C = 50 and 500,
#             :interactive clients at 8,1 and :default clients at 8,0 (under M-g-r2 nothing is marked
#             there: what the mark's code costs a worker pool that does not use it)
#   server    cell 1 of 2026-11-17 (/aggregate?n=100000&op=groupby, c = 500, PROBE=1) at 8,1 and 8,0:
#             bare_spawn on WS and on partr (fairness.sh's `%<label>`, in SERVER_ENV, an environment
#             with HTTP.jl and JSON resolved on the PR's build), bare_spawn (no VARIANT) and
#             bare_marked under M-g-r2 on the released build
#
# Usage: WS=<julia> PARTR=<julia> REL=<julia> SERVER_ENV=<dir> bench/tasks/mark_62285.sh <block> [rounds]
#   OUT bench/results/618-62285-part2; CPUS 0,1,2,3,6,7,8,9; D 8; TIMEOUT_S 900 per process
# Writes <OUT>/<block>-*.tsv (spawn_order.jl / mixed_cell.jl / nested.jl rows; fairness.sh writes its own).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BLOCK="${1:?usage: mark_62285.sh harness|pool|server [rounds]}"; ROUNDS="${2:-1}"
OUT="${OUT:-$ROOT/bench/results/618-62285-part2}"; mkdir -p "$OUT"
CPUS="${CPUS:-0,1,2,3,6,7,8,9}"; D="${D:-8}"; TIMEOUT_S="${TIMEOUT_S:-900}"
: "${WS:?WS=<julia>}" "${PARTR:?PARTR=<julia>}" "${REL:?REL=<julia>}"
COLS=("ws=$WS=A" "partr=$PARTR=A" "rel=$REL=A" "relg=$REL=M-g-r2")

cols_in_order() {   # round -> the columns, reversed in even rounds
  if [ $(( $1 % 2 )) = 0 ]; then for ((i = ${#COLS[@]} - 1; i >= 0; i--)); do echo "${COLS[i]}"; done
  else printf '%s\n' "${COLS[@]}"; fi
}
run() {   # tsv, threads, julia, VAR=value..., script: one process, its rows appended to tsv
  local tsv="$1" threads="$2" bin="$3"; shift 3
  local script="${*: -1}" nh=0
  local envs=("${@:1:$#-1}")
  [ -s "$tsv" ] && nh=1
  timeout -s KILL "$TIMEOUT_S" env NOHEADER="$nh" "${envs[@]}" \
    taskset -c "$CPUS" "$bin" --startup-file=no --threads="$threads" "$script" >> "$tsv" ||
    echo "mark_62285: $(basename "$tsv") $bin ${envs[*]} $(basename "$script") failed or timed out" >&2
}

harness() {
  local r col label bin v
  for r in $(seq 1 "$ROUNDS"); do
    while IFS= read -r col; do
      label="${col%%=*}"; v="${col##*=}"; bin="${col#*=}"; bin="${bin%=*}"
      echo "[$(date +%H:%M:%S)] harness r$r $label ($v)"
      run "$OUT/harness-spawn.tsv" 8,1 "$bin" ROUND="$r" COLUMN="$label" VARIANT="$v" D="$D" MODES=spawn CLIENTS=interactive \
        CELLS="500:2 500:2:inner 500:2:io" "$HERE/spawn_order.jl"
      run "$OUT/harness-spawn.tsv" 8,0 "$bin" ROUND="$r" COLUMN="$label" VARIANT="$v" D="$D" MODES=spawn CLIENTS=default \
        CELLS="500:2" "$HERE/spawn_order.jl"
      run "$OUT/harness-mixed.tsv" 8,1 "$bin" ROUND="$r" COLUMN="$label" VARIANT="$v" D="$D" "$HERE/mixed_cell.jl"
      run "$OUT/harness-mixedinner.tsv" 8,1 "$bin" ROUND="$r" COLUMN="$label" VARIANT="$v" D="$D" SHAPE=inner "$HERE/mixed_cell.jl"
      env ROUND="$r" CHANNELS="$bin" LAYOUTS=8,1 VARIANTS="$v" WORKLOADS=fib_fine SKIP= CPUS="$CPUS" TIMEOUT_S="$TIMEOUT_S" \
        "$HERE/nested.sh" "$r" "$OUT/harness-nested-$label.tsv" >/dev/null ||
        echo "mark_62285: nested.sh $label failed" >&2
    done < <(cols_in_order "$r")
  done
}

pool() {
  local r col label bin v
  for r in $(seq 1 "$ROUNDS"); do
    while IFS= read -r col; do
      label="${col%%=*}"; v="${col##*=}"; bin="${col#*=}"; bin="${bin%=*}"
      echo "[$(date +%H:%M:%S)] pool r$r $label ($v)"
      run "$OUT/pool.tsv" 8,1 "$bin" ROUND="$r" COLUMN="$label" VARIANT="$v" D="$D" MODES=pool CLIENTS=interactive \
        CELLS="50:0 500:0" "$HERE/spawn_order.jl"
      run "$OUT/pool.tsv" 8,0 "$bin" ROUND="$r" COLUMN="$label" VARIANT="$v" D="$D" MODES=pool CLIENTS=default \
        CELLS="50:0 500:0" "$HERE/spawn_order.jl"
    done < <(cols_in_order "$r")
  done
}

case "$BLOCK" in
  harness) "$ROOT/bench/socket/quiet.sh" "618-62285-harness" bash -c "$(declare -f run cols_in_order harness); $(declare -p COLS OUT CPUS D TIMEOUT_S ROUNDS HERE); harness" ;;
  pool)    "$ROOT/bench/socket/quiet.sh" "618-62285-pool" bash -c "$(declare -f run cols_in_order pool); $(declare -p COLS OUT CPUS D TIMEOUT_S ROUNDS HERE); pool" ;;
  server)
    : "${SERVER_ENV:?SERVER_ENV=<env with HTTP.jl and JSON for the PR builds>}"
    env JULIA="$REL" JULIAS="ws=$WS,$SERVER_ENV partr=$PARTR,$SERVER_ENV" PROBE=1 ROUTE="/aggregate?n=100000&op=groupby" \
      "$ROOT/bench/socket/quiet.sh" "618-62285-server" "$ROOT/bench/socket/fairness.sh" \
      "bare_spawn@8,1%ws bare_spawn@8,1%partr bare_spawn@8,1 bare_marked@8,1@M-g-r2 bare_spawn@8,0%ws bare_spawn@8,0%partr bare_spawn@8,0 bare_marked@8,0@M-g-r2" \
      "$ROUNDS" "${DUR:-8s}" ;;
  *) echo "mark_62285.sh: unknown block $BLOCK" >&2; exit 2 ;;
esac
