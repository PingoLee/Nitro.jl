#!/usr/bin/env bash
# Start a built executable (or the JIT baseline), time the FIRST /plaintext and a warm one, read
# the process's RSS and OS thread count, stop it. Repeat.
#
#   bench/juliac/smoke.sh <path-to-exe | jit> [repeats]
#
# Env: PORT (default 18080), THREADS (default "8,1"; exported as JULIA_NUM_THREADS for the exe,
#      passed as --threads for the JIT run), JULIA (default "julia +1.12").
# The thread count answers #570's question of whether the exe honours JULIA_NUM_THREADS: with
# "8,1" a Julia process shows well over 9 OS threads (pool + libuv + GC); with 1 it shows a handful.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TARGET=${1:?usage: smoke.sh <exe|jit> [repeats]}
REPEATS=${2:-3}
PORT=${PORT:-18080}
THREADS=${THREADS:-8,1}
JULIA=${JULIA:-"julia +1.12"}
URL="http://127.0.0.1:$PORT/plaintext"

for i in $(seq 1 "$REPEATS"); do
  T0=$(date +%s.%N)
  if [ "$TARGET" = jit ]; then
    PORT=$PORT $JULIA --startup-file=no --project="$HERE" --threads="$THREADS" "$HERE/app.jl" >/dev/null 2>&1 &
  else
    PORT=$PORT JULIA_NUM_THREADS=$THREADS "$TARGET" >/dev/null 2>&1 &
  fi
  PID=$!
  for _ in $(seq 1 1200); do
    ss -ltn "( sport = :$PORT )" 2>/dev/null | grep -q LISTEN && break
    kill -0 "$PID" 2>/dev/null || { echo "run $i: process exited before listening"; break; }
    sleep 0.05
  done
  T1=$(date +%s.%N)
  FIRST=$(curl -s -o /dev/null -w '%{time_total}' "$URL")
  BODY=$(curl -s "$URL")
  WARM=$(curl -s -o /dev/null -w '%{time_total}' "$URL")
  RSS=$(awk '/VmRSS/{print $2 " " $3}' "/proc/$PID/status" 2>/dev/null)
  NTHR=$(ls "/proc/$PID/task" 2>/dev/null | wc -l)
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  LISTEN=$(awk -v a="$T0" -v b="$T1" 'BEGIN { printf "%.2f", b - a }')
  printf 'run %d: listen=%ss first=%ss warm=%ss body=%s rss=%s threads=%s\n' \
    "$i" "$LISTEN" "$FIRST" "$WARM" "${BODY:-<none>}" "${RSS:-?}" "$NTHR"
done
