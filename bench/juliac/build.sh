#!/usr/bin/env bash
# Build bench/juliac/app.jl into a standalone executable with Julia 1.12's juliac (#570).
#
#   bench/juliac/build.sh [no|unsafe-warn|safe]     # the --trim mode; default `no`
#   ENTRY=probe bench/juliac/build.sh unsafe-warn    # build probe.jl instead (#718)
#
# Env: JULIA (default "julia +1.12" -- the driver ships with 1.12 under share/julia/juliac),
#      OUT (default bench/juliac/out, gitignored),
#      ENTRY (default `app`): `app` is the served minimal app, `probe` calls the request pipeline
#      directly so the verifier reaches it whatever stands in front of the listener.
# The driver compiles in the ACTIVE project, so --project is pinned to bench/juliac here, and the
# environment is instantiated first because the driver's own Pkg.precompile() step assumes it.
# Everything the build prints goes to bench/results/juliac-<stamp>-<entry>-<mode>.log
# (gitignored); the exit code is the driver's.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MODE=${1:-no}
ENTRY=${ENTRY:-app}
[ -f "$HERE/$ENTRY.jl" ] || { echo "no entry $HERE/$ENTRY.jl"; exit 2; }
JULIA=${JULIA:-"julia +1.12"}
OUT=${OUT:-"$HERE/out"}
mkdir -p "$OUT" "$ROOT/bench/results"

DRIVER=$($JULIA --startup-file=no -e 'print(normpath(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl")))')
[ -f "$DRIVER" ] || { echo "juliac driver not found at $DRIVER (it ships with Julia 1.12)"; exit 2; }

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$ROOT/bench/results/juliac-$STAMP-$ENTRY-$MODE.log"
# `nitro-min-<mode>` for the app, the name smoke.sh and the README use.
if [ "$ENTRY" = app ]; then EXE="$OUT/nitro-min-$MODE"; else EXE="$OUT/nitro-$ENTRY-$MODE"; fi
{
  echo "julia:  $($JULIA --startup-file=no -e 'print(VERSION)')"
  echo "driver: $DRIVER"
  echo "entry:  $ENTRY.jl"
  echo "mode:   --trim=$MODE"
  echo "exe:    $EXE"
  echo "nitro:  $(git -C "$ROOT" rev-parse --short HEAD)"
} | tee "$LOG"

START=$(date +%s)
$JULIA --startup-file=no --project="$HERE" -e 'using Pkg; Pkg.instantiate()' 2>&1 | tee -a "$LOG"
( cd "$ROOT" && $JULIA --startup-file=no --project="$HERE" "$DRIVER" --output-exe "$EXE" \
    --experimental --trim="$MODE" "$HERE/$ENTRY.jl" ) 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
echo "build: rc=$RC, $(( $(date +%s) - START )) s" | tee -a "$LOG"
[ -f "$EXE" ] && ls -la "$EXE" | tee -a "$LOG"
exit "$RC"
