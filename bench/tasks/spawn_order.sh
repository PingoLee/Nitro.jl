#!/usr/bin/env bash
# One round of spawn_order.jl (#618) on every Julia channel and thread layout, back to back, so a
# round is one `quiet.sh` block and the versions interleave across rounds. Every process is pinned
# to the same CPUs as #618's servers: 8 CPUs for `--threads=8,1` (9 threads) and for `8,0`.
#
# Usage: bench/tasks/spawn_order.sh <round> <tsv>
#   CHANNELS="1.12 1.13.2 nightly" LAYOUTS="8,1 8,0" D=8 bench/tasks/spawn_order.sh 1 bench/results/spawn-order.tsv
#   julia bench/tasks/spawn_order.jl --report bench/results/spawn-order.tsv
#
# Appends one line per cell to <tsv>, writing the header only when the file is new. spawn_order.jl
# reads D, CS, HS, MODES, CLIENTS and GUARD from the environment.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND="${1:?round}"
TSV="${2:?tsv}"
CHANNELS="${CHANNELS:-1.12 1.13.2 nightly}"
LAYOUTS="${LAYOUTS:-8,1 8,0}"
CPUS="${CPUS:-0,1,2,3,6,7,8,9}"
mkdir -p "$(dirname "$TSV")"

for ch in $CHANNELS; do
  for layout in $LAYOUTS; do
    header=0; [ -s "$TSV" ] && header=1
    ROUND="$ROUND" NOHEADER="$header" taskset -c "$CPUS" julia +"$ch" --threads="$layout" \
      "$HERE/spawn_order.jl" >>"$TSV" || { echo "spawn_order.sh: julia +$ch --threads=$layout failed" >&2; exit 1; }
  done
done
