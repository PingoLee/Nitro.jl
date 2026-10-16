#!/usr/bin/env bash
# The second unattended night run (#587, #588, #590), in decision order. About an hour.
#
#   1. #587  login flood: stall.sh, `login` and `login_bcrypt`, K = 1 2 4 8 16, at 8,1 and 8,0
#   2. #588  the two largest holds of the inventory (`Res.json` of ~12 MB, multipart of 64 MiB)
#            beside `/cpu`: stall.sh, K = 1 4 8 16, on Julia 1.12 and on 1.13.2 (#586)
#   3. #590  the kernel alone: bench/suite `aggregate` (one thread, BenchmarkTools minimum) and
#            `go test -bench Aggregate`
#   4. #590  throughput: run.sh on /aggregate groupby at N = 10^3 and 10^5, go / nitro@8,1 /
#            nitro@8,0 / bare_spawn at c=50, then N = 10^5 at c=500, with raw JSON and GC snapshots
#   5. #590  the knee: stall.sh on /aggregate groupby at N = 10^7, in the handler, through the
#            queue (&queue=1) and Go in the handler, K = 1 2 4 8 16
#   6. #590  the tail: gc_tail.jl over block 4's runs (p99, p99.9, GC deltas, Go gctrace)
#
# It first waits up to QUIET_WAIT_S (default 1800) for the 1-minute load average to fall under
# QUIET_LOAD (default 0.5), and aborts if it does not. A block that fails is logged and the next
# one runs. Everything goes to bench/results/night2-<stamp>.log; each script also leaves its own TSV
# and raw oha JSON under bench/results/.
#
# Usage: bench/socket/night2.sh
#   QUIET_LOAD=100 ROUNDS=1 DUR=2s BENCH_S=0.2 GO_COUNT=1 bench/socket/night2.sh   # a dry run
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT" || exit 1

QUIET_LOAD="${QUIET_LOAD:-0.5}"
QUIET_WAIT_S="${QUIET_WAIT_S:-1800}"
J12="${J12:-julia +1.12}"
J13="${J13:-julia +1.13.2}"
DUR="${DUR:-8s}"
ROUNDS="${ROUNDS:-3}"
BENCH_S="${BENCH_S:-3}"     # block 3: seconds per Julia row and per Go -benchtime
GO_COUNT="${GO_COUNT:-5}"   # block 3: go test -count; the report quotes the minimum
# One request of /aggregate groupby at N = 10^7 is ~115 ms on this box (suite/aggregate.jl); one
# hold request is ~200 ms (the `write_dict_10mb` row). They set the queued variant's offered rate
# and the settle time after each pass.
AGG_MS="${AGG_MS:-115}"
HOLD_MS="${HOLD_MS:-200}"
# Ports away from stall.sh's and run.sh's defaults, so a sibling session's bench cannot collide.
STALL_PORT="${STALL_PORT:-8680}"
RUN_PORT="${RUN_PORT:-8780}"
export PATH="$HOME/.local/go/bin:$PATH"

OUT="$ROOT/bench/results"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT/night2-$STAMP.log"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
load1() { cut -d' ' -f1 /proc/loadavg; }

say "night2: waiting for the 1-minute load average to fall under $QUIET_LOAD (at most ${QUIET_WAIT_S}s)"
waited=0
until awk -v l="$(load1)" -v q="$QUIET_LOAD" 'BEGIN { exit !(l < q) }'; do
  if [ "$waited" -ge "$QUIET_WAIT_S" ]; then
    say "night2: ABORTED -- load average still $(load1) after ${QUIET_WAIT_S}s; nothing was measured"
    echo "busy processes:"; ps -eo pid,pcpu,etime,comm --sort=-pcpu | head -8
    exit 2
  fi
  sleep 30; waited=$((waited + 30))
done
say "night2: quiet after ${waited}s (load $(load1)); starting"

say "environment"
echo "bench code: $(git rev-parse HEAD) ($(git rev-parse --abbrev-ref HEAD))$(git diff --quiet HEAD -- bench || echo ', bench/ DIRTY')"
echo "cpu: $(lscpu | sed -n 's/^Model name: *//p'); governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo "kernel: $(uname -r); oha: $(oha --version); go: $(go version)"
for j in "$J12" "$J13"; do echo "--- $j"; $j -e 'using InteractiveUtils; versioninfo()'; done
$J12 --project=bench -e 'using Pkg; Pkg.status(["HTTP", "JSON"])'

STATUS=()
block() {   # name, command...
  local name="$1"; shift
  say "BLOCK $name (load $(load1))"
  if "$@"; then STATUS+=("$name: ok"); else STATUS+=("$name: FAILED (exit $?)"); say "BLOCK $name FAILED"; fi
}

MULTIPART="bench/results/multipart-64mib.bin"
MULTIPART_CT="$($J12 bench/socket/multipart_body.jl "$MULTIPART")"

b1() {
  env PORT="$STALL_PORT" JULIA="$J12" KEEP_JSON=1 CPU_MS=200 KS="1 2 4 8 16" VARIANTS="login login_bcrypt" \
    bench/socket/stall.sh "nitro@8,1 nitro@8,0" "$ROUNDS" "$DUR"
}
b2() {
  local j
  for j in "$J12" "$J13"; do
    say "#588 on $j"
    env PORT="$STALL_PORT" JULIA="$j" KEEP_JSON=1 HOLDS=1 CPU_MS=200 ROUTE_MS="$HOLD_MS" ROUTE_CT="$MULTIPART_CT" KS="1 4 8 16" \
      VARIANTS="cpu route:/hold/json route:/hold/multipart@$MULTIPART" \
      bench/socket/stall.sh "nitro@8,1" "$ROUNDS" "$DUR" || return 1
  done
}
b3() {
  env NITRO_BENCH_GROUPS=aggregate NITRO_BENCH_SECONDS="$BENCH_S" taskset -c 5 $J12 --project=bench --threads=1 \
    bench/runbenchmarks.jl || return 1
  (cd bench/socket/go && taskset -c 5 go test -run 'TestAggregateChecksum|XXX' -v -bench Aggregate \
     -benchtime "${BENCH_S}s" -count "$GO_COUNT" .)
}
RUN4=""
b4() {
  local out
  out="$(env PORT="$RUN_PORT" JULIA="$J12" KEEP_JSON=1 GC_SNAPSHOTS=1 GODEBUG=gctrace=1 AGG_ROWS=10000000 \
    ROUTES="/aggregate?n=1000&op=groupby /aggregate?n=100000&op=groupby" \
    bench/socket/run.sh "go nitro@8,1 nitro@8,0 bare_spawn" "$ROUNDS" "$DUR" | tee /dev/stderr)" || return 1
  RUN4="$(sed -n 's/^results: \(.*\)\.tsv$/\1/p' <<<"$out")"
  say "#590 throughput at c=500"
  out="$(env PORT="$RUN_PORT" JULIA="$J12" CONNS=500 KEEP_JSON=1 GC_SNAPSHOTS=1 GODEBUG=gctrace=1 AGG_ROWS=10000000 \
    ROUTES="/aggregate?n=100000&op=groupby" \
    bench/socket/run.sh "go nitro@8,1 nitro@8,0 bare_spawn" "$ROUNDS" "$DUR" | tee /dev/stderr)" || return 1
  RUN4="$RUN4 $(sed -n 's/^results: \(.*\)\.tsv$/\1/p' <<<"$out")"
}
b5() {
  env PORT="$STALL_PORT" JULIA="$J12" KEEP_JSON=1 AGG_ROWS=10000000 ROUTE_MS="$AGG_MS" KS="1 2 4 8 16" \
    VARIANTS="route:/aggregate?n=10000000&op=groupby route:/aggregate?n=10000000&op=groupby&queue=1" \
    bench/socket/stall.sh "nitro@8,1 go" "$ROUNDS" "$DUR"
}
b6() {
  [ -n "$RUN4" ] || { echo "no run-4 results to read"; return 1; }
  local stem
  for stem in $RUN4; do
    say "tail of $stem"
    $J12 --project=bench bench/socket/gc_tail.jl "$stem" || return 1
  done
}

block "1 #587 login flood" b1
block "2 #588 holds, 1.12 and 1.13.2" b2
block "3 #590 kernel" b3
block "4 #590 throughput" b4
block "5 #590 knee" b5
block "6 #590 tail" b6

say "night2: done"
printf '  %s\n' "${STATUS[@]}"
echo "log: $LOG"
