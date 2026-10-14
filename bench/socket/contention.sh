#!/usr/bin/env bash
# How badly does a busy `:default` pool delay a cheap request, per thread layout? (#491)
#
# `run.sh` measures throughput. This measures what the interactive thread exists to protect: one
# server per layout, all started up front, each with `WORKERS=1 LAG=1` (see server.jl). Every
# round runs every scenario against every layout in turn (interleaved, as in run.sh), and in each
# one `/health` is probed at a fixed rate PROBE_RATE with `--latency-correction` while something
# else keeps the default threads busy:
#
#   idle       nothing else -- the floor
#   cpu        CPU_CONNS connections hammer `/cpu`, a handler that burns CPU_MS without yielding
#   burst<K>   `/burst?n=K` submits K Workers jobs that each burn JOB_MS without yielding, then the
#              probe starts at once (e.g. burst8, burst64)
#   burst<K>q  the same K jobs through a queue of concurrency BURST_K (#513's bulkhead)
#   ...cp<MS>  either burst, each job calling `checkpoint!` every MS ms (e.g. burst64cp5, burst64qcp5)
#
# Each row reports `/health` p50/p99/max and its success rate, the `/lag` probe's p50/p99/max (how
# late a 10 ms `sleep` on the `:default` pool woke during the window, the delay a `Timer`-driven
# deadline such as a Workers timeout sees), and for `cpu` the `/cpu` throughput -- medians over
# ROUNDS. Pinning and JULIA work as in run.sh.
#
# Usage: bench/socket/contention.sh [layouts] [rounds] [duration]
#   bench/socket/contention.sh "8,1 6,2 8,0" 5 8s
#   SCENARIOS="idle cpu burst8 burst64" CPU_MS=50 bench/socket/contention.sh
#   JULIA="julia +1.12" bench/socket/contention.sh
#   SCENARIOS="idle burst64 burst64q burst64cp5 burst64qcp5" bench/socket/contention.sh "8,1 6,2"
#
# Results: one TSV per invocation under bench/results/ (gitignored).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

LAYOUTS="${1:-8,1 6,2 8,0}"
ROUNDS="${2:-5}"
DUR="${3:-8s}"
MODE="${MODE:-nitro}"
SCENARIOS="${SCENARIOS:-idle cpu burst8 burst64}"
PROBE_RATE="${PROBE_RATE:-200}"
PROBE_CONNS="${PROBE_CONNS:-4}"
CPU_CONNS="${CPU_CONNS:-16}"
CPU_MS="${CPU_MS:-50}"
JOB_MS="${JOB_MS:-500}"
BASE_PORT="${PORT:-8180}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,3,6,7,8,9}"
CLIENT_CPUS="${CLIENT_CPUS:-4,5,10,11}"
read -r -a JULIA_CMD <<<"${JULIA:-julia}"

for tool in oha taskset jq curl "${JULIA_CMD[0]}" ss; do
  command -v "$tool" >/dev/null || { echo "contention.sh: $tool not on PATH" >&2; exit 1; }
done
read -r -a LAYOUT_LIST <<<"$LAYOUTS"
read -r -a SCENARIO_LIST <<<"$SCENARIOS"
# Whole seconds only: the `cpu` load runs for DUR + 2 s, computed in shell arithmetic.
[[ $DUR =~ ^[0-9]+s$ ]] || { echo "contention.sh: duration must be whole seconds, e.g. 8s" >&2; exit 1; }
for scenario in "${SCENARIO_LIST[@]}"; do
  case "$scenario" in
    idle|cpu) ;;
    burst*)
      [[ $scenario =~ ^burst[0-9]+q?(cp[0-9]+)?$ ]] || { echo "contention.sh: unknown scenario $scenario" >&2; exit 1; }
      # Only the Nitro modes serve `/burst`; a bare mode would label an idle run a burst.
      [[ $MODE == nitro* ]] || { echo "contention.sh: $scenario needs a nitro MODE" >&2; exit 1; } ;;
    *) echo "contention.sh: unknown scenario $scenario" >&2; exit 1 ;;
  esac
done

OUT="$ROOT/bench/results"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/contention-$STAMP.tsv"
printf 'mode\tthreads\tscenario\thealth_p50_ms\thealth_p99_ms\thealth_max_ms\thealth_success\tlag_p50_ms\tlag_p99_ms\tlag_max_ms\tlag_starved\tcpu_rps\n' > "$RESULT"

median() { sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

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

echo "contention bench: $MODE, layouts [$LAYOUTS], scenarios [$SCENARIOS], $ROUNDS x $DUR interleaved"
echo "  probe /health at ${PROBE_RATE}/s over $PROBE_CONNS conns; cpu: $CPU_CONNS conns x ${CPU_MS} ms; jobs ${JOB_MS} ms"
echo "  server CPUs $SERVER_CPUS, client CPUs $CLIENT_CPUS; julia: $("${JULIA_CMD[@]}" --version)"
echo "  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"

declare -A PORT_OF
i=0
for layout in "${LAYOUT_LIST[@]}"; do
  port=$((BASE_PORT + i)); i=$((i + 1))
  if [ -n "$(ss -Hltn "sport = :$port")" ]; then
    echo "contention.sh: port $port is already in use; stop that listener or set PORT" >&2
    exit 1
  fi
  log="$OUT/contention-$STAMP-$layout.log"
  MODE="$MODE" PORT="$port" WORKERS=1 LAG=1 CPU_MS="$CPU_MS" JOB_MS="$JOB_MS" ${BURST_K:+BURST_K="$BURST_K"} \
    taskset -c "$SERVER_CPUS" "${JULIA_CMD[@]}" --project="$ROOT/bench" --threads="$layout" \
    "$HERE/server.jl" >"$log" 2>&1 &
  pid=$!
  PIDS+=("$pid")
  if ! wait_up "$port" "$pid"; then
    echo "contention.sh: $layout did not come up; tail of $log:" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  PORT_OF[$layout]=$port
done

# `burst64qcp5` -> 64 and `/burst?n=64&queue=1&cp=5` (#513).
burst_n() { local s="${1#burst}"; echo "${s%%[!0-9]*}"; }
burst_query() {
  local q="/burst?n=$(burst_n "$1")"
  [[ $1 =~ ^burst[0-9]+q ]] && q+="&queue=1"
  [[ $1 =~ cp([0-9]+)$ ]] && q+="&cp=${BASH_REMATCH[1]}"
  echo "$q"
}

oha_probe() {   # duration url -> oha JSON
  taskset -c "$CLIENT_CPUS" oha -z "$1" -c "$PROBE_CONNS" -q "$PROBE_RATE" --latency-correction \
    --no-tui --disable-compression --output-format json "$2" 2>/dev/null
}
ms() { jq -r "(.$1 // 0) * 1000 | . * 100 | floor / 100"; }

# Warm every route the scenarios touch, including one small burst, so nothing measured compiles.
for layout in "${LAYOUT_LIST[@]}"; do
  base="http://127.0.0.1:${PORT_OF[$layout]}"
  taskset -c "$CLIENT_CPUS" oha -z 3s -c 4 --no-tui "$base/health" >/dev/null 2>&1
  taskset -c "$CLIENT_CPUS" oha -n 20 -c 4 --no-tui "$base/cpu" >/dev/null 2>&1
  curl -fsS -o /dev/null "$base/burst?n=2"; sleep 2; curl -fsS -o /dev/null "$base/lag"
done

declare -A H50 H99 HMAX HOK L50 L99 LMAX STARVED CPU
for _ in $(seq 1 "$ROUNDS"); do
  for scenario in "${SCENARIO_LIST[@]}"; do
    for layout in "${LAYOUT_LIST[@]}"; do
      base="http://127.0.0.1:${PORT_OF[$layout]}"
      key="$layout|$scenario"
      curl -fsS -o /dev/null "$base/lag"              # reset the lag window
      bg=""; cpu_json=""
      case "$scenario" in
        idle) ;;
        cpu)
          cpu_json="$(mktemp)"
          taskset -c "$CLIENT_CPUS" oha -z "$((${DUR%s} + 2))s" -c "$CPU_CONNS" --no-tui \
            --output-format json "$base/cpu" >"$cpu_json" 2>/dev/null &
          bg=$!
          sleep 1 ;;
        burst*)
          burst_url="$(burst_query "$scenario")"
          curl -fsS -o /dev/null "$base$burst_url" ||
            { echo "contention.sh: $layout refused $burst_url" >&2; exit 1; } ;;
      esac
      js="$(oha_probe "$DUR" "$base/health")"
      [ -n "$bg" ] && wait "$bg"
      lag="$(curl -fsS "$base/lag")"
      H50[$key]+="$(ms latencyPercentiles.p50 <<<"$js") "
      H99[$key]+="$(ms latencyPercentiles.p99 <<<"$js") "
      HMAX[$key]+="$(ms summary.slowest <<<"$js") "
      HOK[$key]+="$(jq -r '.summary.successRate // 0' <<<"$js") "
      # A window with no samples means the probe never woke at all: the worst starvation, not
      # zero lag. Count it (`starved` in the row) instead of folding a 0 into the medians, where it
      # would read as the best result.
      if [ "$(jq -r '.n' <<<"$lag")" = 0 ]; then
        STARVED[$key]=$(( ${STARVED[$key]:-0} + 1 ))
      else
        L50[$key]+="$(jq -r '.p50' <<<"$lag") "
        L99[$key]+="$(jq -r '.p99' <<<"$lag") "
        LMAX[$key]+="$(jq -r '.max' <<<"$lag") "
      fi
      if [ -n "$cpu_json" ]; then
        CPU[$key]+="$(jq -r '.summary.requestsPerSec | floor' <"$cpu_json") "
        rm -f "$cpu_json"
      fi
      # Let a burst's jobs drain before the next layout is measured: every server is pinned to the
      # same cores, so leftover jobs here would load the next one. K jobs over at least 4 threads.
      case "$scenario" in burst*) sleep $(( ($(burst_n "$scenario") * ${JOB_MS%.*} / 4000) + 2 )) ;; esac
    done
  done
done

med_of() { local v="$1"; [ -z "$v" ] && { printf -- '-'; return; }; printf '%s\n' $v | median; }

for scenario in "${SCENARIO_LIST[@]}"; do
  for layout in "${LAYOUT_LIST[@]}"; do
    key="$layout|$scenario"
    row=("$MODE" "$layout" "$scenario"
         "$(med_of "${H50[$key]}")" "$(med_of "${H99[$key]}")" "$(med_of "${HMAX[$key]}")"
         "$(med_of "${HOK[$key]}")"
         "$(med_of "${L50[$key]:-}")" "$(med_of "${L99[$key]:-}")" "$(med_of "${LMAX[$key]:-}")"
         "${STARVED[$key]:-0}"
         "$(med_of "${CPU[$key]:-}")")
    printf '%-6s %-9s health p50=%sms p99=%sms max=%sms ok=%s | lag p50=%sms p99=%sms max=%sms starved=%s | cpu_rps=%s\n' \
      "${row[1]}" "${row[2]}" "${row[3]}" "${row[4]}" "${row[5]}" "${row[6]}" "${row[7]}" "${row[8]}" "${row[9]}" "${row[10]}" "${row[11]}"
    (IFS=$'\t'; printf '%s\n' "${row[*]}") >> "$RESULT"
  done
done
echo "results: $RESULT"
