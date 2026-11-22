#!/usr/bin/env bash
# The pilot of the native mark's port to master (#618, agent-config #82 Idea 17), one quiet block.
# Every build is read against master's control only; nothing here is compared with the tag.
#
#   bench/julia/pilot_master.sh            the pilot: starved, mixed, fib_fine x6, H = 0 x3
#   STEPS=unmarked UNMARKED="A%control N-none%mark N-none%mark-inline" bench/julia/pilot_master.sh
#                                          commit 2: the two unmarked cells with the three builds
#
# The cells (rounds_fifo.sh's own functions, reached with --run, and nested.sh):
#   starved   500:2 at 8,1, :interactive clients: A on the control, N on the mark build
#   mixed     mixed_cell.jl at 8,1: A on the control, N on the mark build
#   fib_fine  nested.jl fib_fine alone at 8,1, nothing marked, FIB_ROUNDS (6) rounds, the order of
#             the builds rotated by round
#   h0        spawn_order H = 0, C = 50 and 500, 8,0, :default clients, nothing marked, H0_ROUNDS (3)
#             rounds, rotated
# Builds: ~/app/julia-618-master/bin/julia-<build> (JLS below). PILOT_OUT: ~/app/julia-618-master/results/pilot.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
B="$HOME/app/julia-618-master/bin"
# quiet.sh sets OUT for its own samples, so the cells' directory travels as PILOT_OUT.
export PILOT_OUT="${PILOT_OUT:-$HOME/app/julia-618-master/results/pilot}"
OUT="$PILOT_OUT"
export JLS="control=$B/julia-control mark=$B/julia-mark mark-inline=$B/julia-mark-inline"
export JL="$B/julia-control" MICRO_PROJECT="$HOME/app/julia-618/benchenv" PROFILE=native
export CPUS="${CPUS:-0,1,2,3,6,7,8,9}"
STEPS="${STEPS:-starved mixed fib_fine h0}"
UNMARKED="${UNMARKED:-A%control N-none%mark}"
FIB_ROUNDS="${FIB_ROUNDS:-6}" H0_ROUNDS="${H0_ROUNDS:-3}"
mkdir -p "$OUT"
RF="$ROOT/bench/tasks/rounds_fifo.sh"
log() { echo "[$(date +%H:%M:%S)] pilot_master: $*"; }
rf() { "$RF" --run "$@"; }
jl() { local b="${1##*%}"; printf '%s' "$B/julia-$b"; }

# The tokens of $2.. rotated left by $1.
rotate() { local k="$1"; shift; local a=("$@") n=$#; for ((i = 0; i < n; i++)); do printf '%s ' "${a[$(((i + k) % n))]}"; done; }

cells() {
  local v r
  for s in $STEPS; do
    case "$s" in
      starved)
        for v in A%control N%mark; do rf spawn 1 "$OUT/starved.tsv" 8,1 interactive "$v" 500:2 || return 1; done ;;
      mixed)
        NATIVE_MIX_COLS="A%control N%mark" rf mixed_block 1 "$OUT/mixed.tsv" || return 1 ;;
      fib_fine)
        for ((r = 1; r <= FIB_ROUNDS; r++)); do
          for v in $(rotate $((r - 1)) $UNMARKED); do
            CHANNELS="$(jl "$v")" LAYOUTS=8,1 VARIANTS="${v%%\%*}" WORKLOADS=fib_fine SKIP= TIMEOUT_S=600 \
              "$ROOT/bench/tasks/nested.sh" "$r" "$OUT/fib_fine.tsv" || return 1
          done
        done ;;
      h0)
        for ((r = 1; r <= H0_ROUNDS; r++)); do
          for v in $(rotate $((r - 1)) $UNMARKED); do
            rf spawn "$r" "$OUT/h0.tsv" 8,0 default "$v" "50:0 500:0" || return 1
          done
        done ;;
      *) echo "pilot_master: unknown step $s" >&2; return 1 ;;
    esac
    log "$s done"
  done
}

if [ "${1:-}" = --cells ]; then export OUT="$PILOT_OUT"; cells; exit $?; fi
log "steps: $STEPS; unmarked columns: $UNMARKED; out $OUT"
"$ROOT/bench/socket/quiet.sh" "pilot-master" "$0" --cells
rc=$?
log "quiet block exit $rc"
exit "$rc"
