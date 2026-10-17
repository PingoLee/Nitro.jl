#!/usr/bin/env bash
# Pinned-core, median-of-N socket throughput for bench/socket/server.jl (#448, #453).
#
# The servers and the load generator are pinned to DISJOINT physical cores so they never contend.
# Every mode's server is started up front, each on its own port, and the runs are INTERLEAVED --
# run 1 of every mode, then run 2 of every mode, and so on -- so a load spike from anything else on
# the box lands on all modes alike instead of on whichever happened to be measured then. An idle
# server costs the measured one nothing. Each route is warmed first; the median (with min/max) of
# RUNS runs is reported. Loopback only.
#
# The CPU sets assume a 6-core/12-thread part whose SMT siblings are n and n+6 (`lscpu -e` shows
# the pairing); override SERVER_CPUS/CLIENT_CPUS for another layout.
#
# Usage: bench/socket/run.sh [modes] [runs] [duration]
#   bench/socket/run.sh "nitro bare_spawn bare_nospawn" 5 6s
#   ACCESS_LOG=1 bench/socket/run.sh nitro
#   THREADS=8,2 bench/socket/run.sh            # two interactive threads, every mode
#   bench/socket/run.sh "nitro@8,1 nitro@8,2 nitro@8,4"   # per-mode --threads, one interleaved run
#   PROFILE=10 bench/socket/run.sh nitro 1 20s # one mode only; see server.jl
#   BASE_ROOT=/path/to/other/checkout bench/socket/run.sh "baseline nitro"
#   RATE=20000 bench/socket/run.sh "nitro@8,1 nitro@8,0"  # fixed request rate, not saturation
#   JULIA="julia +1.12" bench/socket/run.sh               # another Julia (juliaup channel)
#
# RATE sets oha's `-q` (requests per second across all connections) with `--latency-correction`,
# so a server that falls behind is charged the time requests spent waiting to be sent: p50/p99 at
# a rate every setting can sustain compare latency without throughput's own queueing (#491).
# Unset, every connection sends as fast as it is answered.
#
# `baseline` is `nitro` served from the checkout at BASE_ROOT (its own bench/ env, instantiated),
# so a change can be A/B'd against the code it replaces in the same interleaved run.
#
# `go` is the Go `net/http` reference in socket/go/ (#469): same routes, same bodies, built once
# per invocation and pinned to the same SERVER_CPUS. Its `threads` column is GOMAXPROCS, which
# defaults to the number of server CPUs; `go@4` sets it. Go is required only when `go` is one of
# the modes, so Julia-only runs keep working without a Go toolchain.
#
# Every mode's resident memory is read from /proc for the process that owns the listening socket,
# not for `$!`, so a wrapper between the two cannot misreport it: `rss_rest_mib` once it answers `/health`,
# `rss_after_mib` once every run is done, and `rss_peak_mib` (VmHWM) over its life.
#
# `mode@threads` starts that one server with its own `--threads` and records it in the TSV's
# `threads` column; a bare mode takes THREADS. That is what lets a sweep of the interactive
# thread count (#462: does HTTP.jl's single interactive thread set the ceiling?) obey the rule
# the README states -- compare within ONE run -- instead of one run per thread count.
#
# KEEP_JSON=1 keeps every measured oha JSON report under bench/results/socket-<stamp>-raw/ (it
# carries p99.9 and the latency histogram, which the TSV does not). GC_SNAPSHOTS=1 records each
# server's GC counters right before and right after every measured run in socket-<stamp>-gc.tsv,
# so a run's tail can be set against the collections it contained (#590): a Julia mode's line is
# its `/gc` (every `Base.gc_num()` field), a `go` mode's is the line count of its log, which with
# GODEBUG=gctrace=1 in the environment is one line per collection.
#
# Results: one TSV per invocation under bench/results/ (gitignored).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

MODES="${1:-nitro bare_spawn bare_nospawn}"
RUNS="${2:-5}"
DUR="${3:-6s}"
CONNS="${CONNS:-50}"
THREADS="${THREADS:-8}"
BASE_PORT="${PORT:-8080}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,3,6,7,8,9}"   # 4 physical cores (8 logical)
CLIENT_CPUS="${CLIENT_CPUS:-4,5,10,11}"         # 2 other physical cores
ROUTES="${ROUTES:-/plaintext /json}"
RATE="${RATE:-}"
KEEP_JSON="${KEEP_JSON:-0}"
GC_SNAPSHOTS="${GC_SNAPSHOTS:-0}"
read -r -a JULIA_CMD <<<"${JULIA:-julia}"

for tool in oha taskset jq curl "${JULIA_CMD[0]}" ss; do
  command -v "$tool" >/dev/null || { echo "run.sh: $tool not on PATH" >&2; exit 1; }
done
read -r -a MODE_LIST <<<"$MODES"
WANT_GO=0
for mode in "${MODE_LIST[@]}"; do [ "${mode%%@*}" = go ] && WANT_GO=1; done
if [ "$WANT_GO" = 1 ]; then
  command -v go >/dev/null || { echo "run.sh: go not on PATH (needed by the go mode)" >&2; exit 1; }
fi
if [ "${PROFILE:-0}" != "0" ] && [ "${#MODE_LIST[@]}" -ne 1 ]; then
  echo "run.sh: PROFILE takes exactly one mode" >&2; exit 1
fi

OUT="$ROOT/bench/results"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/socket-$STAMP.tsv"
RAW="$OUT/socket-$STAMP-raw"
[ "$KEEP_JSON" = 1 ] && mkdir -p "$RAW"
GC_TSV="$OUT/socket-$STAMP-gc.tsv"
[ "$GC_SNAPSHOTS" = 1 ] && printf 'mode\troute\trun\tphase\tsnapshot\n' > "$GC_TSV"
printf 'mode\tthreads\taccess_log\troute\trate\tmedian_rps\tmin_rps\tmax_rps\tmedian_p50_ms\tmedian_p99_ms\trss_rest_mib\trss_after_mib\trss_peak_mib\n' > "$RESULT"

median() { sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

# `nitro@8,2` -> name `nitro`, threads `8,2`; `nitro` -> name `nitro`, threads $THREADS; a bare
# `go` -> GOMAXPROCS = the number of server CPUs (`nproc` honours the affinity mask).
SERVER_NCPU="$(taskset -c "$SERVER_CPUS" nproc)"
mode_name()    { printf '%s' "${1%%@*}"; }
mode_threads() {
  case "$1" in
    *@*) printf '%s' "${1#*@}" ;;
    go)  printf '%s' "$SERVER_NCPU" ;;
    *)   printf '%s' "$THREADS" ;;
  esac
}

# The pid that owns the listening socket on port $1, and a /proc/<pid>/status field in MiB.
listener_pid() { ss -Hltnp "sport = :$1" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; }
status_mib()   { awk -v k="$2:" '$1 == k { printf "%.0f", $2 / 1024 }' "/proc/$1/status" 2>/dev/null; }

GO_BIN="$OUT/go-server"
if [ "$WANT_GO" = 1 ]; then
  (cd "$HERE/go" && go build -o "$GO_BIN" .) || { echo "run.sh: go build failed" >&2; exit 1; }
fi

PIDS=()
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

wait_up() {
  local port="$1" pid="$2"
  for _ in $(seq 1 240); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.5
  done
  return 1
}

RATE_ARGS=()
[ -n "$RATE" ] && RATE_ARGS=(-q "$RATE" --latency-correction)

oha_json() {
  taskset -c "$CLIENT_CPUS" oha -z "$1" -c "$CONNS" ${RATE_ARGS[@]+"${RATE_ARGS[@]}"} --no-tui --disable-compression \
    --output-format json "$2" 2>/dev/null
}

echo "socket bench: server CPUs $SERVER_CPUS (--threads=$THREADS unless mode@threads), client CPUs $CLIENT_CPUS, $RUNS x $DUR interleaved, c=$CONNS${RATE:+, rate=$RATE/s}"
echo "julia: $("${JULIA_CMD[@]}" --version)"
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
[ "$WANT_GO" = 1 ] && echo "go: $(go version)"

declare -A PORT_OF LOG_OF SPID_OF RSS_REST
i=0
for mode in "${MODE_LIST[@]}"; do
  port=$((BASE_PORT + i)); i=$((i + 1))
  # A port already in use would make the new server die with EADDRINUSE while `wait_up` saw the
  # OLD listener answer `/health`, and the run would silently measure whatever that is.
  # A command substitution, not `| grep -q`: under `pipefail` a SIGPIPE'd `ss` would read as
  # "port free".
  if [ -n "$(ss -Hltn "sport = :$port")" ]; then
    echo "run.sh: port $port is already in use; stop that listener or set PORT" >&2
    exit 1
  fi
  log="$OUT/socket-$STAMP-$mode.log"
  name="$(mode_name "$mode")"; threads="$(mode_threads "$mode")"
  project="$ROOT/bench"; served="$name"
  if [ "$name" = baseline ]; then
    [ -n "${BASE_ROOT:-}" ] || { echo "run.sh: baseline needs BASE_ROOT" >&2; exit 1; }
    project="$BASE_ROOT/bench"; served=nitro
  fi
  if [ "$name" = go ]; then
    GOMAXPROCS="$threads" PORT="$port" taskset -c "$SERVER_CPUS" "$GO_BIN" >"$log" 2>&1 &
  else
    MODE="$served" PORT="$port" ACCESS_LOG="${ACCESS_LOG:-0}" PROFILE="${PROFILE:-0}" WARMUP="${WARMUP:-8}" \
      taskset -c "$SERVER_CPUS" "${JULIA_CMD[@]}" --project="$project" --threads="$threads" \
      "$HERE/server.jl" >"$log" 2>&1 &
  fi
  pid=$!
  PIDS+=("$pid")
  if ! wait_up "$port" "$pid"; then
    echo "run.sh: $mode did not come up; tail of $log:" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  PORT_OF[$mode]=$port
  LOG_OF[$mode]=$log
  SPID_OF[$mode]="$(listener_pid "$port")"
  RSS_REST[$mode]="$(status_mib "${SPID_OF[$mode]}" VmRSS)"
done

# Warm every route on every server before anything is recorded: compiles the route and fills
# HTTP.jl's connection paths.
for mode in "${MODE_LIST[@]}"; do
  for route in $ROUTES; do oha_json 3s "http://127.0.0.1:${PORT_OF[$mode]}$route" >/dev/null; done
done

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
gc_snapshot() {   # mode route run phase
  local snap
  if [ "$(mode_name "$1")" = go ]; then
    snap="loglines=$(wc -l <"${LOG_OF[$1]}")"
  else
    snap="$(curl -fsS "http://127.0.0.1:${PORT_OF[$1]}/gc" 2>/dev/null || printf '{}')"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$snap" >> "$GC_TSV"
}

declare -A RPS P50 P99
for run in $(seq 1 "$RUNS"); do
  for route in $ROUTES; do
    for mode in "${MODE_LIST[@]}"; do
      [ "$GC_SNAPSHOTS" = 1 ] && gc_snapshot "$mode" "$route" "$run" before
      js=$(oha_json "$DUR" "http://127.0.0.1:${PORT_OF[$mode]}$route")
      [ "$GC_SNAPSHOTS" = 1 ] && gc_snapshot "$mode" "$route" "$run" after
      [ "$KEEP_JSON" = 1 ] && printf '%s\n' "$js" >"$RAW/r$run-$(slug "$mode")-$(slug "$route").json"
      RPS[$mode$route]+="$(jq -r '.summary.requestsPerSec|floor' <<<"$js") "
      P50[$mode$route]+="$(jq -r '(.latencyPercentiles.p50 // 0) * 1000 | . * 100 | floor / 100' <<<"$js") "
      P99[$mode$route]+="$(jq -r '(.latencyPercentiles.p99 // 0) * 1000 | . * 100 | floor / 100' <<<"$js") "
    done
  done
done

declare -A RSS_AFTER RSS_PEAK
for mode in "${MODE_LIST[@]}"; do
  RSS_AFTER[$mode]="$(status_mib "${SPID_OF[$mode]}" VmRSS)"
  RSS_PEAK[$mode]="$(status_mib "${SPID_OF[$mode]}" VmHWM)"
done

for route in $ROUTES; do
  for mode in "${MODE_LIST[@]}"; do
    read -r -a rps <<<"${RPS[$mode$route]}"
    read -r -a p50 <<<"${P50[$mode$route]}"
    read -r -a p99 <<<"${P99[$mode$route]}"
    med=$(printf '%s\n' "${rps[@]}" | median)
    mn=$(printf '%s\n' "${rps[@]}" | sort -n | head -1)
    mx=$(printf '%s\n' "${rps[@]}" | sort -n | tail -1)
    m50=$(printf '%s\n' "${p50[@]}" | median)
    mp=$(printf '%s\n' "${p99[@]}" | median)
    printf '%-13s %-10s median=%-8s [%s..%s]  p50=%sms p99=%sms  rss=%s/%s/%sMiB  runs: %s\n' \
      "$mode" "$route" "$med" "$mn" "$mx" "$m50" "$mp" \
      "${RSS_REST[$mode]}" "${RSS_AFTER[$mode]}" "${RSS_PEAK[$mode]}" "${rps[*]}"
    logged="${ACCESS_LOG:-0}"; [ "$(mode_name "$mode")" = nitro_log ] && logged=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(mode_name "$mode")" "$(mode_threads "$mode")" \
      "$logged" "$route" "${RATE:-max}" "$med" "$mn" "$mx" "$m50" "$mp" \
      "${RSS_REST[$mode]}" "${RSS_AFTER[$mode]}" "${RSS_PEAK[$mode]}" >> "$RESULT"
  done
done

# With PROFILE set, keep the server up until it has written its report.
if [ "${PROFILE:-0}" != "0" ]; then
  for _ in $(seq 1 120); do grep -q "profile written" "${LOG_OF[${MODE_LIST[0]}]}" && break; sleep 1; done
fi
echo "results: $RESULT"
