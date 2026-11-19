#!/usr/bin/env bash
# #618, the native mark, session 2: one profile of a server cell for chosen builds, one server at a
# time (the cell where mark0's throughput range did not overlap ctl's). For each build in BUILDS:
# start `bare_spawn` (no VARIANT) on that build at LAYOUT with fairness.sh's AGG_ROWS and BACKLOG=1024, PROFILE=10 (a window that
# opens WARMUP=15 s after start, every thread sampled every 1 ms, raw samples saved), drive ROUTE with
# the go client at c = 500 for 30 s from start-up (the window falls inside it), then stop the server.
# The reports go to bench/results/profile-bare_spawn-<time>-*, renamed with the build's label.
# Run behind bench/socket/quiet.sh. JULIAS as native_measure.sh exports it.
#
# Usage: BUILDS="control mark" LAYOUT=8,1 bench/julia/native_profile.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILDS="${BUILDS:-control mark}"
LAYOUT="${LAYOUT:-8,1}"
ROUTE="${ROUTE:-/aggregate?n=100000&op=groupby}"
PORT="${PORT:-8890}"
OUT="$ROOT/bench/results"
SERVER_CPUS="0,1,2,3,6,7,8,9"; CLIENT_CPUS="4,5,10,11"
CLIENT="$OUT/fairness"
[ -x "$CLIENT" ] || { echo "native_profile: $CLIENT missing (fairness.sh builds it)" >&2; exit 1; }
declare -A BIN PROJ
for kv in ${JULIAS:?}; do v="${kv#*=}"; BIN["${kv%%=*}"]="${v%%,*}"; PROJ["${kv%%=*}"]="${v#*,}"; done
for b in $BUILDS; do
  t0="$(date +%s)"; touch "$OUT/native-profile-$b.log.start"
  env MODE=bare_spawn PORT="$PORT" AGG_ROWS=10000000 BACKLOG=1024 PROFILE=10 PROFILE_SAVE=1 WARMUP=15 \
    taskset -c "$SERVER_CPUS" "${BIN[$b]}" --project="${PROJ[$b]}" --threads="$LAYOUT" "$ROOT/bench/socket/server.jl" \
    >"$OUT/native-profile-$b.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 240); do curl -fsS -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null && break; sleep 0.5; done
  up=$(( $(date +%s) - t0 ))
  echo "native_profile: $b up after ${up}s; client for 30 s"
  GOMAXPROCS=4 taskset -c "$CLIENT_CPUS" "$CLIENT" -url "http://127.0.0.1:$PORT$ROUTE" -c 500 -d 30s >"$OUT/native-profile-$b-client.json"
  jq -c '{rps, p99: .latency_ms.p99}' "$OUT/native-profile-$b-client.json"
  # The server's log reaches its file only at exit, so the profile is found by its files: the raw
  # samples (.jlprof) are written last; wait for one newer than this server's start, then for its size
  # to settle.
  jp=""
  for _ in $(seq 1 300); do
    jp="$(find "$OUT" -maxdepth 1 -name 'profile-bare_spawn-*.jlprof' -newer "$OUT/native-profile-$b.log.start" | head -1)"
    [ -n "$jp" ] && break; sleep 1
  done
  if [ -n "$jp" ]; then s0=-1; while [ "$(stat -c %s "$jp")" != "$s0" ]; do s0="$(stat -c %s "$jp")"; sleep 3; done; fi
  stem="${jp%.jlprof}"
  kill "$pid"; wait "$pid" 2>/dev/null
  [ -n "$stem" ] || { echo "native_profile: $b wrote no profile" >&2; exit 1; }
  for f in "$stem"*; do mv "$f" "$OUT/native-profile-$b-${LAYOUT/,/_}${f#"$stem"}"; done
  echo "native_profile: $b -> $OUT/native-profile-$b-${LAYOUT/,/_}*"
  sleep 5
done
