#!/usr/bin/env bash
# How evenly does each server serve C connections at once? (#590 H3)
#
# At c=500 on `/aggregate?n=100000&op=groupby`, Nitro's p99 was ~2 s against Go's ~163 ms at
# similar throughput, while GC took 3-5% of the window. Pooled percentiles cannot say whether
# every connection waits a little or a few wait a lot. `go/fairness` keeps C keep-alive
# connections busy, one request at a time each, and reports requests per connection (min, p1,
# p10, median, Jain's index), every request's latency and each connection's longest wait.
#
# Modes as in run.sh: `nitro` (`serve()`), `bare_spawn` (HTTP.jl + one `Threads.@spawn` per
# request, no Nitro: is the unevenness Nitro's or the runtime's?), `bare_nospawn`, `bare_pool`,
# `go`. `mode@threads` starts that server with its own `--threads` (`nitro@8,0 nitro@6,2`, #618);
# a bare name takes THREADS. `mode@threads@VARIANT` also starts it with that scheduler VARIANT
# (`bare_marked@8,1@M-g-r2`, #618; see server.jl): the variant is part of the server's label, so
# its log, its TSV rows and its probe files are its own. Without the third field the server gets
# no VARIANT at all and never includes the variant file. VALIDATE=1 passes through to every Julia
# server, and `/mq` (the classification counts) is saved after each of its runs as
# `<stem>-mq.json`, with one read just before the run as `<stem>-mq0.json`, so the read after
# covers the run alone. Rounds are interleaved.
#
# PROBE=1 (#618) starts the Julia servers with PROBE=1 and runs the client with `-stamp`, then
# keeps, per run, the client's per-request trace and the server's `/probe` rows under the raw
# directory; `probe_report.jl <raw dir>` joins them into where each slow request's time went.
#
# Around every run: a Julia server's `/gc` before and after (`<stem>-gc0.json`, `-gc1.json`; the
# TSV's gc_n and gc_ms are the collections and their time in the window), the server's VmRSS after
# it, and the box's swap-ins and swap-outs (`pswpin`/`pswpout` of /proc/vmstat) over the window:
# every server of a round is up at once, and a page read back from swap reads as latency. Also
# the kernel's ListenOverflows over the window (TcpExt, /proc/net/netstat): the client opens its C
# connections at once on its first requests, and a connect the accept queue (HTTP.jl's backlog,
# 128 by default) drops is retried by the client's kernel a second later, which the probe sees as
# a first request waiting ~1 s before its connection task.
#
# OHA=1 (cell 2, #618): after the client's run, `oha` drives the same route for the same duration
# and connections, and its throughput is the TSV's oha_rps (otherwise -).
#
# MIX=1 (cell 4, #618): the Julia servers start with MIX=1, and each run of a bare mode is
# bracketed by `/mix?on=1` and `/mix?on=0`, so unmarked fib_fine runs loop on `:default` only during
# that server's own window; the runs and their walls are kept as `<stem>-mix.json`.
#
# JULIAS="<label>=<julia binary>,<project dir> ..." with a mode spec ending in `%<label>`
# (`bare_spawn@8,0%ws`) starts that server on another Julia build and environment, so servers of
# several builds interleave in one block (#618, the stall repro's part 2).
#
# Usage: bench/socket/fairness.sh [modes] [rounds] [duration]
#   ROUTE="/aggregate?n=100000&op=groupby" CONNS=500 bench/socket/fairness.sh "nitro bare_spawn go" 3 8s
#   PROBE=1 bench/socket/fairness.sh "nitro bare_spawn bare_nospawn bare_pool" 3 8s
#
# Results: bench/results/fairness-<stamp>.tsv (one line per run) and the JSON reports beside it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

MODES="${1:-nitro bare_spawn go}"
ROUNDS="${2:-3}"
DUR="${3:-8s}"
ROUTE="${ROUTE:-/aggregate?n=100000&op=groupby}"
CONNS="${CONNS:-500}"
THREADS="${THREADS:-8}"
AGG_ROWS="${AGG_ROWS:-10000000}"
BASE_PORT="${PORT:-8880}"
PROBE="${PROBE:-0}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,3,6,7,8,9}"
CLIENT_CPUS="${CLIENT_CPUS:-4,5,10,11}"
read -r -a JULIA_CMD <<<"${JULIA:-julia}"
read -r -a MODE_LIST <<<"$MODES"
for tool in go oha jq curl taskset ss "${JULIA_CMD[0]}"; do
  command -v "$tool" >/dev/null || { echo "fairness.sh: $tool not on PATH" >&2; exit 1; }
done

OUT="$ROOT/bench/results"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/fairness-$STAMP.tsv"
RAW="$OUT/fairness-$STAMP-raw"; mkdir -p "$RAW"
GO_BIN="$OUT/go-server"; CLIENT="$OUT/fairness"
(cd "$HERE/go" && go build -o "$GO_BIN" . && go build -o "$CLIENT" ./fairness) || { echo "fairness.sh: go build failed" >&2; exit 1; }

# `nitro@8,0` -> name `nitro`, threads `8,0`, file label `nitro-8_0`;
# `bare_marked@8,1@M-g-r2` -> variant `M-g-r2` too, label `bare_marked-8_1-M-g-r2`.
# `bare_spawn@8,0%ws` -> the server runs on the build labelled `ws` in JULIAS (#618, the stall repro's
# part 2), label `bare_spawn-8_0-ws`.
mode_core()    { printf '%s' "${1%%\%*}"; }
mode_build()   { case "$1" in *%*) printf '%s' "${1##*%}" ;; esac; }
mode_name()    { local m; m="$(mode_core "$1")"; printf '%s' "${m%%@*}"; }
mode_threads() { local m; m="$(mode_core "$1")"; case "$m" in *@*) local t="${m#*@}"; printf '%s' "${t%%@*}" ;; *) printf '%s' "$THREADS" ;; esac; }
mode_variant() { local m; m="$(mode_core "$1")"; case "$m" in *@*@*) printf '%s' "${m##*@}" ;; esac; }
mode_label()   { printf '%s' "$1" | tr '@,%' '-_-'; }
declare -A BUILD_BIN BUILD_PROJECT
for kv in ${JULIAS:-}; do   # "<label>=<julia binary>,<project dir>"
  v="${kv#*=}"; BUILD_BIN["${kv%%=*}"]="${v%%,*}"; BUILD_PROJECT["${kv%%=*}"]="${v#*,}"
done
listen_ovf()   { awk '/^TcpExt:/ { if (!h) { for (i = 1; i <= NF; i++) if ($i == "ListenOverflows") c = i; h = 1 } else print $c }' /proc/net/netstat; }
swap_counts()  { awk '$1 == "pswpin" { i = $2 } $1 == "pswpout" { o = $2 } END { print i, o }' /proc/vmstat; }
rss_mb()       { awk '$1 == "VmRSS:" { printf "%d", $2 / 1024 }' "/proc/$1/status" 2>/dev/null || printf -- '-'; }

PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; wait 2>/dev/null' EXIT
declare -A PORT_OF PID_OF
i=0
for mode in "${MODE_LIST[@]}"; do
  port=$((BASE_PORT + i)); i=$((i + 1))
  [ -n "$(ss -Hltn "sport = :$port")" ] && { echo "fairness.sh: port $port in use" >&2; exit 1; }
  log="$OUT/fairness-$STAMP-$(mode_label "$mode").log"
  if [ "$(mode_name "$mode")" = go ]; then
    GOMAXPROCS="$(taskset -c "$SERVER_CPUS" nproc)" PORT="$port" AGG_ROWS="$AGG_ROWS" taskset -c "$SERVER_CPUS" "$GO_BIN" >"$log" 2>&1 &
  else
    variant="$(mode_variant "$mode")"
    build="$(mode_build "$mode")"
    jcmd=("${JULIA_CMD[@]}"); jproject="$ROOT/bench"
    if [ -n "$build" ]; then
      [ -n "${BUILD_BIN[$build]:-}" ] || { echo "fairness.sh: $mode: no JULIAS entry for $build" >&2; exit 1; }
      jcmd=("${BUILD_BIN[$build]}"); jproject="${BUILD_PROJECT[$build]}"
    fi
    env MODE="$(mode_name "$mode")" PORT="$port" AGG_ROWS="$AGG_ROWS" PROBE="$PROBE" VALIDATE="${VALIDATE:-0}" MIX="${MIX:-0}" \
      ${variant:+VARIANT="$variant"} taskset -c "$SERVER_CPUS" \
      "${jcmd[@]}" --project="$jproject" --threads="$(mode_threads "$mode")" "$HERE/server.jl" >"$log" 2>&1 &
  fi
  PIDS+=("$!")
  PID_OF[$mode]=$!
  for _ in $(seq 1 240); do curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null && break; sleep 0.5; done
  curl -fsS -o /dev/null "http://127.0.0.1:$port/health" || { echo "fairness.sh: $mode did not come up" >&2; tail -20 "$log" >&2; exit 1; }
  PORT_OF[$mode]=$port
done

echo "fairness bench: modes [$MODES], $ROUTE, c=$CONNS, $ROUNDS x $DUR interleaved$([ "$PROBE" = 1 ] && printf ', PROBE=1')"
echo "  server CPUs $SERVER_CPUS (--threads=$THREADS unless mode@threads; go GOMAXPROCS=$(taskset -c "$SERVER_CPUS" nproc)), client CPUs $CLIENT_CPUS"
echo "  concurrency bounds: serve() max_concurrent_requests at its default (nothing: no cap); HTTP.jl listen! defaults (no HTTP/1 connection cap); bare_pool POOL=${POOL:-nthreads(:default)}"
echo "  julia: $("${JULIA_CMD[@]}" --version); $(go version)"
for mode in "${MODE_LIST[@]}"; do
  taskset -c "$CLIENT_CPUS" oha -z 3s -c "$CONNS" --no-tui "http://127.0.0.1:${PORT_OF[$mode]}$ROUTE" >/dev/null 2>&1
done

printf 'mode\tround\trps\tp50_ms\tp99_ms\tp999_ms\tmax_ms\tshare_over_1s\tconn_min\tconn_p1\tconn_p10\tconn_p50\tconn_max\tjain\tmaxwait_p50_ms\tmaxwait_p90_ms\tp90_ms\tgc_n\tgc_ms\trss_mb\tswap_in\tswap_out\tlisten_ovf\toha_rps\n' > "$RESULT"
for round in $(seq 1 "$ROUNDS"); do
  for mode in "${MODE_LIST[@]}"; do
    stem="$RAW/r$round-$(mode_label "$mode")"
    js="$stem.json"
    probe_args=()
    [ "$PROBE" = 1 ] && probe_args=(-stamp -trace "$stem-client.tsv")
    julia_server=0; [ "$(mode_name "$mode")" != go ] && julia_server=1
    [ "$julia_server" = 1 ] && curl -fsS -m 30 -o "$stem-gc0.json" "http://127.0.0.1:${PORT_OF[$mode]}/gc"
    # VALIDATE: a `/mq` just before the window (#618, the `8,0` diagnostic), so the one after it
    # covers this run alone, not the start-up, the warm-up or the previous rounds.
    if [ "$julia_server" = 1 ] && [ "${VALIDATE:-0}" = 1 ]; then
      case "$(mode_name "$mode")" in bare_*)
        curl -fsS -m 60 -o "$stem-mq0.json" "http://127.0.0.1:${PORT_OF[$mode]}/mq" ;;
      esac
    fi
    read -r swin0 swout0 < <(swap_counts)
    lo0="$(listen_ovf)"
    mixing=0
    [ "${MIX:-0}" = 1 ] && case "$(mode_name "$mode")" in bare_*) mixing=1 ;; esac
    [ "$mixing" = 1 ] && curl -fsS -m 60 -o /dev/null "http://127.0.0.1:${PORT_OF[$mode]}/mix?on=1"
    GOMAXPROCS="$(taskset -c "$CLIENT_CPUS" nproc)" taskset -c "$CLIENT_CPUS" "$CLIENT" \
      -url "http://127.0.0.1:${PORT_OF[$mode]}$ROUTE" -c "$CONNS" -d "$DUR" ${probe_args[@]+"${probe_args[@]}"} >"$js"
    [ "$mixing" = 1 ] && curl -fsS -m 600 -o "$stem-mix.json" "http://127.0.0.1:${PORT_OF[$mode]}/mix?on=0"
    # The client has waited for every response, so no request is still in flight.
    [ "$PROBE" = 1 ] && [ "$(mode_name "$mode")" != go ] &&
      curl -fsS -m 60 -o "$stem-server.tsv" "http://127.0.0.1:${PORT_OF[$mode]}/probe"
    read -r swin1 swout1 < <(swap_counts)
    lo1="$(listen_ovf)"
    rss="$(rss_mb "${PID_OF[$mode]}")"
    gc_n=-; gc_ms=-
    if [ "$julia_server" = 1 ]; then
      curl -fsS -m 30 -o "$stem-gc1.json" "http://127.0.0.1:${PORT_OF[$mode]}/gc"
      gc_n="$(jq -n --slurpfile a "$stem-gc0.json" --slurpfile b "$stem-gc1.json" '$b[0].pause - $a[0].pause')"
      gc_ms="$(jq -n --slurpfile a "$stem-gc0.json" --slurpfile b "$stem-gc1.json" '($b[0].total_time - $a[0].total_time) / 1e6 | . * 10 | round / 10')"
      case "$(mode_name "$mode")" in bare_*)
        [ "${VALIDATE:-0}" = 1 ] && curl -fsS -m 60 -o "$stem-mq.json" "http://127.0.0.1:${PORT_OF[$mode]}/mq" ;;
      esac
    fi
    oha_rps=-
    if [ "${OHA:-0}" = 1 ]; then
      taskset -c "$CLIENT_CPUS" oha -z "$DUR" -c "$CONNS" --no-tui --output-format json \
        "http://127.0.0.1:${PORT_OF[$mode]}$ROUTE" > "$stem-oha.json" 2>/dev/null
      oha_rps="$(jq '.summary.requestsPerSec | floor' "$stem-oha.json" 2>/dev/null || printf -- '-')"
    fi
    row="$(jq -r --arg m "$mode" --arg r "$round" '[$m, $r, (.rps | floor), .latency_ms.p50, .latency_ms.p99, .latency_ms.p999,
        .latency_ms.max, .share_over_1s, .per_conn_count.min, .per_conn_count.p1, .per_conn_count.p10,
        .per_conn_count.p50, .per_conn_count.max, .jain_index, .per_conn_max_wait_ms.p50,
        .per_conn_max_wait_ms.p90, .latency_ms.p90] | map(if type == "number" then (. * 1000 | round / 1000) else . end) | @tsv' "$js")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$row" "$gc_n" "$gc_ms" "$rss" "$((swin1 - swin0))" "$((swout1 - swout0))" \
      "$((lo1 - lo0))" "$oha_rps" >> "$RESULT"
    sleep 2
  done
done

echo
printf '| mode | rps | p50 ms | p90 ms | p99 ms | p99.9 ms | max ms | share > 1 s | requests per connection: min / p1 / p10 / median / max | Jain | longest wait per connection: median / p90 ms | GC: collections / ms | RSS MB | swap in / out (pages, summed) | listen overflows (summed) | oha rps |\n'
printf '|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|\n'
for mode in "${MODE_LIST[@]}"; do
  awk -F'\t' -v m="$mode" '
    function med(c,   n, i, j, v, x) { n = 0; for (i = 1; i <= rows; i++) v[++n] = col[i, c] + 0
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { x = v[i]; v[i] = v[j]; v[j] = x }
      return (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2 }
    function rng(c,   n, i, lo, hi) { lo = hi = col[1, c] + 0; for (i = 2; i <= rows; i++) { if (col[i, c] + 0 < lo) lo = col[i, c] + 0; if (col[i, c] + 0 > hi) hi = col[i, c] + 0 }
      return sprintf("%g [%g–%g]", med(c), lo, hi) }
    NR > 1 && $1 == m { rows++; for (c = 3; c <= 24; c++) col[rows, c] = $c; si += $21; so += $22; lo += $23 }
    END { printf "| %s | %s | %s | %s | %s | %s | %s | %s | %g / %g / %g / %g / %g | %s | %g / %g | %s / %s | %s | %d / %d | %d | %s |\n", m, rng(3), rng(4), rng(17), rng(5), rng(6), rng(7), rng(8),
          med(9), med(10), med(11), med(12), med(13), rng(14), med(15), med(16), rng(18), rng(19), rng(20), si, so, lo, rng(24) }' "$RESULT"
done
echo "results: $RESULT"
