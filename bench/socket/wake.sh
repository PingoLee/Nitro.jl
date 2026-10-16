#!/usr/bin/env bash
# Does a parked handler wake while every `:default` thread runs a `yield()`ing handler? (#598)
#
# On Julia 1.13.0-rc3 through 1.13.2, a task in `sleep` does not wake while every `:default`
# thread runs a busy loop that calls `yield()`, as long as its own `Timer` is the only live libuv
# handle in the process (JuliaLang/julia#63882, #586). This asks whether a Nitro server shows it.
# server.jl's LAG=1 probe is a `:default` task in a `sleep(0.01)` loop. K requests of `/cpu_yield`
# (SPIN_MS each, `yield()` every YIELD_MS), K = THREADS by default, keep every default thread
# busy. `/lag` then reports how late the probe woke over the pass. A stall reads as a max near
# SPIN_MS; no stall reads as a few ms.
#
# Each config is `<julia channel>/<park>/<guard>`, with PARK and GUARD as in server.jl:
#   timer/0   server.jl's usual shape: parked on a never-firing Timer, which is itself a guard
#   event/0   no Timer of the bench's own: the shape of a `serve()` with no janitor
#   event/1   the same plus `Timer(typemax(Int32))`, the workaround #598 proposes for `serve()`
# Every pass runs twice: `quiet` (only the K yielding requests) and `traffic` (`/plaintext` at
# c=CONNS alongside), in case busy sockets keep the event loop awake on their own.
#
# Usage: bench/socket/wake.sh [rounds]
#   CONFIGS="1.12/event/0 1.13.2/event/0 1.13.2/event/1 1.13.2/timer/0" bench/socket/wake.sh 3
#
# Results: one TSV per invocation under bench/results/ (gitignored).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

ROUNDS="${1:-3}"
CONFIGS="${CONFIGS:-1.12/event/0 1.13.2/event/0 1.13.2/event/1 1.13.2/timer/0}"
SPIN_MS="${SPIN_MS:-1500}"
YIELD_MS="${YIELD_MS:-1}"
THREADS="${THREADS:-8}"
K="${K:-$THREADS}"
CONNS="${CONNS:-50}"
BASE_PORT="${PORT:-8380}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,3,6,7,8,9}"
CLIENT_CPUS="${CLIENT_CPUS:-4,5,10,11}"
read -r -a CONFIG_LIST <<<"$CONFIGS"

for tool in oha taskset jq curl julia ss; do
  command -v "$tool" >/dev/null || { echo "wake.sh: $tool not on PATH" >&2; exit 1; }
done
for c in "${CONFIG_LIST[@]}"; do
  [[ $c =~ ^[^/]+/(timer|event)/[01]$ ]] || { echo "wake.sh: config $c: expected <channel>/<timer|event>/<0|1>" >&2; exit 1; }
done

OUT="$ROOT/bench/results"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/wake-$STAMP.tsv"
printf 'julia\tpark\tguard\tload\tround\tn\tp50_ms\tp99_ms\tmax_ms\n' > "$RESULT"

PIDS=()
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

wait_up() {
  local port="$1" pid="$2"
  for _ in $(seq 1 600); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.5
  done
  return 1
}

echo "wake bench: configs [$CONFIGS], K=$K /cpu_yield of ${SPIN_MS} ms (yield every ${YIELD_MS} ms), $ROUNDS rounds"
echo "  server CPUs $SERVER_CPUS at --threads=$THREADS, client CPUs $CLIENT_CPUS"
echo "  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"

declare -A PORT_OF
i=0
for c in "${CONFIG_LIST[@]}"; do
  IFS=/ read -r ch park guard <<<"$c"
  port=$((BASE_PORT + i)); i=$((i + 1))
  if [ -n "$(ss -Hltn "sport = :$port")" ]; then
    echo "wake.sh: port $port is already in use; stop that listener or set PORT" >&2
    exit 1
  fi
  echo "  $c: $(julia +"$ch" --version)"
  log="$OUT/wake-$STAMP-${c//\//_}.log"
  env MODE=nitro PORT="$port" LAG=1 PARK="$park" GUARD="$guard" CPU_MS="$SPIN_MS" YIELD_MS="$YIELD_MS" \
    taskset -c "$SERVER_CPUS" julia +"$ch" --project="$ROOT/bench" --threads="$THREADS" \
    "$HERE/server.jl" >"$log" 2>&1 &
  pid=$!
  PIDS+=("$pid")
  if ! wait_up "$port" "$pid"; then
    echo "wake.sh: $c did not come up; tail of $log:" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  PORT_OF[$c]=$port
done

# Warm every route, so nothing measured compiles.
for c in "${CONFIG_LIST[@]}"; do
  base="http://127.0.0.1:${PORT_OF[$c]}"
  taskset -c "$CLIENT_CPUS" oha -z 2s -c "$CONNS" --no-tui "$base/plaintext" >/dev/null 2>&1
  taskset -c "$CLIENT_CPUS" oha -n 2 -c 2 --no-tui "$base/cpu_yield" >/dev/null 2>&1
  curl -fsS -o /dev/null "$base/lag"
done

LOAD_DUR="$(( SPIN_MS / 1000 + 3 ))s"
for r in $(seq 1 "$ROUNDS"); do
  for load in quiet traffic; do
    for c in "${CONFIG_LIST[@]}"; do
      IFS=/ read -r ch park guard <<<"$c"
      base="http://127.0.0.1:${PORT_OF[$c]}"
      curl -fsS -o /dev/null "$base/lag"   # resets the probe's samples
      bg=""
      if [ "$load" = traffic ]; then
        taskset -c "$CLIENT_CPUS" oha -z "$LOAD_DUR" -c "$CONNS" --no-tui "$base/plaintext" >/dev/null 2>&1 &
        bg=$!
        sleep 0.5
      fi
      taskset -c "$CLIENT_CPUS" oha -n "$K" -c "$K" --no-tui "$base/cpu_yield" >/dev/null 2>&1
      js="$(curl -fsS "$base/lag")"
      [ -n "$bg" ] && wait "$bg"
      row="$(jq -r --arg c "$ch" --arg p "$park" --arg g "$guard" --arg l "$load" --arg r "$r" \
        '[$c, $p, $g, $l, $r, .n, (.p50 // "-"), (.p99 // "-"), (.max // "-")] | @tsv' <<<"$js")"
      printf '%s\n' "$row" >> "$RESULT"
      printf '%-16s %-8s round %s  /lag n=%s p50=%s p99=%s max=%s ms\n' "$c" "$load" "$r" \
        "$(jq -r .n <<<"$js")" "$(jq -r '.p50 // "-"' <<<"$js")" "$(jq -r '.p99 // "-"' <<<"$js")" "$(jq -r '.max // "-"' <<<"$js")"
      sleep 1
    done
  done
done
echo "results: $RESULT"
