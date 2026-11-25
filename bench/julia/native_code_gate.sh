#!/usr/bin/env bash
# #618, the candidate's second version: is a function's native code the same on two builds?
#   bench/julia/native_code_gate.sh <julia A> <julia B> [label A] [label B]
# Runs unmarked_code.jl --full --heaps on each build, cuts the output into one block a function,
# normalises what differs between two images without being code (rip-relative and absolute
# addresses, immediates that are addresses, symbol suffixes and comments) and prints, a function a
# line, IDENTICAL or DIFFERS with the number of differing lines. Exit 0 when every function present
# on both is identical. The normalised blocks stay in $GATE_OUT (default a temporary directory).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="$1" B="$2" LA="${3:-A}" LB="${4:-B}"
O="${GATE_OUT:-$(mktemp -d)}"; mkdir -p "$O"
for side in A B; do
  jl="$A"; [ "$side" = B ] && jl="$B"
  "$jl" --startup-file=no "$HERE/unmarked_code.jl" --full --heaps > "$O/raw-$side.txt" 2>&1 || { echo "unmarked_code.jl failed on $jl"; exit 2; }
  awk -v dir="$O" -v side="$side" '
    /^--- native code of / { name = substr($0, 20); gsub(/[^A-Za-z0-9_.]/, "_", name); f = dir "/" side "-" name ".s"; next }
    /^--- end of / { f = ""; next }
    f != "" { print > f }' "$O/raw-$side.txt"
done
norm() {
  sed -E 's/;.*$//; s/#.*$//; s/\[rip \+ -?[0-9]+\]/[rip+X]/g; s/(movabs\s+[a-z0-9]+, )-?[0-9]+/\1N/; s/0x[0-9a-f]+/H/g; s/(julia_|j_|jlplt_|jfptr_)?([A-Za-z_!]+)_[0-9]+/\2/g; s/[[:space:]]+$//' "$1" | grep -v '^\s*$'
}
rc=0
for fa in "$O"/A-*.s; do
  n="${fa#"$O"/A-}"; fb="$O/B-$n"
  [ -f "$fb" ] || { echo "${n%.s}: only on $LA"; continue; }
  d=$(diff <(norm "$fa") <(norm "$fb") | grep -c '^[<>]')
  if [ "$d" = 0 ]; then echo "${n%.s}: IDENTICAL ($(norm "$fa" | wc -l) lines)"; else echo "${n%.s}: DIFFERS ($d lines differ; $LA $(norm "$fa" | wc -l), $LB $(norm "$fb" | wc -l))"; rc=1; fi
done
for fb in "$O"/B-*.s; do n="${fb#"$O"/B-}"; [ -f "$O/A-$n" ] || echo "${n%.s}: only on $LB"; done
echo "normalised blocks in $O"
exit $rc
