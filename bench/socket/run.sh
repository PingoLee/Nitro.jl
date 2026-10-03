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
#   THREADS=8,2 bench/socket/run.sh            # two interactive threads
#   PROFILE=10 bench/socket/run.sh nitro 1 20s # one mode only; see server.jl
#   BASE_ROOT=/path/to/other/checkout bench/socket/run.sh "baseline nitro"
#
# `baseline` is `nitro` served from the checkout at BASE_ROOT (its own bench/ env, instantiated),
# so a change can be A/B'd against the code it replaces in the same interleaved run.
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

for tool in oha taskset jq curl julia ss; do
  command -v "$tool" >/dev/null || { echo "run.sh: $tool not on PATH" >&2; exit 1; }
done
read -r -a MODE_LIST <<<"$MODES"
if [ "${PROFILE:-0}" != "0" ] && [ "${#MODE_LIST[@]}" -ne 1 ]; then
  echo "run.sh: PROFILE takes exactly one mode" >&2; exit 1
fi

OUT="$ROOT/bench/results"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/socket-$STAMP.tsv"
printf 'mode\tthreads\taccess_log\troute\tmedian_rps\tmin_rps\tmax_rps\tmedian_p99_ms\n' > "$RESULT"

median() { sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
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

oha_json() {
  taskset -c "$CLIENT_CPUS" oha -z "$1" -c "$CONNS" --no-tui --disable-compression \
    --output-format json "$2" 2>/dev/null
}

echo "socket bench: server CPUs $SERVER_CPUS (--threads=$THREADS), client CPUs $CLIENT_CPUS, $RUNS x $DUR interleaved, c=$CONNS"
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"

declare -A PORT_OF LOG_OF
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
  project="$ROOT/bench"; served="$mode"
  if [ "$mode" = baseline ]; then
    [ -n "${BASE_ROOT:-}" ] || { echo "run.sh: baseline needs BASE_ROOT" >&2; exit 1; }
    project="$BASE_ROOT/bench"; served=nitro
  fi
  MODE="$served" PORT="$port" ACCESS_LOG="${ACCESS_LOG:-0}" PROFILE="${PROFILE:-0}" WARMUP="${WARMUP:-8}" \
    taskset -c "$SERVER_CPUS" julia --project="$project" --threads="$THREADS" \
    "$HERE/server.jl" >"$log" 2>&1 &
  pid=$!
  PIDS+=("$pid")
  if ! wait_up "$port" "$pid"; then
    echo "run.sh: $mode did not come up; tail of $log:" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  PORT_OF[$mode]=$port
  LOG_OF[$mode]=$log
done

# Warm every route on every server before anything is recorded: compiles the route and fills
# HTTP.jl's connection paths.
for mode in "${MODE_LIST[@]}"; do
  for route in $ROUTES; do oha_json 3s "http://127.0.0.1:${PORT_OF[$mode]}$route" >/dev/null; done
done

declare -A RPS P99
for _ in $(seq 1 "$RUNS"); do
  for route in $ROUTES; do
    for mode in "${MODE_LIST[@]}"; do
      js=$(oha_json "$DUR" "http://127.0.0.1:${PORT_OF[$mode]}$route")
      RPS[$mode$route]+="$(jq -r '.summary.requestsPerSec|floor' <<<"$js") "
      P99[$mode$route]+="$(jq -r '(.latencyPercentiles.p99 // 0) * 1000 | . * 100 | floor / 100' <<<"$js") "
    done
  done
done

for route in $ROUTES; do
  for mode in "${MODE_LIST[@]}"; do
    read -r -a rps <<<"${RPS[$mode$route]}"
    read -r -a p99 <<<"${P99[$mode$route]}"
    med=$(printf '%s\n' "${rps[@]}" | median)
    mn=$(printf '%s\n' "${rps[@]}" | sort -n | head -1)
    mx=$(printf '%s\n' "${rps[@]}" | sort -n | tail -1)
    mp=$(printf '%s\n' "${p99[@]}" | median)
    printf '%-13s %-10s median=%-8s [%s..%s]  p99=%sms  runs: %s\n' \
      "$mode" "$route" "$med" "$mn" "$mx" "$mp" "${rps[*]}"
    logged="${ACCESS_LOG:-0}"; [ "$mode" = nitro_log ] && logged=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$THREADS" "$logged" "$route" \
      "$med" "$mn" "$mx" "$mp" >> "$RESULT"
  done
done

# With PROFILE set, keep the server up until it has written its report.
if [ "${PROFILE:-0}" != "0" ]; then
  for _ in $(seq 1 120); do grep -q "profile written" "${LOG_OF[${MODE_LIST[0]}]}" && break; sleep 1; done
fi
echo "results: $RESULT"
