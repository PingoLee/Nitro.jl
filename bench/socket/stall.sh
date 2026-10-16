#!/usr/bin/env bash
# How few CPU-bound requests does it take to stall the server? (#467)
#
# Julia's scheduler is cooperative: a handler that computes without yielding holds its `:default`
# thread until it returns. This keeps exactly K such requests in flight (`oha -c K` on `/cpu`,
# each burning CPU_MS) while a second `oha` saturates `/plaintext`, and reports `/plaintext`'s
# throughput and p50/p99 for every K. Expected: little change while K is below the number of
# default threads, then a collapse.
#
# Variants -- the same CPU work three ways, then the two password checks (all servers are started
# with WORKERS=1, see server.jl):
#
#   cpu        `/cpu`: the handler computes, never yields. K in flight, closed loop.
#   cpu_yield  `/cpu_yield`: the same, calling `yield()` every YIELD_MS. K in flight, closed loop.
#   cpu_job    `/cpu_job`: the handler submits the work to a Workers queue of concurrency BURST_K
#              (default nthreads(:default) - 2) and answers 202. Offered at the rate that keeps K
#              computations busy if nothing queued -- K * 1000 / CPU_MS per second -- so it is the
#              same CPU demand as `cpu`; past BURST_K the excess waits in the queue, not on a
#              thread, and once the queue's buffer is full a submit is refused with 503. The
#              `load_2xx` column is the share accepted. Each pass drains the queue (`/jobs`)
#              before the next one starts.
#   login         `/login`: one `check_password` against a pbkdf2_sha256 hash at the default cost
#                 (#587), the computing handler every app has. K in flight, closed loop.
#   login_bcrypt  `/login_bcrypt`: the same against a bcrypt hash at the default cost.
#                 The Nitro servers get LOGIN=1 only when one of the two is requested.
#
# `base` (K = 0) is `/plaintext` alone. The `go` mode (socket/go/) runs `base` and `cpu` only: Go
# preempts a computing goroutine, so it is the reference for what preemption buys, and it has no
# Workers. Modes, `mode@threads`, pinning, JULIA and the Go build work as in run.sh.
#
# Usage: bench/socket/stall.sh [modes] [rounds] [duration]
#   bench/socket/stall.sh "nitro go" 3 6s
#   KS="1 2 4 8 16" VARIANTS="cpu cpu_yield cpu_job" CPU_MS=200 bench/socket/stall.sh
#   VARIANTS="login login_bcrypt" bench/socket/stall.sh "nitro go" 3 6s
#
# Results: one TSV per invocation under bench/results/ (gitignored).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

MODES="${1:-nitro go}"
ROUNDS="${2:-3}"
DUR="${3:-6s}"
KS="${KS:-1 2 4 8 16}"
VARIANTS="${VARIANTS:-cpu cpu_yield cpu_job}"
CPU_MS="${CPU_MS:-200}"
YIELD_MS="${YIELD_MS:-2}"
CONNS="${CONNS:-50}"
THREADS="${THREADS:-8}"
BASE_PORT="${PORT:-8280}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,3,6,7,8,9}"
CLIENT_CPUS="${CLIENT_CPUS:-4,5,10,11}"
read -r -a JULIA_CMD <<<"${JULIA:-julia}"
read -r -a MODE_LIST <<<"$MODES"
read -r -a K_LIST <<<"$KS"
read -r -a VARIANT_LIST <<<"$VARIANTS"

[[ $DUR =~ ^[0-9]+s$ ]] || { echo "stall.sh: duration must be whole seconds, e.g. 6s" >&2; exit 1; }
for tool in oha taskset jq curl nproc "${JULIA_CMD[0]}" ss; do
  command -v "$tool" >/dev/null || { echo "stall.sh: $tool not on PATH" >&2; exit 1; }
done
WANT_GO=0
for mode in "${MODE_LIST[@]}"; do
  case "${mode%%@*}" in
    go) WANT_GO=1 ;;
    nitro) ;;
    *) echo "stall.sh: mode $mode: expected nitro or go" >&2; exit 1 ;;
  esac
done
LOGIN=0
for v in "${VARIANT_LIST[@]}"; do
  case "$v" in
    cpu|cpu_yield|cpu_job) ;;
    login|login_bcrypt) LOGIN=1 ;;
    *) echo "stall.sh: unknown variant $v" >&2; exit 1 ;;
  esac
done
if [ "$WANT_GO" = 1 ]; then
  command -v go >/dev/null || { echo "stall.sh: go not on PATH (needed by the go mode)" >&2; exit 1; }
fi

OUT="$ROOT/bench/results"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/stall-$STAMP.tsv"
printf 'mode\tthreads\tvariant\tk\tplaintext_rps\tplaintext_p50_ms\tplaintext_p99_ms\tload_rps\tload_2xx\n' > "$RESULT"

median() { sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }
SERVER_NCPU="$(taskset -c "$SERVER_CPUS" nproc)"
mode_name()    { printf '%s' "${1%%@*}"; }
mode_threads() {
  case "$1" in
    *@*) printf '%s' "${1#*@}" ;;
    go)  printf '%s' "$SERVER_NCPU" ;;
    *)   printf '%s' "$THREADS" ;;
  esac
}

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

GO_BIN="$OUT/go-server"
if [ "$WANT_GO" = 1 ]; then
  (cd "$HERE/go" && go build -o "$GO_BIN" .) || { echo "stall.sh: go build failed" >&2; exit 1; }
fi

echo "stall bench: modes [$MODES], K [$KS], variants [$VARIANTS], $ROUNDS x $DUR interleaved"
echo "  /cpu burns ${CPU_MS} ms (cpu_yield yields every ${YIELD_MS} ms); /plaintext at c=$CONNS"
echo "  server CPUs $SERVER_CPUS, client CPUs $CLIENT_CPUS; julia: $("${JULIA_CMD[@]}" --version)"
[ "$WANT_GO" = 1 ] && echo "  go: $(go version)"
echo "  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"

declare -A PORT_OF
i=0
for mode in "${MODE_LIST[@]}"; do
  port=$((BASE_PORT + i)); i=$((i + 1))
  if [ -n "$(ss -Hltn "sport = :$port")" ]; then
    echo "stall.sh: port $port is already in use; stop that listener or set PORT" >&2
    exit 1
  fi
  log="$OUT/stall-$STAMP-$mode.log"
  threads="$(mode_threads "$mode")"
  if [ "$(mode_name "$mode")" = go ]; then
    GOMAXPROCS="$threads" PORT="$port" CPU_MS="$CPU_MS" taskset -c "$SERVER_CPUS" "$GO_BIN" >"$log" 2>&1 &
  else
    # `env`, because an assignment produced by an expansion is not an assignment to the shell.
    env MODE=nitro PORT="$port" WORKERS=1 LOGIN="$LOGIN" CPU_MS="$CPU_MS" YIELD_MS="$YIELD_MS" ${BURST_K:+"BURST_K=$BURST_K"} \
      taskset -c "$SERVER_CPUS" "${JULIA_CMD[@]}" --project="$ROOT/bench" --threads="$threads" \
      "$HERE/server.jl" >"$log" 2>&1 &
  fi
  pid=$!
  PIDS+=("$pid")
  if ! wait_up "$port" "$pid"; then
    echo "stall.sh: $mode did not come up; tail of $log:" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  PORT_OF[$mode]=$port
done

# A pass applies to a mode unless it is a Julia-only variant on the go mode.
applies() { [ "$(mode_name "$1")" != go ] || [ "$2" = base ] || [ "$2" = cpu ]; }

drain_jobs() {   # base url: wait until no /cpu_job job is pending (at most 120 s)
  for _ in $(seq 1 240); do
    [ "$(curl -fsS "$1/jobs" 2>/dev/null)" = 0 ] && return 0
    sleep 0.5
  done
  echo "stall.sh: $1 still has jobs pending after 120 s" >&2
}

# Warm every route each mode will see, so nothing measured compiles.
for mode in "${MODE_LIST[@]}"; do
  base="http://127.0.0.1:${PORT_OF[$mode]}"
  taskset -c "$CLIENT_CPUS" oha -z 3s -c "$CONNS" --no-tui "$base/plaintext" >/dev/null 2>&1
  for v in "${VARIANT_LIST[@]}"; do
    applies "$mode" "$v" || continue
    taskset -c "$CLIENT_CPUS" oha -n 8 -c 2 --no-tui "$base/$v" >/dev/null 2>&1
  done
  [ "$(mode_name "$mode")" = go ] || drain_jobs "$base"
done

PASSES=("base|0")
for v in "${VARIANT_LIST[@]}"; do for k in "${K_LIST[@]}"; do PASSES+=("$v|$k"); done; done

# The share of the load's requests answered 2xx. oha's own successRate counts any response, so a
# full queue's 503 -- the cpu_job backpressure -- would read as success. The request oha cuts at
# its own deadline is not the server's answer, so it is left out of both sides.
TWO_XX='([.statusCodeDistribution // {} | to_entries[] | select(.key | startswith("2")) | .value] | add // 0) as $ok
  | (([.statusCodeDistribution // {} | to_entries[] | .value] | add // 0)
     + ([.errorDistribution // {} | to_entries[] | select(.key != "aborted due to deadline") | .value]
        | add // 0)) as $all
  | if $all == 0 then 0 else ($ok / $all * 1000 | floor / 1000) end'

LOAD_DUR="$(( ${DUR%s} + 2 ))s"
declare -A RPS P50 P99 LRPS LOK
for _ in $(seq 1 "$ROUNDS"); do
  for pass in "${PASSES[@]}"; do
    variant="${pass%|*}"; k="${pass#*|}"
    for mode in "${MODE_LIST[@]}"; do
      applies "$mode" "$variant" || continue
      base="http://127.0.0.1:${PORT_OF[$mode]}"
      key="$mode|$variant|$k"
      bg=""; load_json=""
      if [ "$variant" != base ]; then
        load_json="$(mktemp)"
        rate=()
        [ "$variant" = cpu_job ] && rate=(-q "$(awk -v k="$k" -v ms="$CPU_MS" 'BEGIN { printf "%.2f", k * 1000 / ms }')")
        taskset -c "$CLIENT_CPUS" oha -z "$LOAD_DUR" -c "$k" ${rate[@]+"${rate[@]}"} --no-tui \
          --output-format json "$base/$variant" >"$load_json" 2>/dev/null &
        bg=$!
        sleep 1
      fi
      js="$(taskset -c "$CLIENT_CPUS" oha -z "$DUR" -c "$CONNS" --no-tui --disable-compression \
              --output-format json "$base/plaintext" 2>/dev/null)"
      RPS[$key]+="$(jq -r '.summary.requestsPerSec | floor' <<<"$js") "
      P50[$key]+="$(jq -r '(.latencyPercentiles.p50 // 0) * 1000 | . * 100 | floor / 100' <<<"$js") "
      P99[$key]+="$(jq -r '(.latencyPercentiles.p99 // 0) * 1000 | . * 100 | floor / 100' <<<"$js") "
      if [ -n "$bg" ]; then
        wait "$bg"
        LRPS[$key]+="$(jq -r '.summary.requestsPerSec * 100 | floor / 100' <"$load_json") "
        LOK[$key]+="$(jq -r "$TWO_XX" <"$load_json") "
        rm -f "$load_json"
        # Requests oha abandoned at its deadline may still be computing; let them finish, and
        # drain any queued jobs, so this pass cannot load the next one.
        sleep "$(awk -v ms="$CPU_MS" -v k="$k" 'BEGIN { printf "%.1f", 0.5 + ms * k / 1000 / 4 }')"
        [ "$variant" = cpu_job ] && drain_jobs "$base"
      fi
    done
  done
done

med_of() { local v="$1"; [ -z "$v" ] && { printf -- '-'; return; }; printf '%s\n' $v | median; }

for pass in "${PASSES[@]}"; do
  variant="${pass%|*}"; k="${pass#*|}"
  for mode in "${MODE_LIST[@]}"; do
    applies "$mode" "$variant" || continue
    key="$mode|$variant|$k"
    row=("$(mode_name "$mode")" "$(mode_threads "$mode")" "$variant" "$k"
         "$(med_of "${RPS[$key]}")" "$(med_of "${P50[$key]}")" "$(med_of "${P99[$key]}")"
         "$(med_of "${LRPS[$key]:-}")" "$(med_of "${LOK[$key]:-}")")
    printf '%-10s %-9s k=%-3s plaintext rps=%-8s p50=%sms p99=%sms | load rps=%s 2xx=%s\n' \
      "$mode" "${row[2]}" "${row[3]}" "${row[4]}" "${row[5]}" "${row[6]}" "${row[7]}" "${row[8]}"
    (IFS=$'\t'; printf '%s\n' "${row[*]}") >> "$RESULT"
  done
done
echo "results: $RESULT"
