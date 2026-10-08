#!/usr/bin/env bash
# Resident memory of a serving process (#451): what a Nitro server costs before it holds any
# request data, and whether that floor moves under load. Linux only -- it reads /proc.
#
# For each repeat it starts bench/socket/server.jl, waits for the listening socket (`ss`, as
# first_request.sh does, so nothing touches the server before the first reading), and reports:
#
#   rest   VmRSS once listening, before any request
#   warm   VmRSS after one request to each route (the first-request JIT is now paid)
#   soak   VmRSS after SOAK of `oha` load on /json, plus 5 s idle  (only when SOAK is set)
#   peak   VmHWM, the high-water mark over the process's life
#
# A `julia` line comes first: an idle `julia` with no packages loaded, the part of the floor
# Nitro cannot change.
#
# Usage: bench/socket/rss.sh [threads] [repeats]
#   bench/socket/rss.sh 8 3
#   SOAK=60s bench/socket/rss.sh 8 1
#   MODE=bare_spawn bench/socket/rss.sh 8           # HTTP.jl alone, no Nitro
#   PRELOAD=PormG PROJECT=/path/to/env bench/socket/rss.sh 8
#
# PRELOAD needs a project that has the package; the bench env deliberately does not carry PormG.
# One way to build one, at the commit Nitro's own Project.toml pins:
#   julia --project=/tmp/rss-pormg -e 'using Pkg; Pkg.develop(path="."); Pkg.add(["HTTP", "JSON"]);
#       Pkg.add(url="https://github.com/PingoLee/PormG.jl.git", rev="<the [sources] rev>")'
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
THREADS="${1:-8}"
REPEATS="${2:-3}"
PORT="${PORT:-8091}"
MODE="${MODE:-nitro}"
SOAK="${SOAK:-}"
PROJECT="${PROJECT:-$ROOT/bench}"

for tool in julia curl ss; do
  command -v "$tool" >/dev/null || { echo "rss.sh: $tool not on PATH" >&2; exit 1; }
done
[ -n "$SOAK" ] && { command -v oha >/dev/null || { echo "rss.sh: SOAK needs oha" >&2; exit 1; }; }
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null' EXIT

# kB from /proc/<pid>/status, printed as MiB.
mib() { awk -v k="$2:" '$1 == k { printf "%.0f", $2 / 1024 }' "/proc/$1/status"; }

echo "rss.sh: $(julia --version), --threads=$THREADS, MODE=$MODE${PRELOAD:+, PRELOAD=$PRELOAD}"

# Output discarded: SIGTERM makes an idle julia print a backtrace.
julia --startup-file=no --threads="$THREADS" -e 'sleep(30)' >/dev/null 2>&1 &
pid=$!
sleep 5
printf 'julia  rest=%s MiB\n' "$(mib "$pid" VmRSS)"
kill "$pid"; wait "$pid" 2>/dev/null; pid=""

for _ in $(seq 1 "$REPEATS"); do
  if [ -n "$(ss -Hltn "sport = :$PORT")" ]; then
    echo "rss.sh: port $PORT is already in use; stop that listener or set PORT" >&2
    exit 1
  fi
  # No startup.jl, like the `julia` line: a Revise or OhMyREPL there would land in every row.
  MODE="$MODE" PORT="$PORT" julia --startup-file=no --project="$PROJECT" --threads="$THREADS" \
    "$HERE/server.jl" >/dev/null 2>&1 &
  pid=$!
  up=0
  for _ in $(seq 1 6000); do          # up to 5 minutes: a stale cache recompiles first
    [ -n "$(ss -Hltn "sport = :$PORT")" ] && { up=1; break; }   # not `| grep -q`: pipefail
    kill -0 "$pid" 2>/dev/null || { echo "server exited" >&2; exit 1; }
    sleep 0.05
  done
  [ "$up" = 1 ] || { echo "server never listened on :$PORT" >&2; exit 1; }
  sleep 2                             # let startup allocation settle before the first reading
  rest="$(mib "$pid" VmRSS)"
  for route in /plaintext /json /health; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$route")"
    [ "$code" = 200 ] || { echo "rss.sh: $route answered $code" >&2; exit 1; }
  done
  sleep 2
  line="$MODE  rest=$rest  warm=$(mib "$pid" VmRSS)"
  if [ -n "$SOAK" ]; then
    oha -z "$SOAK" -c 50 --no-tui "http://127.0.0.1:$PORT/json" >/dev/null 2>&1
    sleep 5
    line="$line  soak=$(mib "$pid" VmRSS)"
  fi
  printf '%s  peak=%s MiB\n' "$line" "$(mib "$pid" VmHWM)"
  kill "$pid"; wait "$pid" 2>/dev/null; pid=""
done
