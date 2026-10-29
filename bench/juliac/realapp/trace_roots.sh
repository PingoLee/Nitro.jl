#!/usr/bin/env bash
# #745 step 5: trace the WHOLE JIT process (start-up included) under the #744 workload, for
# bench/juliac/roots.jl. Unlike trace.sh, which keeps one route's window per process, this keeps
# every line: an image needs the start-up specializations too.
#
#   SECRETS=… AUTH_HEADER=… bench/juliac/realapp/trace_roots.sh <trace.jl>
#   julia bench/juliac/roots.jl <trace.jl> <roots.txt>
#   ROOTS_FILE=<roots.txt> ENTRY=main_roots bench/juliac/realapp/build.sh unsafe-warn
#
# Every route twice, then SETTLE_S (default 30) seconds so the lifecycle start-up hooks are done
# before the stop: a SIGTERM during start-up once left this server running for hours (#744).
# SIGKILL after STOP_GRACE_S (default 30), as bench/socket/run.sh does. Same env as measure.sh.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TRACE=${1:?usage: trace_roots.sh <trace.jl>}
PORT=${PORT:-18748}
JULIA=${JULIA:-"julia +1.13"}
: "${SECRETS:?set SECRETS}" "${AUTH_HEADER:?set AUTH_HEADER}"
JULIA_BIN=$($JULIA --startup-file=no -e 'print(joinpath(Sys.BINDIR, Base.julia_exename()))')
[ -z "$(ss -Hltn "sport = :$PORT")" ] || { echo "trace_roots.sh: port $PORT in use" >&2; exit 1; }
ITEM='{"name":"widget","category":"tools","quantity":3}'
REQS=(
  "GET|/health|" "POST|/items|$ITEM" "GET|/items|" "GET|/items/1|"
  "POST|/items/validated|$ITEM" "GET|/search/tools?limit=5&min_qty=1|"
  "GET|/session|" "GET|/me|" "GET|/file|" "GET|/bad|"
)
LOG=$(dirname "$TRACE")/trace_roots-server.log
( set -a; . "$SECRETS"; set +a; PORT=$PORT REALAPP_ROOT="$HERE" PORMG_POSTGRES_DRIVER=Postgres \
  exec "$JULIA_BIN" --startup-file=no --project="$HERE" --threads=8,1 --trace-compile="$TRACE" \
  "$HERE/main.jl" ) >"$LOG" 2>&1 &
pid=$!
for _ in $(seq 1 6000); do
  [ -n "$(ss -Hltn "sport = :$PORT")" ] && break
  kill -0 "$pid" 2>/dev/null || { echo "trace_roots.sh: server exited; log $LOG" >&2; exit 1; }
  sleep 0.05
done
for pass in 1 2; do
  for r in "${REQS[@]}"; do
    IFS='|' read -r method path body <<<"$r"
    args=(-s -m 120 -o /dev/null -w '%{http_code}' -X "$method")
    [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")
    [ "$path" = /me ] && args+=(-H "@$AUTH_HEADER")
    printf 'pass %s %s %s %s\n' "$pass" "$method" "$path" "$(curl "${args[@]}" "http://127.0.0.1:$PORT$path")"
  done
done
sleep "${SETTLE_S:-30}"
kill "$pid" 2>/dev/null
for _ in $(seq 1 "${STOP_GRACE_S:-30}"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$pid" 2>/dev/null; then
  echo "trace_roots.sh: pid $pid still alive ${STOP_GRACE_S:-30}s after SIGTERM; sending SIGKILL" >&2
  kill -9 "$pid" 2>/dev/null
fi
wait "$pid" 2>/dev/null
echo "trace_roots.sh: $(wc -l <"$TRACE") trace lines -> $TRACE"
