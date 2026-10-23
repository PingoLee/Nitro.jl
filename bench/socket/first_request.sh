#!/usr/bin/env bash
# First-request latency over a socket (#450): how much of the first request to a fresh server is
# JIT of the transport layer the precompile workload cannot reach without a socket.
#
# Readiness is detected by watching for the listening socket (`ss`), never by connecting, so
# nothing warms the request path before the measured one. Then the same route is requested
# again, warm. A first request that fails prints its status, so a broken server cannot pass for
# a fast one. `listen` is launch to listening socket: package load, route registration, `serve`.
#
# Usage: bench/socket/first_request.sh [route] [repeats]
#   bench/socket/first_request.sh /plaintext 5
#   FILLER_ROUTES=1000 ROUTE_MW=1 bench/socket/first_request.sh /mw 3   # a large mixed table (#718)
#   BASE_ROOT=/path/to/other/checkout bench/socket/first_request.sh   # measure that checkout
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ROUTE="${1:-/plaintext}"
REPEATS="${2:-5}"
PORT="${PORT:-8090}"
PROJECT="${BASE_ROOT:-$ROOT}/bench"

for tool in julia curl ss bc; do
  command -v "$tool" >/dev/null || { echo "first_request.sh: $tool not on PATH" >&2; exit 1; }
done
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null' EXIT

for _ in $(seq 1 "$REPEATS"); do
  # Refuse a busy port: the readiness check would see the OTHER listener and time it instead.
  if [ -n "$(ss -Hltn "sport = :$PORT")" ]; then   # not `| grep -q`: pipefail + SIGPIPE
    echo "first_request.sh: port $PORT is already in use; stop that listener or set PORT" >&2
    exit 1
  fi
  t0=$(date +%s.%N)
  MODE=nitro PORT="$PORT" julia --project="$PROJECT" --threads=8 "${SERVER_SCRIPT:-$HERE/server.jl}" >/dev/null 2>&1 &
  pid=$!
  up=0
  # UP_TIMEOUT_S (default 300): a stale cache recompiles Nitro first, and a large route table
  # (FILLER_ROUTES, #718) is registered before the server listens.
  for _ in $(seq 1 $(( ${UP_TIMEOUT_S:-300} * 20 ))); do
    ss -Hltn "sport = :$PORT" | grep -q . && { up=1; break; }
    kill -0 "$pid" 2>/dev/null || { echo "server exited" >&2; exit 1; }
    sleep 0.05
  done
  [ "$up" = 1 ] || { echo "server never listened on :$PORT" >&2; kill "$pid"; exit 1; }
  listen=$(echo "$(date +%s.%N) - $t0" | bc -l)
  read -r code1 first < <(curl -s -o /dev/null -w '%{http_code} %{time_total}' "http://127.0.0.1:$PORT$ROUTE")
  read -r code2 warm  < <(curl -s -o /dev/null -w '%{http_code} %{time_total}' "http://127.0.0.1:$PORT$ROUTE")
  printf 'listen=%.2fs  first=%.1fms (%s)  warm=%.1fms (%s)\n' "$listen" "$(echo "$first * 1000" | bc -l)" "$code1" \
    "$(echo "$warm * 1000" | bc -l)" "$code2"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
done
