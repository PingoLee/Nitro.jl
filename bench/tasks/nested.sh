#!/usr/bin/env bash
# One round of nested.jl (#618) on every Julia channel, thread layout, workload and multiqueue
# variant, back to back, so a round is one `quiet.sh` block and the variants interleave across
# rounds. Variants are the innermost loop: the variants of one cell run next to each other in time.
# One process per (channel, layout, workload, variant), pinned to the same CPUs as #618's runs.
#
# Usage: bench/tasks/nested.sh <round> <tsv>
#   CHANNELS="1.12 1.13.2 nightly" LAYOUTS="8,1 8,0" VARIANTS="A A0 B C" bench/tasks/nested.sh 1 out.tsv
#   VALIDATE=1 bench/tasks/nested.sh 0 validate.tsv
#   julia bench/tasks/nested.jl --report out.tsv
#
#   WORKLOADS    nested.jl workloads, "fib_fine fib_coarse msort reduce fanout" by default
#   SKIP         "<variant>:<workload>" pairs not run, for a variant known to be pathological on a
#                workload: B on fine-grain fib (default "B:fib_fine"; one run did not end in minutes)
#   TIMEOUT_S    each process is killed after this many seconds (default 600). A kill appends a row
#                whose digest is `timeout`; --report lists it instead of numbers
#
# Every other nested.jl variable (RUNS, BUDGET_S, FIB_FINE, VALIDATE, ...) passes through. The real
# julia binary is run, not the juliaup launcher, so that the timeout's SIGKILL reaches it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND="${1:?round}"
TSV="${2:?tsv}"
CHANNELS="${CHANNELS:-1.12 1.13.2 nightly}"
LAYOUTS="${LAYOUTS:-8,1 8,0}"
VARIANTS="${VARIANTS:-A A0 B C}"
WORKLOADS="${WORKLOADS:-fib_fine fib_coarse msort reduce fanout}"
SKIP="${SKIP-B:fib_fine}"
CPUS="${CPUS:-0,1,2,3,6,7,8,9}"
TIMEOUT_S="${TIMEOUT_S:-600}"
mkdir -p "$(dirname "$TSV")"
status=0

for ch in $CHANNELS; do
  jl="$(julia +"$ch" -e 'print(joinpath(Sys.BINDIR, "julia"))')" || { echo "nested.sh: no julia +$ch" >&2; exit 1; }
  ver="$("$jl" -e 'print(VERSION, "\t", Base.GIT_VERSION_INFO.commit_short)')"
  for layout in $LAYOUTS; do
    for w in $WORKLOADS; do
      for variant in $VARIANTS; do
        case " $SKIP " in *" $variant:$w "*) continue ;; esac
        header=0; [ -s "$TSV" ] && header=1
        env ROUND="$ROUND" NOHEADER="$header" VARIANT="$variant" WHAT="$w" \
          timeout -s KILL "$TIMEOUT_S" taskset -c "$CPUS" "$jl" --threads="$layout" \
          "$HERE/nested.jl" >>"$TSV"
        rc=$?
        if [ "$rc" = 137 ]; then
          echo "nested.sh: julia +$ch --threads=$layout VARIANT=$variant $w killed after ${TIMEOUT_S}s" >&2
          # julia, commit, threads, guard, variant, round, bench, then 18 empty numbers and the digest
          printf '%s\t%s\t%s\t%s\t%s%s\ttimeout\n' "$ver" "$layout" "${GUARD:-1}" "$variant" "$ROUND" \
            "$(printf '\t%s' "$w" NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN NaN)" >>"$TSV"
          status=1
        elif [ "$rc" != 0 ]; then
          echo "nested.sh: julia +$ch --threads=$layout VARIANT=$variant $w failed ($rc)" >&2
          exit 1
        fi
      done
    done
  done
done
exit "$status"
