#!/usr/bin/env bash
# Build bench/juliac/app.jl into a standalone executable with `juliac` (#570).
#
#   bench/juliac/build.sh [no|unsafe-warn|safe]      # the --trim mode; default `no`
#   ENTRY=probe bench/juliac/build.sh unsafe-warn     # build probe.jl instead (#718)
#   JULIAC=bundled bench/juliac/build.sh unsafe-warn  # Julia 1.12's own driver, for a 1.12 count
#
# Env: JULIAC (default `juliac`) picks the frontend:
#        juliac  -- the JuliaC.jl app (`julia +1.13 -e 'using Pkg; Pkg.Apps.add("JuliaC")'`),
#                   run as JULIAC_BIN (default ~/.julia/bin/juliac). The default, because Julia
#                   1.13 ships no driver of its own, and 1.13 is what CI runs and where the floor
#                   is moving (#526).
#        bundled -- the juliac.jl driver Julia 1.12 ships under share/julia/juliac. Kept until the
#                   floor moves, so a 1.12 count can still be reproduced.
#      JULIA (default "julia +1.13", or "julia +1.12" with JULIAC=bundled) is the Julia that
#        builds; JuliaC's shim is pointed at it through JULIA_APPS_JULIA_CMD.
#      JULIA_CPU_TARGET (default `native`). The bundled driver builds for the running Julia's own
#        target, `native`; JuliaC, left alone, builds for every target of Julia's system image
#        (`generic;sandybridge;haswell;x86-64-v4`, each cloned), which on 1.13 made the untrimmed
#        app 512 MB and its build 7 minutes. `native` keeps size and build time comparable across
#        the two frontends; the verifier's count does not depend on it.
#      OUT (default bench/juliac/out, gitignored),
#      ENTRY (default `app`): `app` is the served minimal app, `probe` calls the request pipeline
#        directly so the verifier reaches it whatever stands in front of the listener.
# The environment is instantiated under JULIA first, into its own Manifest-v<major>.<minor>.toml
# (gitignored), so a 1.12 and a 1.13 build never re-resolve each other's manifest. Both frontends
# compile against --project=bench/juliac: the bundled driver in the active project, JuliaC in a
# temporary copy of it.
# Everything the build prints goes to bench/results/juliac-<stamp>-<entry>-<mode>.log (gitignored)
# through `tee`. Keep the pipe: on 1.13 a build whose stderr went straight to a file lost the tail
# of the verifier's output, summary line included. Do not add JuliaC's --verbose either: it prints
# the whole process environment, tokens and all, into the log. The exit code is the frontend's.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MODE=${1:-no}
ENTRY=${ENTRY:-app}
[ -f "$HERE/$ENTRY.jl" ] || { echo "no entry $HERE/$ENTRY.jl"; exit 2; }
JULIAC=${JULIAC:-juliac}
case "$JULIAC" in
  juliac)  JULIA=${JULIA:-"julia +1.13"} ;;
  bundled) JULIA=${JULIA:-"julia +1.12"} ;;
  *) echo "JULIAC must be juliac or bundled, not $JULIAC"; exit 2 ;;
esac
OUT=${OUT:-"$HERE/out"}
JULIA_CPU_TARGET=${JULIA_CPU_TARGET:-native}
export JULIA_CPU_TARGET
mkdir -p "$OUT" "$ROOT/bench/results"

if [ "$JULIAC" = juliac ]; then
  JULIAC_BIN=${JULIAC_BIN:-"$HOME/.julia/bin/juliac"}
  [ -x "$JULIAC_BIN" ] || { echo "JuliaC not found at $JULIAC_BIN (pkg> app add JuliaC, under Julia 1.13)"; exit 2; }
  APP_MANIFEST="$(dirname "$JULIAC_BIN")/../environments/apps/JuliaC/Manifest.toml"
  FRONTEND="JuliaC $($JULIA --startup-file=no -e '
    using TOML
    e = isfile(ARGS[1]) ? only(TOML.parsefile(ARGS[1])["deps"]["JuliaC"]) : nothing
    print(e === nothing ? "(version unknown)" : string(e["version"], " (tree ", e["git-tree-sha1"], ")"))' "$APP_MANIFEST") at $JULIAC_BIN"
  JULIA_APPS_JULIA_CMD=$($JULIA --startup-file=no -e 'print(joinpath(Sys.BINDIR, Base.julia_exename()))')
  export JULIA_APPS_JULIA_CMD
else
  DRIVER=$($JULIA --startup-file=no -e 'print(normpath(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl")))')
  [ -f "$DRIVER" ] || { echo "juliac driver not found at $DRIVER (it ships with Julia 1.12 only)"; exit 2; }
  FRONTEND="bundled $DRIVER"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$ROOT/bench/results/juliac-$STAMP-$ENTRY-$MODE.log"
# `nitro-min-<mode>` for the app, the name smoke.sh and the README use.
if [ "$ENTRY" = app ]; then EXE="$OUT/nitro-min-$MODE"; else EXE="$OUT/nitro-$ENTRY-$MODE"; fi
{
  echo "julia:    $($JULIA --startup-file=no -e 'print(VERSION)')"
  echo "frontend: $FRONTEND"
  echo "entry:    $ENTRY.jl"
  echo "mode:     --trim=$MODE"
  echo "cpu:      $JULIA_CPU_TARGET"
  echo "exe:      $EXE"
  echo "nitro:    $(git -C "$ROOT" rev-parse --short HEAD)"
} | tee "$LOG"

START=$(date +%s)
$JULIA --startup-file=no --project="$HERE" -e '
  using Pkg
  m = joinpath(dirname(Base.active_project()), "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
  isfile(m) || touch(m)
  Pkg.resolve(); Pkg.instantiate()' 2>&1 | tee -a "$LOG"
rm -f "$EXE"
if [ "$JULIAC" = juliac ]; then
  # `--output-exe` takes a file name, not a path: JuliaC writes it to the working directory.
  # Unbundled, the exe links against JULIA's own lib/ by absolute path, which is what a local
  # measurement wants; `--bundle` would copy ~100 MB of libraries per build.
  ( cd "$OUT" && "$JULIAC_BIN" --project "$HERE" --output-exe "$(basename "$EXE")" \
      --trim="$MODE" --experimental "$HERE/$ENTRY.jl" ) 2>&1 | tee -a "$LOG"
else
  ( cd "$ROOT" && $JULIA --startup-file=no --project="$HERE" "$DRIVER" --output-exe "$EXE" \
      --experimental --trim="$MODE" "$HERE/$ENTRY.jl" ) 2>&1 | tee -a "$LOG"
fi
RC=${PIPESTATUS[0]}
echo "build: rc=$RC, $(( $(date +%s) - START )) s" | tee -a "$LOG"
[ -f "$EXE" ] && ls -la "$EXE" | tee -a "$LOG"
exit "$RC"
