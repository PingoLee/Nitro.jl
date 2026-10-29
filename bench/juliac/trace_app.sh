#!/usr/bin/env bash
# #745 step 3: trace what the JIT compiles for app.jl under a fixed workload, for roots.jl.
#
#   bench/juliac/trace_app.sh <trace.jl>
#   julia bench/juliac/roots.jl <trace.jl> <roots.txt>
#   ROOTS_FILE=<roots.txt> ENTRY=app_roots bench/juliac/build.sh unsafe-warn
#
# The whole process is traced, start-up included: an image needs the start-up specializations
# too. The workload is every request #779 sent the trimmed app: GET /plaintext, a miss, a POST
# with a JSON body to /plaintext and to a miss, and a chunked POST. The server stops with SIGTERM,
# then SIGKILL after STOP_GRACE_S (default 30), as bench/socket/run.sh does.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TRACE=${1:?usage: trace_app.sh <trace.jl>}
PORT=${PORT:-18746}
JULIA=${JULIA:-"julia +1.13"}
JULIA_BIN=$($JULIA --startup-file=no -e 'print(joinpath(Sys.BINDIR, Base.julia_exename()))')
[ -z "$(ss -Hltn "sport = :$PORT")" ] || { echo "trace_app.sh: port $PORT in use" >&2; exit 1; }
PORT=$PORT "$JULIA_BIN" --startup-file=no --project="$HERE" --threads=8,1 --trace-compile="$TRACE" \
  "$HERE/app.jl" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 1200); do
  [ -n "$(ss -Hltn "sport = :$PORT")" ] && break
  kill -0 "$pid" 2>/dev/null || { echo "trace_app.sh: server exited" >&2; exit 1; }
  sleep 0.05
done
U="http://127.0.0.1:$PORT"
for _ in 1 2; do
  curl -s -o /dev/null -w '%{http_code} GET /plaintext\n' "$U/plaintext"
  curl -s -o /dev/null -w '%{http_code} GET /nope\n' "$U/nope"
  curl -s -o /dev/null -w '%{http_code} POST /plaintext json\n' -X POST -H 'Content-Type: application/json' --data '{"a":1}' "$U/plaintext"
  curl -s -o /dev/null -w '%{http_code} POST /nope json\n' -X POST -H 'Content-Type: application/json' --data '{"a":1}' "$U/nope"
  curl -s -o /dev/null -w '%{http_code} POST /plaintext chunked\n' -X POST -H 'Transfer-Encoding: chunked' --data 'abc' "$U/plaintext"
done
sleep 1
kill "$pid" 2>/dev/null
for _ in $(seq 1 "${STOP_GRACE_S:-30}"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$pid" 2>/dev/null; then
  echo "trace_app.sh: pid $pid still alive ${STOP_GRACE_S:-30}s after SIGTERM; sending SIGKILL" >&2
  kill -9 "$pid" 2>/dev/null
fi
wait "$pid" 2>/dev/null
echo "trace_app.sh: $(wc -l <"$TRACE") trace lines -> $TRACE"
