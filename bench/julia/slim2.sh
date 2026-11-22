#!/usr/bin/env bash
# #618, the native mark: the slim unmarked path s2 (agent-config #82 Idea 16) on two builds, then its
# validation as the measured patch had it, as one driver that needs nothing from the session that
# launched it.
#   Part A, does s2 stand on two builds? Columns ctl (the tag), m2 (the mark), bp and bp2 (two builds of
#     the bypass commit, the zero of the path), s2 and s2b (two builds of s2's commit b304809bc9; s2b's
#     tree is marked dirty by an untracked file, as bp2's). slim_report.jl reads s2b as its `w2` column
#     (a second build of the winner). Steps: c21 (H = 0 C = 50 :default and tasks.jl micro at 2,1), c41
#     (tasks.jl micro at 4,1), split (spawnwait_fixed.jl MODE=split, perf_unmarked.sh a5), turn (the poll
#     turn, perf_unmarked.sh a6, s2b s2 bp m2; needs perf), decideA (slim2_decide.jl: stands, no, or a
#     draw), then the riders f21 (fib_fine 2,1, the layout control), a4fib (fib_fine 8,1), a4cost
#     (H = 0, C = 50 and 500, :default clients at 8,0) and a5perf (the plain loop on bp and bp2 at 2,1
#     with perf attached and without; perf_unmarked.sh a7).
#   Part B, only if decideA says s2 stands: vharness (rounds_fifo.sh PROFILE=native VALIDATE=1 on s2's
#     validation build), vchecks (native_checks.jl at 8,1, 8,2 and 1, and slim2_corners.jl's three cases
#     on s2-validate and mark-validate), vwin (wake_window.jl ring and wake at 2,1 and 4,1, five minutes
#     each, and rblind once at 2,1), tests (Julia's six sets on s2-validate; the control's counts are
#     run_tests.sh's log of the control), vcells (the harness cells under N, s2 beside m2, 3 rounds),
#     weak (H = 0, C = 50 and 500, :default clients at 8,0, everything marked: ctl, N on m2, N on s2, 6
#     rounds), server1 (server cell 1, bare_marked_listen, PROBE=1, BACKLOG=1024, at 8,1 and 8,0, N on m2
#     and N on s2, 3 rounds), markall (the six sets on the mark-all build of s2's validate branch with
#     the switch unset, =spawn and =insert, with the exit log), onethread (the sets that ran in one-thread
#     workers on 2026-11-20, with workers at --threads=4,1: on ctl first, one set at a time; the ones that
#     pass, on the mark-all build with =spawn and =insert), patch (s2's diff against the tag, if every
#     part-B step held).
# Around every step, as slim.sh: before it, wait for no julia, oha or go-server process (PS_WAIT_S,
# default 900 s), and STOP if one stays; after it, the cache-write check against a (path, size, inode)
# snapshot of the builds' own depots: a write during a timed step STOPS the driver, during an untimed
# one it is logged. A RESULT (a stuck task, a lost corner task, a failed check) is logged and recorded
# in $OUT/results, and the driver goes on.
#
# Usage: bench/julia/slim2.sh   (detached: setsid nohup … > driver.out 2>&1 < /dev/null &)
#   STEPS="<names>" runs a subset, FROM=<name> starts at that step. DEADLINE=<epoch s>: a cuttable step
#   that has not started by then is skipped and logged as CUT; the step running at the deadline
#   finishes. Cuttable, in the prompt's cut order: onethread, a5perf, a4fib a4cost, markall, f21,
#   server1, turn. Never c21, c41, split, vharness, vchecks, vwin.
#   ROUNDS_A (12), WIN_DUR_S (300), TD=<s> NOGATE=1 (smoke, never a measurement)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
J="${JULIA618:-$HOME/app/julia-618}"
OUT="${OUT:-$ROOT/bench/results/618-slim2}"
mkdir -p "$OUT"
LOG="$OUT/driver.log"
export PATH="$HOME/.local/go/bin:$HOME/.local/bin:$HOME/.juliaup/bin:$PATH"
B="$J/bin"
# slimw2 is s2b: slim_report.jl's name for a second build of s2.
export JLS="control=$B/julia-control mark=$B/julia-mark bypass=$B/julia-mark-bypass bypass2=$B/julia-mark-bypass2 slim2=$B/julia-mark-slim2 slimw2=$B/julia-mark-slim2b"
export JULIAS="control=$B/julia-control,$ROOT/bench mark=$B/julia-mark,$ROOT/bench slim2=$B/julia-mark-slim2,$ROOT/bench"
export MICRO_PROJECT="${MICRO_PROJECT:-$J/benchenv}"
export SLIM_COMMITS="s2=b304809bc9"
PS_WAIT_S="${PS_WAIT_S:-900}"
CPUS8="0,1,2,3,6,7,8,9"
AGG="/aggregate?n=100000&op=groupby"
COLS6="A%control N-none%mark N-none%bypass N-none%bypass2 N-none%slim2 N-none%slimw2"
ROUNDS_A="${ROUNDS_A:-12}"
WIN_DUR_S="${WIN_DUR_S:-300}"; WIN_THRESHOLD="${WIN_THRESHOLD:-0}"; WIN_DELAY_NS="${WIN_DELAY_NS:-0:20000}"
SIX='["core", "threads", "channels", "channel_threadpool", "threadpool_use", "threadpool_latency"]'
# The sets with no marked enqueue under =spawn on 2026-11-20 (notes-s3: they ran in the runner's
# one-thread workers). The notes list seven.
ONE_SETS="core channels channel_threadpool threadpool_use threadpool_latency gc ioloop_wakeup"
PU="$HERE/perf_unmarked.sh"
PU6="ctl:control:depot-control m2:mark:depot-mark-r bp:mark-bypass:depot-mark-bypass bp2:mark-bypass2:depot-mark-bypass2 s2:mark-slim2:depot-mark-slim2 s2b:mark-slim2b:depot-mark-slim2b"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
stop() { log "STOP: $*"; log "driver stopped; restart with FROM=<step> after fixing"; exit 1; }
result() { log "RESULT: $*"; echo "[$(date '+%F %T')] $*" >>"$OUT/results"; }
procs() { ps -eo pid=,etime=,comm=,args= | awk '$3 == "julia" || $3 == "oha" || $3 == "go-server"' | cut -c1-220; }
ps_check() {
  local waited=0 p
  [ "${NOGATE:-0}" = 1 ] && return 0   # a smoke runs beside builds; never a measurement
  while :; do
    p="$(procs)"
    [ -z "$p" ] && return 0
    [ "$waited" -ge "$PS_WAIT_S" ] && { log "ps check: still present after ${waited}s:"; echo "$p" | tee -a "$LOG"; return 1; }
    log "ps check: waiting (${waited}s) for:"; echo "$p" | tee -a "$LOG"
    sleep 30; waited=$((waited + 30))
  done
}
snap() { find "$@" -type f -printf '%p %s %i\n' 2>/dev/null | sort; }
cache_mark() { snap "$J"/depot-*/compiled >"$OUT/.snap-own"; snap "$HOME/.julia/compiled" >"$OUT/.snap-shared"; }
cache_check() {   # label
  local own other
  own="$(comm -13 "$OUT/.snap-own" <(snap "$J"/depot-*/compiled))"
  other="$(comm -13 "$OUT/.snap-shared" <(snap "$HOME/.julia/compiled") | head -20)"
  [ -n "$other" ] && { log "cache check $1: files created or replaced under ~/.julia/compiled during the step (not by the builds here):"; echo "$other" | tee -a "$LOG"; }
  [ -z "$own" ] || { log "cache check $1: CACHE FILES CREATED OR REPLACED during the step (path size inode):"; echo "$own" | head -40 | tee -a "$LOG"; return 1; }
  log "cache check $1: no cache file created or replaced"
}
rf() { PROFILE=native JL="$B/julia-control" "$ROOT/bench/tasks/rounds_fifo.sh" "$@"; }
gated() {   # label, command...: quiet.sh, retried on a failed gate (3) or a stopped block (4), twice at most
  local attempt=1 rc
  while :; do
    if [ "${NOGATE:-0}" = 1 ]; then "${@:2}"; return $?; fi
    "$ROOT/bench/socket/quiet.sh" "$@"; rc=$?
    { [ "$rc" = 3 ] || [ "$rc" = 4 ]; } || return "$rc"
    [ "$attempt" -le 2 ] || return "$rc"
    log "gated $1: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    ps_check || return 1
  done
}
stands() { [ -s "$OUT/stands" ] && cat "$OUT/stands" || echo unknown; }
need_stands() { [ "$(stands)" = yes ] || { log "$1: skipped (part A: s2 stands = $(stands))"; return 1; }; }
perf_ok() { [ "$(cat /proc/sys/kernel/perf_event_paranoid)" -le 1 ]; }

# ---------------------------------------------------------------- part A
step_prep() {   # untimed: the bench project (server cells) precompiled into m2's and s2's own depots
  local w
  for w in mark mark-slim2; do
    "$B/julia-$w" --project="$ROOT/bench" --startup-file=no -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); using Nitro, HTTP' >>"$LOG" 2>&1 ||
      { log "prep: the bench project does not precompile on $w"; return 1; }
    log "prep: bench project ready on $w"
  done
  # The report reads s2b as w2, the second build of the winner.
  echo slim2 >"$OUT/winner"
}
step_cost() {   # dir, layout, cpus, columns, rounds: H = 0 C = 50 :default and tasks.jl micro (FanOut 1000)
  OUT="$OUT/$1" CPUS="$3" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="$5" ROTATE=1 NATIVE_COLS="$4" \
    WARM=cell CLIENT_CELLS_SPEC="$2 default" COST_CELLS_NATIVE=50:0 MICRO_LAYOUTS="$2" MICRO_ARGS=micro \
    MICRO_FAN_OUT=1000 rf >>"$LOG" 2>&1
}
step_micro() {  # dir, layout, cpus, columns, rounds: tasks.jl micro only
  OUT="$OUT/$1" CPUS="$3" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="$5" ROTATE=1 NATIVE_COLS="$4" \
    CLIENT_CELLS_SPEC="$2 default" COST_CELLS_NATIVE=none MICRO_LAYOUTS="$2" MICRO_ARGS=micro \
    MICRO_FAN_OUT=1000 rf >>"$LOG" 2>&1
}
step_fib() {    # dir, layout, cpus, columns, rounds: fib_fine alone
  OUT="$OUT/$1" CPUS="$3" BLOCKS=fibabba ROUNDS=1 ROTATE=1 ABBA_COLS="$4" ABBA_ROUNDS="$5" \
    ABBA_LAYOUTS="$2" rf >>"$LOG" 2>&1
}
step_spawn80() {  # dir, columns, rounds: H = 0, C = 50 and 500, :default clients at 8,0
  OUT="$OUT/$1" CPUS="$CPUS8" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="$3" ROTATE=1 NATIVE_COLS="$2" WARM=cell \
    CLIENT_CELLS_SPEC="8,0 default" COST_CELLS_NATIVE="50:0 500:0" MICRO_LAYOUTS=none rf >>"$LOG" 2>&1
}
pu() {   # perf_unmarked.sh with its own OUT under ours: steps, builds, layouts, then env assignments
  local steps="$1" builds="$2" layouts="$3"; shift 3
  env PERF_UNMARKED_OUT="$OUT/perf" STEPS="$steps" PU_BUILDS="$builds" PU_LAYOUTS="$layouts" "$@" "$PU" >>"$LOG" 2>&1
}
step_split() { pu a5 "$PU6" "2,1:0,1,2 4,1:0,1,2,3,4"; }
step_turn() {
  perf_ok || { log "turn: SKIPPED, perf is not allowed (perf_event_paranoid $(cat /proc/sys/kernel/perf_event_paranoid))"; return 0; }
  pu a6 "s2b:mark-slim2b:depot-mark-slim2b s2:mark-slim2:depot-mark-slim2 bp:mark-bypass:depot-mark-bypass m2:mark:depot-mark-r" "2,1:0,1,2 4,1:0,1,2,3,4"
}
step_a5perf() {
  perf_ok || { log "a5perf: SKIPPED, perf is not allowed"; return 0; }
  pu a7 "bp:mark-bypass:depot-mark-bypass bp2:mark-bypass2:depot-mark-bypass2" "2,1:0,1,2" PAIRS=5
}
reports() {
  SLIM_DIRS="c21 c41 f21 f81 a4cost" "$B/julia-control" --startup-file=no "$HERE/slim_report.jl" "$OUT" >"$OUT/report-a.txt" 2>&1 ||
    { log "reports: slim_report.jl failed (see $OUT/report-a.txt)"; return 1; }
  if [ -d "$OUT/weak" ]; then
    SLIM_DIRS="weak" "$B/julia-control" --startup-file=no "$HERE/slim_report.jl" "$OUT" >"$OUT/report-weak.txt" 2>&1 ||
      log "reports: slim_report.jl on the weak cell failed (see $OUT/report-weak.txt)"
  fi
  PU_COLS="ctl m2 bp bp2 s2 s2b" "$B/julia-control" --startup-file=no "$HERE/perf_report.jl" "$OUT/perf" >"$OUT/report-perf.md" 2>&1 ||
    { log "reports: perf_report.jl failed (see $OUT/report-perf.md)"; return 1; }
}
step_decideA() {
  reports || return 1
  "$B/julia-control" --startup-file=no "$HERE/slim2_decide.jl" "$OUT/report-a.txt" "$OUT/perf" >"$OUT/decideA.txt" 2>&1 ||
    { log "decideA: slim2_decide.jl failed (see $OUT/decideA.txt)"; return 1; }
  log "decideA: s2 stands = $(stands)"
  grep -v '(info)' "$OUT/decideA.txt" | cut -c1-200 | while read -r l; do log "decideA: $l"; done
  [ "$(stands)" = yes ] || result "part A: s2 stands = $(stands); part B skips itself"
}

# ---------------------------------------------------------------- part B
step_vharness() {
  need_stands vharness || return 0
  JL="$B/julia-mark-slim2v" VALIDATE=1 OUT="$OUT/validate" PROFILE=native "$ROOT/bench/tasks/rounds_fifo.sh" >>"$LOG" 2>&1 ||
    { result "vharness: rounds_fifo.sh VALIDATE=1 on s2-validate failed (see the log)"; return 0; }
}
step_vchecks() {
  need_stands vchecks || return 0
  local l c b rc
  for l in 8,1 8,2 1; do
    "$B/julia-mark-slim2v" --startup-file=no --threads="$l" "$HERE/native_checks.jl" >>"$OUT/native_checks.log" 2>&1; rc=$?
    [ "$rc" = 0 ] || result "vchecks: native_checks.jl FAILED on s2-validate at $l (exit $rc; $OUT/native_checks.log)"
    log "vchecks: native_checks.jl on s2-validate at $l: exit $rc, $(grep -c 'native_checks: ok:' "$OUT/native_checks.log") ok lines so far"
  done
  for b in mark-slim2v mark-validate; do
    for c in a b c; do
      CASE=$c K=200 timeout -s KILL 300 taskset -c 0,1,2,3,4 "$B/julia-$b" --startup-file=no --threads=4,1 "$HERE/slim2_corners.jl" \
        >>"$OUT/corners.tsv" 2>>"$OUT/corners.log"; rc=$?
      [ "$rc" = 0 ] || result "vchecks: corner case $c on $b: exit $rc (a lost task or an assert; $OUT/corners.log)"
      log "vchecks: corner $c on $b: exit $rc; $(grep "case=$c" "$OUT/corners.tsv" | tail -2 | cut -f3,8-10,13-23 | tr '\t' ' ' | tr '\n' '|')"
    done
  done
}
win_one() {   # tsv, layout, cpus, label, wrapper, mode, mark, negative control (- for none)
  local tsv="$1" layout="$2" cpus="$3" label="$4" wr="$5" mode="$6" mark="$7" neg="$8" header=1 rc ev row stuck
  [ -s "$tsv" ] && header=0
  ev="${tsv%.tsv}.events"
  local extra=()
  [ "$neg" != - ] && extra+=(JULIA_SCHED_NEGATIVE="$neg")
  env JULIA_THREAD_SLEEP_THRESHOLD="$WIN_THRESHOLD" ${extra[@]+"${extra[@]}"} \
    MODE="$mode" MARK="$mark" DUR_S="${TD:-$WIN_DUR_S}" DELAY_NS="$WIN_DELAY_NS" ${WIN_TASKS:+TASKS=$WIN_TASKS} \
    LABEL="$label" NOHEADER=$((1 - header)) \
    timeout -s KILL $(( ${TD:-$WIN_DUR_S} + 120 )) taskset -c "$cpus" "$B/julia-$wr" --startup-file=no --threads="$layout" \
    "$ROOT/bench/tasks/wake_window.jl" >>"$tsv" 2>>"$ev"
  rc=$?
  [ "$rc" = 0 ] || { result "window $label at $layout: exit $rc (see $ev)"; return 0; }
  row="$(tail -1 "$tsv")"
  stuck="$(echo "$row" | awk -F'\t' '{ print $15 + $16 + $17 }')"
  log "window $label at $layout: $(echo "$row" | awk -F'\t' '{ printf "rounds %s, enqueued %s, stuck %s, late %s, unrescued %s, p99.9 %s us, max %s us", $13, $14, $15, $16, $17, $20, $21 }')"
  if [ "$neg" = - ] && [ "$stuck" != 0 ]; then result "a task stuck or late on $label at $layout ($tsv)"; fi
  if [ "$neg" != - ] && [ "$stuck" = 0 ]; then result "the negative control $neg showed no stuck task on $label at $layout ($tsv)"; fi
}
step_vwin() {
  need_stands vwin || return 0
  local tsv="$OUT/window/vwin.tsv"; mkdir -p "$OUT/window"
  win_one "$tsv" 2,1 0,1,2 sv-ring mark-slim2v ring 1 -
  win_one "$tsv" 2,1 0,1,2 sv-wake mark-slim2v wake 1 -
  win_one "$tsv" 4,1 0,1,2,3,4 sv-ring mark-slim2v ring 1 -
  win_one "$tsv" 4,1 0,1,2,3,4 sv-wake mark-slim2v wake 1 -
  win_one "$tsv" 2,1 0,1,2 sv-neg-rblind-wake mark-slim2v wake 1 rblind
}
tests_one() {   # label, wrapper, switch (unset|spawn|insert), sets (a Julia vector literal), [worker exeflags]
  local label="$1" wr="$2" sw="$3" sets="$4" ex="${5:-}" d t0 rc envs=()
  d="$OUT/tests/$label"; mkdir -p "$d/log"
  rm -f "$J/mark-all-log/current"; mkdir -p "$J/mark-all-log"
  [ "$wr" = mark-slim2all ] && ln -sfn "$d/log" "$J/mark-all-log/current"
  [ -n "$ex" ] && envs+=("JULIA_TEST_EXTRA_EXEFLAGS=$ex")
  [ "$sw" != unset ] && envs+=("JULIA_SCHED_MARK_ALL=$sw")
  [ "$wr" = mark-slim2all ] && envs+=("JULIA_SCHED_MARK_ALL_LOG=$d/log")
  # A single set runs in the runner itself (no worker: n = min(threads, length(tests))), so the flags go to
  # the runner too, through runtests' julia_args, as well as to any worker through the variable.
  local ja=""; [ -n "$ex" ] && ja=", julia_args = \`$ex\`"
  t0=$(date +%s)
  ( cd "$J" && env ${envs[@]+"${envs[@]}"} timeout -s KILL "${TESTS_TIMEOUT_S:-3600}" "$B/julia-$wr" --startup-file=no \
      -e "Base.runtests($sets; ncores = 6$ja)" >"$d/tests.log" 2>&1 )
  rc=$?
  rm -f "$J/mark-all-log/current"
  log "tests $label: $wr, switch $sw${ex:+, workers $ex}: exit $rc after $(( $(date +%s) - t0 )) s; $(grep -E '^ *(SUCCESS|FAILURE)' "$d/tests.log" | tail -1 | tr -s ' ')$( [ "$wr" = mark-slim2all ] && echo "; $(ls "$d/log" | wc -l) exit-log files")"
  return "$rc"
}
step_tests() {
  need_stands tests || return 0
  tests_one sv mark-slim2v unset "$SIX" || result "tests: Julia's six sets failed on s2-validate ($OUT/tests/sv/tests.log)"
  log "tests: the control's counts (run_tests.sh, $J/tests-control.log): $(grep -E '^ *(SUCCESS|FAILURE)' "$J/tests-control.log" | tail -1 | tr -s ' ')"
}
step_vcells() {
  need_stands vcells || return 0
  OUT="$OUT/vcells" CPUS="$CPUS8" BLOCKS=cells ROUNDS=3 ROTATE=1 NATIVE_COLS="N%mark N%slim2" NATIVE_MIX_COLS="N%mark N%slim2" \
    rf >>"$LOG" 2>&1
}
step_weak() { need_stands weak || return 0; step_spawn80 weak "A%control N%mark N%slim2" 6; }
step_server1() {
  need_stands server1 || return 0
  gated 618s2-cell1 env PROBE=1 BACKLOG=1024 REVERSE_EVEN=1 THROWAWAY=1 ROUTE="$AGG" "$ROOT/bench/socket/fairness.sh" \
    "bare_marked_listen@8,1@N%mark bare_marked_listen@8,1@N%slim2 bare_marked_listen@8,0@N%mark bare_marked_listen@8,0@N%slim2" \
    3 8s >>"$LOG" 2>&1
}
step_markall() {
  need_stands markall || return 0
  local sw
  for sw in unset spawn insert; do
    tests_one "mall-$sw" mark-slim2all "$sw" "$SIX" || result "markall: the six sets failed on the mark-all build with the switch $sw ($OUT/tests/mall-$sw/tests.log)"
  done
}
step_onethread() {
  need_stands onethread || return 0
  local s pass="" sw
  for s in $ONE_SETS; do
    if tests_one "one-ctl-$s" control unset "[\"$s\"]" "--threads=4,1"; then pass="$pass \"$s\","; else
      log "onethread: $s fails on ctl with workers at --threads=4,1: not runnable that way ($OUT/tests/one-ctl-$s/tests.log)"; fi
  done
  [ -n "$pass" ] || { log "onethread: no set passes on ctl in that layout"; return 0; }
  echo "$pass" >"$OUT/onethread-sets"
  for sw in spawn insert; do
    tests_one "one-mall-$sw" mark-slim2all "$sw" "[${pass%,} ]" "--threads=4,1" ||
      result "onethread: the sets [${pass%,} ] failed on the mark-all build with $sw and workers at 4,1"
  done
}
step_patch() {
  need_stands patch || return 0
  [ -s "$OUT/results" ] && { log "patch: skipped, a part-B result is recorded ($OUT/results)"; return 0; }
  local p="$HERE/native-mark-v1.13.4-slim.patch"
  git -C "$J/mark-slim2" diff v1.13.4 nitro-618-native-mark-slim2 >"$p" || return 1
  log "patch: $p, $(wc -l <"$p") lines, sha256 $(sha256sum "$p" | cut -d' ' -f1)"
}

# quiet.sh runs a command, so a block can be reached through this script itself.
if [ "${1:-}" = --run ]; then shift; "$@"; exit $?; fi

UNTIMED=" prep decideA vharness vchecks vwin tests markall onethread patch "
CUTTABLE=" onethread a5perf a4fib a4cost markall f21 server1 turn "
STEPS="${STEPS:-prep c21 c41 split turn decideA vharness vchecks vwin tests vcells weak server1 f21 markall a4fib a4cost a5perf onethread patch}"
if [ -n "${FROM:-}" ]; then
  STEPS="$(echo "$STEPS" | tr ' ' '\n' | sed -n "/^${FROM}\$/,\$p" | tr '\n' ' ')"
  [ -n "$STEPS" ] || stop "FROM=$FROM is not a step"
fi

log "driver start: steps [$STEPS], OUT $OUT, columns [$COLS6] x $ROUNDS_A rounds${DEADLINE:+, deadline $(date -d @"$DEADLINE" '+%F %T') for [$CUTTABLE]}"
log "perf_event_paranoid $(cat /proc/sys/kernel/perf_event_paranoid)"
for w in control mark mark-bypass mark-bypass2 mark-slim2 mark-slim2b mark-slim2v mark-slim2all mark-validate; do
  [ -x "$B/julia-$w" ] && log "build $w: $("$B/julia-$w" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)' 2>&1)" ||
    log "build $w: MISSING"
done
for s in $STEPS; do
  if [ -n "${DEADLINE:-}" ] && [ "$(date +%s)" -ge "$DEADLINE" ] && [[ "$CUTTABLE" == *" $s "* ]]; then
    log "step $s: CUT (not started by the deadline)"; echo "$s" >>"$OUT/cut"; continue
  fi
  ps_check || stop "ps check before $s"
  cache_mark
  log "step $s: start"
  t0=$(date +%s)
  case "$s" in
    prep) step_prep ;;
    c21) step_cost c21 2,1 0,1,2 "$COLS6" "$ROUNDS_A" ;;
    c41) step_micro c41 4,1 0,1,2,3,4 "$COLS6" "$ROUNDS_A" ;;
    split) step_split ;;
    turn) step_turn ;;
    decideA) step_decideA ;;
    vharness) step_vharness ;;
    vchecks) step_vchecks ;;
    vwin) step_vwin ;;
    tests) step_tests ;;
    vcells) step_vcells ;;
    weak) step_weak ;;
    server1) step_server1 ;;
    f21) step_fib f21 2,1 0,1,2 "$COLS6" "$ROUNDS_A" ;;
    markall) step_markall ;;
    a4fib) step_fib f81 8,1 "$CPUS8" "$COLS6" "$ROUNDS_A" ;;
    a4cost) step_spawn80 a4cost "$COLS6" 6 ;;
    a5perf) step_a5perf ;;
    onethread) step_onethread ;;
    patch) step_patch ;;
    *) stop "unknown step $s" ;;
  esac
  rc=$?
  log "step $s: exit $rc after $(( ($(date +%s) - t0) / 60 )) min"
  if ! cache_check "$s"; then
    [[ "$UNTIMED" == *" $s "* ]] && log "cache check $s: logged, not fatal (an untimed step)" || stop "cache check after $s"
  fi
  [ "$rc" = 0 ] || stop "step $s failed (exit $rc)"
done
reports
log "driver done: every step finished"
