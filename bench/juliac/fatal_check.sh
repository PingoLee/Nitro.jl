#!/usr/bin/env bash
# Run a built `ENTRY=fatal` executable (or the JIT) in each failure mode and grep its stderr for
# the probe's sentinel secrets (#749, #750). See fatal.jl for the modes.
#
#   ENTRY=fatal bench/juliac/build.sh unsafe-warn
#   bench/juliac/fatal_check.sh bench/juliac/out/nitro-fatal-unsafe-warn
#   bench/juliac/fatal_check.sh jit
#
# Per mode it prints the exit code, what stderr says the failure was, and any sentinel found.
# For an executable, `serve`, `boot` and `wrapped` must exit non-zero, leak nothing and say what
# failed: `serve` through the value-free `LoggedException` Nitro's `serve` throws in a trimmed
# image, the other two through the recipe's `start-up failed: …` line. `bare` is reported, not
# judged: it fails before Nitro's frames, so it leaks unless the app catches it. Under `jit`
# nothing is judged either, since Base's display calls the `show` methods and Nitro does not
# sanitize there. An untrimmed (`--trim=no`) executable fails `serve` until #752: `serve` cannot
# tell it from the JIT yet, so that red is expected there and is not a regression.
# Exits 1 if an executable fails a judged mode. Stderr goes to OUT (default
# bench/juliac/out, gitignored) as fatal-<mode>.stderr; it may hold the sentinels, never real keys.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TARGET=${1:?usage: fatal_check.sh <exe|jit>}
JULIA=${JULIA:-"julia +1.13"}
OUT=${OUT:-"$HERE/out"}
mkdir -p "$OUT"
SENTINELS=$(grep -oE '"fatal-probe-[a-z-]+-SENTINEL-[0-9]+"' "$HERE/fatal.jl" | tr -d '"')
[ -n "$SENTINELS" ] || { echo "no sentinels found in fatal.jl"; exit 2; }

RC_ALL=0
for MODE in serve boot wrapped bare; do
  ERR="$OUT/fatal-$MODE.stderr"
  if [ "$TARGET" = jit ]; then
    FAIL=$MODE PORT=0 $JULIA --startup-file=no --project="$HERE" "$HERE/fatal.jl" >/dev/null 2>"$ERR"
  else
    FAIL=$MODE PORT=0 "$TARGET" >/dev/null 2>"$ERR"
  fi
  RC=$?
  LEAKED=""
  for S in $SENTINELS; do grep -qF "$S" "$ERR" && LEAKED="$LEAKED ${S%-SENTINEL-*}"; done
  case "$MODE" in
    serve) SAID=$(grep -oE 'LoggedException\(type=:[A-Za-z0-9_]+' "$ERR" | head -1) ;;
    boot|wrapped) SAID=$(grep -oE 'start-up failed: [A-Za-z0-9_]+' "$ERR" | head -1) ;;
    *)     SAID="" ;;
  esac
  printf '%-5s rc=%-3s said=%-40s leaked=%s\n' "$MODE" "$RC" "${SAID:--}" "${LEAKED:- none}"
  if [ "$TARGET" != jit ] && [ "$MODE" != bare ] &&
     { [ -n "$LEAKED" ] || [ -z "$SAID" ] || [ "$RC" -eq 0 ]; }; then
    RC_ALL=1
  fi
done
exit "$RC_ALL"
