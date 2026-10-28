#!/usr/bin/env bash
# Correctness smoke for the #589 database routes, not a measurement: every route on every mode
# answers 200 with a JSON body of the right shape, `/updates` really writes (each row it reports
# reads back from the table with that value), and `/db_wait?ms=200` takes about 200 ms. Prints one
# line per check and exits non-zero on the first failure.
#
# Usage: DB=postgres bench/socket/db/smoke.sh ["nitro bare_spawn go"]
#        DB=sqlite   bench/socket/db/smoke.sh ["nitro bare_spawn"]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DB="${DB:-postgres}"
. "$HERE/db/env.sh"
MODES="${1:-$([ "$DB" = postgres ] && echo "nitro bare_spawn go" || echo "nitro bare_spawn")}"
BASE_PORT="${PORT:-18580}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/db-smoke.XXXXXX")"

PIDS=()
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

GO_BIN="$LOG_DIR/go-server"
case " $MODES " in *" go "*) (cd "$HERE/go" && go build -o "$GO_BIN" .) || fail "go build" ;; esac

# The rows the table holds for these ids, as `id randomnumber` lines, read the way each backend's
# own client would: a one-off Julia process through PormG, so nothing here needs psql or sqlite3.
# It always reads PostgreSQL through LibPQ, so a server on PG_DRIVER=Postgres is checked by the
# other driver.
read_back() {
  env -u PORMG_POSTGRES_DRIVER julia --startup-file=no --project="$HERE/db" -e '
    using PormG, HTTP, JSON
    ENV["DB"] == "sqlite" ? (@eval using SQLite) : (@eval using LibPQ)
    redirect_stderr(devnull) do
        include(joinpath(ENV["SMOKE_HERE"], "db", "world.jl"))
    end
    for id in parse.(Int, split(ENV["SMOKE_IDS"], ","))
        r = world().get("id" => id)
        println(r.id, " ", r.randomnumber)
    end' 2>/dev/null
}

i=0
for mode in $MODES; do
  port=$((BASE_PORT + i)); i=$((i + 1))
  log="$LOG_DIR/$mode.log"
  if [ "$mode" = go ]; then
    PORT="$port" "$GO_BIN" >"$log" 2>&1 &
  else
    MODE="$mode" PORT="$port" julia --startup-file=no --project="$SERVER_PROJECT" --threads=4 \
      "$HERE/server.jl" >"$log" 2>&1 &
  fi
  PIDS+=("$!")
  up=0
  for _ in $(seq 1 240); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null && { up=1; break; }
    sleep 0.5
  done
  [ "$up" = 1 ] || fail "$mode did not come up (log $log)"
  base="http://127.0.0.1:$port"

  body="$(curl -fsS "$base/db")" || fail "$mode /db status"
  jq -e 'type == "object" and (.id | type) == "number" and (.randomnumber | type) == "number" and .id >= 1 and .id <= 10000' <<<"$body" >/dev/null ||
    fail "$mode /db shape: $body"
  echo "ok  $mode /db $body"

  for n in 1 5 20; do
    body="$(curl -fsS "$base/queries?n=$n")" || fail "$mode /queries?n=$n status"
    jq -e --argjson n "$n" 'type == "array" and length == $n and all(.[]; (.id | type) == "number" and (.randomnumber | type) == "number")' <<<"$body" >/dev/null ||
      fail "$mode /queries?n=$n shape"
    echo "ok  $mode /queries?n=$n ($n rows)"
  done
  for q in "n=0" "n=foo" "n=501"; do
    want=$([ "$q" = "n=501" ] && echo 500 || echo 1)
    got="$(curl -fsS "$base/queries?$q" | jq length)"
    [ "$got" = "$want" ] || fail "$mode /queries?$q gave $got rows, expected $want"
  done
  echo "ok  $mode /queries clamps n (0 -> 1, foo -> 1, 501 -> 500)"

  body="$(curl -fsS "$base/updates?n=20")" || fail "$mode /updates status"
  jq -e 'type == "array" and length == 20 and ([.[].id] | unique | length) == 20' <<<"$body" >/dev/null ||
    fail "$mode /updates shape"
  want="$(jq -r '.[] | "\(.id) \(.randomnumber)"' <<<"$body" | sort -n)"
  got="$(SMOKE_HERE="$HERE" SMOKE_IDS="$(jq -r '[.[].id] | join(",")' <<<"$body")" read_back | sort -n)"
  [ -n "$got" ] && [ "$want" = "$got" ] || fail "$mode /updates did not write what it reported"
  echo "ok  $mode /updates?n=20 wrote 20 rows (read back)"

  if [ "$DB" = postgres ]; then
    t="$(curl -fsS -o /dev/null -w '%{time_total}' "$base/db_wait?ms=200")" || fail "$mode /db_wait status"
    awk -v t="$t" 'BEGIN { exit !(t >= 0.19 && t < 0.4) }' || fail "$mode /db_wait?ms=200 took ${t}s"
    echo "ok  $mode /db_wait?ms=200 took ${t}s"
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' "$base/db_wait?ms=200")"
    [ "$code" = 400 ] || fail "$mode /db_wait on sqlite answered $code, expected 400"
    echo "ok  $mode /db_wait refused on sqlite (400)"
  fi
  # What the server reported about the database at startup (never the conninfo).
  grep -h -A5 'bench: database' "$log" | grep -v 'bench: serving' | tr -s ' \n' ' ' | sed 's/^/    /'; echo
done
echo "smoke passed: DB=$DB, modes [$MODES]"
