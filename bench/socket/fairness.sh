#!/usr/bin/env bash
# How evenly does each server serve C connections at once? (#590 H3)
#
# At c=500 on `/aggregate?n=100000&op=groupby`, Nitro's p99 was ~2 s against Go's ~163 ms at
# similar throughput, while GC took 3-5% of the window. Pooled percentiles cannot say whether
# every connection waits a little or a few wait a lot. `go/fairness` keeps C keep-alive
# connections busy, one request at a time each, and reports requests per connection (min, p1,
# p10, median, Jain's index), every request's latency and each connection's longest wait.
#
# Modes as in run.sh: `nitro` (`serve()`), `bare_spawn` (HTTP.jl + one `Threads.@spawn` per
# request, no Nitro: is the unevenness Nitro's or the runtime's?), `bare_nospawn`, `bare_pool`,
# `go`. `mode@threads` starts that server with its own `--threads` (`nitro@8,0 nitro@6,2`, #618);
# a bare name takes THREADS. Rounds are interleaved.
#
# PROBE=1 (#618) starts the Julia servers with PROBE=1 and runs the client with `-stamp`, then
# keeps, per run, the client's per-request trace and the server's `/probe` rows under the raw
# directory; `probe_report.jl <raw dir>` joins them into where each slow request's time went.
#
# Usage: bench/socket/fairness.sh [modes] [rounds] [duration]
#   ROUTE="/aggregate?n=100000&op=groupby" CONNS=500 bench/socket/fairness.sh "nitro bare_spawn go" 3 8s
#   PROBE=1 bench/socket/fairness.sh "nitro bare_spawn bare_nospawn bare_pool" 3 8s
#
# Results: bench/results/fairness-<stamp>.tsv (one line per run) and the JSON reports beside it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

MODES="${1:-nitro bare_spawn go}"
ROUNDS="${2:-3}"
DUR="${3:-8s}"
ROUTE="${ROUTE:-/aggregate?n=100000&op=groupby}"
CONNS="${CONNS:-500}"
THREADS="${THREADS:-8}"
AGG_ROWS="${AGG_ROWS:-10000000}"
BASE_PORT="${PORT:-8880}"
PROBE="${PROBE:-0}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,3,6,7,8,9}"
CLIENT_CPUS="${CLIENT_CPUS:-4,5,10,11}"
read -r -a JULIA_CMD <<<"${JULIA:-julia}"
read -r -a MODE_LIST <<<"$MODES"
for tool in go oha jq curl taskset ss "${JULIA_CMD[0]}"; do
  command -v "$tool" >/dev/null || { echo "fairness.sh: $tool not on PATH" >&2; exit 1; }
done

OUT="$ROOT/bench/results"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/fairness-$STAMP.tsv"
RAW="$OUT/fairness-$STAMP-raw"; mkdir -p "$RAW"
GO_BIN="$OUT/go-server"; CLIENT="$OUT/fairness"
(cd "$HERE/go" && go build -o "$GO_BIN" . && go build -o "$CLIENT" ./fairness) || { echo "fairness.sh: go build failed" >&2; exit 1; }

# `nitro@8,0` -> name `nitro`, threads `8,0`, file label `nitro-8_0`.
mode_name()    { printf '%s' "${1%%@*}"; }
mode_threads() { case "$1" in *@*) printf '%s' "${1#*@}" ;; *) printf '%s' "$THREADS" ;; esac; }
mode_label()   { printf '%s' "$1" | tr '@,' '-_'; }

PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; wait 2>/dev/null' EXIT
declare -A PORT_OF
i=0
for mode in "${MODE_LIST[@]}"; do
  port=$((BASE_PORT + i)); i=$((i + 1))
  [ -n "$(ss -Hltn "sport = :$port")" ] && { echo "fairness.sh: port $port in use" >&2; exit 1; }
  log="$OUT/fairness-$STAMP-$(mode_label "$mode").log"
  if [ "$(mode_name "$mode")" = go ]; then
    GOMAXPROCS="$(taskset -c "$SERVER_CPUS" nproc)" PORT="$port" AGG_ROWS="$AGG_ROWS" taskset -c "$SERVER_CPUS" "$GO_BIN" >"$log" 2>&1 &
  else
    env MODE="$(mode_name "$mode")" PORT="$port" AGG_ROWS="$AGG_ROWS" PROBE="$PROBE" taskset -c "$SERVER_CPUS" \
      "${JULIA_CMD[@]}" --project="$ROOT/bench" --threads="$(mode_threads "$mode")" "$HERE/server.jl" >"$log" 2>&1 &
  fi
  PIDS+=("$!")
  for _ in $(seq 1 240); do curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null && break; sleep 0.5; done
  curl -fsS -o /dev/null "http://127.0.0.1:$port/health" || { echo "fairness.sh: $mode did not come up" >&2; tail -20 "$log" >&2; exit 1; }
  PORT_OF[$mode]=$port
done

echo "fairness bench: modes [$MODES], $ROUTE, c=$CONNS, $ROUNDS x $DUR interleaved$([ "$PROBE" = 1 ] && printf ', PROBE=1')"
echo "  server CPUs $SERVER_CPUS (--threads=$THREADS unless mode@threads; go GOMAXPROCS=$(taskset -c "$SERVER_CPUS" nproc)), client CPUs $CLIENT_CPUS"
echo "  concurrency bounds: serve() max_concurrent_requests at its default (nothing: no cap); HTTP.jl listen! defaults (no HTTP/1 connection cap); bare_pool POOL=${POOL:-nthreads(:default)}"
echo "  julia: $("${JULIA_CMD[@]}" --version); $(go version)"
for mode in "${MODE_LIST[@]}"; do
  taskset -c "$CLIENT_CPUS" oha -z 3s -c "$CONNS" --no-tui "http://127.0.0.1:${PORT_OF[$mode]}$ROUTE" >/dev/null 2>&1
done

printf 'mode\tround\trps\tp50_ms\tp99_ms\tp999_ms\tmax_ms\tshare_over_1s\tconn_min\tconn_p1\tconn_p10\tconn_p50\tconn_max\tjain\tmaxwait_p50_ms\tmaxwait_p90_ms\tp90_ms\n' > "$RESULT"
for round in $(seq 1 "$ROUNDS"); do
  for mode in "${MODE_LIST[@]}"; do
    stem="$RAW/r$round-$(mode_label "$mode")"
    js="$stem.json"
    probe_args=()
    [ "$PROBE" = 1 ] && probe_args=(-stamp -trace "$stem-client.tsv")
    GOMAXPROCS="$(taskset -c "$CLIENT_CPUS" nproc)" taskset -c "$CLIENT_CPUS" "$CLIENT" \
      -url "http://127.0.0.1:${PORT_OF[$mode]}$ROUTE" -c "$CONNS" -d "$DUR" ${probe_args[@]+"${probe_args[@]}"} >"$js"
    # The client has waited for every response, so no request is still in flight.
    [ "$PROBE" = 1 ] && [ "$(mode_name "$mode")" != go ] &&
      curl -fsS -m 60 -o "$stem-server.tsv" "http://127.0.0.1:${PORT_OF[$mode]}/probe"
    jq -r --arg m "$mode" --arg r "$round" '[$m, $r, (.rps | floor), .latency_ms.p50, .latency_ms.p99, .latency_ms.p999,
        .latency_ms.max, .share_over_1s, .per_conn_count.min, .per_conn_count.p1, .per_conn_count.p10,
        .per_conn_count.p50, .per_conn_count.max, .jain_index, .per_conn_max_wait_ms.p50,
        .per_conn_max_wait_ms.p90, .latency_ms.p90] | map(if type == "number" then (. * 1000 | round / 1000) else . end) | @tsv' "$js" >> "$RESULT"
    sleep 2
  done
done

echo
printf '| mode | rps | p50 ms | p90 ms | p99 ms | p99.9 ms | max ms | share > 1 s | requests per connection: min / p1 / p10 / median / max | Jain | longest wait per connection: median / p90 ms |\n'
printf '|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|\n'
for mode in "${MODE_LIST[@]}"; do
  awk -F'\t' -v m="$mode" '
    function med(c,   n, i, j, v, x) { n = 0; for (i = 1; i <= rows; i++) v[++n] = col[i, c] + 0
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { x = v[i]; v[i] = v[j]; v[j] = x }
      return (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2 }
    function rng(c,   n, i, lo, hi) { lo = hi = col[1, c] + 0; for (i = 2; i <= rows; i++) { if (col[i, c] + 0 < lo) lo = col[i, c] + 0; if (col[i, c] + 0 > hi) hi = col[i, c] + 0 }
      return sprintf("%g [%g–%g]", med(c), lo, hi) }
    NR > 1 && $1 == m { rows++; for (c = 3; c <= 17; c++) col[rows, c] = $c }
    END { printf "| %s | %s | %s | %s | %s | %s | %s | %s | %g / %g / %g / %g / %g | %s | %g / %g |\n", m, rng(3), rng(4), rng(17), rng(5), rng(6), rng(7), rng(8),
          med(9), med(10), med(11), med(12), med(13), rng(14), med(15), med(16) }' "$RESULT"
done
echo "results: $RESULT"
