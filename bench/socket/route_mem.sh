#!/usr/bin/env bash
# Resident memory against the route count, for one or more builds (#728): does a cost scale with
# routes, or is it fixed code?
#
# For each repeat, each build in ROOTS (the order reverses on every other repeat) and each count in
# COUNTS, it starts bench/socket/server.jl with FILLER_ROUTES=<count> and ROUTE_MW=1, pinned to
# SERVER_CPUS, and records:
#
#   listen_s    launch to listening socket (`ss`, as rss.sh does: no request before the first read)
#   rss_rest    VmRSS once listening, before any request
#   *_rest      `/mem` right after (it collects first): gc_live_bytes, jit_total_bytes, and the
#               summarysize of the router, the route middleware, the chain records and the App
#   rss_warm    VmRSS after one request to every route of the table (the first-request JIT paid)
#   *_warm      `/mem` again
#   pkgimage    the size of the Nitro package image the server loaded
#
# SMAPS=1 also writes, at rest, the server's resident memory per mapping (`/proc/<pid>/smaps`, Rss
# summed by mapping name: a file path, `[heap]`, `[stack]`, or `[anon]` for an unnamed one, which
# is where thread stacks and malloc arenas land) to route_mem-<stamp>-smaps.tsv. That breaks down
# the RSS `/mem` does not account for: outside the GC heap, the JIT and Nitro's image (#728).
#
# Every build is served by THIS checkout's server.jl and route_table.jl; ROOTS only picks the bench
# env, and so the Nitro, each server loads.
#
# Usage: ROOTS="main=/wt/main branch=/wt/branch" bench/socket/route_mem.sh [counts] [repeats]
#   ROOTS="old=/wt/a new=/wt/b" bench/socket/route_mem.sh "0 100 1000" 2
# Results: bench/results/route_mem-<stamp>.tsv (gitignored).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNTS="${1:-0 100 1000}"
REPEATS="${2:-2}"
THREADS="${THREADS:-8}"
PORT="${PORT:-8093}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,3,6,7,8,9}"
ROOTS="${ROOTS:-here=$ROOT}"
read -r -a JULIA_CMD <<<"${JULIA:-julia}"

for tool in curl ss jq taskset "${JULIA_CMD[0]}"; do
  command -v "$tool" >/dev/null || { echo "route_mem.sh: $tool not on PATH" >&2; exit 1; }
done
read -r -a PAIRS <<<"$ROOTS"
for pair in "${PAIRS[@]}"; do
  case "$pair" in *=*) ;; *) echo "route_mem.sh: ROOTS entry '$pair' is not name=path" >&2; exit 1 ;; esac
done

OUT="$ROOT/bench/results"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT/route_mem-$STAMP.tsv"
printf 'build\troutes\trepeat\tlisten_s\trss_rest_mib\tlive_rest_mib\tjit_rest_mib\trouter_kib\tmiddleware_kib\tchains_kib\tapp_kib\trss_warm_mib\tlive_warm_mib\tjit_warm_mib\tpkgimage_mib\n' > "$RESULT"
SMAPS="${SMAPS:-0}"
SMAPS_OUT="$OUT/route_mem-$STAMP-smaps.tsv"
if [ "$SMAPS" = 1 ]; then printf 'build\troutes\trepeat\tmapping\trss_kib\n' > "$SMAPS_OUT"; fi
echo "route_mem.sh: $("${JULIA_CMD[@]}" --version), --threads=$THREADS, CPUs $SERVER_CPUS, counts [$COUNTS] x $REPEATS"
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"

pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null' EXIT
kib() { awk -v k="$2:" '$1 == k { print $2 }' "/proc/$1/status"; }
listener_pid() { ss -Hltnp "sport = :$1" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; }

# One curl config that requests every route of the table once, over one connection.
warm_config() {   # count -> file
  local f="$OUT/route_mem-$STAMP-warm-$1.curl"
  : > "$f"
  for r in /plaintext /json /health /mw; do printf 'url = "http://127.0.0.1:%s%s"\noutput = "/dev/null"\n' "$PORT" "$r" >> "$f"; done
  for i in $(seq 1 "$1"); do
    printf 'url = "http://127.0.0.1:%s/g%s/fill/%s"\noutput = "/dev/null"\n' "$PORT" $(( (i - 1) % 3 + 1 )) "$i" >> "$f"
  done
  printf '%s' "$f"
}

for rep in $(seq 1 "$REPEATS"); do
  order=("${PAIRS[@]}")
  if [ $((rep % 2)) = 0 ]; then
    order=(); for ((k = ${#PAIRS[@]} - 1; k >= 0; k--)); do order+=("${PAIRS[$k]}"); done
  fi
  for pair in "${order[@]}"; do
    build="${pair%%=*}"; broot="${pair#*=}"
    for n in $COUNTS; do
      if [ -n "$(ss -Hltn "sport = :$PORT")" ]; then
        echo "route_mem.sh: port $PORT is already in use; stop that listener or set PORT" >&2; exit 1
      fi
      log="$OUT/route_mem-$STAMP-$build-$n-r$rep.log"
      t0=$(date +%s.%N)
      MODE=nitro PORT="$PORT" FILLER_ROUTES="$n" ROUTE_MW=1 WARMUP=0 \
        taskset -c "$SERVER_CPUS" "${JULIA_CMD[@]}" --startup-file=no --project="$broot/bench" \
        --threads="$THREADS" "$HERE/server.jl" >"$log" 2>&1 &
      pid=$!
      until [ -n "$(ss -Hltn "sport = :$PORT")" ]; do
        kill -0 "$pid" 2>/dev/null || { echo "route_mem.sh: $build N=$n died; tail of $log:" >&2; tail -20 "$log" >&2; exit 1; }
        sleep 0.05
      done
      t1=$(date +%s.%N)
      spid="$(listener_pid "$PORT")"
      rss_rest=$(kib "$spid" VmRSS)
      mem_rest=$(curl -fsS "http://127.0.0.1:$PORT/mem")
      if [ "$SMAPS" = 1 ]; then
        awk -v b="$build" -v n="$n" -v r="$rep" '
          /^[0-9a-f]+-[0-9a-f]+ / { name = (NF >= 6) ? $6 : "[anon]"; for (i = 7; i <= NF; i++) name = name " " $i; next }
          $1 == "Rss:" { rss[name] += $2 }
          END { for (k in rss) if (rss[k] > 0) printf "%s\t%s\t%s\t%s\t%d\n", b, n, r, k, rss[k] }' \
          "/proc/$spid/smaps" >> "$SMAPS_OUT"
      fi
      curl -fsS -K "$(warm_config "$n")" || echo "route_mem.sh: a warm-up request failed ($build N=$n)" >&2
      rss_warm=$(kib "$spid" VmRSS)
      mem_warm=$(curl -fsS "http://127.0.0.1:$PORT/mem")
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=""
      m() { jq -r --arg k "$2" --argjson d "$3" '.[$k] / $d * 10 | round / 10' <<<"$1"; }
      row=$(printf '%s\t%s\t%s\t%.2f\t%.1f\t%s\t%s\t%s\t%s\t%s\t%s\t%.1f\t%s\t%s\t%s' \
        "$build" "$n" "$rep" "$(echo "$t1 - $t0" | bc)" "$(echo "$rss_rest / 1024" | bc -l)" \
        "$(m "$mem_rest" gc_live_bytes 1048576)" "$(m "$mem_rest" jit_total_bytes 1048576)" \
        "$(m "$mem_rest" router_bytes 1024)" "$(m "$mem_rest" middleware_bytes 1024)" \
        "$(m "$mem_rest" chains_bytes 1024)" "$(m "$mem_rest" app_bytes 1024)" \
        "$(echo "$rss_warm / 1024" | bc -l)" "$(m "$mem_warm" gc_live_bytes 1048576)" \
        "$(m "$mem_warm" jit_total_bytes 1048576)" "$(m "$mem_rest" pkgimage_bytes 1048576)")
      printf '%s\n' "$row" >> "$RESULT"
      printf '%s\n' "$row"
      # Let the port leave TIME_WAIT's listener table before the next start.
      sleep 1
    done
  done
done
echo "results: $RESULT"
if [ "$SMAPS" = 1 ]; then echo "smaps: $SMAPS_OUT"; fi
