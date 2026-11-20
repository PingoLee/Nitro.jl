#!/usr/bin/env bash
# Runs bench/tasks/stall.jl RUNS times on each build, the builds interleaved (run r of every build
# before run r + 1), each run pinned with taskset to CPUS at --threads=8 and ended by an outer
# `timeout -s KILL` after TIMEOUT_S. A pass-or-stall check, not a timing: no quiet gate, but nothing
# else may run on the box meanwhile, since the script holds every `:default` thread. Pass each
# build's REAL julia binary (not the juliaup launcher, which can outlive the timeout's kill).
#
# Every run is counted one way:
#   ok       all twelve lines printed and exit 0
#   stuck    the script's own watchdog: "stuck: <k> of <n> holder tasks started ..." (with the
#            iteration it was in: the last `ok` line before it)
#   timeout  killed by the outer timeout. Its last line is not known: Julia's stdout to a file is
#            buffered, and a SIGKILL drops what was not flushed (a run killed mid-way can show 0 lines)
#   other    anything else (exit code and last line kept)
#
# Usage: BUILDS="ws=<julia> partr=<julia> master=<julia> ..." bench/tasks/stall.sh
#   RUNS 10, TIMEOUT_S 120, CPUS 0,1,2,3,6,7,8,9, THREADS 8, OUT bench/results/stall-<stamp>
# An entry may carry a marking mode and environment (#618, the battery's item 4):
#   label=<julia>@<mode>[@KEY=VALUE...], e.g. m2-tasks=<julia>@tasks or
#   negblind=<julia>@tasks@JULIA_SCHED_NEGATIVE=blind. The mode is stall.jl's STALL_MARK.
# STOP_ON=<regex>: the first run that is not `ok` for a label matching it ends the script (exit 5), its
# log kept: a stall on a build that must not stall is the result, and the rest of the block waits.
# Writes <OUT>/runs.tsv (one row per run), <OUT>/<build>-r<run>.log, and prints the outcome table.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUNS="${RUNS:-10}"
TIMEOUT_S="${TIMEOUT_S:-120}"
CPUS="${CPUS:-0,1,2,3,6,7,8,9}"
THREADS="${THREADS:-8}"
STOP_ON="${STOP_ON:-}"
OUT="${OUT:-$ROOT/bench/results/stall-$(date +%Y%m%d-%H%M%S)}"
read -r -a BUILD_LIST <<<"${BUILDS:?set BUILDS=\"label=<julia binary> ...\"}"
mkdir -p "$OUT"

# label=<julia>[@mode][@KEY=VALUE...] -> label, binary, the environment to run it with.
entry() {   # entry -> sets label, bin, envs (array)
  local rest e
  label="${1%%=*}"; rest="${1#*=}"; bin="${rest%%@*}"; envs=()
  [ "$rest" = "$bin" ] && return 0
  IFS='@' read -r -a e <<<"${rest#*@}"
  for x in "${e[@]}"; do
    case "$x" in *=*) envs+=("$x") ;; *) envs+=("STALL_MARK=$x") ;; esac
  done
}
for b in "${BUILD_LIST[@]}"; do
  entry "$b"
  [ -x "$bin" ] || { echo "stall.sh: $label: $bin is not executable" >&2; exit 1; }
  printf '%s\t%s %s\t%s\n' "$label" "$bin" "${envs[*]:-}" \
    "$("$bin" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short, " ", Base.GIT_VERSION_INFO.date_string, isdefined(Base, :JULIA_SCHEDULER) ? " scheduler=$(Base.JULIA_SCHEDULER)" : "")')"
done | tee "$OUT/builds.tsv"

printf 'build\trun\toutcome\tok_lines\texit\tseconds\tlast_line\n' > "$OUT/runs.tsv"
for r in $(seq 1 "$RUNS"); do
  for b in "${BUILD_LIST[@]}"; do
    entry "$b"
    log="$OUT/$label-r$r.log"
    t0=$(date +%s.%N)
    env ${envs[@]+"${envs[@]}"} timeout -s KILL "$TIMEOUT_S" taskset -c "$CPUS" "$bin" --startup-file=no --threads="$THREADS" "$HERE/stall.jl" > "$log" 2>&1
    rc=$?
    t1=$(date +%s.%N)
    oks=$(grep -c ' ok$' "$log")
    last=$(grep -v '^\s*$' "$log" | grep -E ' ok$|stuck:' | tail -1)
    if [ "$rc" = 0 ] && [ "$oks" = 12 ]; then outcome=ok
    elif grep -q 'stuck:' "$log"; then outcome=stuck; last="$(grep -o 'stuck: [^"]*' "$log" | head -1) (after: $(grep ' ok$' "$log" | tail -1))"
    elif [ "$rc" = 137 ]; then outcome=timeout; last="$(grep ' ok$' "$log" | tail -1)"
    else outcome=other; last="$(tail -1 "$log")"
    fi
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$r" "$outcome" "$oks" "$rc" "$secs" "${last:--}" >> "$OUT/runs.tsv"
    echo "[$(date +%H:%M:%S)] $label r$r: $outcome ($oks lines, exit $rc, ${secs}s) ${last:-}"
    if [ "$outcome" != ok ] && [ -n "$STOP_ON" ] && [[ "$label" =~ $STOP_ON ]]; then
      echo "stall.sh: STOP: $label run $r ended $outcome (log $log); the rest of the block is not run"
      STOPPED=1; break 2
    fi
  done
done

echo
echo "| build | ok | stuck | timeout | other | of |"
echo "|---|--:|--:|--:|--:|--:|"
awk -F'\t' 'NR > 1 { if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 } c[$1, $3]++; t[$1]++ }
  END { for (i = 1; i <= n; i++) { b = order[i]
    printf "| %s | %d | %d | %d | %d | %d |\n", b, c[b, "ok"], c[b, "stuck"], c[b, "timeout"], c[b, "other"], t[b] } }' "$OUT/runs.tsv"
echo "results: $OUT"
[ "${STOPPED:-0}" = 1 ] && exit 5
exit 0
