#!/usr/bin/env bash
# #618, the native mark: the battery "what a reviewer of a scheduler change would ask" (agent-config #82
# Idea 12, with Idea 11 as its item 1), as one driver that needs nothing from the session that launched
# it. Every timed block goes through bench/socket/quiet.sh (inside rounds_fifo.sh, or here for the pfib
# and server blocks). Around every step the driver:
#   - before it: waits for no julia, oha or go-server process (PS_WAIT_S, default 900 s, logging what it
#     sees every 30 s); still there at the end, the driver STOPS and logs them. It never stops a process;
#   - after it: the cache-write check of native_measure.sh, against a (path, size, inode) snapshot of the
#     builds' own depots taken just before it. A write during a timed step STOPS the driver; during an
#     untimed one (tests, stall, pfibcount, cornersv) it is logged;
#   - stops on a step that fails (a timed block that gave up after its retries, a failed cache pin).
# Item 4 (stall) never stops the driver: a stuck or timed-out run on a mark build ends that sub-block
# (stall.sh STOP_ON), its log kept, and the driver goes on; that run is the session's result.
#
# The builds (~/app/julia-618/bin wrappers, each with its own first depot): ctl (control, the tag), m1
# (mark, session 1's build of the patch), m2 (mark-r, the clean rebuild), mv (mark-validate), mall
# (mark-all, the switch; never timed), official (the juliaup 1.13.4 binary), ws and base
# (JuliaLang/julia#62285's head, work-stealing and partr builds: another Julia version, read only
# ws / base).
#
# Steps, in run order (the maintainer's): fib3 (item 1's yardstick), tests (item 3), stall (item 4),
# pfib21 pfib20 pfib80 pfibcount (item 2), leans plain80f plain81f cell1f (the rest of item 1),
# t20 t21 t40 t41 (item 5), cornersa cornersv cornersb cornersc (item 7). STEPS="<names>" runs a
# subset, FROM=<name> starts at that step. Cut order if the night is short: corners*, t*, the ws/base
# columns of pfib (PFIB_COLS), plain81f; never tests or stall.
#
# Usage: bench/julia/battery.sh   (detached: setsid nohup … > driver.out 2>&1 < /dev/null &)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
J="${JULIA618:-$HOME/app/julia-618}"
OUT="${OUT:-$ROOT/bench/results/618-battery}"
mkdir -p "$OUT"
LOG="$OUT/driver.log"
export PATH="$HOME/.local/go/bin:$HOME/.local/bin:$HOME/.juliaup/bin:$PATH"
B="$J/bin"
export JLS="control=$B/julia-control mark=$B/julia-mark mark1=$B/julia-mark1 official=$B/julia-official"
export JULIAS="control=$B/julia-control,$ROOT/bench mark=$B/julia-mark,$ROOT/bench official=$B/julia-official,$ROOT/bench"
export MICRO_PROJECT="${MICRO_PROJECT:-$J/benchenv}"
BENCHENV_62285="${BENCHENV_62285:-$HOME/app/julia-62285/benchenv}"
PS_WAIT_S="${PS_WAIT_S:-900}"
CPUS8="0,1,2,3,6,7,8,9"
AGG="/aggregate?n=100000&op=groupby"
THREE="A%control N-none%mark1 N-none%mark"   # ctl, m1, m2: every unmarked cost cell

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
stop() { log "STOP: $*"; log "driver stopped; restart with FROM=<step> after fixing"; exit 1; }
procs() { ps -eo pid=,etime=,comm=,args= | awk '$3 == "julia" || $3 == "oha" || $3 == "go-server"' | cut -c1-220; }

ps_check() {
  local waited=0 p
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

# The official binary takes the newest valid cache, and another process can touch ~/.julia's copies:
# re-pin and re-check its bench env right before a block that starts it (notes.md, 2026-11-19).
pin_official() {
  local out
  "$B/julia-official" --startup-file=no --project="$ROOT/bench" "$J/pin_caches.jl" >>"$LOG" 2>&1
  out="$("$B/julia-official" --startup-file=no --project="$ROOT/bench" "$J/check_caches.jl" 2>&1)"
  echo "$out" >>"$LOG"
  echo "$out" | grep -q 'from ~/.julia: 0$' || { log "pin_official: the official binary still loads caches from ~/.julia"; return 1; }
}

rf() { PROFILE=native JL="$B/julia-control" "$ROOT/bench/tasks/rounds_fifo.sh" "$@"; }

# A gated command (quiet.sh), retried on a failed gate (3) or a stopped block (4), twice at most.
gated() {   # label, command...
  local attempt=1 rc
  while :; do
    "$ROOT/bench/socket/quiet.sh" "$@"; rc=$?
    { [ "$rc" = 3 ] || [ "$rc" = 4 ]; } || return "$rc"
    [ "$attempt" -le 2 ] || return "$rc"
    log "gated $1: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    ps_check || return 1
  done
}

# ---------------------------------------------------------------- item 2: pfib(25), JuliaLang/julia#35589
# Columns: label:wrapper:mode. ws and base load BenchmarkTools from the 1.14 environment.
PFIB_COLS="${PFIB_COLS:-ctl:control:none m1:mark1:none m2:mark:none root:mark:root all:mark:all ws:ws:none base:base:none}"
pfib_one() {   # tsv, round, layout, cpus, column, [COUNT=1]
  local tsv="$1" r="$2" layout="$3" cpus="$4" col="$5" count="${6:-}" label wr mode env out rc
  IFS=: read -r label wr mode <<<"$col"
  env="$J/benchenv"; case "$wr" in ws|base) env="$BENCHENV_62285" ;; esac
  out="$(env PFIB_MODE="$mode" LABEL="$label" ROUND="$r" ${count:+$count} timeout -s KILL "${PFIB_TIMEOUT_S:-300}" \
    taskset -c "$cpus" "$B/julia-$wr" --startup-file=no --project="$env" --threads="$layout" "$HERE/../tasks/pfib.jl" 2>>"$tsv.err")"
  rc=$?
  if [ "$rc" = 0 ] && [ -n "$out" ]; then echo "$out" >>"$tsv"
  else printf '%s\t%s\t%s\t%s\t25\tFAILED rc=%s\n' "$r" "$label" "$mode" "$layout" "$rc" >>"$tsv"; fi
}
rotated() {   # round, items... -> the items rotated by (round - 1) mod n
  local r="$1"; shift
  local n=$# k a i out=(); k=$(( ((r - 1) % n + n) % n )); a=("$@")
  for ((i = 0; i < n; i++)); do out+=("${a[$(( (i + k) % n ))]}"); done
  echo "${out[*]}"
}
pfib_block() {   # tsv, layout, cpus
  local tsv="$1" layout="$2" cpus="$3" r c first
  first="$(echo $PFIB_COLS | cut -d' ' -f1)"
  pfib_one "$OUT/pfib-throwaway.tsv" 0 "$layout" "$cpus" "$first"
  for r in $(seq 1 "${PFIB_ROUNDS:-6}"); do
    for c in $(rotated "$r" $PFIB_COLS); do pfib_one "$tsv" "$r" "$layout" "$cpus" "$c"; done
  done
}
step_pfib() {   # layout, cpus
  local tag="${1/,/}" a
  a="$OUT/pfib-$tag.tsv"; rm -f "$a"
  printf 'round\tlabel\tmode\tlayout\tn\tmin_s\tmedian_s\tallocs\tmemory_bytes\tsamples\tmaxrss_mb\n' >"$a"
  gated "618bat-pfib-$tag" "$HERE/battery.sh" --run pfib_block "$a" "$1" "$2" >>"$LOG" 2>&1
}
step_pfibcount() {   # untimed: the peak of live tasks per mode, once per layout
  local a="$OUT/pfib-count.tsv" spec layout cpus c
  printf 'round\tlabel\tmode\tlayout\tn\tpeak_live\tspawned\tmaxrss_mb\n' >"$a"
  for spec in "2,1:0,1,2" "2,0:0,1" "8,0:$CPUS8"; do
    layout="${spec%%:*}"; cpus="${spec#*:}"
    for c in ctl:control:none m2:mark:none root:mark:root all:mark:all; do pfib_one "$a" 1 "$layout" "$cpus" "$c" COUNT=1; done
  done
}

# ---------------------------------------------------------------- item 3: Julia's own tests
# Two runtests calls a column. A: the six sets of session 1 plus gc and ioloop_wakeup, in the runner's
# own worker layout (threadpool_use, threadpool_latency and ioloop_wakeup assert it; threads, channels
# and gc start their own multithreaded subprocesses). B: sets that only exercise the scheduler in a
# multithreaded worker, with JULIA_TEST_EXTRA_EXEFLAGS=--threads=4,1. Every column runs both, ctl too.
TEST_SETS_A='["core", "threads", "channels", "channel_threadpool", "threadpool_use", "threadpool_latency", "gc", "ioloop_wakeup"]'
TEST_SETS_B='["scopedvalues", "Distributed", "Logging", "Profile"]'
tests_pass() {   # label, wrapper, switch (unset|spawn|insert)
  local label="$1" wr="$2" sw="$3" d t0 rc part sets envs
  d="$OUT/tests/$label"; mkdir -p "$d/log"
  rm -f "$J/mark-all-log/current"; mkdir -p "$J/mark-all-log"
  [ "$wr" = mark-all ] && ln -sfn "$d/log" "$J/mark-all-log/current"
  for part in A B; do
    envs=()
    [ "$part" = B ] && envs+=("JULIA_TEST_EXTRA_EXEFLAGS=--threads=4,1")
    [ "$sw" != unset ] && envs+=("JULIA_SCHED_MARK_ALL=$sw")
    [ "$wr" = mark-all ] && envs+=("JULIA_SCHED_MARK_ALL_LOG=$d/log")
    if [ "$part" = A ]; then sets="$TEST_SETS_A"; else sets="$TEST_SETS_B"; fi
    t0=$(date +%s)
    ( cd "$J" && env ${envs[@]+"${envs[@]}"} timeout -s KILL "${TESTS_TIMEOUT_S:-3600}" "$B/julia-$wr" --startup-file=no \
        -e "Base.runtests($sets; ncores = 6)" >"$d/tests-$part.log" 2>&1 )
    rc=$?
    log "tests $label $part: $wr, JULIA_SCHED_MARK_ALL=$sw: exit $rc after $(( $(date +%s) - t0 )) s; $(grep -E '^ *(SUCCESS|FAILURE)' "$d/tests-$part.log" | tail -1 | tr -d ' ')"
  done
  rm -f "$J/mark-all-log/current"
  log "tests $label: $(ls "$d/log" | wc -l) exit-log files ($(grep -l fallback "$d"/log/*.tsv 2>/dev/null | wc -l) through the fallback: started without the switch's variables)"
}
step_tests() {
  local n=0 t_end
  tests_pass ctl control unset
  tests_pass mv mark-validate unset
  tests_pass mall-unset mark-all unset
  tests_pass mall-spawn-1 mark-all spawn
  tests_pass mall-insert-1 mark-all insert
  t_end=$(( $(date +%s) + ${TESTS_REPEAT_S:-3600} ))
  n=2
  while [ "$(date +%s)" -lt "$t_end" ]; do
    tests_pass "mall-spawn-$n" mark-all spawn
    [ "$(date +%s)" -lt "$t_end" ] || break
    tests_pass "mall-insert-$n" mark-all insert
    n=$((n + 1))
  done
  return 0
}

# ---------------------------------------------------------------- item 4: the stall repro, marked
stall_run() {   # label, env... (RUNS, THREADS, CPUS, STOP_ON, BUILDS)
  local label="$1" rc; shift
  env "$@" TIMEOUT_S="${STALL_TIMEOUT_S:-60}" OUT="$OUT/stall-$label" "$ROOT/bench/tasks/stall.sh" >>"$LOG" 2>&1; rc=$?
  log "stall $label: exit $rc"
  [ "$rc" = 5 ] && { log "stall $label: A MARK BUILD STALLED; the rest of item 4 is not run (the result of the session)"; return 5; }
  return 0
}
step_stall() {
  local m2="$B/julia-mark" mv="$B/julia-mark-validate" ctl="$B/julia-control" b8 mvb m
  # Positive controls first: the repro must still be able to fail here, for each class of bug.
  stall_run pos RUNS=10 BUILDS="ws=$B/julia-ws base=$B/julia-base negblind=$mv@tasks@JULIA_SCHED_NEGATIVE=blind negrblind=$mv@under@JULIA_SCHED_NEGATIVE=rblind"
  b8=""; mvb=""
  for m in all tasks holders under; do b8+=" m2-$m=$m2@$m"; mvb+=" mv-$m=$mv@$m"; done
  stall_run main8a RUNS="${STALL_RUNS_A:-200}" THREADS=8 CPUS="$CPUS8" STOP_ON='^(m2|mv)-' \
    BUILDS="$b8$mvb ctl-none=$ctl" || return 0
  stall_run main8b RUNS="${STALL_RUNS_B:-300}" THREADS=8 CPUS="$CPUS8" STOP_ON='^m2-' BUILDS="$b8" || return 0
  stall_run t2 RUNS="${STALL_RUNS_T:-200}" THREADS=2 CPUS=0,1,2 STOP_ON='^m2-' \
    BUILDS="m2-tasks=$m2@tasks m2-under=$m2@under" || return 0
  stall_run t4 RUNS="${STALL_RUNS_T:-200}" THREADS=4 CPUS=0,1,2,3,4 STOP_ON='^m2-' \
    BUILDS="m2-tasks=$m2@tasks m2-under=$m2@under" || return 0
}

# ---------------------------------------------------------------- items 1, 5, 7
step_fib3() {
  OUT="$OUT/fib3" BLOCKS=fibabba ROUNDS=1 ROTATE=1 ABBA_COLS="$THREE" ABBA_ROUNDS=12 ABBA_LAYOUTS="8,1 8,0" \
    rf >>"$LOG" 2>&1
}
step_leans() {
  OUT="$OUT/leans" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS=12 ROTATE=1 NATIVE_COLS="$THREE" \
    CLIENT_CELLS_SPEC="8,1 default" MICRO_LAYOUTS=8,0 MICRO_ARGS=micro MICRO_FAN_OUT=1000 rf >>"$LOG" 2>&1
}
step_plain() {   # layout
  pin_official || return 1
  gated "618bat-plain-${1/,/_}" env FRESH=1 BACKLOG=1024 REVERSE_EVEN=1 THROWAWAY=1 OHA=1 PROBE=0 CLIENT_CPU=1 \
    ROUTE="/plaintext" "$ROOT/bench/socket/fairness.sh" \
    "bare_spawn@$1%control bare_spawn@$1%mark bare_spawn@$1%official bare_spawn@$1@A0%official bare_spawn@$1@M-none%official" \
    8 8s >>"$LOG" 2>&1
}
step_cell1f() {
  gated 618bat-cell1-fresh env FRESH=1 BACKLOG=1024 REVERSE_EVEN=1 THROWAWAY=1 PROBE=0 ROUTE="$AGG" \
    "$ROOT/bench/socket/fairness.sh" "bare_spawn@8,1%control bare_spawn@8,1%mark" 8 8s >>"$LOG" 2>&1
}
step_threads() {   # layout, cpus: item 5, one hardware thread per Julia thread, each on its own core
  local tag="${1/,/}"
  OUT="$OUT/t$tag" CPUS="$2" BLOCKS=fibabba ROUNDS=1 ROTATE=1 ABBA_COLS="$THREE" ABBA_ROUNDS=12 ABBA_LAYOUTS="$1" \
    rf >>"$LOG" 2>&1 || return 1
  OUT="$OUT/t$tag" CPUS="$2" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS=6 ROTATE=1 NATIVE_COLS="$THREE" WARM=cell \
    CLIENT_CELLS_SPEC="$1 default" MICRO_LAYOUTS="$1" MICRO_ARGS=micro MICRO_FAN_OUT=1000 rf >>"$LOG" 2>&1
}
step_cornersa() {   # 7(a): the async shape beside the plain one, the starved cell at 8,1, ctl and N on m2
  OUT="$OUT/corners" BLOCKS=shaperounds ROUNDS=1 MULTI_ROUNDS=6 NATIVE_COLS="A%control N%mark" WARM=cell \
    SHAPE_CELLS_NATIVE="500:2 500:2:async" rf >>"$LOG" 2>&1
}
step_cornersv() {   # 7(a) VALIDATE on mark-validate, untimed: the starved cell and the mixed cell, async shape
  local d="$OUT/corners"; mkdir -p "$d"
  env VALIDATE=1 VARIANT=N CELLS="500:2 500:2:async" MODES=spawn CLIENTS=interactive D=4 \
    timeout -s KILL 600 taskset -c "$CPUS8" "$B/julia-mark-validate" --threads=8,1 "$ROOT/bench/tasks/spawn_order.jl" \
    >"$d/validate-async-spawn.tsv" 2>"$d/validate-async-spawn.log" || { log "cornersv: spawn_order VALIDATE failed"; return 1; }
  local s
  for s in plain async; do
    env VALIDATE=1 VARIANT=N SHAPE="$s" FIB_FINE=36:12 D=4 timeout -s KILL 600 taskset -c "$CPUS8" \
      "$B/julia-mark-validate" --threads=8,1 "$ROOT/bench/tasks/mixed_cell.jl" \
      >"$d/validate-mixed-$s.tsv" 2>"$d/validate-mixed-$s.log" || { log "cornersv: mixed_cell VALIDATE SHAPE=$s failed"; return 1; }
  done
  log "cornersv: $(grep -h 'credit-run\|async children' "$d"/validate-*.log | cut -c1-200 | tr '\n' ' ')"
}
step_cornersb() {   # 7(b): server cell 1 at 8,2 and 8,1
  gated 618bat-cell1-82 env PROBE=1 BACKLOG=1024 REVERSE_EVEN=1 THROWAWAY=1 ROUTE="$AGG" \
    "$ROOT/bench/socket/fairness.sh" \
    "bare_spawn@8,2%control bare_spawn@8,1%control bare_marked_listen@8,2@N%mark bare_marked_listen@8,1@N%mark" \
    6 8s >>"$LOG" 2>&1
}
step_cornersc() {   # 7(b): the harness's starved cell with :interactive clients at 8,2 (8,1 beside it)
  OUT="$OUT/corners" BLOCKS=fairrounds ROUNDS=1 MULTI_ROUNDS=6 NATIVE_COLS="A%control N%mark" WARM=cell \
    CLIENT_CELLS_SPEC="8,2 interactive;8,1 interactive" rf >>"$LOG" 2>&1
}

# quiet.sh runs a command, so the pfib block is reached through this script itself.
if [ "${1:-}" = --run ]; then shift; "$@"; exit $?; fi

UNTIMED=" tests stall pfibcount cornersv "
STEPS="${STEPS:-fib3 tests stall pfib21 pfib20 pfib80 pfibcount leans plain80f plain81f cell1f t20 t21 t40 t41 cornersa cornersv cornersb cornersc}"
if [ -n "${FROM:-}" ]; then
  STEPS="$(echo "$STEPS" | tr ' ' '\n' | sed -n "/^${FROM}\$/,\$p" | tr '\n' ' ')"
  [ -n "$STEPS" ] || stop "FROM=$FROM is not a step"
fi

log "driver start: steps [$STEPS], OUT $OUT"
for w in control mark1 mark mark-validate mark-all official ws base; do
  log "build $w: $("$B/julia-$w" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)' 2>&1)"
done
for s in $STEPS; do
  ps_check || stop "ps check before $s"
  cache_mark
  log "step $s: start"
  t0=$(date +%s)
  case "$s" in
    fib3) step_fib3 ;;
    tests) step_tests ;;
    stall) step_stall ;;
    pfib21) step_pfib 2,1 0,1,2 ;;
    pfib20) step_pfib 2,0 0,1 ;;
    pfib80) step_pfib 8,0 "$CPUS8" ;;
    pfibcount) step_pfibcount ;;
    leans) step_leans ;;
    plain80f) step_plain 8,0 ;;
    plain81f) step_plain 8,1 ;;
    cell1f) step_cell1f ;;
    t20) step_threads 2,0 0,1 ;;
    t21) step_threads 2,1 0,1,2 ;;
    t40) step_threads 4,0 0,1,2,3 ;;
    t41) step_threads 4,1 0,1,2,3,4 ;;
    cornersa) step_cornersa ;;
    cornersv) step_cornersv ;;
    cornersb) step_cornersb ;;
    cornersc) step_cornersc ;;
    *) stop "unknown step $s" ;;
  esac
  rc=$?
  log "step $s: exit $rc after $(( ($(date +%s) - t0) / 60 )) min"
  if ! cache_check "$s"; then
    [[ "$UNTIMED" == *" $s "* ]] && log "cache check $s: logged, not fatal (an untimed step)" || stop "cache check after $s"
  fi
  [ "$rc" = 0 ] || stop "step $s failed (exit $rc)"
done
log "driver done: every step finished"
