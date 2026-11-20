#!/usr/bin/env bash
# #618, variants M and O (multiq_variant.jl): a FIFO queue beside stock's heaps for the tasks a
# program marks (M) or the tasks that cross pools (O), against A, A0 and C, on one build. Every
# block is one bench/socket/quiet.sh run; variants are the innermost loop, and their order is
# reversed in even rounds. A block whose gate fails (quiet.sh exit 3) or that a foreign process
# stopped (exit 4) is retried, RETRIES times at most, each attempt into its own files; only a
# finished attempt is renamed into place, so <OUT>/<block>-*-r<N>.tsv hold complete blocks only.
#
#   cost      spawn_order.jl H = 0, C = 50 and 500, clients on :interactive at 8,1 and on :default at
#             8,1 and 8,0; tasks.jl micro (FanOut 1000/10000) and queued, both layouts.
#             Variants: A A0 C M-none M-f M-l O-f O-l
#   fairness  the starved cell (C = 500, H = 2 ms, D = 8 s) in the same three client/layout cells,
#             with `pool` under A as the reference. Variants: A A0 C M-none M-f M-l, plus M-h-f and
#             M-h-l with :default clients, plus O-f and O-l (with :interactive clients at 8,1; with
#             :default clients at 8,0, where nothing crosses pools, and at 8,1, where the main task
#             spawns the clients from :interactive, so O makes the clients F and not the handlers)
#   shapes    500:2:inner, 500:2:hetero and 500:2:io, clients on :interactive at 8,1.
#             Variants: A C M-none M-f M-l
#   nesting   nested.sh's five workloads, both layouts. Variants: A A0 C M-none M-f M-l O-f O-l
#   markall   optional: fib_fine with every spawn marked (MARK_ALL=1) under M-f and M-l, A beside
#   pilot     the gate before the rounds: at 8,1 the starved cell with both client pools and
#             fib_fine, variants A M-none M-f M-l, one block
#   mixed     mixed_cell.jl: the starved cell (clients on :interactive, 8,1) while fib_fine loops on
#             :default for the whole D. Variants: A C M-l M-h-l (BLOCKS=mixed ROUNDS=3)
#   halfmix   the mixed cell at half the pool: C = 4 clients beside 4 unmarked loops of short chunks
#             (mixed_cell.jl BG=loops:4), so the pool is not over capacity; the MIX_V variants
#   sweep     the H = 0 cell (C = 500, :default clients) at each of SWEEP_LAYOUTS (2,0 on CPUs 0,1;
#             4,0 on 0-3; 8,0 on the 8 CPUs), the SWEEP_V variants
# PROFILE=rings (the rings of 2026-11-16, M-l-r<d>): Q1 is the q1 block; then cost (both cells, A
# A0 C M-none M-l M-l-r2 M-l-r4), fairness (A C M-l M-l-r2 M-l-r4, plus M-h-l and its rings with
# :default clients), shapes inner and io (A M-l M-l-r2), mixed (M-l M-l-r2), nesting fib_fine (A
# M-none M-l M-l-r2) and sweep (A M-none M-l M-l-r2 M-l-r4); VALIDATE adds the sweep cells and runs
# the negative controls under M-l and M-l-r2.
# PROFILE=inherit (the classes of 2026-11-16, agent-config #82 Idea 5: -i and -g on the rings):
# BLOCKS=step0b ROUNDS=1 first (the own-ring insert timed once: the sweep for A M-l-r2 M-l-r2o, then
# the three starved cells for M-l-r2 and M-l-r2o); BLOCKS=pilot ROUNDS=1 is the gate (8,1: the inner
# shape, the mixed cell and the mixed-inner cell for A M-l-r2 M-t-r2 M-il-r2 M-it-r2 M-g-r2; julia
# bench/tasks/aggregate_fifo.jl <OUT> inheritpilot); then the rounds: mixed and mixedinner (A C
# M-l-r2 M-t-r2 M-g-r2 M-g25-r2 M-g75-r2 M-g0-r2 and I_RULE, the -i rule the pilot kept, default
# M-il-r2), fairness (A M-l-r2 M-g-r2, plus M-h-g-r2 with :default clients), shapes (inner and io
# for A M-l-r2 M-t-r2 M-g-r2, inner for I_RULE), nesting (fib_fine alone, A M-none M-l-r2 M-g-r2),
# markroot (fib_fine under one marked root, A M-g-r2 I_RULE) and cost (A A0 M-none M-l-r2 M-g-r2);
# BLOCKS=age ROUNDS=1 is the age sweep (mixed and inner, M-a10-r2 M-a100-r2 M-a1000-r2). VALIDATE
# adds the mixed-inner and marked-root cells and the R heaps' negative control (rblind).
#   mixedinner  mixed_cell.jl SHAPE=inner: the mixed cell with the inner shape
#   markroot    nested.sh MARK_ROOT=1, fib_fine only
#   q1        the rings run's first question, one block (BLOCKS=q1 ROUNDS=1): one sweep round, M-l
#             under VALIDATE per layout for the F-lock counts, and a profile of the 8,0 cell per
#             variant (A and M-l)
# PROFILE=gc (the corrected accounts in the harness, agent-config #82 Idea 8: M-gc-r2 beside M-g-r2):
# BLOCKS=pilot ROUNDS=1 first (8,1: the inner shape, the mixed and the mixed-inner cell for A M-g-r2
# M-gc-r2: M-g-r2 must land on the classes run); BLOCKS=pool, the Channel worker pool with nothing
# marked; then the rounds: mixed and mixedinner (A M-g-r2 M-gc-r2 M-gc25-r2 M-gc75-r2, or MIX_V_GC),
# fairness (A M-g-r2 M-gc-r2, plus M-h-gc-r2 with :default clients), shapes (inner and io for A M-l-r2
# M-g-r2 M-gc-r2), nesting (fib_fine alone, A M-none M-g-r2 M-gc-r2), markroot (A M-g-r2 M-gc-r2) and
# cost (A A0 M-none M-g-r2 M-gc-r2). VALIDATE adds the mixed-inner, marked-root and pool cells, the
# credited-against-run lines (`aggregate_fifo.jl <OUT> credit`), and the no-clock step: under
# M_NOCLOCK=1 the pool cells and fib_fine alone for M-g-r2 and M-gc-r2 must leave the pool flag unset.
#   pool      spawn_order.jl MODES=pool at H = 0, C = 50 and 500, :interactive clients at 8,1 and
#             :default clients at 8,0, the POOL_V variants, nothing marked (PROFILE=gc only)
#
#
# PROFILE=share (the shares of 2026-11-16, M-t and M-p<K>) swaps the lists: cost at C = 500 only,
# A A0 M-none M-l M-t; fairness A M-l M-t, plus M-h-t with :default clients; shapes inner and io for
# A M-l M-t, inner only for M-p2 M-p1024; nesting fib_fine only, A M-none M-l M-t; mixed A C M-l
# M-t M-t0 M-p2 M-p16 M-p128 M-p1024; the pilot is the starved cell with :default clients and the
# mixed cell, A M-l M-t (aggregate_fifo.jl <OUT> sharepilot); VALIDATE adds the mixed cell for
# every variant (C at FIB_FINE=36:12) and runs the negative controls under M-f and M-t.
#
# PROFILE=native (the native mark, agent-config #82 Idea 10: M-gc-r2 written inside a local build of
# Julia, bench/julia/): a variant token `V%label` runs VARIANT=V on the julia that JLS names `label`
# (JLS="control=<julia> mark=<julia> official=<julia>"); a bare token runs on JL. BLOCKS=pilot ROUNDS=1
# is the gate, at 8,1: the starved cell (500:2) and the H = 0 cell (500:0) with :default clients, the
# mixed cell, and fib_fine alone, for PILOT_V (default: A on the control build, N-none and N on the
# mark build, A and M-gc-r2 on the official binary). VALIDATE=1 runs on JL, the mark build's
# validation build: the cost and fairness cells, nested.jl, the mixed and mixed-inner cells, the marked
# root, the pool cells, the no-clock step (N-none and N, nothing marked in those cells) and the three
# negative controls under N.
# The measurement (session 2) runs five columns in every timed block, NATIVE_COLS: ctl (A%control),
# bridgeA (A%official), mark (N%mark), bridge (M-gc-r2%official), mark0 (N-none%mark), with JL the
# control build; the mixed cells add N25%mark and N75%mark (N at the weights 1/4 and 3/4). Each timed
# block starts with one throwaway slot (THROWAWAY=0 turns it off). The blocks: cost (as above, the
# micro rows' variant column carrying the whole token), cells (fairness's three starved cells, the
# inner shape, mixed, mixed-inner, fib_fine alone and under a marked root, in one quiet block) and
# fibabba (BLOCKS=fibabba ROUNDS=1: fib_fine alone for ABBA_COLS, ctl and mark0, ABBA_ROUNDS = 12
# rounds of A B / B A at 8,1 and 8,0). TD=<s> shortens every spawn_order window and NOGATE=1 runs a
# block without quiet.sh: together, a smoke pass of the block code, never a measurement.
# bench/julia/native_measure.sh drives the whole session.
# The battery (#618, agent-config #82 Idea 12; bench/julia/battery.sh drives it) adds, under
# PROFILE=native: ROTATE=1 (rotate the token order by round, so three columns take every position
# equally; reversal leaves the middle one fixed); ABBA_LAYOUTS (fibabba's layouts, default "8,1 8,0");
# CLIENT_CELLS_SPEC="<layout> <clients>;..." (the cost and fairness cells' layouts, with CPUS set to
# match); MICRO_LAYOUTS ("none" skips tasks.jl), MICRO_ARGS and MICRO_FAN_OUT (tasks.jl's rows);
# SHAPE_CELLS_NATIVE (the shapes block's cells); and the blocks costrounds, shaperounds and
# fairrounds: MULTI_ROUNDS rounds of cost, shapes or fairness in one quiet block after one throwaway
# slot (run with ROUNDS=1). WARM=cell reaches spawn_order.jl through the environment.
#
# Usage: JL=<julia binary> MICRO_PROJECT=<env with BenchmarkTools> bench/tasks/rounds_fifo.sh [rounds]
#   OUT           results directory (default bench/results/618-fifo)
#   ROUNDS        3 (or the argument): the last round
#   FIRST_ROUND   1: the first round, to add rounds to a block (FIRST_ROUND=5 ROUNDS=6 adds two,
#                 numbered and ordered as rounds 5 and 6)
#   BLOCKS        "cost fairness shapes nesting": which blocks a round runs ("pilot" and "markall"
#                 are run on their own: BLOCKS=pilot ROUNDS=1)
#   CPUS          0,1,2,3,6,7,8,9, as spawn_order.sh
#   RETRIES       2
#   VALIDATE=1    one validation pass instead, not behind the gate and not timed: every layout x
#                 client pool x variant at D = 1 s over all four shapes, tasks.jl's rows, nested.jl
#                 at FIB_FINE=36:12 and RUNS=1 (MARK_ALL too), and the two negative controls
#                 (M_NEGATIVE=blind fails the check_empty probe, M_NEGATIVE=stall trips the stall
#                 check), into <OUT>/validate-*.tsv and <OUT>/validate.log; NEG_ONLY=1 runs only
#                 the negative controls
#   QUIET_LOAD, QUIET_WAIT_S, SAMPLE_S  pass through to quiet.sh
# Afterwards: julia bench/tasks/aggregate_fifo.jl <OUT>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
: "${JL:?JL=<julia binary>}"
: "${MICRO_PROJECT:?MICRO_PROJECT=<environment with BenchmarkTools>}"
ROUNDS="${1:-${ROUNDS:-3}}"
OUT="${OUT:-$ROOT/bench/results/618-fifo}"
BLOCKS="${BLOCKS:-cost fairness shapes nesting}"
CPUS="${CPUS:-0,1,2,3,6,7,8,9}"
RETRIES="${RETRIES:-2}"
VALIDATE="${VALIDATE:-0}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # absolute: quiet.sh runs its command from elsewhere
[ -x "$JL" ] || { echo "rounds_fifo: $JL is not an executable" >&2; exit 1; }
export QUIET_LOAD="${QUIET_LOAD:-0.5}" QUIET_WAIT_S="${QUIET_WAIT_S:-1800}" SAMPLE_S="${SAMPLE_S:-5}"
VER="$("$JL" -e 'print(VERSION)')"

log() { echo "[$(date +%H:%M:%S)] rounds_fifo: $*"; }

# A variant token `V%label` (PROFILE=native) runs VARIANT=V on the julia JLS names `label`.
declare -A JL_OF
for kv in ${JLS:-}; do JL_OF["${kv%%=*}"]="${kv#*=}"; done
jl_of()  { case "$1" in
             *%*) local b="${1##*%}"; [ -n "${JL_OF[$b]:-}" ] || { echo "rounds_fifo: no JLS entry for $b" >&2; return 1; }
                  printf '%s' "${JL_OF[$b]}" ;;
             *) printf '%s' "$JL" ;;
           esac; }
var_of() { printf '%s' "${1%%\%*}"; }

# The variants of each cell. ROUND_ORDER reverses them in even rounds. PROFILE=share is the run of
# 2026-11-16 (the shares, M-t and M-p<K>, against M-l); the default is the M/O run of 2026-11-15.
PROFILE="${PROFILE:-mo}"
COST_V="A A0 C M-none M-f M-l O-f O-l"
COST_CELLS="50:0 500:0"
FAIR_I81_V="A A0 C M-none M-f M-l O-f O-l"          # :interactive clients, 8,1
FAIR_D_V="A A0 C M-none M-f M-l M-h-f M-h-l O-f O-l"  # :default clients, 8,1 and 8,0
SHAPE_V="A C M-none M-f M-l"
SHAPE_CELLS="500:2:inner 500:2:hetero 500:2:io"
SHAPE_INNER_V=""                                    # variants run in 500:2:inner only
NEST_V="A A0 C M-none M-f M-l O-f O-l"
NEST_WORKLOADS=""                                   # nested.sh's default: all five
PILOT_V="A M-none M-f M-l"
MIX_V="A C M-l M-h-l"
VAL_V=""            # VALIDATE: the variants of the cost and fairness cells, when not the lists above
VAL_NEST_V="$NEST_V"
VAL_MARKALL_V="M-f M-l"
VAL_MIX_V=""        # VALIDATE: the mixed cell (C at FIB_FINE=36:12)
NEG_V="M-f"         # VALIDATE: the variants the two negative controls run under
NEG_R_V=""          # VALIDATE: the variants the R heaps' negative control (rblind) runs under
MARKROOT_V=""       # markroot: fib_fine under one marked root
AGE_V=""            # age: the age rule's sweep
if [ "$PROFILE" = share ]; then
  COST_V="A A0 M-none M-l M-t"
  COST_CELLS="500:0"
  FAIR_I81_V="A M-l M-t"
  FAIR_D_V="A M-l M-t M-h-t"
  SHAPE_V="A M-l M-t"
  SHAPE_CELLS="500:2:inner 500:2:io"
  SHAPE_INNER_V="M-p2 M-p1024"
  NEST_V="A M-none M-l M-t"
  NEST_WORKLOADS="fib_fine"
  PILOT_V="A M-l M-t"
  MIX_V="A C M-l M-t M-t0 M-p2 M-p16 M-p128 M-p1024"
  VAL_V="A A0 C M-none M-l M-t M-t0 M-p2 M-p16 M-p128 M-p1024 M-h-t"
  VAL_NEST_V="A M-none M-l M-t M-t0 M-p2 M-p1024 M-h-t"
  VAL_MARKALL_V=""
  VAL_MIX_V="A C M-l M-t M-t0 M-p2 M-p16 M-p128 M-p1024 M-h-t"
  NEG_V="M-f M-t"
elif [ "$PROFILE" = rings ]; then
  # Q1 of the rings run: is the single F lock the cost? The H = 0 cell with :default clients, every
  # task marked, against the thread count (SWEEP_LAYOUTS: layout:cpus, one thread per core up to 4,
  # then the 8 CPUs, 4 cores x 2 SMT).
  SWEEP_V="${SWEEP_V:-A M-none M-l M-l-r2 M-l-r4}"
  # Q2, the rings against the single queue (M-l), in the cost, fairness, shapes, mixed, nesting
  # and sweep blocks.
  COST_V="A A0 C M-none M-l M-l-r2 M-l-r4"
  COST_CELLS="50:0 500:0"
  FAIR_I81_V="A C M-l M-l-r2 M-l-r4"
  FAIR_D_V="A C M-l M-l-r2 M-l-r4 M-h-l M-h-l-r2 M-h-l-r4"
  SHAPE_V="A M-l M-l-r2"
  SHAPE_CELLS="500:2:inner 500:2:io"
  SHAPE_INNER_V=""
  NEST_V="A M-none M-l M-l-r2"
  NEST_WORKLOADS="fib_fine"
  MIX_V="M-l M-l-r2"
  VAL_V="A A0 C M-none M-l M-l-r2 M-l-r4 M-h-l M-h-l-r2 M-h-l-r4"
  VAL_NEST_V="A M-none M-l M-l-r2 M-l-r4"
  VAL_MARKALL_V=""
  VAL_MIX_V="M-l M-l-r2"
  NEG_V="M-l M-l-r2"
elif [ "$PROFILE" = gc ]; then
  COST_V="A A0 M-none M-g-r2 M-gc-r2"
  COST_CELLS="50:0 500:0"
  FAIR_I81_V="A M-g-r2 M-gc-r2"
  FAIR_D_V="A M-g-r2 M-gc-r2 M-h-gc-r2"
  SHAPE_V="A M-l-r2 M-g-r2 M-gc-r2"
  SHAPE_CELLS="500:2:inner 500:2:io"
  SHAPE_INNER_V=""
  NEST_V="A M-none M-g-r2 M-gc-r2"
  NEST_WORKLOADS="fib_fine"
  MARKROOT_V="A M-g-r2 M-gc-r2"
  PILOT_V="A M-g-r2 M-gc-r2"
  MIX_V="${MIX_V_GC:-A M-g-r2 M-gc-r2 M-gc25-r2 M-gc75-r2}"
  POOL_V="A A0 M-none M-g-r2 M-gc-r2"
  VAL_V="A A0 M-none M-l-r2 M-g-r2 M-gc-r2 M-gc25-r2 M-gc75-r2 M-h-gc-r2"
  VAL_NEST_V="A M-none M-g-r2 M-gc-r2"
  VAL_MARKALL_V=""
  VAL_MARKROOT_V="M-g-r2 M-gc-r2"
  VAL_MIX_V="A M-g-r2 M-gc-r2 M-gc25-r2 M-gc75-r2"
  NOCLOCK_V="M-g-r2 M-gc-r2"
  NEG_V="M-g-r2 M-gc-r2"
  NEG_R_V="M-g-r2 M-gc-r2"
elif [ "$PROFILE" = native ]; then
  PILOT_V="${PILOT_V_NATIVE:-A%control N-none%mark N%mark A%official M-gc-r2%official}"
  # The measurement (session 2): five columns in every timed block, one token each. The control build
  # (ctl), the official binary's own stock (bridgeA), the mark build with the marks M-gc-r2 uses (mark),
  # the official binary under the runtime patch (bridge), and the mark build with nothing marked (mark0).
  # Reversed in even rounds, so ctl and mark0 share slots 1 and 5, bridgeA and bridge slots 2 and 4.
  # The mixed cells add mark at the weights 1/4 and 3/4 in the middle, keeping that symmetry. JL is the
  # control build: fairness's `pool` reference runs there. VALIDATE keeps the bare lists, on JL.
  NATIVE_COLS="${NATIVE_COLS:-A%control A%official N%mark M-gc-r2%official N-none%mark}"
  NATIVE_MIX_COLS="${NATIVE_MIX_COLS:-A%control A%official N%mark N25%mark N75%mark M-gc-r2%official N-none%mark}"
  COST_V="$NATIVE_COLS"
  COST_CELLS="50:0 500:0"
  FAIR_I81_V="$NATIVE_COLS"
  FAIR_D_V="$NATIVE_COLS"
  SHAPE_V="$NATIVE_COLS"
  SHAPE_CELLS="${SHAPE_CELLS_NATIVE:-500:2:inner}"
  SHAPE_INNER_V=""
  NEST_V="$NATIVE_COLS"
  NEST_WORKLOADS="fib_fine"
  MARKROOT_V="$NATIVE_COLS"
  MIX_V="$NATIVE_MIX_COLS"
  # fibabba: fib_fine alone, ctl and mark0 only, ABBA_ROUNDS rounds of A B / B A at 8,1 and 8,0.
  ABBA_COLS="${ABBA_COLS:-A%control N-none%mark}"
  POOL_V="A N-none N"
  VAL_V="A N-none N N-h"
  VAL_NEST_V="A N-none N"
  VAL_MARKALL_V=""
  VAL_MARKROOT_V="N"
  VAL_MIX_V="A N N25 N75"
  NOCLOCK_V="N-none N"
  NEG_V="N"
  NEG_R_V="N"
elif [ "$PROFILE" = inherit ]; then
  I_RULE="${I_RULE:-M-il-r2}"
  COST_V="A A0 M-none M-l-r2 M-g-r2"
  COST_CELLS="50:0 500:0"
  FAIR_I81_V="A M-l-r2 M-g-r2"
  FAIR_D_V="A M-l-r2 M-g-r2 M-h-g-r2"
  SHAPE_V="A M-l-r2 M-t-r2 M-g-r2"
  SHAPE_CELLS="500:2:inner 500:2:io"
  SHAPE_INNER_V="$I_RULE"
  NEST_V="A M-none M-l-r2 M-g-r2"
  NEST_WORKLOADS="fib_fine"
  MARKROOT_V="A M-g-r2 $I_RULE"
  PILOT_V="A M-l-r2 M-t-r2 M-il-r2 M-it-r2 M-g-r2"
  MIX_V="A C M-l-r2 M-t-r2 M-g-r2 M-g25-r2 M-g75-r2 M-g0-r2 $I_RULE"
  AGE_V="M-a10-r2 M-a100-r2 M-a1000-r2"
  SWEEP_V="${SWEEP_V:-A M-l-r2 M-l-r2o}"
  VAL_V="A A0 C M-none M-l-r2 M-l-r2o M-t-r2 M-t0-r2 M-il-r2 M-it-r2 M-g-r2 M-g25-r2 M-g75-r2 M-g0-r2 M-h-g-r2 M-a100-r2"
  VAL_NEST_V="A M-none M-l-r2 M-il-r2 M-g-r2 M-g0-r2"
  VAL_MARKALL_V=""
  VAL_MARKROOT_V="M-il-r2 M-it-r2 M-g-r2"
  VAL_MIX_V="A C M-l-r2 M-t-r2 M-t0-r2 M-il-r2 M-it-r2 M-g-r2 M-g25-r2 M-g75-r2 M-g0-r2 M-h-g-r2 M-a100-r2"
  NEG_V="M-l-r2 M-g-r2"
  NEG_R_V="M-g-r2"
fi
SWEEP_LAYOUTS="${SWEEP_LAYOUTS:-2,0:0,1 4,0:0,1,2,3 8,0:0,1,2,3,6,7,8,9}"
case "$PROFILE" in mo|share|rings|inherit|gc|native) ;; *) echo "rounds_fifo: PROFILE must be mo, share, rings, inherit, gc or native" >&2; exit 1 ;; esac
ordered() {   # round, variants...
  local r="$1"; shift
  # ROTATE=1 (#618, the battery): rotate the list by (r - 1) mod n, so that over n rounds every token
  # takes every position once (three columns are not balanced by reversal: the middle one never moves).
  if [ "${ROTATE:-0}" = 1 ] && [ $# -gt 0 ]; then
    local n=$# k a i out=()
    k=$(( ((r - 1) % n + n) % n )); a=("$@")
    for ((i = 0; i < n; i++)); do out+=("${a[$(( (i + k) % n ))]}"); done
    echo "${out[*]}"; return
  fi
  if [ $((r % 2)) = 0 ]; then printf '%s\n' "$@" | tac | tr '\n' ' '; else echo "$*"; fi
}

# One spawn_order.jl process: round, tsv, layout, clients, variant, cells, mode, D.
spawn() {
  local r="$1" tsv="$2" layout="$3" clients="$4" variant="$5" cells="$6" mode="${7:-spawn}" d="${8:-${TD:-8}}"
  local header=0; [ -s "$tsv" ] && header=1
  local jl; jl="$(jl_of "$variant")" || return 1
  env ROUND="$r" NOHEADER="$header" VARIANT="$(var_of "$variant")" CELLS="$cells" MODES="$mode" CLIENTS="$clients" D="$d" \
    timeout -s KILL "${TIMEOUT_S:-900}" taskset -c "$CPUS" "$jl" --threads="$layout" \
    "$HERE/spawn_order.jl" >>"$tsv" ||
    { echo "rounds_fifo: spawn_order $layout $clients VARIANT=$variant CELLS=$cells failed or timed out" >&2; return 1; }
}

# One tasks.jl process: round, tsv, layout, variant.
# A `V%label` token runs on that build, and its rows carry the whole token in the variant column (two
# builds of one version would otherwise read alike: the rows' build= label tells them apart too).
micro() {
  local r="$1" tsv="$2" layout="$3" variant="$4" jl
  jl="$(jl_of "$variant")" || return 1
  # MICRO_ARGS and MICRO_FAN_OUT (#618, the battery) narrow the rows: "micro" and "1000" give SpawnWait,
  # PingPong and FanOut1000 only.
  VARIANT="$(var_of "$variant")" FAN_OUT_NS="${MICRO_FAN_OUT:-1000 10000}" timeout -s KILL "${MICRO_TIMEOUT_S:-240}" taskset -c "$CPUS" "$jl" \
    --project="$MICRO_PROJECT" --threads="$layout" "$HERE/tasks.jl" ${MICRO_ARGS:-micro queued} |
    sed "s|^|$r\t$VER\t$layout\t$variant\t|" >>"$tsv"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" = 0 ] || { echo "rounds_fifo: tasks.jl $layout VARIANT=$variant failed ($rc)" >&2; return 1; }
}

# The three client/layout cells of cost and fairness: "layout clients".
CLIENT_CELLS=("8,1 interactive" "8,1 default" "8,0 default")
# CLIENT_CELLS_SPEC="<layout> <clients>;..." replaces them (#618, the battery: other layouts, with CPUS
# set to match), for the cost and fairness blocks and their throwaway slot.
[ -n "${CLIENT_CELLS_SPEC:-}" ] && IFS=';' read -r -a CLIENT_CELLS <<<"$CLIENT_CELLS_SPEC"

cost_block() {   # round, spawn tsv, micro tsv
  local r="$1" tsv="$2" mtsv="$3" cells="$COST_CELLS" d="${TD:-8}" cc layout clients v vs="$COST_V"
  [ "$VALIDATE" = 1 ] && { d=1; [ -n "$VAL_V" ] && vs="$VAL_V"; }
  native_throwaway "$r" cost || return 1
  for cc in "${CLIENT_CELLS[@]}"; do
    read -r layout clients <<<"$cc"
    for v in $(ordered "$r" $vs); do spawn "$r" "$tsv" "$layout" "$clients" "$v" "$cells" spawn "$d" || return 1; done
  done
  for layout in ${MICRO_LAYOUTS:-8,1 8,0}; do
    [ "$layout" = none ] && continue
    for v in $(ordered "$r" ${MICRO_V:-$vs}); do micro "$r" "$mtsv" "$layout" "$v" || return 1; done
  done
}

fairness_block() {   # round, spawn tsv
  local r="$1" tsv="$2" cells="500:2" d="${TD:-8}" cc layout clients v vs
  [ "$VALIDATE" = 1 ] && { cells="50:0.2 500:2 500:2:inner 500:2:hetero 500:2:io"; d=1; }
  for cc in "${CLIENT_CELLS[@]}"; do
    read -r layout clients <<<"$cc"
    if [ "$clients" = interactive ]; then vs="$FAIR_I81_V"; else vs="$FAIR_D_V"; fi
    [ "$VALIDATE" = 1 ] && [ -n "$VAL_V" ] && vs="$VAL_V"
    spawn "$r" "$tsv" "$layout" "$clients" A "$cells" pool "$d" || return 1
    for v in $(ordered "$r" $vs); do spawn "$r" "$tsv" "$layout" "$clients" "$v" "$cells" spawn "$d" || return 1; done
  done
}

shapes_block() {   # round, spawn tsv
  local r="$1" tsv="$2" v
  for v in $(ordered "$r" $SHAPE_V $SHAPE_INNER_V); do
    if [[ " $SHAPE_INNER_V " == *" $v "* ]]; then
      spawn "$r" "$tsv" 8,1 interactive "$v" "500:2:inner" || return 1
    else
      spawn "$r" "$tsv" 8,1 interactive "$v" "$SHAPE_CELLS" || return 1
    fi
  done
}

nesting_block() {   # round, nested tsv, variants, extra env...
  local r="$1" tsv="$2" vs="$3"; shift 3
  if [ "$PROFILE" = native ] && [ "$VALIDATE" != 1 ]; then
    # One nested.sh call per token, the tokens innermost (nested.sh's own loop puts the build outermost).
    local layout v rc=0 s
    for layout in ${NEST_LAYOUTS:-8,1 8,0}; do
      for v in $(ordered "$r" $vs); do
        native_nested "$r" "$tsv" "$layout" "$v" "$@"; s=$?
        case "$s" in 0) ;; 2) rc=2 ;; *) return "$s" ;; esac
      done
    done
    return "$rc"
  fi
  env "$@" ROUND="$r" CHANNELS="$JL" LAYOUTS="${NEST_LAYOUTS:-8,1 8,0}" VARIANTS="$(ordered "$r" $vs)" SKIP= \
    CPUS="$CPUS" TIMEOUT_S="${TIMEOUT_S:-600}" "$HERE/nested.sh" "$r" "$tsv"
}

pilot_block() {   # spawn tsv, nested tsv (PROFILE=share: the mixed tsv; inherit: mixed, mixed-inner; native: mixed, nested)
  local tsv="$1" ntsv="$2" v
  if [ "$PROFILE" = native ]; then
    # The native mark's gate, at 8,1: the starved and the H = 0 cell with :default clients, the mixed
    # cell, fib_fine alone; one nested.sh call per token, each on its own build.
    for v in $PILOT_V; do spawn 0 "$tsv" 8,1 default "$v" "500:2 500:0" || return 1; done
    MIX_V="$PILOT_V" mixed_block 0 "$ntsv" || return 1
    for v in $PILOT_V; do
      CHANNELS="$(jl_of "$v")" LAYOUTS=8,1 VARIANTS="$(var_of "$v")" WORKLOADS=fib_fine SKIP= ROUND=0 \
        CPUS="$CPUS" TIMEOUT_S="${TIMEOUT_S:-600}" "$HERE/nested.sh" 0 "$3" || return 1
    done
    return
  fi
  if [ "$PROFILE" = inherit ] || [ "$PROFILE" = gc ]; then
    # The classes' gate (PROFILE=gc: the same cells, M-g-r2 against the classes run), at 8,1: the inner shape, the mixed cell, the mixed-inner cell.
    for v in $PILOT_V; do spawn 0 "$tsv" 8,1 interactive "$v" "500:2:inner" || return 1; done
    MIX_V="$PILOT_V" mixed_block 0 "$ntsv" || return 1
    MIX_V="$PILOT_V" mixed_block 0 "$3" SHAPE=inner
    return
  fi
  if [ "$PROFILE" = share ]; then
    # The share's gate: at 8,1 the starved cell with :default clients, then the mixed cell.
    for v in $PILOT_V; do spawn 0 "$tsv" 8,1 default "$v" "500:2" || return 1; done
    MIX_V="$PILOT_V" mixed_block 0 "$ntsv"
    return
  fi
  for clients in interactive default; do
    for v in $PILOT_V; do spawn 0 "$tsv" 8,1 "$clients" "$v" "500:2" || return 1; done
  done
  NEST_LAYOUTS=8,1 nesting_block 0 "$ntsv" "$PILOT_V" WORKLOADS=fib_fine
}

# PROFILE=gc: the Channel worker pool, nothing marked, at H = 0 (the stall repro's part 2 cell):
# :interactive clients at 8,1, :default clients at 8,0. Extra VAR=value arguments reach every process.
pool_block() {   # round, tsv, variants, extra env...
  local r="$1" tsv="$2" vs="$3" d=8 cc layout clients v; shift 3
  [ "$VALIDATE" = 1 ] && d=1
  for cc in "8,1 interactive" "8,0 default"; do
    read -r layout clients <<<"$cc"
    for v in $(ordered "$r" $vs); do
      ( for kv in "$@"; do export "${kv?}"; done; spawn "$r" "$tsv" "$layout" "$clients" "$v" "50:0 500:0" pool "$d" ) || return 1
    done
  done
}

mixed_block() {   # round, tsv, extra env...
  local r="$1" tsv="$2" v header; shift 2
  for v in $(ordered "$r" $MIX_V); do
    header=0; [ -s "$tsv" ] && header=1
    local jl; jl="$(jl_of "$v")" || return 1
    env "$@" ROUND="$r" NOHEADER="$header" VARIANT="$(var_of "$v")" timeout -s KILL "${TIMEOUT_S:-900}" taskset -c "$CPUS" \
      "$jl" --threads=8,1 "$HERE/mixed_cell.jl" >>"$tsv" ||
      { echo "rounds_fifo: mixed_cell VARIANT=$v failed or timed out" >&2; return 1; }
  done
}

# The H = 0 cell (C = 500, :default clients) at each of SWEEP_LAYOUTS, on that layout's CPUs.
sweep_block() {   # round, tsv, [variants]
  local r="$1" tsv="$2" vs="${3:-$SWEEP_V}" lc layout cpus v d=8
  [ "$VALIDATE" = 1 ] && d=1
  for lc in $SWEEP_LAYOUTS; do
    layout="${lc%%:*}" cpus="${lc#*:}"
    for v in $(ordered "$r" $vs); do
      ( CPUS="$cpus"; spawn "$r" "$tsv" "$layout" default "$v" "500:0" spawn "$d" ) || return 1
    done
  done
}

# Q1, one quiet block: the sweep timed (one round); then, per layout, M-l under VALIDATE at D = 4
# for the F-lock counts (acquisitions, how many found the lock held, F operations per request:
# "validate: F lock" lines in <OUT>/q1-validate.log); then one profile of the 8,0 cell per variant
# in Q1_PROF_V (PROF=<OUT>/profile-<variant>-8,0.txt; their rows, perturbed by the profiler, go to
# <OUT>/q1-profile-rows.tsv and are not measurements).
q1_block() {   # timed tsv, VALIDATE tsv
  local tsv="$1" vtsv="$2" lc layout cpus v
  sweep_block 1 "$tsv" || return 1
  for lc in $SWEEP_LAYOUTS; do
    layout="${lc%%:*}" cpus="${lc#*:}"
    for v in ${Q1_VAL_V:-M-l}; do
      ( export VALIDATE=1; CPUS="$cpus"; spawn 1 "$vtsv" "$layout" default "$v" "500:0" spawn 4 ) \
        2>>"$OUT/q1-validate.log" || return 1
    done
  done
  for v in ${Q1_PROF_V:-A M-l}; do
    ( export PROF="$OUT/profile-$v-8,0.txt"; spawn 1 "$OUT/q1-profile-rows.tsv" 8,0 default "$v" "500:0" ) || return 1
  done
}

# PROFILE=inherit, step 0's timing, one quiet block: the sweep (A M-l-r2 M-l-r2o), then the three
# starved cells for M-l-r2 and M-l-r2o.
step0b_block() {   # sweep tsv, fairness tsv
  local tsv="$1" ftsv="$2" cc layout clients v
  sweep_block 1 "$tsv" || return 1
  for cc in "${CLIENT_CELLS[@]}"; do
    read -r layout clients <<<"$cc"
    for v in M-l-r2 M-l-r2o; do spawn 1 "$ftsv" "$layout" "$clients" "$v" "500:2" || return 1; done
  done
}

# PROFILE=inherit, the age sweep, one round: the mixed cell and the inner shape for AGE_V.
age_block() {   # mixed tsv, spawn tsv
  local v
  MIX_V="$AGE_V" mixed_block 1 "$1" || return 1
  for v in $AGE_V; do spawn 1 "$2" 8,1 interactive "$v" "500:2:inner" || return 1; done
}

# PROFILE=native: one nested.sh process for one token. Exit 2 is a process killed by its timeout.
native_nested() {   # round, tsv, layout, token, extra env...
  local r="$1" tsv="$2" layout="$3" v="$4" jl; shift 4
  jl="$(jl_of "$v")" || return 1
  env "$@" ROUND="$r" CHANNELS="$jl" LAYOUTS="$layout" VARIANTS="$(var_of "$v")" SKIP= \
    CPUS="$CPUS" TIMEOUT_S="${TIMEOUT_S:-600}" "$HERE/nested.sh" "$r" "$tsv"
}

# PROFILE=native, timed blocks only: one throwaway slot before the block's first measured process, so
# that none takes the block's first slot (on 2026-11-18 the first process of a block read low in one
# cell and high in another). It is the first token of the round's order, run once more in the block's
# first cell, into <OUT>/throwaway-*.tsv (never read). THROWAWAY=0 turns it off.
native_throwaway() {   # round, kind (cost, cells, fib)
  [ "$PROFILE" = native ] && [ "$VALIDATE" != 1 ] && [ "${THROWAWAY:-1}" = 1 ] || return 0
  local r="$1" first cl cc
  cc="${CLIENT_CELLS[0]}"   # the block's first client cell (8,1 interactive unless CLIENT_CELLS_SPEC)
  case "$2" in
    cost)  first="$(ordered "$r" $COST_V | cut -d' ' -f1)"
           spawn "$r" "$OUT/throwaway-spawn.tsv" ${cc% *} ${cc#* } "$first" "$COST_CELLS" spawn "${TD:-8}" ;;
    cells) first="$(ordered "$r" $FAIR_I81_V | cut -d' ' -f1)"
           spawn "$r" "$OUT/throwaway-spawn.tsv" ${cc% *} ${cc#* } "$first" "500:2" spawn "${TD:-8}" ;;
    shapes) first="$(ordered "$r" $SHAPE_V | cut -d' ' -f1)"
           spawn "$r" "$OUT/throwaway-spawn.tsv" 8,1 interactive "$first" "$SHAPE_CELLS" spawn "${TD:-8}" ;;
    fib)   first="$(ordered "$r" $ABBA_COLS | cut -d' ' -f1)"; set -- ${ABBA_LAYOUTS:-8,1 8,0}
           native_nested "$r" "$OUT/throwaway-nested.tsv" "$1" "$first" WORKLOADS=fib_fine ;;
  esac
}

# PROFILE=native: the small cells of a round in one quiet block (one gate instead of six), after one
# throwaway slot: the three starved cells (fairness), the inner shape, the mixed and the mixed-inner
# cells, fib_fine alone and fib_fine under a marked root, both at 8,1 and 8,0.
cells_block() {   # round, fairness tsv, shapes tsv, mixed tsv, mixedinner tsv, nested tsv, markroot tsv
  local r="$1" rc=0 s
  native_throwaway "$r" cells || return 1
  fairness_block "$r" "$2" || return 1
  shapes_block "$r" "$3" || return 1
  mixed_block "$r" "$4" || return 1
  mixed_block "$r" "$5" SHAPE=inner || return 1
  nesting_block "$r" "$6" "$NEST_V" WORKLOADS=fib_fine; s=$?
  case "$s" in 0) ;; 2) rc=2 ;; *) return "$s" ;; esac
  markroot_block "$r" "$7" "$MARKROOT_V"; s=$?
  case "$s" in 0) ;; 2) rc=2 ;; *) return "$s" ;; esac
  return "$rc"
}

# PROFILE=native: fib_fine alone for ABBA_COLS (ctl and mark0), ABBA_ROUNDS rounds (12) in one quiet
# block after one throwaway slot. Round r runs 8,1 then 8,0, the two tokens in order in odd rounds
# and reversed in even ones (A B / B A), so each token takes each position equally often per layout.
fibabba_block() {   # nested tsv
  local tsv="$1" r layout v rc=0 s
  native_throwaway 1 fib || return 1
  for r in $(seq 1 "${ABBA_ROUNDS:-12}"); do
    for layout in ${ABBA_LAYOUTS:-8,1 8,0}; do
      for v in $(ordered "$r" $ABBA_COLS); do
        native_nested "$r" "$tsv" "$layout" "$v" WORKLOADS=fib_fine; s=$?
        case "$s" in 0) ;; 2) rc=2 ;; *) return "$s" ;; esac
      done
    done
  done
  return "$rc"
}

# PROFILE=native, the battery (#618): MULTI_ROUNDS rounds of the cost, shapes or fairness block in ONE
# quiet block (one gate, not one per round: after a heavy block the gate waits 2-3 min for the load to
# fall), one throwaway slot first, the rounds numbered 1..MULTI_ROUNDS in the TSVs. Run with ROUNDS=1.
costrounds_block() {   # spawn tsv, micro tsv
  local r; native_throwaway 1 cost || return 1
  for r in $(seq 1 "${MULTI_ROUNDS:-6}"); do THROWAWAY=0 cost_block "$r" "$1" "$2" || return 1; done
}
shaperounds_block() {   # spawn tsv
  local r; native_throwaway 1 shapes || return 1
  for r in $(seq 1 "${MULTI_ROUNDS:-6}"); do shapes_block "$r" "$1" || return 1; done
}
fairrounds_block() {   # spawn tsv
  local r; native_throwaway 1 cells || return 1
  for r in $(seq 1 "${MULTI_ROUNDS:-6}"); do fairness_block "$r" "$1" || return 1; done
}

markroot_block() {   # round, nested tsv, variants, extra env...
  local r="$1" tsv="$2" vs="$3"; shift 3
  NEST_LAYOUTS="${NEST_LAYOUTS:-8,1 8,0}" nesting_block "$r" "$tsv" "$vs" WORKLOADS=fib_fine MARK_ROOT=1 "$@"
}

markall_block() {   # nested tsv
  NEST_LAYOUTS="8,1 8,0" nesting_block 1 "$1" "A M-f M-l" WORKLOADS=fib_fine MARK_ALL=1
}

# One block behind quiet.sh, retrying a gate failure or a stopped block. nested.sh's exit 2 (a
# process killed by its timeout, recorded in the TSV) counts as finished.
block() {   # label, files..., --, function args...
  local label="$1"; shift
  local files=()
  while [ "$1" != -- ]; do files+=("$1"); shift; done; shift
  local attempt=1 rc
  # NOGATE=1: run the block directly, not behind quiet.sh (a smoke pass of the block code, never timed).
  if [ "${NOGATE:-0}" = 1 ]; then "$@"; rc=$?; [ "$rc" = 2 ] && rc=0; return "$rc"; fi
  while :; do
    "$ROOT/bench/socket/quiet.sh" "$label" "$@"; rc=$?
    [ "$rc" = 2 ] && { log "$label: finished with a process killed by its timeout (recorded in the TSV)"; return 0; }
    [ "$rc" = 3 ] || [ "$rc" = 4 ] || return "$rc"
    [ "$attempt" -le "$RETRIES" ] || { log "$label: giving up after $attempt attempts (status $rc)"; return "$rc"; }
    log "$label: attempt $attempt ended with status $rc; retrying"
    attempt=$((attempt + 1))
    rm -f "${files[@]}"
  done
}

# quiet.sh runs a command, so the block functions are reached through this script itself.
if [ "${1:-}" = --run ]; then shift; "$@"; exit $?; fi
SELF=("$0" --run)

if [ "$VALIDATE" = 1 ]; then
  export VALIDATE
  status=0
  vlog="$OUT/validate.log"
  if [ "${NEG_ONLY:-0}" = 1 ]; then
    log "negative controls only, stderr appended to $vlog"
  else
    : >"$vlog"
    log "validation pass (not timed, no gate): $JL ($VER) -> $OUT/validate-*.tsv, stderr in $vlog"
    rm -f "$OUT"/validate-*.tsv
    {
      cost_block 1 "$OUT/validate-cost-spawn.tsv" "$OUT/validate-micro.tsv" &&
      fairness_block 1 "$OUT/validate-fairness-spawn.tsv" &&
      nesting_block 1 "$OUT/validate-nested.tsv" "$VAL_NEST_V" FIB_FINE=36:12 &&
      { [ -z "$VAL_MARKALL_V" ] ||
        NEST_LAYOUTS="8,1 8,0" nesting_block 1 "$OUT/validate-markall.tsv" "$VAL_MARKALL_V" WORKLOADS=fib_fine FIB_FINE=36:12 MARK_ALL=1; } &&
      { [ -z "$VAL_MIX_V" ] || MIX_V="$VAL_MIX_V" mixed_block 1 "$OUT/validate-mixed.tsv" FIB_FINE=36:12 D=4; } &&
      { [ "$PROFILE" != rings ] || sweep_block 1 "$OUT/validate-sweep.tsv"; } &&
      { [ "$PROFILE" != inherit ] || {
          MIX_V="$VAL_MIX_V" mixed_block 1 "$OUT/validate-mixedinner.tsv" FIB_FINE=36:12 D=4 SHAPE=inner &&
          markroot_block 1 "$OUT/validate-markroot.tsv" "$VAL_MARKROOT_V" FIB_FINE=36:12 &&
          sweep_block 1 "$OUT/validate-sweep.tsv"; }; } &&
      { { [ "$PROFILE" != gc ] && [ "$PROFILE" != native ]; } || {
          MIX_V="$VAL_MIX_V" mixed_block 1 "$OUT/validate-mixedinner.tsv" FIB_FINE=36:12 D=4 SHAPE=inner &&
          markroot_block 1 "$OUT/validate-markroot.tsv" "$VAL_MARKROOT_V" FIB_FINE=36:12 &&
          pool_block 1 "$OUT/validate-pool.tsv" "$POOL_V" &&
          pool_block 1 "$OUT/validate-noclock-pool.tsv" "$NOCLOCK_V" M_NOCLOCK=1 &&
          nesting_block 1 "$OUT/validate-noclock-nested.tsv" "$NOCLOCK_V" WORKLOADS=fib_fine FIB_FINE=36:12 M_NOCLOCK=1; }; }
    } 2>>"$vlog" || status=1
  fi
  # The negative controls must fail, each with its own message:
  #   blind  a check_empty blind to the F queue says empty with a task queued (probe 2 fails);
  #   stall  an F task pinned to a thread that never pops trips f_pop!'s stall check (abort, 134).
  nlog="$OUT/negative-control.err"
  #   rblind (PROFILE=inherit) a check_empty blind to the R heaps says empty with an R task queued.
  for control in "blind:says empty while the F queue holds a task" "stall:made no pop meanwhile" \
                 ${NEG_R_V:+"rblind:says empty while the R heaps hold a task"}; do
    name="${control%%:*}" msg="${control#*:}"
    nvs="$NEG_V"; [ "$name" = rblind ] && nvs="$NEG_R_V"
    for nv in $nvs; do
    for layout in 8,1 8,0; do
      : >"$nlog"
      if env VALIDATE=1 VARIANT="$nv" M_NEGATIVE="$name" CELLS=50:0.2 MODES=spawn D=1 timeout -s KILL 300 \
           taskset -c "$CPUS" "$JL" --threads="$layout" "$HERE/spawn_order.jl" >/dev/null 2>"$nlog"; then
        log "NEGATIVE CONTROL $name under $nv at $layout passed, and it must fail"; status=1
      elif grep -q "$msg" "$nlog"; then
        log "negative control $name under $nv at $layout failed as it must: $(grep -m1 "$msg" "$nlog" | cut -c1-160)"
      else
        log "negative control $name under $nv at $layout failed for another reason; see $vlog"; status=1
      fi
      { echo "--- negative control $name under $nv at $layout"; cat "$nlog"; } >>"$vlog"
    done
    done
  done
  rm -f "$nlog"
  log "validation pass done (status $status)"
  exit "$status"
fi

status=0
for r in $(seq "${FIRST_ROUND:-1}" "$ROUNDS"); do
  for kind in $BLOCKS; do
    stamp="$(date +%Y%m%d-%H%M%S)"
    case "$kind" in
      cost)
        a="$OUT/attempt-cost-spawn-r$r-$stamp.tsv" b="$OUT/attempt-micro-r$r-$stamp.tsv"
        if block "cost-r$r" "$a" "$b" -- "${SELF[@]}" cost_block "$r" "$a" "$b"; then
          mv "$a" "$OUT/cost-spawn-r$r.tsv"; mv "$b" "$OUT/micro-r$r.tsv"; log "round $r cost done"
        else log "round $r cost FAILED"; status=1; fi ;;
      pool)
        a="$OUT/attempt-pool-r$r-$stamp.tsv"
        if block "pool-r$r" "$a" -- "${SELF[@]}" pool_block "$r" "$a" "$POOL_V"; then
          mv "$a" "$OUT/pool-r$r.tsv"; log "round $r pool done"
        else log "round $r pool FAILED"; status=1; fi ;;
      fairness|shapes)
        a="$OUT/attempt-$kind-spawn-r$r-$stamp.tsv"
        if block "$kind-r$r" "$a" -- "${SELF[@]}" "${kind}_block" "$r" "$a"; then
          mv "$a" "$OUT/$kind-spawn-r$r.tsv"; log "round $r $kind done"
        else log "round $r $kind FAILED"; status=1; fi ;;
      nesting)
        a="$OUT/attempt-nested-r$r-$stamp.tsv"
        if block "nesting-r$r" "$a" -- "${SELF[@]}" nesting_block "$r" "$a" "$NEST_V" ${NEST_WORKLOADS:+WORKLOADS=$NEST_WORKLOADS}; then
          mv "$a" "$OUT/nested-r$r.tsv"; log "round $r nesting done"
        else log "round $r nesting FAILED"; status=1; fi ;;
      pilot)
        a="$OUT/attempt-pilot-spawn-$stamp.tsv" b="$OUT/attempt-pilot-nested-$stamp.tsv" c="$OUT/attempt-pilot-mixedinner-$stamp.tsv"
        second=pilot-nested.tsv; [ "$PROFILE" = share ] || [ "$PROFILE" = inherit ] || [ "$PROFILE" = gc ] || [ "$PROFILE" = native ] && second=pilot-mixed.tsv
        third=pilot-mixedinner.tsv; [ "$PROFILE" = native ] && third=pilot-nested.tsv
        if block "pilot" "$a" "$b" "$c" -- "${SELF[@]}" pilot_block "$a" "$b" "$c"; then
          mv "$a" "$OUT/pilot-spawn.tsv"; mv "$b" "$OUT/$second"
          [ -s "$c" ] && mv "$c" "$OUT/$third"; log "pilot done"
        else log "pilot FAILED"; status=1; fi ;;
      mixedinner)
        a="$OUT/attempt-mixedinner-r$r-$stamp.tsv"
        if block "mixedinner-r$r" "$a" -- "${SELF[@]}" mixed_block "$r" "$a" SHAPE=inner; then
          mv "$a" "$OUT/mixedinner-r$r.tsv"; log "round $r mixedinner done"
        else log "round $r mixedinner FAILED"; status=1; fi ;;
      cells)
        a="$OUT/attempt-cells-fairness-r$r-$stamp.tsv" b="$OUT/attempt-cells-shapes-r$r-$stamp.tsv"
        c="$OUT/attempt-cells-mixed-r$r-$stamp.tsv" d="$OUT/attempt-cells-mixedinner-r$r-$stamp.tsv"
        e="$OUT/attempt-cells-nested-r$r-$stamp.tsv" f="$OUT/attempt-cells-markroot-r$r-$stamp.tsv"
        if block "cells-r$r" "$a" "$b" "$c" "$d" "$e" "$f" -- "${SELF[@]}" cells_block "$r" "$a" "$b" "$c" "$d" "$e" "$f"; then
          mv "$a" "$OUT/fairness-spawn-r$r.tsv"; mv "$b" "$OUT/shapes-spawn-r$r.tsv"; mv "$c" "$OUT/mixed-r$r.tsv"
          mv "$d" "$OUT/mixedinner-r$r.tsv"; mv "$e" "$OUT/nested-r$r.tsv"; mv "$f" "$OUT/markroot-r$r.tsv"
          log "round $r cells done"
        else log "round $r cells FAILED"; status=1; fi ;;
      costrounds)
        a="$OUT/attempt-costrounds-spawn-$stamp.tsv" b="$OUT/attempt-costrounds-micro-$stamp.tsv"
        if block "costrounds" "$a" "$b" -- "${SELF[@]}" costrounds_block "$a" "$b"; then
          mv "$a" "$OUT/costrounds-spawn.tsv"; [ -s "$b" ] && mv "$b" "$OUT/costrounds-micro.tsv"; log "costrounds done"
        else log "costrounds FAILED"; status=1; fi ;;
      shaperounds|fairrounds)
        a="$OUT/attempt-$kind-spawn-$stamp.tsv"
        if block "$kind" "$a" -- "${SELF[@]}" "${kind}_block" "$a"; then
          mv "$a" "$OUT/$kind-spawn.tsv"; log "$kind done"
        else log "$kind FAILED"; status=1; fi ;;
      fibabba)
        a="$OUT/attempt-fibabba-$stamp.tsv"
        if block "fibabba" "$a" -- "${SELF[@]}" fibabba_block "$a"; then
          mv "$a" "$OUT/fibabba-nested.tsv"; log "fibabba done"
        else log "fibabba FAILED"; status=1; fi ;;
      markroot)
        a="$OUT/attempt-markroot-r$r-$stamp.tsv"
        if block "markroot-r$r" "$a" -- "${SELF[@]}" markroot_block "$r" "$a" "$MARKROOT_V"; then
          mv "$a" "$OUT/markroot-r$r.tsv"; log "round $r markroot done"
        else log "round $r markroot FAILED"; status=1; fi ;;
      step0b)
        a="$OUT/attempt-step0b-sweep-$stamp.tsv" b="$OUT/attempt-step0b-fairness-$stamp.tsv"
        if block "step0b" "$a" "$b" -- "${SELF[@]}" step0b_block "$a" "$b"; then
          mv "$a" "$OUT/step0b-sweep.tsv"; mv "$b" "$OUT/step0b-fairness.tsv"; log "step0b done"
        else log "step0b FAILED"; status=1; fi ;;
      age)
        a="$OUT/attempt-age-mixed-$stamp.tsv" b="$OUT/attempt-age-spawn-$stamp.tsv"
        if block "age" "$a" "$b" -- "${SELF[@]}" age_block "$a" "$b"; then
          mv "$a" "$OUT/age-mixed.tsv"; mv "$b" "$OUT/age-spawn.tsv"; log "age done"
        else log "age FAILED"; status=1; fi ;;
      mixed)
        a="$OUT/attempt-mixed-r$r-$stamp.tsv"
        if block "mixed-r$r" "$a" -- "${SELF[@]}" mixed_block "$r" "$a"; then
          mv "$a" "$OUT/mixed-r$r.tsv"; log "round $r mixed done"
        else log "round $r mixed FAILED"; status=1; fi ;;
      halfmix)
        a="$OUT/attempt-halfmix-r$r-$stamp.tsv"
        if block "halfmix-r$r" "$a" -- "${SELF[@]}" mixed_block "$r" "$a" BG=loops:4 C=4; then
          mv "$a" "$OUT/halfmix-r$r.tsv"; log "round $r halfmix done"
        else log "round $r halfmix FAILED"; status=1; fi ;;
      sweep)
        a="$OUT/attempt-sweep-r$r-$stamp.tsv"
        if block "sweep-r$r" "$a" -- "${SELF[@]}" sweep_block "$r" "$a"; then
          mv "$a" "$OUT/sweep-r$r.tsv"; log "round $r sweep done"
        else log "round $r sweep FAILED"; status=1; fi ;;
      q1)
        a="$OUT/attempt-q1-sweep-$stamp.tsv" b="$OUT/attempt-q1-validate-$stamp.tsv"
        if block "q1" "$a" "$b" -- "${SELF[@]}" q1_block "$a" "$b"; then
          mv "$a" "$OUT/q1-sweep.tsv"; mv "$b" "$OUT/q1-validate.tsv"; log "q1 done"
        else log "q1 FAILED"; status=1; fi ;;
      markall)
        a="$OUT/attempt-markall-$stamp.tsv"
        if block "markall" "$a" -- "${SELF[@]}" markall_block "$a"; then
          mv "$a" "$OUT/markall-nested.tsv"; log "markall done"
        else log "markall FAILED"; status=1; fi ;;
      *) echo "rounds_fifo: unknown block $kind" >&2; exit 1 ;;
    esac
  done
done
log "done (status $status); next: julia $HERE/aggregate_fifo.jl $OUT"
exit "$status"
