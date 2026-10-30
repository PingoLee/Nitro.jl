#!/usr/bin/env bash
# Build the #744 realapp (main.jl) into an executable with JuliaC: bench/juliac/build.sh's
# recipe, pointed at this project.
#
#   bench/juliac/realapp/build.sh [no|unsafe-warn|safe]          # the --trim mode; default `no`
#   CPU=default bench/juliac/realapp/build.sh no                  # JuliaC's own CPU target list
#
# Env: CPU (default `native`): exported as JULIA_CPU_TARGET; `default` leaves it unset, so
#        JuliaC builds for every target of Julia's system image -- the portable build, for a
#        server binary deployed to a machine it was not built on. Any other value is passed as is
#        (e.g. "generic;x86-64-v3").
#      ENTRY (default `main`): the entry file in this directory.
#      JULIA, JULIAC_BIN, OUT as in bench/juliac/build.sh. OUT defaults to ./out (gitignored).
# Nothing secret is read while building: main.jl reads ENV, and `main` loads db/connection.yml,
# when the executable starts. RealApp includes its models rather than `@import_models`ing them
# (#790), because that macro registered them by loading db/connection.yml implicitly in the build
# process, which put the database password into the image (#744).
# Output goes through `tee` to bench/results/juliac-<stamp>-realapp-<entry>-<mode>-<cpu>.log;
# never JuliaC's --verbose (it prints the whole environment).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
MODE=${1:-no}
ENTRY=${ENTRY:-main}
[ -f "$HERE/$ENTRY.jl" ] || { echo "no entry $HERE/$ENTRY.jl"; exit 2; }
JULIA=${JULIA:-"julia +1.13"}
OUT=${OUT:-"$HERE/out"}
CPU=${CPU:-native}
if [ "$CPU" = default ]; then unset JULIA_CPU_TARGET; else export JULIA_CPU_TARGET="$CPU"; fi
CPU_TAG=$(printf '%s' "$CPU" | tr -c 'A-Za-z0-9_.-' '_')
mkdir -p "$OUT" "$ROOT/bench/results"

JULIAC_BIN=${JULIAC_BIN:-"$HOME/.julia/bin/juliac"}
[ -x "$JULIAC_BIN" ] || { echo "JuliaC not found at $JULIAC_BIN (pkg> app add JuliaC, under Julia 1.13)"; exit 2; }
APP_MANIFEST="$(dirname "$JULIAC_BIN")/../environments/apps/JuliaC/Manifest.toml"
FRONTEND="JuliaC $($JULIA --startup-file=no -e '
  using TOML
  e = isfile(ARGS[1]) ? only(TOML.parsefile(ARGS[1])["deps"]["JuliaC"]) : nothing
  print(e === nothing ? "(version unknown)" : string(e["version"], " (tree ", e["git-tree-sha1"], ")"))' "$APP_MANIFEST") at $JULIAC_BIN"
JULIA_APPS_JULIA_CMD=$($JULIA --startup-file=no -e 'print(joinpath(Sys.BINDIR, Base.julia_exename()))')
export JULIA_APPS_JULIA_CMD

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$ROOT/bench/results/juliac-$STAMP-realapp-$ENTRY-$MODE-$CPU_TAG.log"
EXE="$OUT/realapp-$ENTRY-$MODE-$CPU_TAG"
{
  echo "julia:    $($JULIA --startup-file=no -e 'print(VERSION)')"
  echo "frontend: $FRONTEND"
  echo "entry:    realapp/$ENTRY.jl"
  echo "mode:     --trim=$MODE"
  echo "cpu:      ${JULIA_CPU_TARGET:-(JuliaC default)}"
  echo "exe:      $EXE"
  echo "nitro:    $(git -C "$ROOT" rev-parse --short HEAD)"
} | tee "$LOG"

START=$(date +%s)
$JULIA --startup-file=no --project="$HERE" -e 'using Pkg; Pkg.instantiate()' 2>&1 | tee -a "$LOG"
rm -f "$EXE"
# `--output-exe` takes a file name: JuliaC writes it to the working directory. Unbundled, as
# bench/juliac/build.sh builds: the exe links against JULIA's own lib/ by absolute path.
( cd "$OUT" && "$JULIAC_BIN" --project "$HERE" --output-exe "$(basename "$EXE")" \
    --trim="$MODE" --experimental "$HERE/$ENTRY.jl" ) 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
echo "build: rc=$RC, $(( $(date +%s) - START )) s" | tee -a "$LOG"
[ -f "$EXE" ] && ls -la "$EXE" | tee -a "$LOG"
exit "$RC"
