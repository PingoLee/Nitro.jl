#!/usr/bin/env bash
# Julia tasks vs goroutines, same box, same run (#469 part 2). Both sides are pinned to the same
# CPUs, and the Julia `:default` thread count equals GOMAXPROCS: the number of those CPUs.
#
#   Go:    go/tasks_test.go (`go test -bench`, COUNT passes), then go/main.go `parked` and `spin`,
#          the latter once more with GODEBUG=asyncpreemptoff=1 (Julia's cooperative model, in Go).
#   Julia: tasks.jl `micro parked spin` at --threads=N,1.
#
# Usage: bench/tasks/run.sh
#   CPUS=0,1,2,3,6,7,8,9 COUNT=5 JULIA="julia +1.12" bench/tasks/run.sh
#
# Output: everything is printed and kept in bench/results/tasks-<stamp>.txt (gitignored).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CPUS="${CPUS:-0,1,2,3,6,7,8,9}"
COUNT="${COUNT:-5}"
read -r -a JULIA_CMD <<<"${JULIA:-julia}"

for tool in go taskset nproc "${JULIA_CMD[0]}"; do
  command -v "$tool" >/dev/null || { echo "tasks/run.sh: $tool not on PATH" >&2; exit 1; }
done
N="$(taskset -c "$CPUS" nproc)"
OUT="$ROOT/bench/results"
mkdir -p "$OUT"
RESULT="$OUT/tasks-$(date +%Y%m%d-%H%M%S).txt"

{
  echo "tasks bench: CPUs $CPUS (N=$N), $(lscpu | sed -n 's/^Model name: *//p')"
  echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
  echo "go: $(go version)"
  echo "julia: $("${JULIA_CMD[@]}" --version)"

  (cd "$HERE/go" && GOMAXPROCS="$N" taskset -c "$CPUS" go test -run '^$' -bench . -benchmem -count "$COUNT")
  (cd "$HERE/go" && go build -o "$OUT/go-tasks" .) || exit 1
  GOMAXPROCS="$N" taskset -c "$CPUS" "$OUT/go-tasks" parked
  GOMAXPROCS="$N" taskset -c "$CPUS" "$OUT/go-tasks" spin
  GOMAXPROCS="$N" GODEBUG=asyncpreemptoff=1 taskset -c "$CPUS" "$OUT/go-tasks" spin

  taskset -c "$CPUS" "${JULIA_CMD[@]}" --project="$ROOT/bench" --threads="$N,1" "$HERE/tasks.jl" micro parked spin
} 2>&1 | tee "$RESULT"
echo "results: $RESULT"
