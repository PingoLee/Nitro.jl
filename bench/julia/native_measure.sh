#!/usr/bin/env bash
# #618, the native mark, session 2 (agent-config #82 Idea 10): the whole measurement as one driver
# that needs nothing from the session that launched it. Every timed block goes through
# bench/socket/quiet.sh (inside rounds_fifo.sh and mark_server.sh). Around every block the driver:
#   - before a gated block: waits for no julia, oha or go-server process (PS_WAIT_S, default 900 s,
#     logging what it sees every 30 s); still there at the end, the driver STOPS and logs them. It
#     never stops a process itself;
#   - after every block: the cache-write check: no file under the builds' own depots' compiled/
#     created or replaced during the block, against a (path, size, inode) snapshot taken just before
#     it (a write there means a build compiled during the block; the driver STOPS). Julia 1.13 touches
#     a cache file in the first depot each time it loads it (`touch_cachefile`), so an mtime alone is
#     not a write: compilecache writes a new file and renames it into place, a new inode. Changes
#     under ~/.julia/compiled are logged, not fatal: no build here writes there (every write goes to
#     its first depot), so they are another process's;
#   - stops on a block that fails (a VALIDATE pass, a negative control, a server's /mq verdict, a
#     smoke check, a timed block that gave up after its retries or lost a process).
# Order (the maintainer's, 2026-11-19): block 0 (validation + smoke, untimed), /plaintext at 8,0 and
# 8,1, fib_fine ABBA (ctl and mark0, 12 rounds), server cell 1 and cell 4 at 8,0, the six harness
# rounds (cost, cells), server cell 1 and cell 4 at 8,1. STEPS="<names>" runs a subset, FROM=<name>
# starts at that step (a restart after a stop).
#
# Usage: bench/julia/native_measure.sh   (detached: setsid nohup … > driver.out 2>&1 < /dev/null &)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
J="${JULIA618:-$HOME/app/julia-618}"
OUT="${OUT:-$ROOT/bench/results/618-native-measure}"
mkdir -p "$OUT"
LOG="$OUT/driver.log"
export PATH="$HOME/.local/go/bin:$HOME/.local/bin:$HOME/.juliaup/bin:$PATH"
export JLS="control=$J/bin/julia-control mark=$J/bin/julia-mark official=$J/bin/julia-official"
export JULIAS="control=$J/bin/julia-control,$ROOT/bench mark=$J/bin/julia-mark,$ROOT/bench official=$J/bin/julia-official,$ROOT/bench mv=$J/bin/julia-mark-validate,$ROOT/bench"
export MICRO_PROJECT="${MICRO_PROJECT:-$J/benchenv}"
PS_WAIT_S="${PS_WAIT_S:-900}"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
stop() { log "STOP: $*"; log "driver stopped; restart with FROM=<step> after fixing"; exit 1; }
procs() { ps -eo pid=,etime=,comm=,args= | awk '$3 == "julia" || $3 == "oha" || $3 == "go-server"' | cut -c1-220; }

ps_check() {   # before a gated block
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
  [ -n "$other" ] && { log "cache check $1: files created or replaced under ~/.julia/compiled during the block (not by the builds here):"; echo "$other" | tee -a "$LOG"; }
  [ -z "$own" ] || { log "cache check $1: CACHE FILES CREATED OR REPLACED during the block (path size inode):"; echo "$own" | tee -a "$LOG"; return 1; }
  log "cache check $1: no cache file created or replaced"
}

# The newest fairness raw directory's /mq verdicts must all be ok.
mq_check() {
  local raw bad n
  raw="$(ls -dt "$ROOT"/bench/results/fairness-*-raw | head -1)"
  n="$(ls "$raw"/*-mq.json 2>/dev/null | wc -l)"
  [ "$n" -gt 0 ] || { log "mq check: no /mq files in $raw"; return 1; }
  bad="$(for f in "$raw"/*-mq.json; do jq -r --arg f "$(basename "$f")" 'select(.verdict != "ok") | "\($f): \(.verdict)"' "$f"; done)"
  [ -z "$bad" ] || { log "mq check: verdicts not ok:"; echo "$bad" | tee -a "$LOG"; return 1; }
  log "mq check: $n /mq files in $(basename "$raw"), every verdict ok"
}

# PROFILE goes to rounds_fifo.sh only: server.jl reads PROFILE as its profiling window, in seconds.
rf() { PROFILE=native "$ROOT/bench/tasks/rounds_fifo.sh" "$@"; }
ms() { "$ROOT/bench/socket/mark_server.sh" "$@"; }

# A gated mark_server block, retried on a failed gate (3) or a stopped block (4), twice at most.
ms_gated() {   # block layout
  local attempt=1 rc
  while :; do
    ms "$@"; rc=$?
    { [ "$rc" = 3 ] || [ "$rc" = 4 ]; } || return "$rc"
    [ "$attempt" -le 2 ] || return "$rc"
    log "mark_server $*: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    ps_check || return 1
  done
}

step_vharness() {
  log "block 0a: VALIDATE on mark-validate (rounds_fifo PROFILE=native VALIDATE=1)"
  JL="$J/bin/julia-mark-validate" VALIDATE=1 OUT="$OUT/validate" rf >>"$LOG" 2>&1
}
step_vserver() {
  log "block 0b: server VALIDATE (nv, mark-validate, /mq)"
  ms nv >>"$LOG" 2>&1 || return 1
  mq_check
}
step_smoke() {
  log "block 0c: smoke of the timed block code (D = 1, no gate, not timed)"
  JL="$J/bin/julia-control" NOGATE=1 TD=1 D=1 RUNS=1 FIB_FINE=36:12 ABBA_ROUNDS=1 MICRO_V="N%mark" \
    OUT="$OUT/smoke" BLOCKS="cost cells fibabba" ROUNDS=1 rf >>"$LOG" 2>&1 || return 1
  log "block 0d: smoke of the five server columns at 8,0 and 8,1 (2 s, no gate)"
  ms nsmoke 8,0 >>"$LOG" 2>&1 || return 1
  ms nsmoke 8,1 >>"$LOG" 2>&1 || return 1
  log "block 0c-0d: done"
}
step_plain80()  { ms_gated nplain 8,0 >>"$LOG" 2>&1; }
step_plain81()  { ms_gated nplain 8,1 >>"$LOG" 2>&1; }
step_fibabba()  { JL="$J/bin/julia-control" OUT="$OUT" BLOCKS=fibabba ROUNDS=1 rf >>"$LOG" 2>&1; }
step_cell1_80() { ms_gated ncell1 8,0 >>"$LOG" 2>&1; }
step_cell4_80() { ms_gated ncell4 8,0 >>"$LOG" 2>&1; }
step_cell1_81() { ms_gated ncell1 8,1 >>"$LOG" 2>&1; }
step_cell4_81() { ms_gated ncell4 8,1 >>"$LOG" 2>&1; }
step_round()    { JL="$J/bin/julia-control" OUT="$OUT" BLOCKS="cost cells" FIRST_ROUND="$1" ROUNDS="$1" rf >>"$LOG" 2>&1; }

STEPS="${STEPS:-vharness vserver smoke plain80 plain81 fibabba cell1_80 cell4_80 round1 round2 round3 round4 round5 round6 cell1_81 cell4_81}"
if [ -n "${FROM:-}" ]; then
  STEPS="$(echo "$STEPS" | tr ' ' '\n' | sed -n "/^${FROM}\$/,\$p" | tr '\n' ' ')"
  [ -n "$STEPS" ] || stop "FROM=$FROM is not a step"
fi

log "driver start: steps [$STEPS], OUT $OUT"
log "builds: control $("$J/bin/julia-control" -e 'print(Base.GIT_VERSION_INFO.commit_short)'), mark $("$J/bin/julia-mark" -e 'print(Base.GIT_VERSION_INFO.commit_short)') ($(readlink -f "$(sed -n 's/^exec "\([^"]*\)".*/\1/p' "$J/bin/julia-mark")")), official $("$J/bin/julia-official" -e 'print(Base.GIT_VERSION_INFO.commit_short)')"
for s in $STEPS; do
  if [ "$s" != vharness ]; then ps_check || stop "ps check before $s"; fi
  cache_mark
  log "step $s: start"
  t0=$(date +%s)
  case "$s" in
    round*) step_round "${s#round}" ;;
    *) "step_$s" ;;
  esac
  rc=$?
  log "step $s: exit $rc after $(( ($(date +%s) - t0) / 60 )) min"
  cache_check "$s" || stop "cache check after $s"
  [ "$rc" = 0 ] || stop "step $s failed (exit $rc)"
done
log "driver done: every step finished"
