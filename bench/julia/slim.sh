#!/usr/bin/env bash
# #618, the native mark: the two things the bypass run left open (agent-config #82 Idea 14), as one
# driver that needs nothing from the session that launched it.
#   Part A, a control that can fail for the ring side: wake_window.jl in ring mode on the ring control's
#     throwaway build (native-mark-nopass.patch: JULIA_SCHED_NOPASS=1, the ring pop without its full
#     pass), five minutes a column, pass or fail, not behind the quiet gate: (a) no pass and the check
#     blind to the rings (JULIA_SCHED_NEGATIVE=blind), which must show stuck tasks; (b) no pass and the
#     check correct, which must show none. (c), the pass with a blind check, ran on 2026-11-20.
#   Part B, what the unmarked path costs where a spawn is the whole operation, and whether a slimmer path
#     removes it: six columns, ctl (the tag), m2 (the mark), bp and bp2 (two builds of the bypass commit,
#     the zero of the path), s1 and s2 (the slim candidates), rotated so each takes each position
#     equally (12 rounds: 8 cannot share 6 columns equally), one throwaway slot first, every block behind
#     quiet.sh (inside rounds_fifo.sh); the pinning of 2026-11-20 (one hardware thread a Julia thread).
#     A candidate that wins (slim_report.jl) is built a second time (w2) and reruns the path cells with
#     m2, bp, bp2, itself and w2; one that holds is validated as session 1 of the port validated the mark.
# Around every step, as bypass.sh: before it, wait for no julia, oha or go-server process (PS_WAIT_S,
# default 900 s), and STOP if one stays; after it, the cache-write check against a (path, size, inode)
# snapshot of the builds' own depots: a write during a timed step STOPS the driver, during an untimed
# one (a window, a build, a validation step) it is logged.
#
# Steps, in run order: ringA (part A's two columns; run before the go), c21 (H = 0 C = 50 :default and
# tasks.jl micro at 2,1), c41 (tasks.jl micro at 4,1, no spawn_order cell: COST_CELLS_NATIVE=none),
# f21 (fib_fine 2,1, the cell that was layout), decide (slim_report.jl: the winner, or none), w2build (a
# second build of the winner), r21 r41 (c21 and c41 again with m2 bp bp2 W w2, 10 rounds), vbuild (the
# winner's validation build), vharness (rounds_fifo.sh PROFILE=native VALIDATE=1: every harness cell
# and the three negative controls), vchecks (native_checks.jl at 8,1, 8,2 and 1 on both of the winner's
# builds; Julia's six test sets on the timed one), vwin (wake_window ring and wake at 2,1 on the
# validation build, five minutes each, no stuck task allowed), vcells (one round of the cells block,
# the starved and mixed cells among them, under N: m2 and the winner). Every step after decide skips
# itself when there is no winner, and every step after r41 when the reruns do not hold.
# STEPS="<names>" runs a subset, FROM=<name> starts at that step. Cut order if the window is short:
# SLIM_ONE=1 (s2 out of the columns: 5 columns, 10 rounds), then vcells, then f21. Never ringA, c21,
# c41, or the validation of a winner. DEADLINE=<epoch s>: a cuttable step that has not started by then
# is skipped, logged as CUT; the step running at the deadline finishes.
#
# Usage: bench/julia/slim.sh   (detached: setsid nohup … > driver.out 2>&1 < /dev/null &)
#   bench/julia/slim.sh --run <function> <args>: one function (quiet.sh, a build, a smoke)
#   WIN_DUR_S (300), WIN_THRESHOLD (0), WIN_DELAY_NS (0:20000), WIN_TASKS (the pool's thread count),
#   ROUNDS_B (12), ROUNDS_R (10), TD=<s> NOGATE=1 (smoke, never a measurement)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
J="${JULIA618:-$HOME/app/julia-618}"
OUT="${OUT:-$ROOT/bench/results/618-slim}"
mkdir -p "$OUT"
LOG="$OUT/driver.log"
export PATH="$HOME/.local/go/bin:$HOME/.local/bin:$HOME/.juliaup/bin:$PATH"
B="$J/bin"
export JLS="control=$B/julia-control mark=$B/julia-mark bypass=$B/julia-mark-bypass bypass2=$B/julia-mark-bypass2 slim1=$B/julia-mark-slim1 slim2=$B/julia-mark-slim2 slimw2=$B/julia-mark-slimw2"
export MICRO_PROJECT="${MICRO_PROJECT:-$J/benchenv}"
PS_WAIT_S="${PS_WAIT_S:-900}"
CPUS8="0,1,2,3,6,7,8,9"
WIN_DUR_S="${WIN_DUR_S:-300}"
WIN_THRESHOLD="${WIN_THRESHOLD:-0}"
WIN_DELAY_NS="${WIN_DELAY_NS:-0:20000}"
if [ "${SLIM_ONE:-0}" = 1 ]; then
  COLS="A%control N-none%mark N-none%bypass N-none%bypass2 N-none%slim1"; ROUNDS_B="${ROUNDS_B:-10}"
else
  COLS="A%control N-none%mark N-none%bypass N-none%bypass2 N-none%slim1 N-none%slim2"; ROUNDS_B="${ROUNDS_B:-12}"
fi
ROUNDS_R="${ROUNDS_R:-10}"
# The candidates' commits, for the report (their rows name the build by commit).
SC=""
for t in slim1 slim2; do
  [ -d "$J/mark-$t" ] && SC="$SC s${t#slim}=$(git -C "$J/mark-$t" rev-parse --short=10 HEAD)"
done
export SLIM_COMMITS="${SC# }"

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

rf() { PROFILE=native JL="$B/julia-control" "$ROOT/bench/tasks/rounds_fifo.sh" "$@"; }
winner() { [ -s "$OUT/winner" ] && cat "$OUT/winner" || echo none; }
holds() { [ -s "$OUT/decide2.tsv" ] && awk -F'\t' '$1 == "holds" { print $2 }' "$OUT/decide2.tsv" || echo no; }

# ---------------------------------------------------------------- builds
# build_tree <tree> <wrapper suffix> <note>: build ~/app/julia-618/<tree> (already a worktree at the
# commit wanted, Make.user copied), then its wrapper bin/julia-<suffix> with its own first depot, the
# bench env precompiled into that depot and pinned there, and the check that no cache comes from ~/.julia.
build_tree() {
  local tree="$1" suf="$2" note="$3" t="$J/$1" r
  if [ -x "$t/usr/bin/julia" ]; then log "build $tree: already built"; else
    cp "$J/Make.user" "$t/Make.user"
    "$J/build.sh" "$tree" >>"$LOG" 2>&1 || { log "build $tree: FAILED (see $J/build-$tree.log)"; return 1; }
  fi
  mkdir -p "$J/depot-$tree"
  printf '%s\n' '#!/bin/sh' \
    "# $note: its own compiled/ first, then the shared depot (packages, registries) and the build's bundled depots." \
    "export JULIA_DEPOT_PATH=\"\$HOME/app/julia-618/depot-$tree:\$HOME/.julia:\"" \
    "exec \"$t/usr/bin/julia\" \"\$@\"" >"$B/julia-$suf"
  chmod +x "$B/julia-$suf"
  log "build $tree: $("$B/julia-$suf" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short, " ", Sys.CPU_NAME)' 2>&1)"
  log "build $tree: sys.so .text $(objdump -h "$t/usr/lib/julia/sys.so" | awk '$2 == ".text" { print strtonum("0x" $3) }') B; libjulia-internal .text sha256 $(objcopy -O binary --only-section=.text "$t/usr/lib/libjulia-internal.so.1.13" /dev/stdout | sha256sum | cut -c1-12) (m2 $(objcopy -O binary --only-section=.text "$J/mark-r/usr/lib/libjulia-internal.so.1.13" /dev/stdout | sha256sum | cut -c1-12))"
  "$B/julia-$suf" --project="$MICRO_PROJECT" --startup-file=no -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' >>"$LOG" 2>&1 || return 1
  "$B/julia-$suf" --project="$MICRO_PROJECT" --startup-file=no "$J/pin_caches.jl" 2>&1 | tail -1 | tee -a "$LOG"
  r="$("$B/julia-$suf" --project="$MICRO_PROJECT" --startup-file=no "$J/check_caches.jl" 2>&1 | tail -1)"
  log "build $tree: $r"
  case "$r" in *"from ~/.julia: 0"*) ;; *) log "build $tree: a cache from ~/.julia"; return 1 ;; esac
}

# ---------------------------------------------------------------- part A: the ring control
# One column: tsv, layout, cpus, label, wrapper, mode, mark, then env assignments (the controls).
win_one() {
  local tsv="$1" layout="$2" cpus="$3" label="$4" wr="$5" mode="$6" mark="$7" header=1 rc ev
  shift 7
  [ -s "$tsv" ] && header=0
  ev="${tsv%.tsv}.events"
  env JULIA_THREAD_SLEEP_THRESHOLD="$WIN_THRESHOLD" "$@" \
    MODE="$mode" MARK="$mark" DUR_S="${TD:-$WIN_DUR_S}" DELAY_NS="$WIN_DELAY_NS" ${WIN_TASKS:+TASKS=$WIN_TASKS} \
    LABEL="$label" NOHEADER=$((1 - header)) \
    timeout -s KILL $(( ${TD:-$WIN_DUR_S} + 120 )) taskset -c "$cpus" "$B/julia-$wr" --startup-file=no --threads="$layout" \
    "$ROOT/bench/tasks/wake_window.jl" >>"$tsv" 2>>"$ev"
  rc=$?
  [ "$rc" = 0 ] || { log "window $label at $layout: exit $rc (see $ev)"; return 1; }
  log "window $label at $layout: $(tail -1 "$tsv" | awk -F'\t' '{ printf "rounds %s, enqueued %s, stuck %s, late %s, unrescued %s, p99.9 %s us, max %s us", $13, $14, $15, $16, $17, $20, $21 }')"
}
step_ringA() {
  local tsv="$OUT/window/ringA21.tsv"; mkdir -p "$OUT/window"
  win_one "$tsv" 2,1 0,1,2 a-nopass-blind mark-nopass ring 1 JULIA_SCHED_NEGATIVE=blind JULIA_SCHED_NOPASS=1 &&
  win_one "$tsv" 2,1 0,1,2 b-nopass mark-nopass ring 1 JULIA_SCHED_NOPASS=1
}

# ---------------------------------------------------------------- part B: the columns
step_cost() {   # dir, layout, cpus, columns, rounds: H = 0 C = 50 :default and tasks.jl micro (FanOut 1000)
  OUT="$OUT/$1" CPUS="$3" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="$5" ROTATE=1 NATIVE_COLS="$4" \
    WARM=cell CLIENT_CELLS_SPEC="$2 default" COST_CELLS_NATIVE=50:0 MICRO_LAYOUTS="$2" MICRO_ARGS=micro \
    MICRO_FAN_OUT=1000 rf >>"$LOG" 2>&1
}
step_micro() {  # dir, layout, cpus, columns, rounds: tasks.jl micro only (SpawnWait, PingPong, FanOut1000)
  OUT="$OUT/$1" CPUS="$3" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="$5" ROTATE=1 NATIVE_COLS="$4" \
    CLIENT_CELLS_SPEC="$2 default" COST_CELLS_NATIVE=none MICRO_LAYOUTS="$2" MICRO_ARGS=micro \
    MICRO_FAN_OUT=1000 rf >>"$LOG" 2>&1
}
step_fib() {    # dir, layout, cpus, columns, rounds: fib_fine alone
  OUT="$OUT/$1" CPUS="$3" BLOCKS=fibabba ROUNDS=1 ROTATE=1 ABBA_COLS="$4" ABBA_ROUNDS="$5" \
    ABBA_LAYOUTS="$2" rf >>"$LOG" 2>&1
}
step_decide() {
  DECIDE_OUT="$OUT/decide.tsv" "$B/julia-control" --startup-file=no "$HERE/slim_report.jl" "$OUT" >"$OUT/report-b.txt" 2>&1 ||
    { log "decide: slim_report.jl failed (see $OUT/report-b.txt)"; return 1; }
  awk -F'\t' '$1 == "winner" { print $2 }' "$OUT/decide.tsv" >"$OUT/winner"
  log "decide: $(grep '^main steps' "$OUT/report-b.txt")"
}
rerun_cols() { echo "N-none%mark N-none%bypass N-none%bypass2 N-none%$(winner) N-none%slimw2"; }
need_winner() { [ "$(winner)" != none ] || { log "$1: skipped (no winner)"; return 1; }; }
need_holds() { need_winner "$1" || return 1; [ "$(holds)" = yes ] || { log "$1: skipped (the reruns did not hold)"; return 1; }; }

# w2build: the winner's commit again, in its own tree and depot, marked dirty by an untracked file (as
# bp2 was): Julia records the dirt in a file it reads at run time, so the image comes from the same sources.
step_w2build() {
  need_winner w2build || return 0
  local w; w="$(winner)"
  local c; c="$(git -C "$J/mark-$w" rev-parse HEAD)"
  [ -d "$J/mark-slimw2" ] || git -C "$J/mark-$w" worktree add --detach "$J/mark-slimw2" "$c" >>"$LOG" 2>&1 || return 1
  [ "$(git -C "$J/mark-slimw2" rev-parse HEAD)" = "$c" ] || { log "w2build: mark-slimw2 is not at $c"; return 1; }
  echo "a second build of the winning slim candidate (#618 Idea 14): this untracked file marks the tree dirty, nothing else" >"$J/mark-slimw2/W2-MARKER"
  build_tree mark-slimw2 mark-slimw2 "second build of $w (session 5, #618 Idea 14)"
}
step_rerun() {   # dir, layout, cpus, kind (cost|micro)
  need_winner "$1" || return 0
  [ -x "$B/julia-mark-slimw2" ] || { log "$1: no w2 build"; return 1; }
  if [ "$4" = cost ]; then step_cost "$1" "$2" "$3" "$(rerun_cols)" "$ROUNDS_R"; else step_micro "$1" "$2" "$3" "$(rerun_cols)" "$ROUNDS_R"; fi || return 1
  [ "$1" = r41 ] || return 0
  DECIDE2_OUT="$OUT/decide2.tsv" "$B/julia-control" --startup-file=no "$HERE/slim_report.jl" "$OUT" >"$OUT/report-b.txt" 2>&1 ||
    { log "rerun: slim_report.jl failed (see $OUT/report-b.txt)"; return 1; }
  log "rerun: $(grep '^reruns' "$OUT/report-b.txt")"
}

# ---------------------------------------------------------------- part B: the winner's validation
# vbuild: the winner's branch plus `const SCHED_VALIDATE = true`, the one line mark-validate differs by.
step_vbuild() {
  need_holds vbuild || return 0
  local w; w="$(winner)"
  local br="nitro-618-native-mark-$w-validate"
  if [ ! -d "$J/mark-slimv" ]; then
    git -C "$J/mark-$w" worktree add -b "$br" "$J/mark-slimv" "nitro-618-native-mark-$w" >>"$LOG" 2>&1 || return 1
    sed -i 's/^const SCHED_VALIDATE = false$/const SCHED_VALIDATE = true/' "$J/mark-slimv/base/partr.jl"
    grep -q '^const SCHED_VALIDATE = true$' "$J/mark-slimv/base/partr.jl" || { log "vbuild: SCHED_VALIDATE not set"; return 1; }
    git -C "$J/mark-slimv" commit -qam "partr: SCHED_VALIDATE = true (the validation build of $w)" || return 1
  fi
  build_tree mark-slimv mark-slimv "validation build of $w (session 5, #618 Idea 14)"
}
step_vharness() {
  need_holds vharness || return 0
  JL="$B/julia-mark-slimv" VALIDATE=1 OUT="$OUT/validate" PROFILE=native "$ROOT/bench/tasks/rounds_fifo.sh" >>"$LOG" 2>&1
}
step_vchecks() {
  need_holds vchecks || return 0
  local w b l; w="$(winner)"
  for b in mark-slimv "mark-$w"; do
    for l in 8,1 8,2 1; do
      "$B/julia-$b" --startup-file=no --threads="$l" "$HERE/native_checks.jl" >>"$OUT/native_checks.log" 2>&1 ||
        { log "vchecks: native_checks.jl FAILED on $b at $l (see $OUT/native_checks.log)"; return 1; }
      log "vchecks: native_checks.jl on $b at $l: $(grep -c 'native_checks: ok:' "$OUT/native_checks.log") ok lines so far"
    done
  done
  "$J/run_tests.sh" "mark-$w" >>"$LOG" 2>&1
  log "vchecks: Julia's tests on mark-$w: $(grep -E 'SUCCESS|FAILURE|Overall' "$J/tests-mark-$w.log" | tail -3 | tr '\n' ' ')"
  log "vchecks: the control's: $(grep -E 'SUCCESS|FAILURE|Overall' "$J/tests-control.log" | tail -3 | tr '\n' ' ')"
}
step_vwin() {
  need_holds vwin || return 0
  local tsv="$OUT/window/vwin21.tsv"; mkdir -p "$OUT/window"
  win_one "$tsv" 2,1 0,1,2 sv-ring mark-slimv ring 1 &&
  win_one "$tsv" 2,1 0,1,2 sv-wake mark-slimv wake 1 || return 1
  local s; s="$(awk -F'\t' 'NR > 1 && $1 != "label" { s += $15 + $16 + $17 } END { print s + 0 }' "$tsv")"
  [ "$s" = 0 ] || { log "RESULT: $s stuck or late tasks on the winner's validation build ($tsv)"; return 1; }
}
step_vcells() {
  need_holds vcells || return 0
  local w; w="$(winner)"
  OUT="$OUT/vcells" CPUS="$CPUS8" BLOCKS=cells ROUNDS=1 NATIVE_COLS="N%mark N%$w" NATIVE_MIX_COLS="N%mark N%$w" rf >>"$LOG" 2>&1
}

# quiet.sh runs a command, so a block can be reached through this script itself.
if [ "${1:-}" = --run ]; then shift; "$@"; exit $?; fi

UNTIMED=" ringA decide w2build vbuild vharness vchecks vwin "
CUTTABLE=" vcells f21 "
STEPS="${STEPS:-c21 c41 f21 decide w2build r21 r41 vbuild vharness vchecks vwin vcells}"
if [ -n "${FROM:-}" ]; then
  STEPS="$(echo "$STEPS" | tr ' ' '\n' | sed -n "/^${FROM}\$/,\$p" | tr '\n' ' ')"
  [ -n "$STEPS" ] || stop "FROM=$FROM is not a step"
fi

log "driver start: steps [$STEPS], OUT $OUT, columns [$COLS] x $ROUNDS_B rounds, reruns x $ROUNDS_R${DEADLINE:+, deadline $(date -d @"$DEADLINE" '+%F %T') for [$CUTTABLE]}"
log "candidates: $SLIM_COMMITS"
for w in control mark mark-bypass mark-bypass2 mark-slim1 mark-slim2; do
  [ -x "$B/julia-$w" ] && log "build $w: $("$B/julia-$w" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)' 2>&1)"
done
for s in $STEPS; do
  if [ -n "${DEADLINE:-}" ] && [ "$(date +%s)" -ge "$DEADLINE" ] && [[ "$CUTTABLE" == *" $s "* ]]; then
    log "step $s: CUT (not started by the deadline)"; continue
  fi
  ps_check || stop "ps check before $s"
  cache_mark
  log "step $s: start"
  t0=$(date +%s)
  case "$s" in
    ringA) step_ringA ;;
    c21) step_cost c21 2,1 0,1,2 "$COLS" "$ROUNDS_B" ;;
    c41) step_micro c41 4,1 0,1,2,3,4 "$COLS" "$ROUNDS_B" ;;
    f21) step_fib f21 2,1 0,1,2 "$COLS" "$ROUNDS_B" ;;
    decide) step_decide ;;
    w2build) step_w2build ;;
    r21) step_rerun r21 2,1 0,1,2 cost ;;
    r41) step_rerun r41 4,1 0,1,2,3,4 micro ;;
    vbuild) step_vbuild ;;
    vharness) step_vharness ;;
    vchecks) step_vchecks ;;
    vwin) step_vwin ;;
    vcells) step_vcells ;;
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
