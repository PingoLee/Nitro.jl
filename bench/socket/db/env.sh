# Sourced by run.sh and stall.sh (HERE and ROOT set): the DB knob of the socket bench.
# The database routes (#589). DB=postgres|sqlite serves every Julia mode from the db/ env with
# PormG and the driver preloaded, and passes DB, DB_POOL and DB_CONNINFO_FILE to every server
# (db/world.jl, go/db.go). PostgreSQL itself runs outside the script; pin it with taskset to CPUs
# that are neither SERVER_CPUS nor CLIENT_CPUS, and say which beside the table.
#
# PG_DRIVER=LibPQ|Postgres picks PormG's PostgreSQL driver for the Julia modes (default LibPQ, as
# PormG's own default): Postgres preloads Postgres.jl and sets PORMG_POSTGRES_DRIVER, which PormG
# reads when its configuration names no driver. Go always runs pgx.
SERVER_PROJECT="$ROOT/bench"
DB="${DB:-}"
if [ -n "$DB" ]; then
  case "$DB" in
    postgres)
      case "${PG_DRIVER:=LibPQ}" in
        LibPQ)    db_preload="PormG LibPQ" ;;
        Postgres) db_preload="PormG Postgres"; export PORMG_POSTGRES_DRIVER=Postgres ;;
        *) echo "$(basename "$0"): PG_DRIVER=$PG_DRIVER: expected LibPQ or Postgres" >&2; exit 1 ;;
      esac ;;
    sqlite)   db_preload="PormG SQLite" ;;
    *) echo "$(basename "$0"): DB=$DB: expected postgres or sqlite" >&2; exit 1 ;;
  esac
  export DB DB_POOL="${DB_POOL:-32}" DB_CONNINFO_FILE="${DB_CONNINFO_FILE:-$HERE/db/conninfo}"
  export PRELOAD="${PRELOAD:+$PRELOAD }$db_preload"
  SERVER_PROJECT="$HERE/db"
fi
# One line for the table's header: the backend, the pool, and for PostgreSQL the CPUs its
# postmaster is pinned to (the port is read from the conninfo; nothing else of it is printed).
db_banner() {
  [ -n "$DB" ] || return 0
  local line="database: DB=$DB, DB_POOL=$DB_POOL (PormG grows to $((DB_POOL * 10)); go mirrors both)"
  if [ "$DB" = postgres ]; then
    line="$line, driver $PG_DRIVER"
    local port pid
    port="$(grep -o 'port=[0-9]*' "$DB_CONNINFO_FILE" | head -1 | cut -d= -f2)"
    pid="$(ss -Hltnp "sport = :${port:-5432}" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
    line="$line, postgres CPUs $( [ -n "$pid" ] && taskset -cp "$pid" | awk '{print $NF}' || echo unknown)"
  fi
  echo "$line"
}
# A PormG route's first request compiles for seconds. Under `oha -c 500` every one of those first
# requests holds a pooled connection while it waits for the compile, the rest wait for a
# connection, and the warm-up ends in `PoolTimeoutError`s instead of a warm server. So each route
# is first requested alone, a few times, before any concurrent warm-up.
db_prewarm() {   # port route...
  [ -n "$DB" ] || return 0
  local port="$1" route; shift
  for route in "$@"; do
    route="${route#*:}"; case "$route" in /*) ;; *) continue ;; esac
    for _ in 1 2 3; do curl -s -o /dev/null -m 300 "http://127.0.0.1:$port$route"; done
  done
}

# psql against the conninfo, its fields passed in the environment of psql alone, so the password
# is on no command line. The conninfo is `key=value` words without quoting.
db_psql() {
  (
    for kv in $(cat "$DB_CONNINFO_FILE"); do
      case "$kv" in
        host=*) export PGHOST="${kv#*=}" ;; port=*) export PGPORT="${kv#*=}" ;;
        user=*) export PGUSER="${kv#*=}" ;; dbname=*) export PGDATABASE="${kv#*=}" ;;
        password=*) export PGPASSWORD="${kv#*=}" ;;
      esac
    done
    psql -X -v ON_ERROR_STOP=1 "$@"
  )
}

# A window `oha` ends leaves its requests running in the server: a route slower than the window
# (`/updates?n=20` at c=500) would then load PostgreSQL while the next mode is measured. Before
# each window, wait until PostgreSQL has run no statement for this database in two readings
# 0.5 s apart (at most 120 s). SQLite has no such view; it waits DB_SETTLE_S (default 3) instead.
db_settle() {
  [ -n "$DB" ] || return 0
  if [ "$DB" = sqlite ]; then sleep "${DB_SETTLE_S:-3}"; return 0; fi
  command -v psql >/dev/null || { sleep "${DB_SETTLE_S:-3}"; return 0; }
  local quiet=0 n
  for _ in $(seq 1 240); do
    n="$(db_psql -tA -c "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()
                          AND pid <> pg_backend_pid() AND state <> 'idle'" 2>/dev/null)"
    if [ "$n" = 0 ]; then quiet=$((quiet + 1)); [ "$quiet" -ge 2 ] && return 0; else quiet=0; fi
    sleep 0.5
  done
  echo "db_settle: PostgreSQL still running statements after 120 s" >&2
}
