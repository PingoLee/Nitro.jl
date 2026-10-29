#!/usr/bin/env bash
# What the first request of each route compiles under the JIT (#744), as
# bench/socket/trace_first_request.sh does for server.jl: start main.jl with --trace-compile,
# wait for the listening socket (never connecting early), let start-up settle, mark the trace,
# send ONE request, and keep the precompile statements that request caused. An untrimmed JuliaC
# executable takes no Julia flags, so the JIT under the same workload is how its first request
# is read; the executable compiles a subset of this.
#
#   SECRETS=… AUTH_HEADER=… bench/juliac/realapp/trace.sh [route-name…]   # default: every route
#
# Writes bench/results/realapp-trace-<stamp>/<route>.jl (the statements of that request) and
# prints one count per route. Same env as measure.sh.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
PORT=${PORT:-18745}
THREADS=${THREADS:-8,1}
JULIA=${JULIA:-"julia +1.13"}
: "${SECRETS:?set SECRETS}" "${AUTH_HEADER:?set AUTH_HEADER}"
JULIA_BIN=$($JULIA --startup-file=no -e 'print(joinpath(Sys.BINDIR, Base.julia_exename()))')
DIR="$ROOT/bench/results/realapp-trace-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR"
ITEM='{"name":"widget","category":"tools","quantity":3}'
declare -A REQ=(
  [health]="GET|/health|"            [write]="POST|/items|$ITEM"
  [list]="GET|/items|"               [by_id]="GET|/items/1|"
  [json_validate]="POST|/items/validated|$ITEM"
  [query_path]="GET|/search/tools?limit=5&min_qty=1|"
  [session]="GET|/session|"          [bearer]="GET|/me|"
  [file]="GET|/file|"                [error_400]="GET|/bad|"
)
NAMES=("$@")
[ ${#NAMES[@]} -gt 0 ] || NAMES=(health write list by_id json_validate query_path session bearer file error_400)

pid=""
# Still alive STOP_GRACE_S (default 30) seconds after SIGTERM: SIGKILL, named, as bench/socket/run.sh
# does. The first run hung here for hours: SIGTERM landed while start-up (the worker hook's PormG
# query) was still compiling, and the server never exited (#744).
stop() {
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null
  for _ in $(seq 1 "${STOP_GRACE_S:-30}"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    echo "trace.sh: pid $pid still alive ${STOP_GRACE_S:-30}s after SIGTERM; sending SIGKILL" >&2
    kill -9 "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null; pid=""
}
trap stop EXIT
for name in "${NAMES[@]}"; do
  IFS='|' read -r method path body <<<"${REQ[$name]}"
  trace="$DIR/full-$name.jl"
  ( set -a; . "$SECRETS"; set +a; cd "$DIR" && PORT=$PORT REALAPP_ROOT="$HERE" PORMG_POSTGRES_DRIVER=Postgres \
    exec "$JULIA_BIN" --startup-file=no --project="$HERE" --threads="$THREADS" --trace-compile="$trace" \
    "$HERE/main.jl" ) >"$DIR/server-$name.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 6000); do
    [ -n "$(ss -Hltn "sport = :$PORT")" ] && break
    kill -0 "$pid" 2>/dev/null || { echo "trace.sh: server exited ($name)" >&2; exit 1; }
    sleep 0.05
  done
  # Let start-up compilation settle. The socket opens BEFORE the lifecycle `startup` hooks run,
  # and 3 s was not enough in the one run: the worker hook's PormG query was still compiling, so
  # the window held start-up statements, not the route's.
  sleep "${SETTLE_S:-3}"
  before=$(wc -l <"$trace")
  args=(-s -o /dev/null -w '%{http_code} %{time_total}' -X "$method")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")
  [ "$path" = /me ] && args+=(-H "@$AUTH_HEADER")
  read -r code secs < <(curl "${args[@]}" "http://127.0.0.1:$PORT$path")
  sleep 1
  tail -n +"$((before + 1))" "$trace" >"$DIR/$name.jl"
  printf '%s\tstatus=%s\tfirst_s=%s\tstatements=%s\n' "$name" "$code" "$secs" "$(wc -l <"$DIR/$name.jl")"
  stop
  for _ in $(seq 1 100); do [ -z "$(ss -Hltn "sport = :$PORT")" ] && break; sleep 0.05; done
done
echo "traces: $DIR"
