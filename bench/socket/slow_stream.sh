#!/usr/bin/env bash
# Does a streamed body give its thread up when the client is slower than the server? (#588)
#
# `stall.sh` showed `Res.file(…; stream = true)` stalling `/plaintext` at K = 8 with almost no GC:
# oha drains loopback as fast as the server writes, so no socket write ever has to wait. This keeps
# K downloads of a hold route in flight with curl, each capped at RATE bytes per second
# (`--limit-rate`; `0` is no cap), while `oha` measures `/plaintext` at c=CONNS, so a capped client
# makes the server's send buffer fill and its writes wait. Rounds are interleaved; each row is the
# median with its min and max. `/gc` brackets each `/plaintext` window, as in `stall.sh`.
#
# Usage: bench/socket/slow_stream.sh [rounds] [duration]
#   TARGETS="/hold/file_stream /hold/file" RATES="0 400M 100M" KS="8 16" bench/socket/slow_stream.sh 3 8s
#
# Results: bench/results/slow-stream-<stamp>.tsv, one line per round, and the per-transfer curl
# logs and oha reports under bench/results/slow-stream-<stamp>-raw/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

ROUNDS="${1:-3}"
DUR="${2:-8s}"
TARGETS="${TARGETS:-/hold/file_stream /hold/file}"
RATES="${RATES:-0 400M 100M}"
KS="${KS:-8 16}"
CONNS="${CONNS:-50}"
THREADS="${THREADS:-8}"
PORT="${PORT:-8580}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,3,6,7,8,9}"
CLIENT_CPUS="${CLIENT_CPUS:-4,5,10,11}"
read -r -a JULIA_CMD <<<"${JULIA:-julia}"
[[ $DUR =~ ^[0-9]+s$ ]] || { echo "slow_stream.sh: duration must be whole seconds" >&2; exit 1; }
for tool in oha curl jq taskset ss "${JULIA_CMD[0]}"; do
  command -v "$tool" >/dev/null || { echo "slow_stream.sh: $tool not on PATH" >&2; exit 1; }
done

OUT="$ROOT/bench/results"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/slow-stream-$STAMP.tsv"
RAW="$OUT/slow-stream-$STAMP-raw"; mkdir -p "$RAW"
printf 'round\ttarget\trate\tk\tplaintext_rps\tp50_ms\tp99_ms\ttransfers_per_s\tgc_share_pct\ttts_per_gc_ms\n' > "$RESULT"
BASE="http://127.0.0.1:$PORT"

[ -n "$(ss -Hltn "sport = :$PORT")" ] && { echo "slow_stream.sh: port $PORT in use" >&2; exit 1; }
LOG="$OUT/slow-stream-$STAMP-server.log"
env MODE=nitro PORT="$PORT" HOLDS=1 taskset -c "$SERVER_CPUS" "${JULIA_CMD[@]}" --project="$ROOT/bench" \
  --threads="$THREADS" "$HERE/server.jl" >"$LOG" 2>&1 &
SERVER=$!
LOOPS=()
stop_loops() {
  for p in ${LOOPS[@]+"${LOOPS[@]}"}; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  # A bare `wait` would also wait for the server, so only when there are loops to reap.
  [ "${#LOOPS[@]}" -gt 0 ] && wait "${LOOPS[@]}" 2>/dev/null
  LOOPS=()
}
trap 'stop_loops; kill $SERVER 2>/dev/null; wait 2>/dev/null' EXIT
for _ in $(seq 1 240); do curl -fsS -o /dev/null "$BASE/health" 2>/dev/null && break; sleep 0.5; done
curl -fsS -o /dev/null "$BASE/health" || { echo "slow_stream.sh: server did not come up" >&2; tail -20 "$LOG" >&2; exit 1; }

echo "slow-stream bench: targets [$TARGETS], rates [$RATES], K [$KS], $ROUNDS x $DUR interleaved, /plaintext c=$CONNS"
echo "  server CPUs $SERVER_CPUS (--threads=$THREADS), client CPUs $CLIENT_CPUS; julia: $("${JULIA_CMD[@]}" --version); $(curl --version | head -1 | cut -d' ' -f1-2)"
taskset -c "$CLIENT_CPUS" oha -z 3s -c "$CONNS" --no-tui "$BASE/plaintext" >/dev/null 2>&1
for t in $TARGETS; do curl -fsS -o /dev/null "$BASE$t"; done

# K curl loops on target $1 at rate $2, each appending "<bytes> <seconds>" per transfer to $3.
start_loops() {
  local url="$BASE$1" rate="$2" log="$3" k="$4" limit=()
  [ "$rate" != 0 ] && limit=(--limit-rate "$rate")
  for _ in $(seq 1 "$k"); do
    taskset -c "$CLIENT_CPUS" bash -c 'while :; do curl -s -o /dev/null "$@" -w "%{size_download} %{time_total}\n" || exit; done' \
      _ ${limit[@]+"${limit[@]}"} "$url" >>"$log" &
    LOOPS+=("$!")
  done
}
gc_json() { curl -fsS -m 30 "$BASE/gc" 2>/dev/null || printf '{}'; }

PASSES=("base|0|0")
for t in $TARGETS; do for r in $RATES; do for k in $KS; do PASSES+=("$t|$r|$k"); done; done; done
LOAD_S=$(( ${DUR%s} + 2 ))
for round in $(seq 1 "$ROUNDS"); do
  for pass in "${PASSES[@]}"; do
    IFS='|' read -r target rate k <<<"$pass"
    stem="$RAW/r$round-$(printf '%s' "$target" | tr -c 'A-Za-z0-9' '_')-$rate-k$k"
    if [ "$k" != 0 ]; then
      : >"$stem-curl.log"
      start_loops "$target" "$rate" "$stem-curl.log" "$k"
      t0=$(date +%s.%N)
      sleep 1
    fi
    g0="$(gc_json)"
    js="$(taskset -c "$CLIENT_CPUS" oha -z "$DUR" -c "$CONNS" --no-tui --disable-compression --output-format json "$BASE/plaintext" 2>/dev/null)"
    g1="$(gc_json)"
    printf '%s\n' "$js" >"$stem-plaintext.json"
    xfer=-
    if [ "$k" != 0 ]; then
      sleep 1
      stop_loops
      t1=$(date +%s.%N)
      # Completed transfers only (a full body), over the time the loops ran.
      xfer=$(awk -v t0="$t0" -v t1="$t1" '$1 == 104857600 { n++ } END { printf "%.2f", n / (t1 - t0) }' "$stem-curl.log")
      sleep 2
    fi
    read -r share tts < <(jq -nr --argjson a "$g0" --argjson b "$g1" --argjson w "$(jq '.summary.total' <<<"$js")" '
      if ($a | has("pause")) and ($b | has("pause")) then
        [(($b.total_time - $a.total_time) / ($w * 1e9) * 100 * 100 | floor / 100),
         (if $b.pause > $a.pause then (($b.total_time_to_safepoint - $a.total_time_to_safepoint) / ($b.pause - $a.pause) / 1e6 * 100 | floor / 100) else 0 end)]
      else ["-", "-"] end | @tsv')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$round" "$target" "$rate" "$k" \
      "$(jq -r '.summary.requestsPerSec | floor' <<<"$js")" \
      "$(jq -r '(.latencyPercentiles.p50 // 0) * 1000 | . * 100 | floor / 100' <<<"$js")" \
      "$(jq -r '(.latencyPercentiles.p99 // 0) * 1000 | . * 100 | floor / 100' <<<"$js")" \
      "$xfer" "$share" "$tts" >> "$RESULT"
  done
done

# One row per pass: the median and [min–max] of each column over the rounds.
echo
printf '| target | rate per stream | K | /plaintext rps | p50 ms | p99 ms | transfers/s | GC %% of window | TTS per GC ms |\n|---|---|--:|--:|--:|--:|--:|--:|--:|\n'
for pass in "${PASSES[@]}"; do
  IFS='|' read -r target rate k <<<"$pass"
  awk -F'\t' -v t="$target" -v r="$rate" -v k="$k" '
    function cell(c,   n, i, j, v, x) { n = 0; for (i = 1; i <= rows; i++) if (col[i, c] != "-") v[++n] = col[i, c] + 0
      if (n == 0) return "–"
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { x = v[i]; v[i] = v[j]; v[j] = x }
      return sprintf("%g [%g–%g]", (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2, v[1], v[n]) }
    NR > 1 && $2 == t && $3 == r && $4 == k { rows++; for (c = 5; c <= 10; c++) col[rows, c] = $c }
    END { printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", t, (r == 0 ? "uncapped" : r "/s"), k,
          cell(5), cell(6), cell(7), cell(8), cell(9), cell(10) }' "$RESULT"
done
echo "results: $RESULT"
