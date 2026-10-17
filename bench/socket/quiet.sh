#!/usr/bin/env bash
# Run one bench block on a quiet box, and say whether it stayed quiet (#588, #587, #590).
#
# Gate: wait until no julia, oha or go-server process exists and the 1-minute load average is under
# QUIET_LOAD (default 0.5), for at most QUIET_WAIT_S (default 1800); past that the block is not run
# (exit 3). Then the command runs in a session of its own, and a sampler records every SAMPLE_S
# (default 5) seconds the load average, any julia/oha/go-server process OUTSIDE that session, and
# the outside processes using more than 5% of a CPU. One foreign julia/oha/go-server stops the block
# (its session is sent SIGTERM; exit 4). The summary goes to stdout and the samples to
# bench/results/quiet-<label>-<stamp>.tsv.
#
# Usage: bench/socket/quiet.sh <label> <command...>
#   bench/socket/quiet.sh holds-1.12 env JULIA="julia +1.12" bench/socket/stall.sh nitro 3 8s
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LABEL="$1"; shift
QUIET_LOAD="${QUIET_LOAD:-0.5}"
QUIET_WAIT_S="${QUIET_WAIT_S:-1800}"
SAMPLE_S="${SAMPLE_S:-5}"
OUT="$ROOT/bench/results"; mkdir -p "$OUT"
SAMPLES="$OUT/quiet-$LABEL-$(date +%Y%m%d-%H%M%S).tsv"

load1() { cut -d' ' -f1 /proc/loadavg; }
# julia/oha/go-server processes not in session $1 (empty: any session), as "pid:comm" words.
foreign() {
  ps -eo pid=,sid=,comm= | awk -v sid="${1:-}" \
    '($3 == "julia" || $3 == "oha" || $3 == "go-server") && $2 != sid { printf "%s:%s ", $1, $3 }'
}
# Outside processes above 5% CPU over a short window, as "comm=pcpu" words.
busy_outside() {
  top -b -n 2 -d 0.3 -w 200 | awk -v sid="$1" '
    /^top -/ { frame++ } frame == 2 && $1 ~ /^[0-9]+$/ && $9 + 0 > 5 { print $1, $9, $12 }' |
  while read -r pid pcpu comm; do
    [ "$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$1" ] || printf '%s=%s ' "$comm" "$pcpu"
  done
}

echo "[$(date +%H:%M:%S)] quiet gate for $LABEL: load1 < $QUIET_LOAD and no julia/oha/go-server (at most ${QUIET_WAIT_S}s)"
waited=0
until [ -z "$(foreign)" ] && awk -v l="$(load1)" -v q="$QUIET_LOAD" 'BEGIN { exit !(l < q) }'; do
  if [ "$waited" -ge "$QUIET_WAIT_S" ]; then
    echo "[$(date +%H:%M:%S)] GATE FAILED for $LABEL after ${waited}s: load1 $(load1), foreign [$(foreign)]; block not run"
    exit 3
  fi
  sleep 10; waited=$((waited + 10))
done
echo "[$(date +%H:%M:%S)] gate passed after ${waited}s (load1 $(load1)); running: $*"

setsid "$@" &
pid=$!
sleep 0.2
SID="$(ps -o sid= -p "$pid" | tr -d ' ')"
printf 'time\tload1\tload5\tforeign\tbusy_outside\n' > "$SAMPLES"
aborted=""
while kill -0 "$pid" 2>/dev/null; do
  f="$(foreign "$SID")"
  read -r l1 l5 _ </proc/loadavg
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%H:%M:%S)" "$l1" "$l5" "$f" "$(busy_outside "$SID")" >> "$SAMPLES"
  if [ -n "$f" ]; then
    aborted="$f"
    echo "[$(date +%H:%M:%S)] ABORTING $LABEL: foreign process(es) appeared: $f"
    kill -TERM -- "-$SID" 2>/dev/null
    break
  fi
  for _ in $(seq 1 "$SAMPLE_S"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
done
wait "$pid"; status=$?

echo "[$(date +%H:%M:%S)] sampler summary for $LABEL ($SAMPLES):"
awk -F'\t' 'NR > 1 { n++; l[n] = $2; if ($4 != "") f++; if ($5 != "") { b++; split($5, w, " "); for (i in w) { split(w[i], kv, "="); if (kv[2] + 0 > peak[kv[1]] + 0) peak[kv[1]] = kv[2] } } }
  END {
    asort(l); printf "  samples %d every %ss; load1 min %s median %s max %s\n", n, "'"$SAMPLE_S"'", l[1], l[int((n + 1) / 2)], l[n]
    printf "  samples with a foreign julia/oha/go-server: %d\n", f + 0
    printf "  samples with an outside process above 5%% CPU: %d", b + 0
    for (c in peak) printf "  [%s peak %s%%]", c, peak[c]; printf "\n" }' "$SAMPLES"
if [ -n "$aborted" ]; then echo "  BLOCK STOPPED: $aborted"; exit 4; fi
echo "  block exit status $status"
exit "$status"
