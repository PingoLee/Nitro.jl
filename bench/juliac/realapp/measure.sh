#!/usr/bin/env bash
# Drive the #744 realapp: correctness, first request per route, warm time, RSS.
#
#   bench/juliac/realapp/measure.sh check <jit|exe>            # every route, status and body
#   bench/juliac/realapp/measure.sh first <jit|exe> [label]    # one fresh process PER ROUTE
#   bench/juliac/realapp/measure.sh first_after_ready <jit|exe> [label]   # the same, after READY
#   bench/juliac/realapp/measure.sh rss   <jit|exe> [label]    # RSS at rest, and after every route
#
# `jit` runs main.jl under the real julia binary of JULIA (not the juliaup launcher, so the pid,
# its RSS and the kill are the server's). An exe is a JuliaC build of the same main.jl.
# Readiness is the listening socket (`ss`), never a connection, as bench/socket/first_request.sh
# does, so nothing warms the request path before the measured request. `listen` is launch to
# listening socket. `warm` is the median of WARM_N requests after the first.
# `first_after_ready` waits instead for the app's `READY` line on fd 2, written by the lifecycle
# hook RealApp registers after `worker_startup`'s, so the start-up hooks have returned before the
# first request (#744, #799); `ready` is launch to that line. Still no request before it.
#
# REALAPP_ROOT is set to this directory for both: see src/RealApp.jl.
# Env: SECRETS (required) a file of `API_SECRET_KEY=…` / `JWT_SECRET=…` lines, AUTH_HEADER
#        (required) a file holding `Authorization: Bearer <token>` signed with JWT_SECRET;
#        both stay outside the repository. db/connection.yml (gitignored) holds the database.
#      PORT (default 18744), THREADS (default 8,1), JULIA (default "julia +1.13"), WARM_N (5),
#      LOGS (default bench/results/realapp-logs, gitignored): each process's output, per route.
# Every line printed is TSV: mode, label, route, then the readings.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
MODE=${1:?usage: measure.sh <check|first|first_after_ready|rss> <jit|exe> [label]}
TARGET=${2:?usage: measure.sh <check|first|first_after_ready|rss> <jit|exe> [label]}
LABEL=${3:-$(basename "$TARGET")}
PORT=${PORT:-18744}
THREADS=${THREADS:-8,1}
JULIA=${JULIA:-"julia +1.13"}
WARM_N=${WARM_N:-5}
LOGS=${LOGS:-"$ROOT/bench/results/realapp-logs"}
: "${SECRETS:?set SECRETS to the secrets file}" "${AUTH_HEADER:?set AUTH_HEADER to the header file}"
mkdir -p "$LOGS"
JULIA_BIN=$($JULIA --startup-file=no -e 'print(joinpath(Sys.BINDIR, Base.julia_exename()))')
URL="http://127.0.0.1:$PORT"
ITEM='{"name":"widget","category":"tools","quantity":3}'

# name|method|path|body|status|substring the body must contain
ROUTES=(
  "health|GET|/health||200|\"ok\""
  "write|POST|/items|$ITEM|201|\"created\":\"widget\""
  "list|GET|/items||200|\"category\":\"tools\""
  "by_id|GET|/items/1||200|\"id\":1"
  "json_validate|POST|/items/validated|$ITEM|200|\"quantity\":3"
  "query_path|GET|/search/tools?limit=5&min_qty=1||200|\"limit\":5"
  "session|GET|/session||200|\"visits\":1"
  "bearer|GET|/me||200|\"sub\":\"bench-user\""
  "file|GET|/file||200|Hello from a static file."
  "error_400|GET|/bad||400|"
)
# Checked by `check` only: the validator's refusal.
INVALID='{"name":"widget","category":"tools","quantity":-1}'

pid=""
# Still alive STOP_GRACE_S (default 30) seconds after SIGTERM: SIGKILL, named, as bench/socket/run.sh
# does. The JIT server once never exited after a SIGTERM that landed during start-up (#744).
stop() {
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null
  for _ in $(seq 1 "${STOP_GRACE_S:-30}"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    echo "measure.sh: pid $pid still alive ${STOP_GRACE_S:-30}s after SIGTERM; sending SIGKILL" >&2
    kill -9 "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null; pid=""
  for _ in $(seq 1 100); do [ -z "$(ss -Hltn "sport = :$PORT")" ] && return 0; sleep 0.05; done
}
trap stop EXIT

# Start the target, wait for the socket; sets pid and LISTEN (seconds). Output goes to $1.
start() {
  if [ -n "$(ss -Hltn "sport = :$PORT")" ]; then
    echo "measure.sh: port $PORT already in use" >&2; exit 1
  fi
  local t0
  t0=$(date +%s.%N); T0=$t0
  if [ "$TARGET" = jit ]; then
    ( set -a; . "$SECRETS"; set +a; cd "$LOGS" && PORT=$PORT REALAPP_ROOT="$HERE" PORMG_POSTGRES_DRIVER=Postgres \
      exec "$JULIA_BIN" --startup-file=no --project="$HERE" --threads="$THREADS" "$HERE/main.jl" ) >"$1" 2>&1 &
  else
    ( set -a; . "$SECRETS"; set +a; cd "$LOGS" && PORT=$PORT REALAPP_ROOT="$HERE" PORMG_POSTGRES_DRIVER=Postgres \
      JULIA_NUM_THREADS=$THREADS exec "$TARGET" ) >"$1" 2>&1 &
  fi
  pid=$!
  for _ in $(seq 1 6000); do
    [ -n "$(ss -Hltn "sport = :$PORT")" ] && { LISTEN=$(echo "$(date +%s.%N) - $t0" | bc -l); return 0; }
    kill -0 "$pid" 2>/dev/null || { echo "measure.sh: $LABEL exited before listening; log $1" >&2; pid=""; return 1; }
    sleep 0.05
  done
  echo "measure.sh: $LABEL never listened; log $1" >&2; stop; return 1
}

# Wait for the app's READY line in log $1, at most READY_TIMEOUT_S (default 300) seconds after the
# launch; sets READY (seconds since launch). The launch time is start()'s t0, kept in T0.
wait_ready() {
  for _ in $(seq 1 $(( ${READY_TIMEOUT_S:-300} * 20 ))); do
    grep -q '^READY$' "$1" && { READY=$(echo "$(date +%s.%N) - $T0" | bc -l); return 0; }
    kill -0 "$pid" 2>/dev/null || { echo "measure.sh: $LABEL exited before READY; log $1" >&2; pid=""; return 1; }
    sleep 0.05
  done
  echo "measure.sh: $LABEL never wrote READY; log $1" >&2; stop; return 1
}

# request <method> <path> <body> -> "status seconds"; the body lands in $BODY_FILE.
BODY_FILE=$(mktemp); trap 'stop; rm -f "$BODY_FILE"' EXIT
request() {
  local args=(-s -o "$BODY_FILE" -w '%{http_code} %{time_total}' -X "$1")
  [ -n "$3" ] && args+=(-H 'Content-Type: application/json' --data "$3")
  [ "$2" = /me ] && args+=(-H "@$AUTH_HEADER")
  curl "${args[@]}" "$URL$2"
}
mib() { awk '$1 == "VmRSS:" { printf "%.0f", $2 / 1024 }' "/proc/$1/status"; }
median() { sort -n | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'; }

case "$MODE" in
check)
  start "$LOGS/$LABEL-check.log" || exit 1
  printf 'check\t%s\tlisten\t%.2f\n' "$LABEL" "$LISTEN"
  fail=0
  for r in "${ROUTES[@]}"; do
    IFS='|' read -r name method path body status want <<<"$r"
    read -r code _ < <(request "$method" "$path" "$body")
    ok=pass
    { [ "$code" = "$status" ] && grep -qF -- "$want" "$BODY_FILE"; } || { ok=FAIL; fail=1; }
    printf 'check\t%s\t%s\t%s\t%s\t%s\n' "$LABEL" "$name" "$code" "$ok" "$(head -c 120 "$BODY_FILE" | tr '\n\t' '  ')"
  done
  read -r code _ < <(request POST /items/validated "$INVALID")
  ok=pass; [ "$code" = 400 ] || { ok=FAIL; fail=1; }
  printf 'check\t%s\t%s\t%s\t%s\t%s\n' "$LABEL" "json_validate_refused" "$code" "$ok" "$(head -c 120 "$BODY_FILE" | tr '\n\t' '  ')"
  stop
  exit "$fail"
  ;;
first)
  for r in "${ROUTES[@]}"; do
    IFS='|' read -r name method path body status _ <<<"$r"
    start "$LOGS/$LABEL-first-$name.log" || exit 1
    read -r code1 t1 < <(request "$method" "$path" "$body")
    warm=$(for _ in $(seq 1 "$WARM_N"); do request "$method" "$path" "$body" | cut -d' ' -f2; done | median)
    [ "$code1" = "$status" ] || echo "measure.sh: $LABEL $name first answered $code1, want $status" >&2
    printf 'first\t%s\t%s\tlisten=%.3f\tfirst_ms=%.1f\tstatus=%s\twarm_ms=%.2f\n' "$LABEL" "$name" "$LISTEN" \
      "$(echo "$t1 * 1000" | bc -l)" "$code1" "$(echo "$warm * 1000" | bc -l)"
    stop
  done
  ;;
first_after_ready)
  for r in "${ROUTES[@]}"; do
    IFS='|' read -r name method path body status _ <<<"$r"
    log="$LOGS/$LABEL-ready-$name.log"
    start "$log" || exit 1
    wait_ready "$log" || exit 1
    read -r code1 t1 < <(request "$method" "$path" "$body")
    warm=$(for _ in $(seq 1 "$WARM_N"); do request "$method" "$path" "$body" | cut -d' ' -f2; done | median)
    [ "$code1" = "$status" ] || echo "measure.sh: $LABEL $name first answered $code1, want $status" >&2
    printf 'first_after_ready\t%s\t%s\tlisten=%.3f\tready=%.3f\tfirst_ms=%.1f\tstatus=%s\twarm_ms=%.2f\n' "$LABEL" "$name" \
      "$LISTEN" "$READY" "$(echo "$t1 * 1000" | bc -l)" "$code1" "$(echo "$warm * 1000" | bc -l)"
    stop
  done
  ;;
rss)
  start "$LOGS/$LABEL-rss.log" || exit 1
  sleep 2                                    # let start-up allocation settle, as rss.sh does
  rest=$(mib "$pid")
  for r in "${ROUTES[@]}"; do
    IFS='|' read -r name method path body status _ <<<"$r"
    read -r code _ < <(request "$method" "$path" "$body")
    [ "$code" = "$status" ] || echo "measure.sh: $LABEL $name answered $code, want $status" >&2
  done
  sleep 2
  printf 'rss\t%s\tall\tlisten=%.3f\trest_mib=%s\twarm_mib=%s\n' "$LABEL" "$LISTEN" "$rest" "$(mib "$pid")"
  stop
  ;;
*) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
