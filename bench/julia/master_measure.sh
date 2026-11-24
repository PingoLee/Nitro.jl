#!/usr/bin/env bash
# #618, the native mark on master, session 2 (agent-config #82 Idea 17): the measurement, with
# JuliaLang/julia#62285 in the same blocks, as one driver that needs nothing from the session that
# launched it. Every timed block goes behind bench/socket/quiet.sh (inside rounds_fifo.sh, or here
# for the server, mixed and pfib blocks). Around every step, as bypass.sh:
#   - before it, the ps check (changed for this run at the maintainer's request): a julia, oha or
#     go-server process that is not the driver's own (S2_DRIVER_PID not among its ancestors) is logged
#     with its pid, start time, parent, working directory and command line, sent SIGTERM, given 10 s,
#     then SIGKILL, and the step goes on. Nothing else is ever signalled. The driver STOPS only if one
#     survives SIGKILL;
#   - after it: the cache-write check, against a (path, size, inode) snapshot of every build's own
#     depot (~/app/julia-618-master/depot-*, ~/app/julia-618/depot-{ws,base}). A write during a timed
#     step STOPS the driver; during an untimed one it is logged;
#   - the files the step's blocks wrote under bench/results (fairness.sh and quiet.sh write there) are
#     moved into the step's directory.
# A failed Julia test set, a stuck task or a failed check is a RESULT: logged, every file kept, and the
# driver goes on. A timed block that fails (its retries spent, a process lost) stops it.
#
# Builds (~/app/julia-618-master/bin wrappers, each with its own first depot): control (master
# 4b0df1484a), control2 (the same commit built again), mark, mark-inline, mark-bypass (the mark's
# commit with stock's entry points: native-mark-master-bypass.patch), mark-validate, mark-all (the
# switch: native-mark-master-all-switch.patch; never timed), mark-inline-validate (never timed); ws and
# base (#62285's head, work-stealing and partr; ~/app/julia-618/bin). Each tree is read only against
# its own base: ws/base and mark/control.
#
# Parts and steps, in run order (the cuttable ones last, in reverse cut order):
#   A  the floor, five columns (control, control2, mark, mark-inline, mark-bypass; nothing marked),
#      A_ROUNDS (15) rotated rounds, one throwaway slot first:
#      a81f (fib_fine 8,1), a80h (H = 0, C = 50 and 500, :default clients, 8,0); cuttable a21f
#      (fib_fine 2,1), a21s, a41s (tasks.jl micro: SpawnWait at 2,1 and 4,1)
#   B  the design over B_ROUNDS (5) rounds, control (stock) against the mark: bstarved (500:2, 8,1,
#      :interactive clients), bmixed (mixed cell, plain and inner, w = 1/2), bshare (the credited share,
#      VALIDATE on mark-validate, untimed), bcell1 (server cell 1, /aggregate, c = 500, 8,1 and 8,0,
#      fresh servers); cuttable bpfib (pfib(25) at 8,1: none, root, all)
#   C  #62285 against the mark, C_ROUNDS (6) rounds: cspawn (H = 0, C = 50 and 500, :default at 8,0
#      and :interactive at 8,1; ws base control mark-none mark-N), cserver (server cell 1 at 8,1),
#      cmixed (mixed, plain and inner, CM_ROUNDS = 5), cplain81 cplain80 (/plaintext, oha), cfj
#      (fib_fine alone at 8,1, and pfib(25)); cuttable ctasks (tasks.jl micro at 8,1, and the Channel
#      worker pool cell: spawn_order.jl MODES=pool, C = 500, 8,1 and 8,0)
#   D  untimed: dtests (Julia's tests with every spawn marked on mark-all, switch unset, spawn and
#      insert, the control beside), donethread (the one-thread sets at --threads=4,1); cuttable
#      dinline (the inlined commit's validation on mark-inline-validate)
#   E  e1 (fib_fine at 8,1 with nothing marked: control, the mark, and the mark with its pool flag
#      armed by one marked task first, N-arm; E1_ROUNDS = 6). E2 (abandon_runs.sh) runs before the go.
# STEPS="<names>" runs a subset, FROM=<name> starts at that step. DEADLINE=<epoch s>: a cuttable step
# that has not started by then is skipped, logged as CUT; the running step finishes. Cut order (the
# prompt's): bpfib, dinline, ctasks, then a41s a21s a21f.
#
# Usage: bench/julia/master_measure.sh   (detached: setsid nohup … > driver.out 2>&1 < /dev/null &)
#   SMOKE=1: every step once, short (TD=1 for the harness windows, one round, NOGATE=1, D steps on one
#   small set), into results/s2-smoke; never a measurement.
#
# SESSION=3 (agent-config #82 Idea 19): master at #62285's merge-base, 6ac8c4f030, untouched, built
# twice: july (the master trees' Make.user, the multi-target sysimage) and july-n (base's Make.user
# without JULIA_SCHEDULER: with JULIA_CPU_TARGET empty, Make.inc sets MARCH=native, so a native sysimage
# AND a C runtime built with -march=native, as ws and base have; an untracked marker makes it report
# 6ac8c4f030*). Five columns, nothing marked: july, july-n, base, control, control2, J_ROUNDS (10)
# rotated rounds, one throwaway slot first, a fresh process a round. base/july-n is the branch at one
# configuration, control/july four months of master at one configuration, july-n/july the build
# configuration at one source, control2/control the floor. Steps, uncuttable first: jtasks (tasks.jl SpawnWait and
# FanOut1000 at 8,1), jspawn (H = 0, C = 50 and 500, :interactive 8,1 and :default 8,0), jpool (the
# Channel worker pool, C = 500, 8,1 and 8,0), jperf (part B: perf_unmarked.sh a1g1 on july, july-n,
# base and control at 8,1, labels july julyn base ctl), jplain81; cuttable jplain80 (/plaintext, oha,
# c = 500). Results in results/s3 (s3-smoke). Report: master_measure_report.jl <OUT>, section S3.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
J="$HOME/app/julia-618-master"
B="$J/bin"
T="$HOME/app/julia-618/bin"
export SMOKE="${SMOKE:-0}"
export SESSION="${SESSION:-2}"
# A block reached through `--run` (behind quiet.sh, which reassigns an exported OUT) takes the
# parent's results directory from S2_OUT.
[ "${1:-}" = --run ] && [ -n "${S2_OUT:-}" ] && OUT="$S2_OUT"
if [ "$SMOKE" = 1 ]; then
  export TD="${TD:-1}" NOGATE=1
  OUT="${OUT:-$J/results/s$SESSION-smoke}"
  A_ROUNDS=1 B_ROUNDS=1 C_ROUNDS=1 CM_ROUNDS=1 E1_ROUNDS=1 J_ROUNDS=1
else
  OUT="${OUT:-$J/results/s$SESSION}"
  A_ROUNDS="${A_ROUNDS:-15}" B_ROUNDS="${B_ROUNDS:-5}" C_ROUNDS="${C_ROUNDS:-6}" CM_ROUNDS="${CM_ROUNDS:-5}" E1_ROUNDS="${E1_ROUNDS:-6}"
  J_ROUNDS="${J_ROUNDS:-10}"
fi
mkdir -p "$OUT"
export S2_OUT="$OUT"
# The driver's own pid, inherited by its `--run` children: a process with it among its ancestors is
# the driver's own, and the ps check never touches one.
export S2_DRIVER_PID="${S2_DRIVER_PID:-$$}"
LOG="$OUT/driver.log"
export PATH="$HOME/.local/go/bin:$HOME/.local/bin:$HOME/.juliaup/bin:$PATH"
export JLS="control=$B/julia-control control2=$B/julia-control2 mark=$B/julia-mark mark-inline=$B/julia-mark-inline mark-bypass=$B/julia-mark-bypass mark-validate=$B/julia-mark-validate mark-all=$B/julia-mark-all mark-inline-validate=$B/julia-mark-inline-validate ws=$T/julia-ws base=$T/julia-base july=$B/julia-july july-n=$B/julia-july-n"
EM="$J/envs/micro-master" EJ="$J/envs/micro-july" SM="$J/envs/server-master" SJ="$J/envs/server-july"
export MICRO_PROJECT="$EM" MICRO_PROJECTS="ws=$EJ base=$EJ july=$EJ july-n=$EJ"
JULIAS4="control=$B/julia-control,$SM mark=$B/julia-mark,$SM ws=$T/julia-ws,$SJ base=$T/julia-base,$SJ"
# Session 3's server columns: the merge-base builds and base load the July environments, the two
# controls master's.
JULIAS5="july=$B/julia-july,$SJ july-n=$B/julia-july-n,$SJ base=$T/julia-base,$SJ control=$B/julia-control,$SM control2=$B/julia-control2,$SM"
CPUS8="0,1,2,3,6,7,8,9"
AGG="/aggregate?n=100000&op=groupby"
FIVE="A%control A%control2 N-none%mark N-none%mark-inline N-none%mark-bypass"
JULY5="A%july A%july-n A%base A%control A%control2"
WIN_DUR_S="${WIN_DUR_S:-300}"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
stop() { log "STOP: $*"; log "driver stopped; restart with FROM=<step> after fixing"; exit 1; }
own_proc() {   # pid -> 0 when S2_DRIVER_PID is among its ancestors (or is it)
  local p="$1" n=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 64 ]; do
    [ "$p" = "$S2_DRIVER_PID" ] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; n=$((n + 1))
  done
  return 1
}
# julia, oha and go-server processes that are not the driver's own. Only these names are ever matched.
foreign_procs() {
  local p
  ps -eo pid=,comm= | awk '$2 == "julia" || $2 == "oha" || $2 == "go-server" { print $1 }' |
    while read -r p; do own_proc "$p" || echo "$p"; done
}
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }
describe_proc() {   # pid -> pid, start time, parent, working directory, command line
  local p="$1" pp
  pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  echo "pid $p, started $(proc_start "$p"), parent $pp ($(ps -o comm= -p "${pp:-0}" 2>/dev/null || echo '?')), cwd $(readlink "/proc/$p/cwd" 2>/dev/null || echo '?'), cmd: $(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | cut -c1-400)"
}
# This run's ps check (changed at the maintainer's request, 2026-11-22): a julia, oha or go-server
# process that is not the driver's own is logged, sent SIGTERM, given 10 s, then SIGKILL, and the
# step goes on. Nothing else is ever signalled. A pid whose start time changed (reused) is skipped.
# It returns 1 only when a process survives SIGKILL.
ps_check() {
  local pass p i pids alive
  local -A starts
  for pass in 1 2 3; do
    mapfile -t pids < <(foreign_procs)
    [ "${#pids[@]}" -eq 0 ] && return 0
    log "ps check: ${#pids[@]} julia/oha/go-server process(es) not the driver's own; stopping them (SIGTERM, 10 s, SIGKILL):"
    starts=()
    for p in "${pids[@]}"; do starts[$p]="$(proc_start "$p")"; log "ps check: $(describe_proc "$p")"; done
    for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null && log "ps check: SIGTERM sent to $p"; done
    for i in $(seq 10); do
      alive=()
      for p in "${pids[@]}"; do [ -n "${starts[$p]}" ] && [ "$(proc_start "$p")" = "${starts[$p]}" ] && alive+=("$p"); done
      [ "${#alive[@]}" -eq 0 ] && break
      sleep 1
    done
    for p in "${alive[@]}"; do kill -KILL "$p" 2>/dev/null && log "ps check: SIGKILL sent to $p (alive 10 s after SIGTERM)"; done
    [ "${#alive[@]}" -gt 0 ] && sleep 1
    for p in "${alive[@]}"; do
      [ "$(proc_start "$p")" = "${starts[$p]}" ] && { log "ps check: $p survived SIGKILL"; return 1; }
    done
    log "ps check: stopped; the step goes on"
  done
  [ -z "$(foreign_procs)" ]
}
DEPOTS=("$J"/depot-* "$HOME/app/julia-618/depot-ws" "$HOME/app/julia-618/depot-base")
snap() { local d; for d in "$@"; do [ -d "$d/compiled" ] && find "$d/compiled" -type f -printf '%p %s %i\n' 2>/dev/null; done | sort; }
cache_mark() { snap "${DEPOTS[@]}" >"$OUT/.snap-own"; find "$HOME/.julia/compiled" -type f -printf '%p %s %i\n' 2>/dev/null | sort >"$OUT/.snap-shared"; }
cache_check() {   # label
  local own other
  own="$(comm -13 "$OUT/.snap-own" <(snap "${DEPOTS[@]}"))"
  other="$(comm -13 "$OUT/.snap-shared" <(find "$HOME/.julia/compiled" -type f -printf '%p %s %i\n' 2>/dev/null | sort) | head -20)"
  [ -n "$other" ] && { log "cache check $1: files created or replaced under ~/.julia/compiled during the step (not by the builds here):"; echo "$other" | tee -a "$LOG"; }
  [ -z "$own" ] || { log "cache check $1: CACHE FILES CREATED OR REPLACED during the step (path size inode):"; echo "$own" | head -40 | tee -a "$LOG"; return 1; }
  log "cache check $1: no cache file created or replaced"
}
results_mark() { ls -1 "$ROOT/bench/results" 2>/dev/null | sort >"$OUT/.results-before"; }
results_move() {   # step
  local f d="$OUT/$1/raw"
  mkdir -p "$d"
  comm -13 "$OUT/.results-before" <(ls -1 "$ROOT/bench/results" 2>/dev/null | sort) | while read -r f; do
    case "$f" in ""|go-server|fairness) continue ;; esac   # fairness.sh's Go binaries stay where it builds them
    mv "$ROOT/bench/results/$f" "$d/"
  done
}

rf() { PROFILE=native JL="$B/julia-control" "$ROOT/bench/tasks/rounds_fifo.sh" "$@"; }

# A gated command (quiet.sh), retried on a failed gate (3) or a stopped block (4), twice at most.
# NOGATE=1 runs it directly (the smoke).
# Julia >= 1.14 keeps a JIT object cache (LMDB, `cache/v1.1x/objcache*/data.mdb`) in the first depot,
# written by every process. It is not a package image, so cache_check ignores it; this logs, per
# gated block and outside the timed command, which data.mdb files changed (size bytes, mtime).
objsnap() { find "${DEPOTS[@]}" "$HOME/.julia/cache" -path '*objcache*' -name data.mdb -printf '%p %s %T@\n' 2>/dev/null | sort; }
objcache_log() {   # label, snapshot before
  local after; after="$(objsnap)"
  if [ "$after" = "$2" ]; then log "objcache $1: no data.mdb written"
  else log "objcache $1: data.mdb written (path size mtime, after):"; comm -13 <(echo "$2") <(echo "$after") | tee -a "$LOG"; fi
}
gated() {   # label, command...
  local attempt=1 rc o0
  [ "${NOGATE:-0}" = 1 ] && { shift; "$@"; return $?; }
  while :; do
    o0="$(objsnap)"
    "$ROOT/bench/socket/quiet.sh" "$@"; rc=$?
    objcache_log "$1" "$o0" >/dev/null   # its caller sends stdout to $LOG too: write it once
    { [ "$rc" = 3 ] || [ "$rc" = 4 ]; } || return "$rc"
    [ "$attempt" -le 2 ] || return "$rc"
    log "gated $1: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    ps_check || return 1
  done
}
rotated() {   # round, items... -> the items rotated by (round - 1) mod n
  local r="$1"; shift
  local n=$# k a i out=(); k=$(( ((r - 1) % n + n) % n )); a=("$@")
  for ((i = 0; i < n; i++)); do out+=("${a[$(( (i + k) % n ))]}"); done
  echo "${out[*]}"
}

# ---------------------------------------------------------------- the harness cells
step_fib() {     # dir, layout, cpus, columns, rounds: fib_fine alone, rotated rounds, one throwaway slot
  OUT="$OUT/$1" CPUS="$3" BLOCKS=fibabba ROUNDS=1 ROTATE=1 ABBA_COLS="$4" ABBA_ROUNDS="$5" ABBA_LAYOUTS="$2" \
    rf >>"$LOG" 2>&1
}
step_h0() {      # dir, client cells spec, columns, rounds: spawn_order H = 0, C = 50 and 500
  OUT="$OUT/$1" CPUS="$CPUS8" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="$4" ROTATE=1 NATIVE_COLS="$3" WARM=cell \
    CLIENT_CELLS_SPEC="$2" COST_CELLS_NATIVE="50:0 500:0" MICRO_LAYOUTS=none rf >>"$LOG" 2>&1
}
step_micro() {   # dir, layout, cpus, columns, rounds: tasks.jl micro only (SpawnWait, PingPong, FanOut1000)
  OUT="$OUT/$1" CPUS="$3" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="$5" ROTATE=1 NATIVE_COLS="$4" \
    CLIENT_CELLS_SPEC="$2 default" COST_CELLS_NATIVE=none MICRO_LAYOUTS="$2" MICRO_ARGS=micro \
    MICRO_FAN_OUT=1000 rf >>"$LOG" 2>&1
}
step_starved() { # dir, columns, rounds: 500:2 at 8,1, :interactive clients (fairness's pool reference beside)
  OUT="$OUT/$1" CPUS="$CPUS8" BLOCKS=fairrounds ROUNDS=1 MULTI_ROUNDS="$3" ROTATE=1 NATIVE_COLS="$2" \
    CLIENT_CELLS_SPEC="8,1 interactive" rf >>"$LOG" 2>&1
}

# The mixed cell, plain and inner, over rounds in one quiet block: one throwaway slot (the first
# token's plain cell), then per round the columns rotated, plain then inner, each a fresh process.
MIX_SMOKE_ENV=(); [ "$SMOKE" = 1 ] && MIX_SMOKE_ENV=(D=1 FIB_FINE=36:12 ALONE_RUNS=1)
mixed_rounds() { # dir, columns, rounds
  local d="$1" cols="$2" n="$3" r first
  mkdir -p "$d"
  first="${cols%% *}"
  NATIVE_MIX_COLS="$first" rf --run mixed_block 0 "$d/throwaway-mixed.tsv" "${MIX_SMOKE_ENV[@]}" || return 1
  for r in $(seq 1 "$n"); do
    ROTATE=1 NATIVE_MIX_COLS="$cols" rf --run mixed_block "$r" "$d/mixed.tsv" "${MIX_SMOKE_ENV[@]}" || return 1
    ROTATE=1 NATIVE_MIX_COLS="$cols" rf --run mixed_block "$r" "$d/mixedinner.tsv" SHAPE=inner "${MIX_SMOKE_ENV[@]}" || return 1
  done
}
step_mixed() {   # step, columns, rounds
  local d="$OUT/$1"; rm -f "$d/mixed.tsv" "$d/mixedinner.tsv" "$d/throwaway-mixed.tsv"
  gated "618s2-$1" "$0" --run mixed_rounds "$d" "$2" "$3" >>"$LOG" 2>&1
}
# The credited share, on the validation build, once: N at w = 1/2, plain and inner, VALIDATE=1 (the
# cell's asserts, including the share check). Untimed, no gate.
step_share() {
  local d="$OUT/bshare" s rc=0
  mkdir -p "$d"
  for s in plain inner; do
    env VALIDATE=1 VARIANT=N SHAPE="$s" ROUND=1 "${MIX_SMOKE_ENV[@]}" timeout -s KILL 900 taskset -c "$CPUS8" \
      "$B/julia-mark-validate" --threads=8,1 "$ROOT/bench/tasks/mixed_cell.jl" >"$d/mixed-$s.tsv" 2>"$d/mixed-$s.err" ||
      { log "RESULT: bshare $s failed (see $d/mixed-$s.err)"; rc=1; }
    log "bshare $s: $(grep -iE 'credit|share' "$d/mixed-$s.err" | tail -3 | tr '\n' ' ')"
  done
  return 0
}

# ---------------------------------------------------------------- the server cells (fairness.sh)
FAIR_ROUNDS_OF() { [ "$SMOKE" = 1 ] && echo 1 || echo "$1"; }
FAIR_DUR() { [ "$SMOKE" = 1 ] && echo 2s || echo 8s; }
step_server() {  # label, route, modes, rounds, extra env...
  local label="$1" route="$2" modes="$3" n; n="$(FAIR_ROUNDS_OF "$4")"; shift 4
  gated "618s2-$label" env "$@" FRESH=1 BACKLOG=1024 ROTATE=1 THROWAWAY=1 PROBE=0 ROUTE="$route" JULIAS="${SERVER_JULIAS:-$JULIAS4}" \
    "$ROOT/bench/socket/fairness.sh" "$modes" "$n" "$(FAIR_DUR)" >>"$LOG" 2>&1
}

# ---------------------------------------------------------------- pfib(25)
pfib_one() {     # tsv, round, layout, cpus, column (label:build:mode)
  local tsv="$1" r="$2" layout="$3" cpus="$4" col="$5" label wr mode env out rc
  IFS=: read -r label wr mode <<<"$col"
  env="$EM"; case "$wr" in ws|base) env="$EJ" ;; esac
  out="$(env PFIB_MODE="$mode" LABEL="$label" ROUND="$r" timeout -s KILL "${PFIB_TIMEOUT_S:-300}" \
    taskset -c "$cpus" "${JL_OF_PFIB[$wr]}" --startup-file=no --project="$env" --threads="$layout" "$ROOT/bench/tasks/pfib.jl" 2>>"$tsv.err")"
  rc=$?
  if [ "$rc" = 0 ] && [ -n "$out" ]; then echo "$out" >>"$tsv"
  else printf '%s\t%s\t%s\t%s\t25\tFAILED rc=%s\n' "$r" "$label" "$mode" "$layout" "$rc" >>"$tsv"; fi
}
declare -A JL_OF_PFIB=([control]="$B/julia-control" [mark]="$B/julia-mark" [ws]="$T/julia-ws" [base]="$T/julia-base")
pfib_block() {   # tsv, rounds, columns...
  local tsv="$1" n="$2" r c; shift 2
  pfib_one "$(dirname "$tsv")/pfib-throwaway.tsv" 0 8,1 "$CPUS8" "$1"
  for r in $(seq 1 "$n"); do
    for c in $(rotated "$r" "$@"); do pfib_one "$tsv" "$r" 8,1 "$CPUS8" "$c"; done
  done
}
step_pfib() {    # step, rounds, columns...
  local s="$1" n="$2" a; shift 2
  a="$OUT/$s/pfib.tsv"; mkdir -p "$OUT/$s"; rm -f "$a"
  printf 'round\tlabel\tmode\tlayout\tn\tmin_s\tmedian_s\tallocs\tmemory_bytes\tsamples\tmaxrss_mb\n' >"$a"
  gated "618s2-$s-pfib" "$0" --run pfib_block "$a" "$n" "$@" >>"$LOG" 2>&1
}

# ---------------------------------------------------------------- the Channel worker pool cell
pool_rounds() {  # tsv, rounds, columns...
  local tsv="$1" n="$2" r v cc layout clients; shift 2
  for r in 0 $(seq 1 "$n"); do
    for cc in "8,1 interactive" "8,0 default"; do
      read -r layout clients <<<"$cc"
      if [ "$r" = 0 ]; then   # the throwaway slot: the first column, the first cell
        CPUS="$CPUS8" rf --run spawn 0 "$(dirname "$tsv")/throwaway-pool.tsv" "$layout" "$clients" "$1" "500:0" pool "${TD:-8}" || return 1
        break
      fi
      for v in $(rotated "$r" "$@"); do
        CPUS="$CPUS8" rf --run spawn "$r" "$tsv" "$layout" "$clients" "$v" "500:0" pool "${TD:-8}" || return 1
      done
    done
  done
}

# ---------------------------------------------------------------- session 3, part B (perf_unmarked.sh)
# perf stat on spawnwait_fixed.jl at N and 2N, attached after the warm-up: step a1g1 (cycles and
# instructions, user and kernel, context switches, migrations), the builds rotated a pair, at 8,1 on
# CPUS8. perf_unmarked.sh runs its block behind quiet.sh itself and checks its builds' depots; its own
# ps check waits for julia, oha and go-server processes (there are none of the driver's here).
step_jperf() {
  local n="${PERF_N:-3000000}" pairs="${PERF_PAIRS:-5}"
  [ "$SMOKE" = 1 ] && { n=100000; pairs=1; }
  local o0 rc; o0="$(objsnap)"   # perf_unmarked.sh gates its own blocks; log the step as a whole
  FROM= PERF_UNMARKED_OUT="$OUT/jperf" N="$n" PAIRS="$pairs" STEPS=a1g1 PU_LAYOUTS="8,1:$CPUS8" \
    PU_BUILDS="july:$B/julia-july:$J/depot-july julyn:$B/julia-july-n:$J/depot-july-n base:$T/julia-base:$HOME/app/julia-618/depot-base ctl:$B/julia-control:$J/depot-control" \
    "$HERE/perf_unmarked.sh" >>"$LOG" 2>&1
  rc=$?; objcache_log jperf "$o0"; return "$rc"
}

# ---------------------------------------------------------------- part D
TEST_SETS='["core", "threads", "channels", "channel_threadpool", "threadpool_use", "threadpool_latency", "cancellation"]'
ONE_SETS="core channels channel_threadpool threadpool_use threadpool_latency"
[ "$SMOKE" = 1 ] && { TEST_SETS='["channel_threadpool"]'; ONE_SETS="channel_threadpool"; }
tests_run() {    # label, build, switch (unset|spawn|insert), log name, julia expression
  local label="$1" wr="$2" sw="$3" name="$4" expr="$5" d t0 rc envs=()
  d="$OUT/dtests/$label"; mkdir -p "$d/log"
  rm -f "$J/mark-all-log/current"; mkdir -p "$J/mark-all-log"
  if [ "$wr" = mark-all ]; then
    ln -sfn "$d/log" "$J/mark-all-log/current"
    envs+=("JULIA_SCHED_MARK_ALL_LOG=$d/log")
    [ "$sw" != unset ] && envs+=("JULIA_SCHED_MARK_ALL=$sw")
  fi
  t0=$(date +%s)
  ( cd "$J" && env ${envs[@]+"${envs[@]}"} timeout -s KILL "${TESTS_TIMEOUT_S:-3600}" "$B/julia-$wr" --startup-file=no \
      -e "$expr" >"$d/$name.log" 2>&1 )
  rc=$?
  rm -f "$J/mark-all-log/current"
  log "tests $label $name: $wr, JULIA_SCHED_MARK_ALL=$sw: exit $rc after $(( $(date +%s) - t0 )) s; $(grep -E '^ *(SUCCESS|FAILURE)' "$d/$name.log" | tail -1 | tr -d ' '); $(grep -E 'Overall' "$d/$name.log" | tail -1 | tr -s ' ')"
  [ "$rc" = 0 ] || log "RESULT: tests $label $name exited $rc (see $d/$name.log)"
}
step_dtests() {
  local c
  for c in ctl:control:unset mall-unset:mark-all:unset mall-spawn:mark-all:spawn mall-insert:mark-all:insert; do
    IFS=: read -r label wr sw <<<"$c"
    tests_run "$label" "$wr" "$sw" sets "Base.runtests($TEST_SETS; ncores = 6)"
  done
  return 0
}
step_donethread() {
  local c s
  for c in ctl41:control:unset mall41-spawn:mark-all:spawn mall41-insert:mark-all:insert; do
    IFS=: read -r label wr sw <<<"$c"
    for s in $ONE_SETS; do
      tests_run "$label" "$wr" "$sw" "$s" "Base.runtests([\"$s\"]; ncores = 1, julia_args = \`--threads=4,1\`)"
    done
  done
  return 0
}
win_one() {      # tsv, label, mode: wake_window.jl at 2,1 on mark-inline-validate, marked, threshold 0
  local tsv="$1" label="$2" mode="$3" header=1 rc
  [ -s "$tsv" ] && header=0
  env JULIA_THREAD_SLEEP_THRESHOLD=0 MODE="$mode" MARK=1 DUR_S="${TD:-$WIN_DUR_S}" DELAY_NS=0:20000 LABEL="$label" NOHEADER=$((1 - header)) \
    timeout -s KILL $(( ${TD:-$WIN_DUR_S} + 120 )) taskset -c 0,1,2 "$B/julia-mark-inline-validate" --startup-file=no --threads=2,1 \
    "$ROOT/bench/tasks/wake_window.jl" >>"$tsv" 2>>"${tsv%.tsv}.events"
  rc=$?
  [ "$rc" = 0 ] || { log "RESULT: window $label exit $rc"; return 0; }
  log "window $label: $(tail -1 "$tsv" | awk -F'\t' '{ printf "rounds %s, enqueued %s, stuck %s, late %s, unrescued %s, p99.9 %s us, max %s us", $13, $14, $15, $16, $17, $20, $21 }')"
}
step_dinline() {
  local d="$OUT/dinline" l rc
  mkdir -p "$d"
  if [ "$SMOKE" = 1 ]; then log "dinline: VALIDATE pass skipped in the smoke"
  else
    OUT="$d/validate" PROFILE=native VALIDATE=1 JL="$B/julia-mark-inline-validate" "$ROOT/bench/tasks/rounds_fifo.sh" >>"$d/validate.out" 2>&1
    rc=$?; log "dinline VALIDATE (rounds_fifo PROFILE=native VALIDATE=1, negatives included): exit $rc"
    [ "$rc" = 0 ] || log "RESULT: the inlined commit's VALIDATE pass failed (see $d/validate.out)"
  fi
  for l in 8,1 8,2 1; do
    timeout -s KILL 900 "$B/julia-mark-inline-validate" --startup-file=no --threads="$l" "$HERE/native_checks.jl" >"$d/native_checks-${l/,/_}.log" 2>&1
    rc=$?; log "dinline native_checks $l: exit $rc; $(grep -c 'ok' "$d/native_checks-${l/,/_}.log") ok lines"
    [ "$rc" = 0 ] || log "RESULT: native_checks $l failed on mark-inline-validate"
  done
  for l in 8,1 8,2; do
    timeout -s KILL 900 "$B/julia-mark-inline-validate" --startup-file=no --threads="$l" "$HERE/master_checks.jl" >"$d/master_checks-${l/,/_}.log" 2>&1
    rc=$?; log "dinline master_checks $l: exit $rc; $(grep -c 'master_checks: ok' "$d/master_checks-${l/,/_}.log") ok lines"
    [ "$rc" = 0 ] || log "RESULT: master_checks $l failed on mark-inline-validate"
  done
  win_one "$d/window21.tsv" mvi-ring ring
  win_one "$d/window21.tsv" mvi-wake wake
  return 0
}

# quiet.sh runs a command, so a block can be reached through this script itself.
if [ "${1:-}" = --run ]; then shift; "$@"; exit $?; fi

UNTIMED=" bshare dtests donethread dinline "
CUTTABLE=" a21f a21s a41s ctasks dinline bpfib "
DEFAULT_STEPS="a81f a80h bstarved bmixed bshare bcell1 cspawn cserver cmixed cplain81 cplain80 cfj dtests donethread e1 a21f a21s a41s ctasks dinline bpfib"
if [ "$SESSION" = 3 ]; then
  CUTTABLE=" jplain80 "
  DEFAULT_STEPS="jtasks jspawn jpool jperf jplain81 jplain80"
fi
STEPS="${STEPS:-$DEFAULT_STEPS}"
if [ -n "${FROM:-}" ]; then
  STEPS="$(echo "$STEPS" | tr ' ' '\n' | sed -n "/^${FROM}\$/,\$p" | tr '\n' ' ')"
  [ -n "$STEPS" ] || stop "FROM=$FROM is not a step"
fi

log "driver start: session $SESSION, steps [$STEPS], OUT $OUT, SMOKE=$SMOKE, rounds A $A_ROUNDS B $B_ROUNDS C $C_ROUNDS mixed-C $CM_ROUNDS E1 $E1_ROUNDS S3 $J_ROUNDS${DEADLINE:+, deadline $(date -d @"$DEADLINE" '+%F %T') for [$CUTTABLE]}"
for w in control control2 mark mark-inline mark-bypass mark-validate mark-all mark-inline-validate july july-n; do
  log "build $w: $("$B/julia-$w" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)' 2>&1 | head -1)"
done
for w in ws base; do log "build $w: $("$T/julia-$w" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)' 2>&1 | head -1)"; done
for s in $STEPS; do
  if [ -n "${DEADLINE:-}" ] && [ "$(date +%s)" -ge "$DEADLINE" ] && [[ "$CUTTABLE" == *" $s "* ]]; then
    log "step $s: CUT (not started by the deadline)"; continue
  fi
  ps_check || stop "ps check before $s"
  cache_mark; results_mark
  log "step $s: start"
  t0=$(date +%s)
  case "$s" in
    a81f) step_fib a81f 8,1 "$CPUS8" "$FIVE" "$A_ROUNDS" ;;
    a80h) step_h0 a80h "8,0 default" "$FIVE" "$A_ROUNDS" ;;
    a21f) step_fib a21f 2,1 0,1,2 "$FIVE" "$A_ROUNDS" ;;
    a21s) step_micro a21s 2,1 0,1,2 "$FIVE" "$A_ROUNDS" ;;
    a41s) step_micro a41s 4,1 0,1,2,3,4 "$FIVE" "$A_ROUNDS" ;;
    bstarved) step_starved bstarved "A%control N%mark" "$B_ROUNDS" ;;
    bmixed) step_mixed bmixed "A%control N%mark" "$B_ROUNDS" ;;
    bshare) step_share ;;
    bcell1) step_server bcell1-81 "$AGG" "bare_spawn@8,1%control bare_marked_listen@8,1@N%mark" "$B_ROUNDS" &&
            step_server bcell1-80 "$AGG" "bare_spawn@8,0%control bare_marked_listen@8,0@N%mark" "$B_ROUNDS" ;;
    bpfib) step_pfib bpfib "$B_ROUNDS" ctl:control:none m:mark:none root:mark:root all:mark:all ;;
    cspawn) step_h0 cspawn "8,0 default;8,1 interactive" "A%ws A%base A%control N-none%mark N%mark" "$C_ROUNDS" ;;
    cserver) step_server cserver "$AGG" "bare_spawn@8,1%ws bare_spawn@8,1%base bare_spawn@8,1%control bare_marked_listen@8,1@N%mark" "$C_ROUNDS" ;;
    cmixed) step_mixed cmixed "A%ws A%base A%control N%mark" "$CM_ROUNDS" ;;
    cplain81) step_server cplain81 /plaintext "bare_spawn@8,1%ws bare_spawn@8,1%base bare_spawn@8,1%control bare_marked_listen@8,1@N%mark" "$C_ROUNDS" OHA=1 CLIENT_CPU=1 ;;
    cplain80) step_server cplain80 /plaintext "bare_spawn@8,0%ws bare_spawn@8,0%base bare_spawn@8,0%control bare_marked_listen@8,0@N%mark" "$C_ROUNDS" OHA=1 CLIENT_CPU=1 ;;
    cfj) step_fib cfj 8,1 "$CPUS8" "A%ws A%base A%control N-none%mark" "$C_ROUNDS" &&
         step_pfib cfj "$C_ROUNDS" ws:ws:none base:base:none ctl:control:none m:mark:none ;;
    ctasks) step_micro ctasks 8,1 "$CPUS8" "A%ws A%base A%control N-none%mark" "$C_ROUNDS" && {
              mkdir -p "$OUT/ctasks"; rm -f "$OUT/ctasks/pool.tsv"
              gated 618s2-ctasks-pool "$0" --run pool_rounds "$OUT/ctasks/pool.tsv" "$C_ROUNDS" A%ws A%base A%control N-none%mark >>"$LOG" 2>&1; } ;;
    dtests) step_dtests ;;
    donethread) step_donethread ;;
    dinline) step_dinline ;;
    e1) step_fib e1 8,1 "$CPUS8" "A%control N-none%mark N-arm%mark" "$E1_ROUNDS" ;;
    jtasks) step_micro jtasks 8,1 "$CPUS8" "$JULY5" "$J_ROUNDS" ;;
    jspawn) step_h0 jspawn "8,1 interactive;8,0 default" "$JULY5" "$J_ROUNDS" ;;
    jpool) mkdir -p "$OUT/jpool"; rm -f "$OUT/jpool/pool.tsv"
           gated 618s3-jpool "$0" --run pool_rounds "$OUT/jpool/pool.tsv" "$J_ROUNDS" $JULY5 >>"$LOG" 2>&1 ;;
    jperf) step_jperf ;;
    jplain81) SERVER_JULIAS="$JULIAS5" step_server jplain81 /plaintext "bare_spawn@8,1%july bare_spawn@8,1%july-n bare_spawn@8,1%base bare_spawn@8,1%control bare_spawn@8,1%control2" "$J_ROUNDS" OHA=1 CLIENT_CPU=1 ;;
    jplain80) SERVER_JULIAS="$JULIAS5" step_server jplain80 /plaintext "bare_spawn@8,0%july bare_spawn@8,0%july-n bare_spawn@8,0%base bare_spawn@8,0%control bare_spawn@8,0%control2" "$J_ROUNDS" OHA=1 CLIENT_CPU=1 ;;
    *) stop "unknown step $s" ;;
  esac
  rc=$?
  results_move "$s"
  log "step $s: exit $rc after $(( ($(date +%s) - t0) / 60 )) min"
  if ! cache_check "$s"; then
    if [[ "$UNTIMED" == *" $s "* ]] || [ "$SMOKE" = 1 ]; then log "cache check $s: logged, not fatal (untimed step or smoke)"
    else stop "cache check after $s"; fi
  fi
  [ "$rc" = 0 ] || stop "step $s failed (exit $rc)"
done
log "driver done: every step finished"
