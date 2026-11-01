#!/usr/bin/env bash
# #744's timing rounds: STARTS starts of every build, the build order alternating between starts
# (forward, reverse, forward, …), each build's block under bench/socket/quiet.sh. A block is
# measure.sh's `rss` then its `first` (one fresh process per route). Then the min and the median
# of each reading, per build and route.
#
#   bench/juliac/realapp/rounds.sh jit=jit native=out/realapp-main-no-native default=out/realapp-main-no-default
#
# Env: STARTS (default 3), FIRST_MODE (default `first`; `first_after_ready` times the first
#      request after the app's READY line instead of after the socket, #744), RESULTS (default bench/results/realapp-rounds-<stamp>.tsv), plus
#      measure.sh's (SECRETS and AUTH_HEADER are required). The quiet gate's summaries go to
#      stdout with the readings.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
STARTS=${STARTS:-3}
FIRST_MODE=${FIRST_MODE:-first}
RESULTS=${RESULTS:-"$ROOT/bench/results/realapp-rounds-$(date +%Y%m%d-%H%M%S).tsv"}
[ $# -gt 0 ] || { echo "usage: rounds.sh label=target..."; exit 2; }
BUILDS=("$@")
: > "$RESULTS"

for s in $(seq 1 "$STARTS"); do
  order=("${BUILDS[@]}")
  if [ $((s % 2)) = 0 ]; then
    order=(); for ((i = ${#BUILDS[@]} - 1; i >= 0; i--)); do order+=("${BUILDS[$i]}"); done
  fi
  for b in "${order[@]}"; do
    label=${b%%=*}; target=${b#*=}
    echo "== start $s: $label"
    "$ROOT/bench/socket/quiet.sh" "realapp-$label-s$s" bash -c '
      "$1/measure.sh" rss "$2" "$3" && "$1/measure.sh" "$4" "$2" "$3"' _ "$HERE" "$target" "$label" "$FIRST_MODE" |
      tee /dev/stderr | awk -v s="$s" -F'\t' '$1 == "rss" || $1 ~ /^first/ { print s "\t" $0 }' >> "$RESULTS"
    [ "${PIPESTATUS[0]}" = 0 ] || { echo "rounds.sh: block $label start $s failed"; exit 1; }
  done
done

echo "== min / median over $STARTS starts ($RESULTS)"
# Each reading is key=value; group by build, route and key.
awk -F'\t' '{
    for (i = 5; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "status") continue
      k = $3 "\t" $4 "\t" kv[1]; n[k]++; v[k, n[k]] = kv[2] + 0 } }
  END {
    for (k in n) {
      m = n[k]; for (i = 1; i <= m; i++) a[i] = v[k, i]
      for (i = 2; i <= m; i++) { x = a[i]; j = i - 1; while (j > 0 && a[j] > x) { a[j + 1] = a[j]; j-- } a[j + 1] = x }
      med = (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
      printf "%s\tmin=%g\tmedian=%g\tn=%d\n", k, a[1], med, m } }' "$RESULTS" | sort
