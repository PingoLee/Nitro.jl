#!/usr/bin/env bash
# #618, the native mark: the two things the battery left open (agent-config #82 Idea 13), as one
# driver that needs nothing from the session that launched it.
#   Question 2, a repro that can see a lost wakeup: bench/tasks/wake_window.jl, five minutes a column,
#     pass or fail, not behind the quiet gate (nothing else runs: the ps check before each step).
#   Question 1, is the unmarked 1-4% at 2 and 4 threads the new path or where the code landed: four
#     columns, ctl (the tag), m1 and m2 (two builds of the mark) and bp (the bypass build:
#     native-mark-bypass.patch, the mark's code in the image and the tag's entry points), rotated so
#     each takes each position equally, one throwaway slot first, every block behind quiet.sh (inside
#     rounds_fifo.sh). Pinning: one hardware thread a Julia thread, each on its own core.
# Around every step, as battery.sh: before it, wait for no julia, oha or go-server process (PS_WAIT_S,
# default 900 s), and STOP if one stays; after it, the cache-write check against a (path, size, inode)
# snapshot of the builds' own depots: a write during a timed step STOPS the driver, during a window
# step it is logged. A stuck task on a column without a negative control does not stop the driver: it
# is logged as RESULT, every file is kept, and it is the session's result.
#
# Steps, in run order: win21 win41 win81 (question 2's columns at 2,1, 4,1 and 8,1), neg41 neg81 (the
# rblind control again, for its hit rate against the thread count; blind cannot fail on this path, as
# read, and ran once at 2,1 before the session: neg21, NEG_BLIND=1), f21 c21 c41 c20 (the six cells:
# fib_fine 2,1; H = 0 C = 50 and tasks.jl SpawnWait/FanOut1000 at 2,1, 4,1 and 2,0), f40 (fib_fine
# 4,0); decide (bypass_report.jl over the six cells), and, only if a cell reads as the path (bp with
# ctl, m2/bp carrying the difference: one bypass build is one layout draw), bp2build (a second build of
# the bypass commit) and bp2f21 bp2c21 bp2c41 bp2c20 (those steps again with ctl, m2, bp and bp2, under
# <OUT>/bp2/; each skips itself unless decide named it); f20 f80 (the control cells), then
# question 3, the maintainer's (throughput: JuliaLang/julia#62285 against the mark, in the same blocks):
# q3spawn (spawn_order.jl H = 0, C = 50 and 500, :default clients at 8,0 and :interactive clients at
# 8,1; ws, base, ctl, m2 under N and m2 with nothing marked, 6 rotated rounds) and q3p81 q3p80
# (/plaintext under oha, c = 500, fresh servers, 8 rotated rounds: ws and base in the environment of
# 2026-11-17, HTTP62285; ctl bare_spawn and m2 bare_marked_listen under N in bench/). ws and base are
# another Julia version: read ws/base and m2/ctl only.
# STEPS="<names>" runs a subset, FROM=<name> starts at that step. Cut order if the window is short:
# question 3 (q3p80, q3p81, q3spawn), then win81 and neg81, then f20 and f80. Never f21 c21 c41 c20 f40
# or the bp2 steps. DEADLINE=<epoch s>: a cuttable step that has not started by then is skipped, logged
# as CUT; the step running at the deadline finishes.
#
# Usage: bench/julia/bypass.sh   (detached: setsid nohup … > driver.out 2>&1 < /dev/null &)
#   WIN_DUR_S (300), WIN_THRESHOLD (0: JULIA_THREAD_SLEEP_THRESHOLD for the window runs), WIN_DELAY_NS
#   (0:20000), WIN_TASKS (the pool's thread count), TD=<s> NOGATE=1 (smoke, never a measurement)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
J="${JULIA618:-$HOME/app/julia-618}"
OUT="${OUT:-$ROOT/bench/results/618-bypass}"
mkdir -p "$OUT"
LOG="$OUT/driver.log"
export PATH="$HOME/.local/go/bin:$HOME/.local/bin:$HOME/.juliaup/bin:$PATH"
B="$J/bin"
export JLS="control=$B/julia-control mark=$B/julia-mark mark1=$B/julia-mark1 bypass=$B/julia-mark-bypass ws=$B/julia-ws base=$B/julia-base"
HTTP62285="${HTTP62285:-$HOME/app/bench-runs/2026-11-17/http-62285}"
export MICRO_PROJECT="${MICRO_PROJECT:-$J/benchenv}"
PS_WAIT_S="${PS_WAIT_S:-900}"
CPUS8="0,1,2,3,6,7,8,9"
FOUR="A%control N-none%mark1 N-none%mark N-none%bypass"   # ctl, m1, m2, bp
FOUR2="A%control N-none%mark N-none%bypass N-none%bypass2" # ctl, m2, bp, bp2 (the bp2 reruns)
WIN_DUR_S="${WIN_DUR_S:-300}"
WIN_THRESHOLD="${WIN_THRESHOLD:-0}"
WIN_DELAY_NS="${WIN_DELAY_NS:-0:20000}"

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

# ---------------------------------------------------------------- question 2: the window repro
# One column: tsv, layout, cpus, label, wrapper, mode, mark, negative control (- for none).
win_one() {
  local tsv="$1" layout="$2" cpus="$3" label="$4" wr="$5" mode="$6" mark="$7" neg="$8" header=1 rc ev
  [ -s "$tsv" ] && header=0
  ev="${tsv%.tsv}.events"
  local extra=()
  [ "$neg" != - ] && extra+=(JULIA_SCHED_NEGATIVE="$neg")
  env JULIA_THREAD_SLEEP_THRESHOLD="$WIN_THRESHOLD" "${extra[@]}" \
    MODE="$mode" MARK="$mark" DUR_S="${TD:-$WIN_DUR_S}" DELAY_NS="$WIN_DELAY_NS" ${WIN_TASKS:+TASKS=$WIN_TASKS} \
    LABEL="$label" NOHEADER=$((1 - header)) \
    timeout -s KILL $(( ${TD:-$WIN_DUR_S} + 120 )) taskset -c "$cpus" "$B/julia-$wr" --startup-file=no --threads="$layout" \
    "$ROOT/bench/tasks/wake_window.jl" >>"$tsv" 2>>"$ev"
  rc=$?
  [ "$rc" = 0 ] || { log "window $label at $layout: exit $rc (see $ev)"; return 1; }
  local row stuck
  row="$(tail -1 "$tsv")"
  stuck="$(echo "$row" | awk -F'\t' '{ print $15 + $16 + $17 }')"
  log "window $label at $layout: $(echo "$row" | awk -F'\t' '{ printf "rounds %s, enqueued %s, stuck %s, late %s, unrescued %s, p99.9 %s us, max %s us", $13, $14, $15, $16, $17, $20, $21 }')"
  if [ "$neg" = - ] && [ "$stuck" != 0 ]; then
    log "RESULT: a task stuck past STUCK_MS on $label at $layout, a column without a negative control; every file kept ($tsv, $ev)"
  fi
}
step_win() {   # layout, cpus
  local tag="${1/,/}" tsv
  tsv="$OUT/window/win$tag.tsv"; mkdir -p "$OUT/window"
  win_one "$tsv" "$1" "$2" mv-ring mark-validate ring 1 - &&
  win_one "$tsv" "$1" "$2" mv-wake mark-validate wake 1 - &&
  win_one "$tsv" "$1" "$2" m2-ring mark ring 1 - &&
  win_one "$tsv" "$1" "$2" m2-wake mark wake 1 - &&
  win_one "$tsv" "$1" "$2" ctl-ring-none control ring 0 - &&
  win_one "$tsv" "$1" "$2" ctl-wake-none control wake 0 -
}
step_neg() {   # layout, cpus: rblind on mark-validate (and blind with NEG_BLIND=1, as neg21 ran)
  local tag="${1/,/}" tsv
  tsv="$OUT/window/neg$tag.tsv"; mkdir -p "$OUT/window"
  if [ "${NEG_BLIND:-0}" = 1 ]; then win_one "$tsv" "$1" "$2" neg-blind-ring mark-validate ring 1 blind || return 1; fi
  win_one "$tsv" "$1" "$2" neg-rblind-wake mark-validate wake 1 rblind
}

# ---------------------------------------------------------------- question 1: the four columns
# COLS4 and SUB: the columns and the results subdirectory (the bp2 reruns: FOUR2 and bp2/).
step_fib() {   # layout, cpus: fib_fine alone, 12 rotated rounds
  local tag="${1/,/}"
  OUT="$OUT/${SUB:-}f$tag" CPUS="$2" BLOCKS=fibabba ROUNDS=1 ROTATE=1 ABBA_COLS="${COLS4:-$FOUR}" ABBA_ROUNDS="${FIB_ROUNDS:-12}" \
    ABBA_LAYOUTS="$1" rf >>"$LOG" 2>&1
}
step_cost() {   # layout, cpus: H = 0 C = 50 with :default clients, and tasks.jl micro (FanOut 1000), 8 rotated rounds
  local tag="${1/,/}"
  OUT="$OUT/${SUB:-}c$tag" CPUS="$2" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="${COST_ROUNDS:-8}" ROTATE=1 NATIVE_COLS="${COLS4:-$FOUR}" \
    WARM=cell CLIENT_CELLS_SPEC="$1 default" COST_CELLS_NATIVE=50:0 MICRO_LAYOUTS="$1" MICRO_ARGS=micro \
    MICRO_FAN_OUT=1000 rf >>"$LOG" 2>&1
}

# ---------------------------------------------------------------- question 1: the second bypass build
# decide: the report's reading of the six cells, one line a cell (step, cell, reading), in decide.tsv.
step_decide() {
  DECIDE_OUT="$OUT/decide.tsv" "$B/julia-control" --startup-file=no "$HERE/bypass_report.jl" "$OUT" >"$OUT/report-q1.txt" 2>&1 ||
    { log "decide: bypass_report.jl failed (see $OUT/report-q1.txt)"; return 1; }
  log "decide: $(awk -F'\t' '{ printf "%s: %s; ", $2, $3 }' "$OUT/decide.tsv")"
  local need; need="$(bp2_steps)"
  [ -n "$need" ] && log "decide: read as the path in [$need]: bp2 is built and those steps rerun" ||
    log "decide: no cell reads as the path: no bp2"
}
# BP2_EXTRA="<steps>": rerun those with bp2 as well (the maintainer's addition: c21 and c41, the cells
# where bp sat halfway between ctl and the mark builds).
bp2_steps() {
  { [ -s "$OUT/decide.tsv" ] && awk -F'\t' '$3 == "path" { print $1 }' "$OUT/decide.tsv"
    for x in ${BP2_EXTRA:-}; do echo "$x"; done; } | sort -u | tr '\n' ' '
}
# bp2build: the bypass commit again, in its own tree and depot. An untracked file marks the tree
# dirty, which Julia records in a file it reads at run time (base/version_git.sh), so the image is
# built from the same sources and the build reports itself as fc9fb3e643*.
step_bp2build() {
  [ -n "$(bp2_steps)" ] || { log "bp2build: not needed (decide named no step)"; return 0; }
  local t="$J/mark-bypass2" c
  c="$(git -C "$J/mark-bypass" rev-parse HEAD)"
  [ -x "$t/usr/bin/julia" ] && { log "bp2build: $t already built"; } || {
    [ -d "$t" ] || git -C "$J/mark-bypass" worktree add --detach "$t" "$c" >>"$LOG" 2>&1 || return 1
    [ "$(git -C "$t" rev-parse HEAD)" = "$c" ] || { log "bp2build: $t is not at $c"; return 1; }
    cp "$J/Make.user" "$t/Make.user"
    echo "a second build of the bypass commit (#618 Idea 13): this untracked file marks the tree dirty, nothing else" >"$t/BP2-MARKER"
    "$J/build.sh" mark-bypass2 >>"$LOG" 2>&1 || return 1
  }
  mkdir -p "$J/depot-mark-bypass2"
  printf '%s\n' '#!/bin/sh' \
    '# second bypass build (session 4, #618 Idea 13): its own compiled/ first, then the shared depot (packages, registries) and the build'"'"'s bundled depots.' \
    'export JULIA_DEPOT_PATH="$HOME/app/julia-618/depot-mark-bypass2:$HOME/.julia:"' \
    "exec \"$t/usr/bin/julia\" \"\$@\"" >"$B/julia-mark-bypass2"
  chmod +x "$B/julia-mark-bypass2"
  log "bp2build: $("$B/julia-mark-bypass2" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short, " ", Sys.CPU_NAME)' 2>&1)"
  local ob; ob="$(objdump -h "$t/usr/lib/julia/sys.so" | awk '$2 == ".text" { print strtonum("0x" $3) }')"
  log "bp2build: sys.so .text $ob bytes (bp $(objdump -h "$J/mark-bypass/usr/lib/julia/sys.so" | awk '$2 == ".text" { print strtonum("0x" $3) }')); libjulia-internal sha256 $(sha256sum "$t/usr/lib/libjulia-internal.so.1.13" | cut -c1-12) (bp $(sha256sum "$J/mark-bypass/usr/lib/libjulia-internal.so.1.13" | cut -c1-12))"
  "$B/julia-mark-bypass2" --project="$MICRO_PROJECT" --startup-file=no -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' >>"$LOG" 2>&1 || return 1
  "$B/julia-mark-bypass2" --project="$MICRO_PROJECT" --startup-file=no "$J/pin_caches.jl" 2>&1 | tail -1 | tee -a "$LOG"
  local r; r="$("$B/julia-mark-bypass2" --project="$MICRO_PROJECT" --startup-file=no "$J/check_caches.jl" 2>&1 | tail -1)"
  log "bp2build: $r"
  case "$r" in *"from ~/.julia: 0"*) ;; *) log "bp2build: a cache from ~/.julia"; return 1 ;; esac
}
step_bp2() {   # step name (f21 c21 c41 c20), then that step's function and arguments
  local s="$1"; shift
  [[ " $(bp2_steps) " == *" $s "* ]] || { log "bp2$s: not needed (neither decide nor BP2_EXTRA named $s)"; return 0; }
  [ -x "$B/julia-mark-bypass2" ] || { log "bp2$s: no bp2 build"; return 1; }
  JLS="$JLS bypass2=$B/julia-mark-bypass2" COLS4="$FOUR2" SUB=bp2/ "$@"
}

# ---------------------------------------------------------------- question 3: #62285 against the mark
step_q3spawn() {   # five columns, both cells in one block
  OUT="$OUT/q3spawn" CPUS="$CPUS8" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="${Q3_ROUNDS:-6}" ROTATE=1 \
    NATIVE_COLS="A%ws A%base A%control N%mark N-none%mark" WARM=cell \
    CLIENT_CELLS_SPEC="8,0 default;8,1 interactive" COST_CELLS_NATIVE="50:0 500:0" MICRO_LAYOUTS=none rf >>"$LOG" 2>&1
}
step_q3plain() {   # layout: /plaintext, fresh servers, oha
  "$ROOT/bench/socket/quiet.sh" "618bp-q3plain-${1/,/_}" env FRESH=1 BACKLOG=1024 ROTATE=1 THROWAWAY=1 OHA=1 PROBE=0 \
    CLIENT_CPU=1 ROUTE="/plaintext" \
    JULIAS="control=$B/julia-control,$ROOT/bench mark=$B/julia-mark,$ROOT/bench ws=$B/julia-ws,$HTTP62285 base=$B/julia-base,$HTTP62285" \
    "$ROOT/bench/socket/fairness.sh" \
    "bare_spawn@$1%ws bare_spawn@$1%base bare_spawn@$1%control bare_marked_listen@$1@N%mark" "${Q3_PLAIN_ROUNDS:-8}" 8s >>"$LOG" 2>&1
}

# quiet.sh runs a command, so a block can be reached through this script itself.
if [ "${1:-}" = --run ]; then shift; "$@"; exit $?; fi

UNTIMED=" win21 win41 win81 neg21 neg41 neg81 decide bp2build "
CUTTABLE=" q3p80 q3p81 q3spawn win81 neg81 f20 f80 "
STEPS="${STEPS:-win21 win41 win81 neg41 neg81 f21 c21 c41 c20 f40 decide bp2build bp2f21 bp2c21 bp2c41 bp2c20 f20 f80 q3spawn q3p81 q3p80}"
if [ -n "${FROM:-}" ]; then
  STEPS="$(echo "$STEPS" | tr ' ' '\n' | sed -n "/^${FROM}\$/,\$p" | tr '\n' ' ')"
  [ -n "$STEPS" ] || stop "FROM=$FROM is not a step"
fi

log "driver start: steps [$STEPS], OUT $OUT${DEADLINE:+, deadline $(date -d @"$DEADLINE" '+%F %T') for [$CUTTABLE]}"
log "window runs: JULIA_THREAD_SLEEP_THRESHOLD=$WIN_THRESHOLD, DELAY_NS=$WIN_DELAY_NS, ${TD:-$WIN_DUR_S} s a column"
for w in control mark1 mark mark-bypass mark-validate ws base; do
  log "build $w: $("$B/julia-$w" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)' 2>&1)"
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
    win21) step_win 2,1 0,1,2 ;;
    win41) step_win 4,1 0,1,2,3,4 ;;
    win81) step_win 8,1 0,1,2,3,4,5,6,7,8 ;;
    neg41) step_neg 4,1 0,1,2,3,4 ;;
    neg81) step_neg 8,1 0,1,2,3,4,5,6,7,8 ;;
    neg21) step_neg 2,1 0,1,2 ;;
    f21) step_fib 2,1 0,1,2 ;;
    c21) step_cost 2,1 0,1,2 ;;
    c41) step_cost 4,1 0,1,2,3,4 ;;
    c20) step_cost 2,0 0,1 ;;
    f40) step_fib 4,0 0,1,2,3 ;;
    f20) step_fib 2,0 0,1 ;;
    f80) step_fib 8,0 "$CPUS8" ;;
    decide) step_decide ;;
    bp2build) step_bp2build ;;
    bp2f21) step_bp2 f21 step_fib 2,1 0,1,2 ;;
    bp2c21) step_bp2 c21 step_cost 2,1 0,1,2 ;;
    bp2c41) step_bp2 c41 step_cost 4,1 0,1,2,3,4 ;;
    bp2c20) step_bp2 c20 step_cost 2,0 0,1 ;;
    q3spawn) step_q3spawn ;;
    q3p81) step_q3plain 8,1 ;;
    q3p80) step_q3plain 8,0 ;;
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
