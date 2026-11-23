#!/usr/bin/env bash
# #618, Idea 17 session 2, part E2: forcible abandonments, `master_checks.jl abandon N`, as many runs as
# fit in BUDGET_S seconds a build, the builds alternating run by run. Not timed: what is counted is
# whether a run hangs, and where.
#
# Each run: `<julia> --threads=8,1 -e 'using Profile; include(popfirst!(ARGS))' master_checks.jl abandon N`, so that a
# hung process can be asked for a per-thread report (SIGUSR1: Julia's profile peek, which needs
# Profile loaded). A run's timeout is TIMEOUT_X (10) times the median wall of the build's first
# CALIB (3) clean runs, and at least MIN_TIMEOUT_S (60). On a timeout, before the kill, into
# <OUT>/<build>-<run>.hang:
#   - every thread's state and kernel wait channel (/proc/<pid>/task/*/{stat,wchan});
#   - SIGUSR1, then PEEK_S (8) seconds for the peek report (it lands in the run's stderr log);
#   - SIGQUIT (Julia's fatal-signal backtrace of the thread that takes it, into the stderr log);
#   - SIGKILL if it is still there.
# No gdb on the bench box, so all-thread native stacks are not taken.
#
# Usage: OUT=<dir> BUILDS="control=<julia> mark-validate=<julia>" bench/julia/abandon_runs.sh
#   N (50), BUDGET_S (1200)
# Output: <OUT>/runs.tsv (build, run, status, wall s, hung, the probe's ok line seen, a
# "Workqueue inconsistency" line seen), <OUT>/<build>-<run>.err, and a .hang file per hang.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OUT:?OUT=<results dir>}" "${BUILDS:?BUILDS=\"label=<julia> ...\"}"
N="${N:-50}" BUDGET_S="${BUDGET_S:-1200}" CALIB="${CALIB:-3}" TIMEOUT_X="${TIMEOUT_X:-10}"
MIN_TIMEOUT_S="${MIN_TIMEOUT_S:-60}" PEEK_S="${PEEK_S:-8}"
mkdir -p "$OUT"
TSV="$OUT/runs.tsv"
[ -s "$TSV" ] || printf 'build\trun\tstatus\twall_s\thung\tok_line\tworkqueue_inconsistency\ttimeout_s\n' >"$TSV"
log() { echo "[$(date '+%F %T')] abandon_runs: $*" | tee -a "$OUT/abandon.log"; }

declare -A JL SPENT RUNS WALLS
LABELS=()
for kv in $BUILDS; do l="${kv%%=*}"; JL[$l]="${kv#*=}"; SPENT[$l]=0; RUNS[$l]=0; WALLS[$l]=""; LABELS+=("$l"); done

median() { tr ' ' '\n' | grep -v '^$' | sort -g | awk '{ a[NR] = $1 } END { if (NR == 0) print 0; else if (NR % 2) print a[(NR + 1) / 2]; else print (a[NR / 2] + a[NR / 2 + 1]) / 2 }'; }
timeout_of() {   # label
  local l="$1" n m
  n="$(echo ${WALLS[$l]} | wc -w)"
  [ "$n" -lt "$CALIB" ] && { echo "$((MIN_TIMEOUT_S * 5))"; return; }   # calibrating: generous
  m="$(echo ${WALLS[$l]} | median)"
  awk -v m="$m" -v x="$TIMEOUT_X" -v lo="$MIN_TIMEOUT_S" 'BEGIN { t = m * x; if (t < lo) t = lo; printf "%d", t + 0.5 }'
}

one_run() {   # label
  local l="$1" r t0 t1 pid status=0 hung=0 tmo err hang waited
  RUNS[$l]=$(( ${RUNS[$l]} + 1 )); r="${RUNS[$l]}"
  err="$OUT/$l-$r.err"; hang="$OUT/$l-$r.hang"
  tmo="$(timeout_of "$l")"
  t0=$(date +%s.%N)
  "${JL[$l]}" --startup-file=no --threads=8,1 \
    -e 'using Profile; include(popfirst!(ARGS))' "$HERE/master_checks.jl" abandon "$N" >"$err" 2>&1 </dev/null &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$((tmo * 10))" ]; then
      hung=1
      {
        echo "run $r of $l: no exit after ${tmo}s (pid $pid), $(date '+%F %T')"
        for d in /proc/"$pid"/task/*; do
          printf '%s\t%s\t%s\n' "${d##*/}" "$(awk '{ print $3 }' "$d/stat" 2>/dev/null)" "$(cat "$d/wchan" 2>/dev/null)"
        done
      } >"$hang"
      kill -USR1 "$pid" 2>/dev/null; sleep "$PEEK_S"
      kill -QUIT "$pid" 2>/dev/null; sleep 3
      kill -KILL "$pid" 2>/dev/null
      break
    fi
    sleep 0.1; waited=$((waited + 1))
  done
  wait "$pid"; status=$?
  t1=$(date +%s.%N)
  local wall ok wq
  wall="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
  ok=0; grep -q "master_checks: ok: c4" "$err" && ok=1
  wq=0; grep -q "Workqueue inconsistency" "$err" && wq=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$l" "$r" "$status" "$wall" "$hung" "$ok" "$wq" "$tmo" >>"$TSV"
  SPENT[$l]="$(awk -v a="${SPENT[$l]}" -v w="$wall" 'BEGIN { printf "%.2f", a + w }')"
  if [ "$hung" = 0 ] && [ "$status" = 0 ] && [ "$ok" = 1 ]; then WALLS[$l]="${WALLS[$l]} $wall"; fi
  [ "$hung" = 1 ] && log "HANG: $l run $r (ok line seen: $ok), see $hang and $err"
  [ "$hung" = 0 ] && [ "$status" != 0 ] && log "FAILED: $l run $r exit $status, see $err"
  return 0
}

log "builds [${LABELS[*]}], N = $N, budget ${BUDGET_S}s a build"
for l in "${LABELS[@]}"; do log "build $l: $("${JL[$l]}" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)' 2>&1)"; done
while :; do
  any=0
  for l in "${LABELS[@]}"; do
    awk -v s="${SPENT[$l]}" -v b="$BUDGET_S" 'BEGIN { exit !(s < b) }' || continue
    any=1; one_run "$l"
  done
  [ "$any" = 1 ] || break
done
for l in "${LABELS[@]}"; do
  log "$l: $(awk -F'\t' -v l="$l" '$1 == l { n++; h += $5; f += ($5 == 0 && $3 != 0) } END { printf "%d runs, %d hung, %d failed otherwise", n, h, f }' "$TSV"), median clean wall $(echo ${WALLS[$l]} | median) s"
done
