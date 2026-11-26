#!/usr/bin/env bash
# The evidence for a pull request of the native mark (#618): every number its description quotes,
# regenerated from three builds by one command. The claims are fixed in advance (README, "The PR
# candidate"): one row a claim, one cell and one criterion a row.
#
#   bench/julia/candidate_evidence.sh <control> <control2> <candidate> [<bypass>]
#
# Each argument is a julia executable or wrapper: <control> and <control2> the same commit built
# twice (the floor), <candidate> that commit with the patch, and optionally <bypass>, the patch with
# stock's entry points under master's names (the mark's code compiled in, unreachable): a fourth
# column in row e and in row f's unmarked line. TIMENS=<julia> adds a variant of the candidate,
# measured in its own steps (t*) beside the candidate, after every row. Run it detached:
#   setsid nohup bench/julia/candidate_evidence.sh C C2 P > driver.out 2>&1 < /dev/null &
# Results go to OUT (default bench/results/candidate-evidence-<date>): raw/<step>/ (the TSVs),
# environment.md, results.md (written by candidate_evidence_report.jl, never by hand), driver.log.
# CE_PREV=<an earlier evidence directory> (with CE_PREV_NAME, CE_THIS_NAME) adds to results.md a table of
# the two runs' medians, row by row. PFIB_COLS and ARM_COLS replace rows f's and h's columns (a
# diagnostic run on other builds; the report then reads only the default columns).
#
# Rows and steps (rounds in brackets; a fresh process a round, columns rotated, one throwaway slot):
#   a, b  starved   the starved cell, 500 clients x 2 ms, :interactive clients, 8,1:
#                   control stock, candidate marked [STARVED_ROUNDS 5]
#   c     mixed     the mixed cell, plain and inner, 8,1 [MIXED_ROUNDS 5]
#   d     cell81, cell80   server cell 1 (/aggregate, c = 500, fresh servers) [CELL_ROUNDS 5]
#   e     floorfib  fib_fine at 8,1, nothing marked, control control2 candidate [FLOOR_ROUNDS 12]
#         floorh0   H = 0, C = 50 and 500, :default clients, 8,0, same columns [FLOOR_ROUNDS 12]
#   f     pfib2, pfib81   pfib(25) at --threads=2 and 8,1: control, control2, candidate unmarked,
#                   root marked, every spawn marked [PFIB_ROUNDS 6]
#   g     spawnpath H = 0, C = 50 and 500, :default clients, 8,0: control, candidate with clients
#                   and handlers marked [SPAWN_ROUNDS 6]
#   h     arm       fib_fine at 8,1: control, candidate, candidate with one marked task run first
#                   [ARM_ROUNDS 6]
#   i     tests     Julia's tests on control and candidate (untimed)
#         repro, repro_gh   the standalone reproducers in bench/julia/candidate/ on control and
#                   candidate [REPRO_ROUNDS 3]; repro_gh holds g's and h's
#         mwe       the PR description's reproducer, once on control and once marked on candidate
#   (TIMENS=) tstarved tmixed tspawnpath tarm tfloorfib tfloorh0   rows b, c, g, h and e with the
#                   variant beside the candidate [TIMENS_ROUNDS 6]
#         report    results.md
# STEPS="<names>" runs a subset, FROM=<name> starts at a step. DEADLINE=<epoch s>: the variant's
# steps and pfib81, if not started by then, are skipped and logged as CUT. SMOKE=1: every step once
# and short, never a measurement.
#
# Around every step, as master_measure.sh: before it the ps check (a julia, oha or go-server
# process that is not the driver's own is logged with its pid, start time, parent, working
# directory and command line, sent SIGTERM, then SIGKILL after 10 s, and the step goes on); after
# it the cache-write check on each build's first depot (compiled/ only: a write during a timed step
# stops the driver). Every timed block goes behind bench/socket/quiet.sh. Pinning: the server and
# the cells on CPUs 0,1,2,3,6,7,8,9 (8 threads), 0,1,2 for --threads=2; fairness.sh's clients on
# 4,5,10,11.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
if [ "${1:-}" != --run ]; then
  { [ $# -eq 3 ] || [ $# -eq 4 ]; } || { echo "usage: $0 <control> <control2> <candidate> [<bypass>]" >&2; exit 2; }
  export CE_CONTROL="$(readlink -f "$1")" CE_CONTROL2="$(readlink -f "$2")" CE_CANDIDATE="$(readlink -f "$3")"
  export CE_BYPASS=""; [ $# -eq 4 ] && CE_BYPASS="$(readlink -f "$4")"
  export CE_TIMENS=""; [ -n "${TIMENS:-}" ] && CE_TIMENS="$(readlink -f "$TIMENS")"
fi
[ -n "${CE_OUT:-}" ] && OUT="$CE_OUT"
export SMOKE="${SMOKE:-0}"
if [ "$SMOKE" = 1 ]; then
  export TD="${TD:-1}" NOGATE=1
  OUT="${OUT:-$ROOT/bench/results/candidate-evidence-smoke}"
  STARVED_ROUNDS=1 MIXED_ROUNDS=1 CELL_ROUNDS=1 FLOOR_ROUNDS=1 PFIB_ROUNDS=1 SPAWN_ROUNDS=1 ARM_ROUNDS=1 REPRO_ROUNDS=1 TIMENS_ROUNDS=1
else
  OUT="${OUT:-$ROOT/bench/results/candidate-evidence-$(date +%Y%m%d)}"
  STARVED_ROUNDS="${STARVED_ROUNDS:-5}" MIXED_ROUNDS="${MIXED_ROUNDS:-5}" CELL_ROUNDS="${CELL_ROUNDS:-5}"
  FLOOR_ROUNDS="${FLOOR_ROUNDS:-12}" PFIB_ROUNDS="${PFIB_ROUNDS:-6}" SPAWN_ROUNDS="${SPAWN_ROUNDS:-6}"
  ARM_ROUNDS="${ARM_ROUNDS:-6}" REPRO_ROUNDS="${REPRO_ROUNDS:-3}" TIMENS_ROUNDS="${TIMENS_ROUNDS:-6}"
fi
mkdir -p "$OUT/raw"
export CE_OUT="$OUT"
export CE_DRIVER_PID="${CE_DRIVER_PID:-$$}"
LOG="$OUT/driver.log"
export PATH="$HOME/.local/go/bin:$HOME/.local/bin:$HOME/.juliaup/bin:$PATH"
C="$CE_CONTROL" C2="$CE_CONTROL2" P="$CE_CANDIDATE" BP="${CE_BYPASS:-}" TN="${CE_TIMENS:-}"
ENVS="${CE_ENVS:-$HOME/app/julia-618-master/envs}"
EM="$ENVS/micro-master" SM="$ENVS/server-master"
export JLS="control=$C control2=$C2 candidate=$P${BP:+ bypass=$BP}${TN:+ timens=$TN}"
export MICRO_PROJECT="$EM"
JULIAS3="control=$C,$SM candidate=$P,$SM${TN:+ timens=$TN,$SM}"
CPUS8="0,1,2,3,6,7,8,9"
AGG="/aggregate?n=100000&op=groupby"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
stop() { log "STOP: $*"; log "driver stopped; restart with FROM=<step> after fixing"; exit 1; }
first_depot() { "$1" --startup-file=no -e 'print(DEPOT_PATH[1])' 2>/dev/null; }
own_proc() {
  local p="$1" n=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 64 ]; do
    [ "$p" = "$CE_DRIVER_PID" ] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; n=$((n + 1))
  done
  return 1
}
foreign_procs() {
  local p
  ps -eo pid=,comm= | awk '$2 == "julia" || $2 == "oha" || $2 == "go-server" { print $1 }' |
    while read -r p; do own_proc "$p" || echo "$p"; done
}
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }
describe_proc() {
  local p="$1" pp
  pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  echo "pid $p, started $(proc_start "$p"), parent $pp ($(ps -o comm= -p "${pp:-0}" 2>/dev/null || echo '?')), cwd $(readlink "/proc/$p/cwd" 2>/dev/null || echo '?'), cmd: $(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | cut -c1-400)"
}
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
DEPOTS=()
if [ "${1:-}" != --run ]; then
  for w in "$C" "$C2" "$P" $BP $TN; do d="$(first_depot "$w")"; [ -n "$d" ] && DEPOTS+=("$d"); done
fi
snap() { local d; for d in "$@"; do [ -d "$d/compiled" ] && find "$d/compiled" -type f -printf '%p %s %i\n' 2>/dev/null; done | sort; }
cache_mark() { snap "${DEPOTS[@]}" >"$OUT/.snap-own"; }
cache_check() {
  local own; own="$(comm -13 "$OUT/.snap-own" <(snap "${DEPOTS[@]}"))"
  [ -z "$own" ] || { log "cache check $1: CACHE FILES CREATED OR REPLACED during the step (path size inode):"; echo "$own" | head -40 | tee -a "$LOG"; return 1; }
  log "cache check $1: no cache file created or replaced"
}
results_mark() { ls -1 "$ROOT/bench/results" 2>/dev/null | sort >"$OUT/.results-before"; }
results_move() {
  local f d="$OUT/raw/$1"
  mkdir -p "$d"
  comm -13 "$OUT/.results-before" <(ls -1 "$ROOT/bench/results" 2>/dev/null | sort) | while read -r f; do
    case "$f" in ""|go-server|fairness|"$(basename "$OUT")") continue ;; esac
    mv "$ROOT/bench/results/$f" "$d/"
  done
}
rf() { PROFILE=native JL="$C" "$ROOT/bench/tasks/rounds_fifo.sh" "$@"; }
gated() {
  local attempt=1 rc
  [ "${NOGATE:-0}" = 1 ] && { shift; "$@"; return $?; }
  while :; do
    "$ROOT/bench/socket/quiet.sh" "$@"; rc=$?
    { [ "$rc" = 3 ] || [ "$rc" = 4 ]; } || return "$rc"
    [ "$attempt" -le 2 ] || return "$rc"
    log "gated $1: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    ps_check || return 1
  done
}
rotated() {
  local r="$1"; shift
  local n=$# k a i out=(); k=$(( ((r - 1) % n + n) % n )); a=("$@")
  for ((i = 0; i < n; i++)); do out+=("${a[$(( (i + k) % n ))]}"); done
  echo "${out[*]}"
}
jl_of() { case "$1" in control) echo "$C" ;; control2) echo "$C2" ;; candidate) echo "$P" ;; bypass) echo "$BP" ;; timens) echo "$TN" ;; *) return 1 ;; esac; }
LABELS="control control2 candidate${BP:+ bypass}${TN:+ timens}"

# ---------------------------------------------------------------- untimed: environments, environment.md
step_prep() {    # each build's first depot gets the micro and server environments precompiled
  local w e
  for w in "$C" "$C2" "$P" $BP $TN; do
    for e in "$EM" "$SM"; do
      JULIA_PKG_OFFLINE=true "$w" --startup-file=no --project="$e" -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' >>"$LOG" 2>&1 ||
        { log "prep: precompiling $e for $w failed"; return 1; }
    done
    "$w" --startup-file=no --project="$SM" -e 'using HTTP, JSON' >>"$LOG" 2>&1 || return 1
    "$w" --startup-file=no --project="$EM" -e 'using BenchmarkTools, JSON' >>"$LOG" 2>&1 || return 1
  done
}
step_env() {
  local f="$OUT/environment.md" w label
  {
    echo "# Environment"
    echo
    echo "- Date: $(date -Is)"
    echo "- CPU: $(lscpu | sed -n 's/^Model name: *//p'), $(nproc) logical CPUs ($(lscpu | sed -n 's/^Core(s) per socket: *//p') cores)"
    echo "- Kernel: $(uname -srvm)"
    echo "- Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?'); boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo '?')"
    echo "- Clocksource: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null)"
    echo "- Uptime: $(uptime -p) (up since $(uptime -s)); load before the first block (/proc/loadavg): $(cat /proc/loadavg)"
    echo "- Memory: $(free -m | awk '/^Mem:/ { printf "%s MiB total, %s MiB free, %s MiB available", $2, $4, $7 }'); swap used $(free -m | awk '/^Swap:/ { print $3 }') MiB"
    echo "- Transparent huge pages: enabled $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null), defrag $(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)"
    echo "- Pinning: the cells and the server on CPUs $CPUS8 (taskset; 0,1,2 for --threads=2); fairness.sh's load generator on 4,5,10,11. Each column is a fresh process every round."
    echo "- Gate: every timed block behind bench/socket/quiet.sh (no other julia, oha or go-server process, load1 < 0.5)."
    echo
    for label in $LABELS; do
      w="$(jl_of "$label")"
      echo "## $label: \`$w\`"
      echo
      echo '```'
      "$w" --startup-file=no -e 'println("commit ", Base.GIT_VERSION_INFO.commit, " (", Base.GIT_VERSION_INFO.commit_short, ")"); println("first depot ", DEPOT_PATH[1]); versioninfo()' 2>&1
      local home; home="$("$w" --startup-file=no -e 'print(normpath(joinpath(Sys.BINDIR, "..", "..")))' 2>/dev/null)"
      [ -f "$home/Make.user" ] && { echo "Make.user:"; sed 's/^/  /' "$home/Make.user"; }
      echo '```'
      echo
    done
    echo "## Package versions"
    echo
    for e in "$EM" "$SM"; do
      echo "- $(basename "$e"): $("$C" --startup-file=no --project="$e" -e 'using Pkg; print(join(sort([string(p.name, " ", p.version) for p in values(Pkg.dependencies()) if p.is_direct_dep]), ", "))' 2>/dev/null)"
    done
  } >"$f"
  log "environment.md written"
}

# ---------------------------------------------------------------- the harness cells (rounds_fifo.sh)
step_fib() {     # dir, layout, cpus, columns, rounds
  OUT="$OUT/raw/$1" CPUS="$3" BLOCKS=fibabba ROUNDS=1 ROTATE=1 ABBA_COLS="$4" ABBA_ROUNDS="$5" ABBA_LAYOUTS="$2" \
    rf >>"$LOG" 2>&1
}
step_h0() {      # dir, client cells spec, columns, rounds
  OUT="$OUT/raw/$1" CPUS="$CPUS8" BLOCKS=costrounds ROUNDS=1 MULTI_ROUNDS="$4" ROTATE=1 NATIVE_COLS="$3" WARM=cell \
    CLIENT_CELLS_SPEC="$2" COST_CELLS_NATIVE="50:0 500:0" MICRO_LAYOUTS=none rf >>"$LOG" 2>&1
}
step_starved() { # dir, columns, rounds
  OUT="$OUT/raw/$1" CPUS="$CPUS8" BLOCKS=fairrounds ROUNDS=1 MULTI_ROUNDS="$3" ROTATE=1 NATIVE_COLS="$2" \
    CLIENT_CELLS_SPEC="8,1 interactive" rf >>"$LOG" 2>&1
}
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
step_mixed() {
  local d="$OUT/raw/$1"; rm -f "$d/mixed.tsv" "$d/mixedinner.tsv" "$d/throwaway-mixed.tsv"
  gated "618ce-$1" "$0" --run mixed_rounds "$d" "$2" "$3" >>"$LOG" 2>&1
}

# ---------------------------------------------------------------- server cell 1 (fairness.sh)
step_server() {  # label, route, modes, rounds
  local dur=8s; [ "$SMOKE" = 1 ] && dur=2s
  gated "618ce-$1" env FRESH=1 BACKLOG=1024 ROTATE=1 THROWAWAY=1 PROBE=0 ROUTE="$2" JULIAS="$JULIAS3" \
    "$ROOT/bench/socket/fairness.sh" "$3" "$4" "$dur" >>"$LOG" 2>&1
}

# ---------------------------------------------------------------- pfib(25)
pfib_one() {     # tsv, round, layout, cpus, column (label:build:mode)
  local tsv="$1" r="$2" layout="$3" cpus="$4" col="$5" label wr mode out rc
  IFS=: read -r label wr mode <<<"$col"
  out="$(env PFIB_MODE="$mode" LABEL="$label" ROUND="$r" timeout -s KILL "${PFIB_TIMEOUT_S:-300}" \
    taskset -c "$cpus" "$(jl_of "$wr")" --startup-file=no --project="$EM" --threads="$layout" "$ROOT/bench/tasks/pfib.jl" 2>>"$tsv.err")"
  rc=$?
  if [ "$rc" = 0 ] && [ -n "$out" ]; then echo "$out" >>"$tsv"
  else printf '%s\t%s\t%s\t%s\t25\tFAILED rc=%s\n' "$r" "$label" "$mode" "$layout" "$rc" >>"$tsv"; fi
}
pfib_block() {   # tsv, rounds, layout, cpus, columns...
  local tsv="$1" n="$2" layout="$3" cpus="$4" r c; shift 4
  pfib_one "$(dirname "$tsv")/pfib-throwaway.tsv" 0 "$layout" "$cpus" "$1"
  for r in $(seq 1 "$n"); do
    for c in $(rotated "$r" "$@"); do pfib_one "$tsv" "$r" "$layout" "$cpus" "$c"; done
  done
}
PFIB_COLS="${PFIB_COLS:-ctl:control:none ctl2:control2:none cand:candidate:none root:candidate:root all:candidate:all${BP:+ byp:bypass:none}}"
step_pfib() {    # step, layout, cpus
  local a="$OUT/raw/$1/pfib.tsv"; mkdir -p "$OUT/raw/$1"; rm -f "$a"
  printf 'round\tlabel\tmode\tlayout\tn\tmin_s\tmedian_s\tallocs\tmemory_bytes\tsamples\tmaxrss_mb\n' >"$a"
  gated "618ce-$1" "$0" --run pfib_block "$a" "$PFIB_ROUNDS" "$2" "$3" $PFIB_COLS >>"$LOG" 2>&1
}

# ---------------------------------------------------------------- Julia's tests (untimed)
TEST_SETS='["core", "threads", "channels", "channel_threadpool", "threadpool_use", "threadpool_latency", "cancellation"]'
[ "$SMOKE" = 1 ] && TEST_SETS='["channel_threadpool"]'
step_tests() {
  local label w d="$OUT/raw/tests" t0 rc
  mkdir -p "$d"
  for label in control candidate; do
    w="$(jl_of "$label")"; t0=$(date +%s)
    timeout -s KILL "${TESTS_TIMEOUT_S:-3600}" "$w" --startup-file=no -e "Base.runtests($TEST_SETS; ncores = 6)" >"$d/$label.log" 2>&1
    rc=$?
    log "tests $label: exit $rc after $(( $(date +%s) - t0 )) s; $(grep -E '^ *(SUCCESS|FAILURE)' "$d/$label.log" | tail -1 | tr -d ' ')"
  done
  return 0
}

# ---------------------------------------------------------------- the standalone reproducers
repro_one() {    # tsv, round, build label, layout, cpus, file, args...
  local tsv="$1" r="$2" label="$3" layout="$4" cpus="$5" file="$6" out rc; shift 6
  out="$(timeout -s KILL 600 taskset -c "$cpus" "$(jl_of "$label")" --startup-file=no --threads="$layout" \
    "$HERE/candidate/$file" "$@" 2>>"$tsv.err")"
  rc=$?
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$label" "$file" "$*" "$layout" "$rc" "$out" >>"$tsv"
}
REPRO_CORE=("8,1|starved.jl|plain" "8,1|starved.jl|fair" "8,1|fib_fine.jl|" "2|pfib.jl|none" "2|pfib.jl|root" "2|pfib.jl|all")
REPRO_GH=("8,0|spawn_path.jl|plain 50" "8,0|spawn_path.jl|fair 50" "8,0|spawn_path.jl|plain 500" "8,0|spawn_path.jl|fair 500" "8,1|armed.jl|unarmed" "8,1|armed.jl|armed")
repro_block() {  # tsv, rounds, items...
  local tsv="$1" n="$2" r it layout file args cpus label; shift 2
  for r in $(seq 1 "$n"); do
    for it in "$@"; do
      IFS='|' read -r layout file args <<<"$it"
      cpus="$CPUS8"; [ "$layout" = 2 ] && cpus="0,1,2"
      for label in $(rotated "$r" control candidate); do
        # shellcheck disable=SC2086
        repro_one "$tsv" "$r" "$label" "$layout" "$cpus" "$file" $args
      done
    done
  done
}
step_repro() {   # step, items...
  local s="$1" a; shift
  a="$OUT/raw/$s/repro.tsv"; mkdir -p "$OUT/raw/$s"; rm -f "$a"
  printf 'round\tbuild\tfile\targs\tlayout\texit\tline\n' >"$a"
  gated "618ce-$s" "$0" --run repro_block "$a" "$REPRO_ROUNDS" "$@" >>"$LOG" 2>&1
}

# ---------------------------------------------------------------- the description's reproducer
mwe_block() {    # dir
  local d="$1"
  sed 's/Threads.@spawn (burn(H); notify(done))/Threads.@spawn fair=true (burn(H); notify(done))/' "$HERE/candidate/mwe.jl" >"$d/mwe-fair.jl"
  grep -q 'fair=true' "$d/mwe-fair.jl" || return 1
  timeout -s KILL 120 taskset -c "$CPUS8" "$C" --startup-file=no --threads=8,1 "$HERE/candidate/mwe.jl" >"$d/mwe-control.txt" 2>&1
  timeout -s KILL 120 taskset -c "$CPUS8" "$P" --startup-file=no --threads=8,1 "$d/mwe-fair.jl" >"$d/mwe-candidate-fair.txt" 2>&1
}

if [ "${1:-}" = --run ]; then shift; "$@"; exit $?; fi

UNTIMED=" prep env tests report "
DEFAULT_STEPS="prep env starved mixed cell81 cell80 floorfib floorh0 pfib2 pfib81 spawnpath arm tests repro repro_gh mwe${TN:+ tstarved tmixed tspawnpath tarm tfloorfib tfloorh0} report"
FLOOR_COLS="A%control A%control2 N-none%candidate${BP:+ N-none%bypass}"
STEPS="${STEPS:-$DEFAULT_STEPS}"
if [ -n "${FROM:-}" ]; then
  STEPS="$(echo "$STEPS" | tr ' ' '\n' | sed -n "/^${FROM}\$/,\$p" | tr '\n' ' ')"
  [ -n "$STEPS" ] || stop "FROM=$FROM is not a step"
fi
log "driver start: steps [$STEPS], OUT $OUT, SMOKE=$SMOKE"
for label in $LABELS; do
  w="$(jl_of "$label")"
  log "build $label: $w: $("$w" --startup-file=no -e 'print(VERSION, " ", Base.GIT_VERSION_INFO.commit_short)' 2>&1 | head -1)"
done
{ printf 'label\tpath\tcommit_short\n'
  for label in $LABELS; do
    w="$(jl_of "$label")"
    printf '%s\t%s\t%s\n' "$label" "$w" "$("$w" --startup-file=no -e 'print(Base.GIT_VERSION_INFO.commit_short)' 2>/dev/null)"
  done; } >"$OUT/builds.tsv"
CUTTABLE=" tstarved tmixed tspawnpath tarm tfloorfib tfloorh0 pfib81 "   # the prompt's cut order: the variant, then row f at 8,1
for s in $STEPS; do
  if [ -n "${DEADLINE:-}" ] && [ "$(date +%s)" -ge "$DEADLINE" ] && [[ "$CUTTABLE" == *" $s "* ]]; then
    log "step $s: CUT (not started by the deadline)"; continue
  fi
  ps_check || stop "ps check before $s"
  cache_mark; results_mark
  log "step $s: start"
  t0=$(date +%s)
  case "$s" in
    prep) step_prep ;;
    env) step_env ;;
    starved) step_starved starved "A%control N%candidate" "$STARVED_ROUNDS" ;;
    mixed) step_mixed mixed "A%control N%candidate" "$MIXED_ROUNDS" ;;
    cell81) step_server cell81 "$AGG" "bare_spawn@8,1%control bare_marked_listen@8,1@N%candidate" "$CELL_ROUNDS" ;;
    cell80) step_server cell80 "$AGG" "bare_spawn@8,0%control bare_marked_listen@8,0@N%candidate" "$CELL_ROUNDS" ;;
    floorfib) step_fib floorfib 8,1 "$CPUS8" "$FLOOR_COLS" "$FLOOR_ROUNDS" ;;
    floorh0) step_h0 floorh0 "8,0 default" "$FLOOR_COLS" "$FLOOR_ROUNDS" ;;
    pfib2) step_pfib pfib2 2 0,1,2 ;;
    pfib81) step_pfib pfib81 8,1 "$CPUS8" ;;
    spawnpath) step_h0 spawnpath "8,0 default" "A%control N%candidate" "$SPAWN_ROUNDS" ;;
    arm) step_fib arm 8,1 "$CPUS8" "${ARM_COLS:-A%control N-none%candidate N-arm%candidate}" "$ARM_ROUNDS" ;;
    tests) step_tests ;;
    repro) step_repro repro "${REPRO_CORE[@]}" ;;
    repro_gh) step_repro repro_gh "${REPRO_GH[@]}" ;;
    mwe) mkdir -p "$OUT/raw/mwe"; gated 618ce-mwe "$0" --run mwe_block "$OUT/raw/mwe" >>"$LOG" 2>&1 ;;
    tstarved) step_starved tstarved "A%control N%candidate N%timens" "$TIMENS_ROUNDS" ;;
    tmixed) step_mixed tmixed "A%control N%candidate N%timens" "$TIMENS_ROUNDS" ;;
    tspawnpath) step_h0 tspawnpath "8,0 default" "A%control N%candidate N%timens" "$TIMENS_ROUNDS" ;;
    tarm) step_fib tarm 8,1 "$CPUS8" "A%control N-none%timens N-arm%timens N-none%candidate N-arm%candidate" "$TIMENS_ROUNDS" ;;
    tfloorfib) step_fib tfloorfib 8,1 "$CPUS8" "A%control A%control2 N-none%candidate N-none%timens" "$TIMENS_ROUNDS" ;;
    tfloorh0) step_h0 tfloorh0 "8,0 default" "A%control A%control2 N-none%candidate N-none%timens" "$TIMENS_ROUNDS" ;;
    report) "$C" --startup-file=no "$HERE/candidate_evidence_report.jl" "$OUT" >"$OUT/results.md" 2>>"$LOG" ;;
    *) stop "unknown step $s" ;;
  esac
  rc=$?
  [ "$s" = report ] || results_move "$s"
  log "step $s: exit $rc after $(( ($(date +%s) - t0) / 60 )) min"
  if ! cache_check "$s"; then
    if [[ "$UNTIMED" == *" $s "* ]] || [ "$SMOKE" = 1 ]; then log "cache check $s: logged, not fatal (untimed step or smoke)"
    else stop "cache check after $s"; fi
  fi
  [ "$rc" = 0 ] || { [[ "$UNTIMED" == *" $s "* ]] && log "RESULT: step $s exited $rc" || stop "step $s failed (exit $rc)"; }
done
log "driver done: every step finished"
