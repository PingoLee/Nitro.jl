#!/usr/bin/env bash
# One round of spawn_order.jl (#618) on every Julia channel, thread layout and multiqueue variant,
# back to back, so a round is one `quiet.sh` block and the versions interleave across rounds. Every
# process is pinned to the same CPUs as #618's servers: 8 CPUs for `--threads=8,1` (9 threads) and
# for `8,0`.
#
# Usage: bench/tasks/spawn_order.sh <round> <tsv>
#   CHANNELS="1.12 1.13.2 nightly" LAYOUTS="8,1 8,0" D=8 bench/tasks/spawn_order.sh 1 bench/results/spawn-order.tsv
#   VARIANTS="A A0 B C" CELLS="50:0 500:0 500:2" A0_CELLS="50:0 500:0" bench/tasks/spawn_order.sh 1 out.tsv
#   julia bench/tasks/spawn_order.jl --report bench/results/spawn-order.tsv
#
# Appends one line per cell to <tsv>, writing the header only when the file is new. spawn_order.jl
# reads D, CS, HS, CELLS, MODES, CLIENTS, GUARD and VARIANT from the environment.
#
#   VARIANTS     multiq_variant.jl variants to run, "A" (stock) by default
#   A0_CELLS     CELLS for variant A0 only (it is a cost control; default: CELLS)
#   MICRO_OUT    also run tasks.jl `micro` for each channel, layout and variant, appending its lines
#                to this file prefixed with round, julia version, layout and variant
#   MICRO_PROJECT  the environment for tasks.jl (it needs BenchmarkTools), default bench/; "{mm}"
#                is replaced with the channel's major.minor, for one environment per version
#   TIMEOUT_S    each process is killed after this many seconds (default 900); a hang is a failure
#
# The real julia binary is run, not the juliaup launcher, so that the timeout's SIGKILL reaches it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND="${1:?round}"
TSV="${2:?tsv}"
CHANNELS="${CHANNELS:-1.12 1.13.2 nightly}"
LAYOUTS="${LAYOUTS:-8,1 8,0}"
VARIANTS="${VARIANTS:-A}"
CPUS="${CPUS:-0,1,2,3,6,7,8,9}"
TIMEOUT_S="${TIMEOUT_S:-900}"
MICRO_OUT="${MICRO_OUT:-}"
MICRO_PROJECT="${MICRO_PROJECT:-$HERE/..}"
mkdir -p "$(dirname "$TSV")"

for ch in $CHANNELS; do
  jl="$(julia +"$ch" -e 'print(joinpath(Sys.BINDIR, "julia"))')" || { echo "spawn_order.sh: no julia +$ch" >&2; exit 1; }
  mm="$("$jl" -e 'print(VERSION.major, ".", VERSION.minor)')"
  ver="$("$jl" -e 'print(VERSION)')"
  for layout in $LAYOUTS; do
    for variant in $VARIANTS; do
      cells="${CELLS:-}"
      [ "$variant" = A0 ] && cells="${A0_CELLS:-$cells}"
      header=0; [ -s "$TSV" ] && header=1
      env ROUND="$ROUND" NOHEADER="$header" VARIANT="$variant" ${cells:+"CELLS=$cells"} \
        timeout -s KILL "$TIMEOUT_S" taskset -c "$CPUS" "$jl" --threads="$layout" \
        "$HERE/spawn_order.jl" >>"$TSV" ||
        { echo "spawn_order.sh: julia +$ch --threads=$layout VARIANT=$variant failed or timed out" >&2; exit 1; }
      if [ -n "$MICRO_OUT" ]; then
        VARIANT="$variant" timeout -s KILL "$TIMEOUT_S" taskset -c "$CPUS" "$jl" \
          --project="${MICRO_PROJECT//\{mm\}/$mm}" --threads="$layout" "$HERE/tasks.jl" micro |
          sed "s/^/$ROUND\t$ver\t$layout\t$variant\t/" >>"$MICRO_OUT"
        [ "${PIPESTATUS[0]}" = 0 ] ||
          { echo "spawn_order.sh: tasks.jl micro +$ch --threads=$layout VARIANT=$variant failed or timed out" >&2; exit 1; }
      fi
    done
  done
done
