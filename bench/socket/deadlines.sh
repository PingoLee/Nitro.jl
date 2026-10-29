#!/usr/bin/env bash
# The #782 deadline repro: Reseau's poller with and without armed read deadlines on idle sockets, no web
# framework (in L1), no ORM, no database. deadlines.jl is the process under test, deadlines_peer.jl
# the echo peer and the idle client; this script drives them. Run every timed command behind quiet.sh.
#
# Usage:
#   bench/socket/deadlines.sh validate                          # the controls; nothing here is a number to keep
#   bench/socket/deadlines.sh probe <L1|L2> <deadline_s> [SILENT=1]   # one timeout probe
#   bench/socket/deadlines.sh probe-c2                          # a 2 s deadline on each worker's c2 (A7's target)
#   bench/socket/deadlines.sh block <threads> "<cells>" [rounds=3] [passes=2]
#   bench/socket/deadlines.sh strace "<cells>"                  # syscall counts, outside any timed window
#
#   bench/socket/quiet.sh deadlines-8-1 bench/socket/deadlines.sh block 8,1 "L1:A0 L1:A1 L1:A2 L1:A3"
#
# A cell is ARMING:CELL[:wW] (W round-trip workers, default 50), e.g. L1:A2, L2:A0, L1:A2:w1:
#   A0  no idle socket              the round trips alone
#   A1  50 idle sockets, no deadline
#   A2  50 idle sockets, 120 s deadline
#   A3  500 idle sockets, 120 s deadline
#   A4  50 idle sockets, 1 s deadline re-armed every 0.5 s by the client
#   A5  no idle socket; every round trip re-arms its own socket as HTTP.jl does per request
#   A6  no idle socket; every 20th round trip does (one request per 20 statements, /queries?n=20)
#   A7  as A6, but the churn re-arms a SECOND connection each worker owns and never reads (c2,
#       parked in a 1-byte read by a helper task); the round trips' own socket carries no deadline
#   A7e as A7 on every round trip (A5's twin)
# L1 arms each idle socket with Reseau's `TCP.set_read_deadline!`; L2 is HTTP.jl's `listen!` with
# `idle_timeout` and `read_header_timeout` set to the deadline (0 when off).
#
# Every cell and round is a fresh process with one WINDOW_S window after a WARM_S warm-up: a 120 s
# deadline outlives a process, never a pass. Rounds interleave (round r of every cell before round
# r + 1); passes alternate forward and reversed cell order (ABBA over two). A run counts only if its
# checks pass: every echo equal to what was sent, the peer's message count equal to the process's
# round trips, no idle socket closed before the window ended, and the poller thread found in
# epoll_wait. Rows go to bench/results/deadlines-<stamp>-<cmd>/results.tsv, the table to stdout.
#
# LOCK_PROFILE=1 (in the environment) adds a `LOCKS` line to each run's log: the window's count of
# contended ReentrantLock acquisitions, from Julia's lock profiling. Diagnostic; not in the table.
#
# Pinning: SERVER_CPUS (0,1,2,6,7,8) the process under test, PEER_CPUS (3,4,9,10) the echo peer with
# PEER_THREADS (4), CLIENT_CPUS (5,11) the idle client.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CMD="${1:?usage: deadlines.sh validate | block <threads> \"<cells>\" [rounds] [passes] | strace \"<cells>\"}"; shift
JULIA="${JULIA:-julia}"
SERVER_CPUS="${SERVER_CPUS:-0,1,2,6,7,8}"
PEER_CPUS="${PEER_CPUS:-3,4,9,10}"
CLIENT_CPUS="${CLIENT_CPUS:-5,11}"
PEER_THREADS="${PEER_THREADS:-4}"
export PEER_PORT="${PEER_PORT:-9190}" IDLE_PORT="${IDLE_PORT:-9191}"
export WARM_S="${WARM_S:-5}" WINDOW_S="${WINDOW_S:-6}"
OUT="$ROOT/bench/results/deadlines-$(date +%Y%m%d-%H%M%S)-$CMD"; mkdir -p "$OUT"
JL=("$JULIA" --startup-file=no --project="$HERE/db")
RESULTS="$OUT/results.tsv"

PIDS=()
# SIGKILL: a julia helper given SIGTERM while a task compiles can hang in its exit path.
cleanup() { for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT
trap 'exit 130' INT TERM
say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { say "ERROR: $*"; exit 1; }

wait_for() {   # file pattern timeout_s
  local i
  for i in $(seq 1 $(($3 * 5))); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
wait_port_free() {
  local i
  for i in $(seq 1 300); do ss -Hltn "sport = :$IDLE_PORT" | grep -q . || return 0; sleep 0.2; done
  die "port $IDLE_PORT still taken after 60 s"
}
cell_env() {   # sets N D R C X (X=1: the churn goes to the worker's second connection)
  C=0; X=0
  case "$1" in
    A0) N=0;   D=0;   R=0 ;;
    A1) N=50;  D=0;   R=0 ;;
    A2) N=50;  D=120; R=0 ;;
    A3) N=500; D=120; R=0 ;;
    A4) N=50;  D=1;   R=0.5 ;;
    A5) N=0;   D=0;   R=0; C=1 ;;
    A6) N=0;   D=0;   R=0; C=20 ;;
    A7) N=0;   D=0;   R=0; C=20; X=1 ;;
    A7e) N=0;  D=0;   R=0; C=1;  X=1 ;;
    *) die "cell $1: expected A0..A7, A7e" ;;
  esac
}
start_peer() {
  taskset -c "$PEER_CPUS" "${JL[@]}" --threads="$PEER_THREADS" "$HERE/deadlines_peer.jl" echo "$PEER_PORT" \
    > "$OUT/peer.log" 2>&1 &
  PIDS+=($!)
  wait_for "$OUT/peer.log" '^READY' 120 || die "echo peer did not start"
}
wait_exit() {   # pid timeout_s
  local i
  for i in $(seq 1 $(($2 * 5))); do kill -0 "$1" 2>/dev/null || break; sleep 0.2; done
  kill -0 "$1" 2>/dev/null && { kill -9 "$1"; say "killed $1 after $2 s"; }
  wait "$1" 2>/dev/null
}

# run_one <threads> <cell> <pass> <round> [VAR=value...]: one process, one window; appends a row.
run_one() {
  local threads="$1" spec="$2" pass="$3" round="$4"; shift 4
  local arming cell wspec w
  IFS=: read -r arming cell wspec <<<"$spec"
  w="${wspec#w}"; w="${w:-50}"
  cell_env "$cell"
  local tag="p$pass-r$round-${spec//:/_}-t${threads/,/_}"
  local log="$OUT/$tag.log" ilog="$OUT/$tag.idle.log"
  wait_port_free
  env ARMING="$arming" N="$N" DEADLINE_S="$D" CHURN_EVERY="$C" CHURN_C2="$X" W="$w" LABEL="$tag" "$@" \
    taskset -c "$SERVER_CPUS" "${JL[@]}" --threads="$threads" "$HERE/deadlines.jl" > "$log" 2>&1 &
  local pid=$! ipid=""
  wait_for "$log" '^READY' 120 || { kill "$pid"; die "$tag: no READY"; }
  if [ "$N" -gt 0 ]; then
    taskset -c "$CLIENT_CPUS" "${JL[@]}" --threads=1 "$HERE/deadlines_peer.jl" idle "$arming" "$IDLE_PORT" "$N" "$R" \
      > "$ilog" 2>&1 &
    ipid=$!
  fi
  wait_exit "$pid" 180
  [ -n "$ipid" ] && { kill -9 "$ipid" 2>/dev/null; wait "$ipid" 2>/dev/null; }
  local row total ppid check="ok" peer=0
  row="$(grep -P '^RESULT\t' "$log" | cut -f2-)"
  total="$(sed -n 's/^TOTAL rt=\([0-9]*\) faults=0 .*/\1/p' "$log")"
  ppid="$(sed -n 's/^READY pid=\([0-9]*\) .*/\1/p' "$log")"
  # The peer prints a connection's count when it closes; give it a moment. A7's second connections
  # (`silent`) must have carried no message at all, and none may have ended before the run did.
  for _ in $(seq 1 25); do
    [ "$(awk -v p="$ppid" '$1 == "CONN" && $2 == p' "$OUT/peer.log" | wc -l)" -ge $((w * (1 + X))) ] && break; sleep 0.2
  done
  peer="$(awk -v p="$ppid" '$1 == "CONN" && $2 == p && $5 != "silent" { s += $4 } END { print s + 0 }' "$OUT/peer.log")"
  local silent
  silent="$(awk -v p="$ppid" '$1 == "CONN" && $2 == p && $5 == "silent" { n++; s += $4 } END { printf "%d:%d", n, s }' "$OUT/peer.log")"
  if [ -z "$row" ] || [ -z "$total" ]; then check="no-result"
  elif [ "$peer" != "$total" ]; then check="peer-$peer-vs-$total"
  elif [ "$silent" != "$((w * X)):0" ]; then check="c2-conns-$silent"
  elif grep -q '^C2END' "$log"; then check="c2-ended-early"
  else
    local t1 closed sc early
    t1="$(cut -f19 <<<"$row")"; closed="$(cut -f16 <<<"$row")"; sc="$(cut -f15 <<<"$row")"
    early="$(awk -v t1="$t1" '$1 == "CLOSED" && $4 * 1000 <= t1' "$ilog" 2>/dev/null | wc -l)"
    [ "$closed" = 0 ] && [ "$early" = 0 ] || check="idle-closed-$closed-$early"
    case "$sc" in 232|281) ;; *) check="poller-syscall-$sc" ;; esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$spec" "$pass" "$round" "$row" "$total" "$peer" "$check" >> "$RESULTS"
  say "$tag: $(cut -f9 <<<"$row") rt/s, poller $(cut -f12 <<<"$row") ticks, $check"
}

# The table: per cell and layout, median [min–max] over its counted windows. µs are per round trip;
# % is of one CPU. Columns of results.tsv: see the header written below.
summary() {
  gawk -F'\t' '
    function med(a, n,   b, i) { for (i = 1; i <= n; i++) b[i] = a[i]; asort(b); return b[int((n + 1) / 2)] }
    function lo(a, n,   i, m) { m = a[1]; for (i = 2; i <= n; i++) if (a[i] < m) m = a[i]; return m }
    function hi(a, n,   i, m) { m = a[1]; for (i = 2; i <= n; i++) if (a[i] > m) m = a[i]; return m }
    function cell(name, k, fmt,   a, i) { for (i = 1; i <= n[k]; i++) a[i] = v[name, k, i]
      return sprintf(fmt " [" fmt "–" fmt "]", med(a, n[k]), lo(a, n[k]), hi(a, n[k])) }
    NR > 1 && $NF == "ok" {
      k = $1 "@" $9; if (!(k in n)) order[++nk] = k; i = ++n[k]
      v["rate", k, i] = $12; v["tot", k, i] = $13 * 1e4 / $10; v["dflt", k, i] = $14 * 1e4 / $10
      v["poll", k, i] = $15 * 1e4 / $10; v["main", k, i] = $16 * 1e4 / $10
      v["pollpct", k, i] = $15 / $11; v["dfltpct", k, i] = $14 / $11; v["totpct", k, i] = $13 / $11 }
    NR > 1 && $NF != "ok" { bad++ }
    END {
      print "| cell | threads | n | rt/s | total µs/rt | default µs/rt | poller µs/rt | main µs/rt | poller % | default % | total % |"
      print "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
      for (j = 1; j <= nk; j++) { k = order[j]; split(k, kk, "@")
        printf "| %s | %s | %d | %s | %s | %s | %s | %s | %s | %s | %s |\n", kk[1], kk[2], n[k],
          cell("rate", k, "%.0f"), cell("tot", k, "%.2f"), cell("dflt", k, "%.2f"), cell("poll", k, "%.3f"),
          cell("main", k, "%.3f"), cell("pollpct", k, "%.1f"), cell("dfltpct", k, "%.0f"), cell("totpct", k, "%.0f") }
      printf "runs failing a check: %d\n", bad + 0 }' "$RESULTS"
}

header() {
  printf 'cell\tpass\tround\tlabel\tarming\tN\tdeadline_s\tW\tthreads\trt\tspan_s\trt_per_s\ttotal_ticks\tdefault_ticks\tpoller_ticks\tmain_ticks\tpoller_tid\tpoller_syscall\tidle_closed\tthreads_seen\tt0_ms\tt1_ms\tprocess_total\tpeer_total\tcheck\n' > "$RESULTS"
}

# probe <arming> <deadline_s> [SILENT=1]: 5 idle sockets, report when the process closes them.
probe() {
  local arming="$1" d="$2" silent="${3:-}" log="$OUT/probe-$1-$2${3:+-silent}.log"
  wait_port_free
  env ARMING="$arming" N=5 DEADLINE_S="$d" W=0 HOLD_S=15 \
    taskset -c "$SERVER_CPUS" "${JL[@]}" --threads=8,1 "$HERE/deadlines.jl" > "$log" 2>&1 &
  local pid=$!
  wait_for "$log" '^READY' 120 || die "probe: no READY"
  env PROBE=1 ${silent:+SILENT=1} taskset -c "$CLIENT_CPUS" "${JL[@]}" --threads=1 "$HERE/deadlines_peer.jl" \
    idle "$arming" "$IDLE_PORT" 5 >> "$log" 2>&1
  wait_exit "$pid" 60
  awk -v what="$arming deadline ${d}s${silent:+, no request}" '
    $1 == "CLOSED" { c++; s = s " " $3 } $1 == "OPEN" { o++ } $1 == "DATA" { d = d " " $3 }
    END { printf "probe %s: %d closed by the process after [%s ] s, %d still open at 12 s%s\n", what, c, s, o,
          d == "" ? "" : ", unasked bytes (a 408) after [" d " ] s" }' "$log"
}

case "$CMD" in
  validate)
    say "validate -> $OUT"
    probe L1 2; probe L2 2; probe L2 2 SILENT=1         # negative control: closed at 2.0 ± 0.2 s
    probe L1 0; probe L2 0; probe L2 0 SILENT=1         # off: still open at 12 s
    header; start_peer
    for spec in L1:A0:w1 L1:A2:w1 L1:A0 L2:A0 L1:A1 L1:A2 L1:A3 L2:A2 L2:A3 L1:A4 L2:A4; do
      run_one 8,1 "$spec" 0 0
    done
    grep -h '^HELD' "$OUT"/p0-r0-L?_A3-*.log | sed 's/^/A3 setup: /'
    summary ;;
  probe)
    probe "$@" ;;
  probe-c2)
    # A7's target is real: a 2 s deadline on each worker's c2 must end its helper's read at 2.0 ± 0.2 s,
    # while the round trips on the first connection run on through a window that spans the 2 s mark.
    start_peer
    log="$OUT/probe-c2.log"
    wait_port_free
    env ARMING=L1 N=0 DEADLINE_S=0 W=50 C2_DEADLINE_S=2 WARM_S=1 WINDOW_S=3 \
      taskset -c "$SERVER_CPUS" "${JL[@]}" --threads=8,1 "$HERE/deadlines.jl" > "$log" 2>&1 &
    pid=$!
    wait_exit "$pid" 120
    ppid="$(sed -n 's/^READY pid=\([0-9]*\) .*/\1/p' "$log")"
    sleep 1
    awk -v p="$ppid" '
      FILENAME ~ /peer/ { if ($1 == "CONN" && $2 == p) { if ($5 == "silent") { sn++; ss += $4 } else ps += $4 }; next }
      $1 == "C2ARMED" { armed = $2 }
      $1 == "C2END" { n++; split($3, r, "="); reason[r[2]]++; split($4, a, "="); x = a[2] + 0
                      if (lo == "" || x < lo) lo = x; if (x > hi) hi = x }
      $1 == "RESULT" { split($0, f, "\t"); rt = f[8]; rate = f[10]; t0 = f[19]; t1 = f[20] }
      $1 == "TOTAL" { total = $2 }
      END {
        printf "probe-c2: %d of 50 c2 reads ended,", n; for (k in reason) printf " %s %d", k, reason[k]
        printf ", after %.2f-%.2f s\n", lo, hi
        printf "probe-c2: first connections: %d round trips (%.0f/s) in a window from %.2f to %.2f s after the first arm; %s; peer echoed %d, silent connections %d carrying %d messages\n",
          rt, rate, (t0 - armed) / 1000, (t1 - armed) / 1000, total, ps, sn, ss }' "$OUT/peer.log" "$log" ;;
  block)
    threads="${1:?threads}"; read -ra cells <<<"${2:?cells}"; rounds="${3:-3}"; passes="${4:-2}"
    say "block $threads: ${cells[*]}, $rounds rounds x $passes passes -> $OUT"
    header; start_peer
    for pass in $(seq 1 "$passes"); do
      order=("${cells[@]}")
      if [ $((pass % 2)) = 0 ]; then order=(); for ((i = ${#cells[@]} - 1; i >= 0; i--)); do order+=("${cells[i]}"); done; fi
      for round in $(seq 1 "$rounds"); do
        for spec in "${order[@]}"; do run_one "$threads" "$spec" "$pass" "$round"; done
      done
    done
    summary ;;
  strace)
    read -ra cells <<<"${1:?cells}"
    say "strace: ${cells[*]} -> $OUT"
    start_peer
    for spec in "${cells[@]}"; do
      IFS=: read -r arming cell wspec <<<"$spec"; cell_env "$cell"
      tag="strace-${spec//:/_}"; log="$OUT/$tag.log"
      wait_port_free
      env ARMING="$arming" N="$N" DEADLINE_S="$D" CHURN_EVERY="$C" CHURN_C2="$X" W=50 STRACE_S=18 LABEL="$tag" \
        taskset -c "$SERVER_CPUS" "${JL[@]}" --threads=8,1 "$HERE/deadlines.jl" > "$log" 2>&1 &
      pid=$!
      wait_for "$log" '^READY' 120 || die "$tag: no READY"
      ipid=""
      if [ "$N" -gt 0 ]; then
        taskset -c "$CLIENT_CPUS" "${JL[@]}" --threads=1 "$HERE/deadlines_peer.jl" idle "$arming" "$IDLE_PORT" "$N" "$R" \
          > "$OUT/$tag.idle.log" 2>&1 &
        ipid=$!
      fi
      wait_for "$log" '^STRACE' 180 || die "$tag: no STRACE"
      ppid="$(sed -n 's/^STRACE pid=\([0-9]*\) .*/\1/p' "$log")"; tid="$(sed -n 's/^STRACE .*poller=\([0-9]*\)/\1/p' "$log")"
      a0=$(date +%s.%N); timeout -s INT 6 strace -c -p "$tid" -o "$OUT/$tag.poller.strace" 2>/dev/null; a1=$(date +%s.%N)
      sleep 1
      b0=$(date +%s.%N); timeout -s INT 6 strace -c -f -p "$ppid" -o "$OUT/$tag.all.strace" 2>/dev/null; b1=$(date +%s.%N)
      wait_exit "$pid" 60
      [ -n "$ipid" ] && { kill -9 "$ipid" 2>/dev/null; wait "$ipid" 2>/dev/null; }
      # Round trips inside each attachment, from the process's TICK lines (every 0.5 s).
      rts() { awk -v a="$1" -v b="$2" '$1 == "TICK" { if ($2 <= a) x = $3; if ($2 <= b) y = $3 } END { print y - x }' "$log"; }
      ra="$(rts "$a0" "$a1")"; rb="$(rts "$b0" "$b1")"
      for f in poller:"$ra" all:"$rb"; do
        which="${f%%:*}"; n="${f#*:}"
        awk -v n="$n" -v t="$tag $which" '
          # strace -c rows: % time, seconds, usecs/call, calls, [errors], syscall.
          $NF ~ /^(epoll_wait|epoll_pwait|epoll_ctl|futex|read|write|timerfd_settime|sched_yield)$/ && $4 ~ /^[0-9]+$/ { calls[$NF] = $4 }
          END { printf "%s: %d round trips;", t, n; for (s in calls) printf " %s %d (%.3f/rt)", s, calls[s], calls[s] / (n > 0 ? n : 1); printf "\n" }' \
          "$OUT/$tag.$which.strace"
      done | tee -a "$OUT/strace-summary.txt"
    done ;;
  *) die "unknown command $CMD" ;;
esac
