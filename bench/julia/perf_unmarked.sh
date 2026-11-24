#!/usr/bin/env bash
# #618, where the unmarked path's 20–30 ns go (agent-config #82 Idea 15): hardware counters on
# bench/tasks/spawnwait_fixed.jl, SpawnWait's body as a fixed loop, across the six builds of
# 2026-11-21 (ctl, m2, bp, bp2, s1, s2) at 2,1 and 4,1. Diagnosis, not a timed comparison: every
# figure is a difference between a run at N and one at 2N, so start-up, compilation and the attach
# edges cancel.
#
#   a1g1 a1g2 a1g3  `perf stat --per-thread -p` (attached after the warm-up: spawnwait_fixed.jl's
#                   ATTACH handshake), one event group a step, at most five hardware events a group
#                   (Zen 3 has six core counters and the NMI watchdog holds one), so nothing
#                   multiplexes. Five pairs (N, 2N) a build and layout; the builds rotated a pair,
#                   N and 2N alternating which goes first, the layouts too.
#                     g1  cycles and instructions, user and kernel; context switches, migrations
#                     g2  cycles:u, branches, branch misses, L1d load misses, iTLB load misses
#                     g3  cycles:u, L2 misses (generic cache-misses on Zen), and the demand fills
#                         from another core's L2 or L3 (int_cache), from the core's own L2, and
#                         from memory
#   a2              MODE=who, five runs a build and layout, no perf: who ran each child.
#   a4              `perf record -e cycles:u -F $REC_F`, attached for the loop only, on m2 and bp at
#                   2,1, three runs each, with
#                   three unrecorded runs beside them so the rate's effect on the loop's wall time
#                   is measured (it must stay within 2%).
#   a5              MODE=split (#618's addition, A5): four stamps an operation, N=$SPLIT_N, five runs a
#                   build and layout, rotated: pickup, run and wake segments; the same file gives A7
#                   (tasks.jl's statistic, the median of BT_EVALS-op block means).
#   a6              MODE=idle with JULIA_THREAD_SLEEP_THRESHOLD=infinite (A6, the poll turn): the
#                   :default threads spin empty turns for IDLE_S. Three runs a build and layout, each a
#                   pair: (u) cycles:u and instructions:u per thread, undisturbed; (b) instructions:u
#                   and a hardware-breakpoint count of the entry of the build's own multiq_deletemin
#                   clone (the .2 clone this CPU runs; one entry a turn). The breakpoint traps on
#                   every hit, so (b) gives instructions per turn only, and (u) the rate.
#   a7              (#618 Idea 16, A5) the plain loop with perf stat attached and with nothing attached,
#                   PAIRS pairs a build and layout (PU_BUILDS, PU_LAYOUTS: bp and bp2 at 2,1 there).
# Every step: wait for no julia, oha or go-server process (PS_WAIT_S, default 900 s, then STOP), run
# behind bench/socket/quiet.sh, and after it compare a (path, size, inode) snapshot of the builds'
# own depots and the shared depot's compiled/ (no step loads a package; a write STOPS the driver).
#
# Usage: bench/julia/perf_unmarked.sh   (detached: setsid nohup … > driver.out 2>&1 < /dev/null &)
#   STEPS="a1g1 a1g2 a1g3 a2 a4" (the default), FROM=<step>; N (3000000), WARM (200000), PAIRS (5),
#   REC_F (999). Report: julia bench/julia/perf_report.jl <OUT>.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
J="${JULIA618:-$HOME/app/julia-618}"
B="$J/bin"
# quiet.sh assigns its own OUT, and an exported OUT would carry its value into the block: the block
# reads PERF_UNMARKED_OUT, which only this driver sets.
OUT="${PERF_UNMARKED_OUT:-${OUT:-$ROOT/bench/results/618-perf}}"
export PERF_UNMARKED_OUT="$OUT"
mkdir -p "$OUT"
LOG="$OUT/driver.log"
LOOP="$ROOT/bench/tasks/spawnwait_fixed.jl"
N="${N:-3000000}"; WARM="${WARM:-200000}"; PAIRS="${PAIRS:-5}"; REC_F="${REC_F:-999}"
SPLIT_N="${SPLIT_N:-1000000}"; IDLE_S="${IDLE_S:-2}"; IDLE_RUNS="${IDLE_RUNS:-3}"
PS_WAIT_S="${PS_WAIT_S:-900}"
# label:wrapper:own depot. A wrapper or depot that starts with / is taken as given (#618 Idea 19:
# master_measure.sh SESSION=3 times builds under two directories); otherwise $B/julia-<wrapper> and
# $J/<depot>. A label is a word (\w+): perf_report.jl reads it back from the file names.
# PU_BUILDS / PU_LAYOUTS replace these (bench/julia/slim2.sh: s2b, a second build of s2, and the
# steps of #618 Idea 16 that run on a subset).
BUILDS="${PU_BUILDS:-ctl:control:depot-control m2:mark:depot-mark-r bp:mark-bypass:depot-mark-bypass bp2:mark-bypass2:depot-mark-bypass2 s1:mark-slim1:depot-mark-slim1 s2:mark-slim2:depot-mark-slim2}"
LAYOUTS="${PU_LAYOUTS:-2,1:0,1,2 4,1:0,1,2,3,4}"   # one hardware thread a Julia thread, each on its own core
G1="cycles:u,instructions:u,cycles:k,instructions:k,context-switches,cpu-migrations"
G2="cycles:u,branches:u,branch-misses:u,L1-dcache-load-misses:u,iTLB-load-misses:u"
G3="cycles:u,cache-misses:u,ls_dmnd_fills_from_sys.int_cache:u,ls_dmnd_fills_from_sys.lcl_l2:u,ls_dmnd_fills_from_sys.mem_io_local:u"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
stop() { log "STOP: $*"; log "driver stopped; restart with FROM=<step> after fixing"; exit 1; }
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
snap() {
  local d=() b
  # compiled/ only: builds from 1.14 on also keep a JIT object cache (cache/v1.1x/objcache*/data.mdb)
  # in the depot, which grows on every run of every build; it holds no package image.
  for b in $BUILDS; do case "${b##*:}" in /*) d+=("${b##*:}/compiled") ;; *) d+=("$J/${b##*:}/compiled") ;; esac; done
  find "${d[@]}" "$HOME/.julia/compiled" -type f -printf '%p %s %i\n' 2>/dev/null | sort
}
wrapper() { local b; for b in $BUILDS; do [ "${b%%:*}" = "$1" ] && { b="${b#*:}"; b="${b%%:*}"; case "$b" in /*) echo "$b" ;; *) echo "$B/julia-$b" ;; esac; return; }; done; }
tree() { case "$1" in ctl) echo control ;; m2) echo mark-r ;; bp) echo mark-bypass ;; bp2) echo mark-bypass2 ;; s1) echo mark-slim1 ;; s2) echo mark-slim2 ;; s2b) echo mark-slim2b ;; esac; }
# The run-time address of the build's multiq_deletemin clone in process $2: sys.so's base + the symbol.
dm_addr() {
  local so="$J/$(tree "$1")/usr/lib/julia/sys.so" sym base
  sym="$(nm "$so" | awk '$3 ~ /^julia_(stock_)?multiq_deletemin_[0-9]+\.2$/ { print $1; exit }')"
  base="$(awk -v so="$so" '$6 == so && $3 == "00000000" { split($1, a, "-"); print a[1]; exit }' "/proc/$2/maps")"
  [ -n "$sym" ] && [ -n "$base" ] || { echo "dm_addr: $1 sym '$sym' base '$base'" >&2; return 1; }
  printf '0x%x' $((0x$base + 0x$sym))
}
labels() { local b; for b in $BUILDS; do printf '%s ' "${b%%:*}"; done; }
# The builds in rotation r (0-based): a cyclic shift.
rotated() { local r="$1" a; read -ra a <<<"$(labels)"; local n=${#a[@]} i; for ((i = 0; i < n; i++)); do printf '%s ' "${a[$(((i + r) % n))]}"; done; }

# One attached run: label, layout, cpus, n, events, out stem[, record]. Writes <stem>.line and
# <stem>.perf (perf stat --per-thread), or <stem>.data (perf record, when the 7th argument is "record").
attached() {
  local lb="$1" layout="$2" cpus="$3" n="$4" ev="$5" stem="$6" tool="${7:-stat}" jp pp pid i
  rm -f "$stem".*
  ATTACH="$stem" N="$n" WARM="$WARM" MODE="${AMODE:-plain}" timeout -s KILL 300 taskset -c "$cpus" "$(wrapper "$lb")" \
    --startup-file=no --threads="$layout" "$LOOP" >"$stem.line" 2>"$stem.err" &
  jp=$!
  for ((i = 0; i < 1200; i++)); do [ -s "$stem.ready" ] && break; kill -0 "$jp" 2>/dev/null || break; sleep 0.05; done
  [ -s "$stem.ready" ] || { wait "$jp"; echo "attached: $lb $layout n=$n never ready" >&2; return 1; }
  pid="$(cat "$stem.ready")"
  if [[ "$ev" == *@DM@* ]]; then
    local a; a="$(dm_addr "$lb" "$pid")" || { kill "$jp"; return 1; }
    ev="${ev//@DM@/$a}"; echo "$a" >"$stem.addr"
  fi
  if [ "$tool" = none ]; then
    : # the handshake and the loop exactly as with perf, and nothing attached (a7)
  elif [ "$tool" = record ]; then
    perf record -q -e "$ev" -F "$REC_F" -p "$pid" -o "$stem.data" 2>"$stem.perr" &
  else
    perf stat --per-thread -x';' -e "$ev" -p "$pid" -o "$stem.perf" 2>"$stem.perr" &
  fi
  pp=$!
  sleep 0.3
  touch "$stem.go"
  wait "$jp" || { echo "attached: $lb $layout n=$n exit $?" >&2; [ "$tool" = none ] || wait "$pp"; return 1; }
  [ "$tool" = none ] || wait "$pp"
  [ -s "$stem.line" ] && { [ "$tool" = none ] || { [ "$tool" = record ] && [ -s "$stem.data" ]; } || grep -q ';' "$stem.perf" 2>/dev/null; } ||
    { echo "attached: $lb $layout n=$n empty output" >&2; return 1; }
}

# A counting block: group name, events.
block_stat() {
  local g="$1" ev="$2" p lc layout cpus lb ns n stem d="$OUT/$1"
  mkdir -p "$d"
  for ((p = 1; p <= PAIRS; p++)); do
    if [ $((p % 2)) = 1 ]; then ns="$N $((2 * N))"; lcs="$LAYOUTS"; else ns="$((2 * N)) $N"; lcs="$(echo "$LAYOUTS" | awk '{ for (i = NF; i > 0; i--) printf "%s ", $i }')"; fi
    for lc in $lcs; do
      layout="${lc%%:*}" cpus="${lc#*:}"
      for lb in $(rotated $((p - 1))); do
        for n in $ns; do
          stem="$d/p$p-${layout/,/_}-$lb-n$n"
          attached "$lb" "$layout" "$cpus" "$n" "$ev" "$stem" || return 1
        done
        echo "$(date +%T) $g pair $p $layout $lb: $(grep -o 'ns_per_op=[0-9.]*' "$d/p$p-${layout/,/_}-$lb-n$N.line")"
      done
    done
  done
}

block_who() {
  local p lc layout cpus lb d="$OUT/a2"
  mkdir -p "$d"
  for ((p = 1; p <= PAIRS; p++)); do
    for lc in $LAYOUTS; do
      layout="${lc%%:*}" cpus="${lc#*:}"
      for lb in $(rotated $((p - 1))); do
        N="$N" WARM="$WARM" MODE=who timeout -s KILL 300 taskset -c "$cpus" "$(wrapper "$lb")" --startup-file=no \
          --threads="$layout" "$LOOP" >"$d/r$p-${layout/,/_}-$lb.line" 2>"$d/r$p-${layout/,/_}-$lb.err" || return 1
        echo "$(date +%T) a2 run $p $layout $lb: $(cut -f9,20- "$d/r$p-${layout/,/_}-$lb.line" | tr '\t' ' ')"
      done
    done
  done
}

block_record() {
  local r lb d="$OUT/a4" stem
  mkdir -p "$d"
  for ((r = 1; r <= 3; r++)); do
    for lb in m2 bp; do
      stem="$d/plain-$r-$lb"
      N="$N" WARM="$WARM" MODE=plain timeout -s KILL 300 taskset -c 0,1,2 "$(wrapper "$lb")" --startup-file=no \
        --threads=2,1 "$LOOP" >"$stem.line" 2>"$stem.err" || return 1
      stem="$d/rec-$r-$lb"
      attached "$lb" 2,1 0,1,2 "$N" cycles:u "$stem" record || return 1
      echo "$(date +%T) a4 $r $lb: plain $(grep -o 'ns_per_op=[0-9.]*' "$d/plain-$r-$lb.line"), recorded $(grep -o 'ns_per_op=[0-9.]*' "$stem.line")"
    done
  done
}

block_split() {
  local p lc layout cpus lb d="$OUT/a5" f
  mkdir -p "$d"
  for ((p = 1; p <= PAIRS; p++)); do
    for lc in $LAYOUTS; do
      layout="${lc%%:*}" cpus="${lc#*:}"
      for lb in $(rotated $((p - 1))); do
        f="$d/r$p-${layout/,/_}-$lb"
        N="$SPLIT_N" WARM="$WARM" MODE=split timeout -s KILL 300 taskset -c "$cpus" "$(wrapper "$lb")" --startup-file=no \
          --threads="$layout" "$LOOP" >"$f.line" 2>"$f.err" || return 1
        echo "$(date +%T) a5 run $p $layout $lb: $(tr '\t' '\n' <"$f.line" | grep -E '^(pickup|wake|op)_p50=|^bt_median=' | paste -sd' ')"
      done
    done
  done
}

# a7 (#618 Idea 16, A5): does attaching perf move the plain fixed loop? PAIRS pairs (N, 2N) a build and
# layout, each run twice in a row: perf stat (group g1) attached, and nothing attached; the order of the
# two alternates a pair, the builds rotate.
block_attach() {
  local p lc layout cpus lb ns n stem tools t d="$OUT/a7"
  mkdir -p "$d"
  for ((p = 1; p <= PAIRS; p++)); do
    if [ $((p % 2)) = 1 ]; then ns="$N $((2 * N))"; tools="stat none"; else ns="$((2 * N)) $N"; tools="none stat"; fi
    for lc in $LAYOUTS; do
      layout="${lc%%:*}" cpus="${lc#*:}"
      for lb in $(rotated $((p - 1))); do
        for t in $tools; do
          for n in $ns; do
            stem="$d/p$p-${layout/,/_}-$lb-$t-n$n"
            attached "$lb" "$layout" "$cpus" "$n" "$G1" "$stem" "$t" || return 1
          done
          echo "$(date +%T) a7 pair $p $layout $lb $t: $(grep -o 'ns_per_op=[0-9.]*' "$d/p$p-${layout/,/_}-$lb-$t-n$N.line")"
        done
      done
    done
  done
}

block_idle() {
  local p lc layout cpus lb d="$OUT/a6"
  mkdir -p "$d"
  export JULIA_THREAD_SLEEP_THRESHOLD=infinite IDLE_S AMODE=idle
  for ((p = 1; p <= IDLE_RUNS; p++)); do
    for lc in $LAYOUTS; do
      layout="${lc%%:*}" cpus="${lc#*:}"
      for lb in $(rotated $((p - 1))); do
        attached "$lb" "$layout" "$cpus" 1 "cycles:u,instructions:u" "$d/u$p-${layout/,/_}-$lb" || return 1
        attached "$lb" "$layout" "$cpus" 1 "instructions:u,mem:@DM@:x" "$d/b$p-${layout/,/_}-$lb" || return 1
        echo "$(date +%T) a6 run $p $layout $lb: addr $(cat "$d/b$p-${layout/,/_}-$lb.addr")"
      done
    done
  done
}

if [ "${1:-}" = "--run" ]; then shift; "$@"; exit $?; fi

STEPS="${STEPS:-a1g1 a1g2 a1g3 a2 a4}"
if [ -n "${FROM:-}" ]; then STEPS="${STEPS#*"$FROM"}"; STEPS="$FROM$STEPS"; fi
log "driver start: steps [$STEPS], N=$N WARM=$WARM PAIRS=$PAIRS REC_F=$REC_F, OUT=$OUT"
log "perf_event_paranoid $(cat /proc/sys/kernel/perf_event_paranoid), nmi_watchdog $(cat /proc/sys/kernel/nmi_watchdog)"
[ "$(cat /proc/sys/kernel/perf_event_paranoid)" -le 1 ] || stop "perf_event_paranoid above 1: the maintainer sets it"
for s in $STEPS; do
  case "$s" in
    a1g1) cmd=(block_stat a1g1 "$G1") ;;
    a1g2) cmd=(block_stat a1g2 "$G2") ;;
    a1g3) cmd=(block_stat a1g3 "$G3") ;;
    a2) cmd=(block_who) ;;
    a4) cmd=(block_record) ;;
    a5) cmd=(block_split) ;;
    a6) cmd=(block_idle) ;;
    a7) cmd=(block_attach) ;;
    *) stop "unknown step $s" ;;
  esac
  ps_check || stop "a julia, oha or go-server process stayed before $s"
  snap >"$OUT/snap-before-$s"
  log "step $s start"
  if [ "${NOGATE:-0}" = 1 ]; then   # a smoke of the step's code, never a measurement
    "$0" --run "${cmd[@]}" >>"$LOG" 2>&1
  else
    "$ROOT/bench/socket/quiet.sh" "perf-$s" "$0" --run "${cmd[@]}" >>"$LOG" 2>&1
  fi
  rc=$?
  snap >"$OUT/snap-after-$s"
  if ! cmp -s "$OUT/snap-before-$s" "$OUT/snap-after-$s"; then
    diff "$OUT/snap-before-$s" "$OUT/snap-after-$s" | head -20 | tee -a "$LOG"
    stop "a cache file was written during $s"
  fi
  [ "$rc" = 0 ] || stop "step $s exit $rc"
  log "step $s done (no cache file written)"
done
log "driver done"
