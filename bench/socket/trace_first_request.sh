#!/usr/bin/env bash
# What the first request to a fresh server compiles (#450). Starts `server.jl` with
# `--trace-compile`, waits for the listening socket (passively, as first_request.sh does), marks
# the trace, sends ONE request, and prints the `precompile(...)` statements that request caused --
# i.e. exactly what the precompile workload did not cache.
#
# Usage: bench/socket/trace_first_request.sh [route]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ROUTE="${1:-/plaintext}"
PORT="${PORT:-8092}"
OUT="$ROOT/bench/results"
mkdir -p "$OUT"
TRACE="$OUT/trace-first-request-$(date +%Y%m%d-%H%M%S).jl"
if [ -n "$(ss -Hltn "sport = :$PORT")" ]; then     # not `| grep -q`: pipefail + SIGPIPE
  echo "trace_first_request.sh: port $PORT is already in use; stop that listener or set PORT" >&2
  exit 1
fi

MODE=nitro PORT="$PORT" julia --project="$ROOT/bench" --threads=8 --trace-compile="$TRACE" \
  "$HERE/server.jl" >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
for _ in $(seq 1 600); do
  ss -Hltn "sport = :$PORT" | grep -q . && break
  kill -0 "$pid" 2>/dev/null || { echo "server exited" >&2; exit 1; }
  sleep 0.05
done
sleep 2                                   # let startup compilation settle
before=$(wc -l <"$TRACE")
curl -s -o /dev/null -w 'first request: %{http_code} in %{time_total}s\n' "http://127.0.0.1:$PORT$ROUTE"
sleep 1
total=$(wc -l <"$TRACE")
echo "statements compiled by the first request: $((total - before)) (trace: $TRACE)"
tail -n +"$((before + 1))" "$TRACE"
