#!/usr/bin/env bash
# Provision a fresh Nitro worktree with the local state it needs to run tests. Safe to re-run.
#
# WHAT IT DOES, AND WHY
#
# `Manifest.toml` is gitignored, so a fresh worktree has none. Left alone, Pkg resolves to
# whatever is newest — a version difference between your worktree and the main checkout that
# nothing announces and that later reads as a flake. This script copies the main checkout's
# manifest, runs `Pkg.resolve()` (conservative: it keeps the copied versions wherever they still
# satisfy Project.toml), and only then `Pkg.instantiate()`. When the copy cannot be reconciled
# with a `[compat]` edit on this branch it discards it and resolves fresh — but only a manifest
# THIS RUN created, and only on a resolve failure. Both conditions are argued at the call site.
#
# It also links any `[sources]` PATH dependency into place. Pkg resolves such a path relative to
# the *project directory*, so from a worktree `../Foo.jl` points at `.claude/worktrees/Foo.jl`
# rather than at the real sibling clone, and EVERY Pkg operation then dies at resolve time with
# `expected package Foo [uuid] to exist at path …` — a resolve failure, not a test failure:
# nothing runs, including tests that have nothing to do with Foo. The link goes in
# `.claude/worktrees/` (gitignored, never committed), one per entry, placed so all sibling
# worktrees share it. Windows uses a directory JUNCTION rather than a symlink: junctions need no
# administrator rights and no Developer Mode, unlike `mklink /D`.
#
# `Project.toml` HAS NO PATH SOURCE TODAY, so that loop finds nothing to link. PormG used to be
# one; `[sources]` now pins it by url + an immutable `rev` that Pkg fetches into the depot (#21),
# and it must never go back — a path entry is committable, so it breaks every other checkout, and
# it was a registry-publication blocker (#117, and docs/design/registry-publication.md). The loop
# is kept generic rather than deleted: it costs nothing and is the only thing standing between a
# future path source and an unusable worktree.
#
# Usage:
#   bash scripts/worktree_setup.sh [<worktree-path>]     # defaults to $(pwd)

set -euo pipefail

WT="${1:-$(pwd)}"
WT="$(cd "$WT" && pwd)"

# The main working tree is the first entry of `git worktree list`.
MAIN="$(git -C "$WT" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
if [[ -z "${MAIN:-}" ]]; then
  echo "!! not inside a git checkout: $WT" >&2
  exit 1
fi
MAIN="$(cd "$MAIN" && pwd)"

echo "main checkout : $MAIN"
echo "worktree      : $WT"

# Create a directory link at $2 pointing to $1, cross-platform. No-op if it already resolves.
link_dir() {
  local target="$1" link="$2"
  mkdir -p "$(dirname "$link")"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # `//J` is MSYS-escaped and reaches cmd.exe as `/J`.
      cmd //c mklink //J "$(cygpath -w "$link")" "$(cygpath -w "$target")" >/dev/null
      ;;
    *)
      ln -s "$target" "$link"
      ;;
  esac
}

# Resolve the `[sources]` path deps against the MAIN checkout, then make the same relative path
# work from the worktree. Generic over the block, so a future second source dep needs no edit.
if [[ "$MAIN" == "$WT" ]]; then
  echo "path deps     : main checkout — relative [sources] paths already resolve, nothing to link"
else
  echo "linking [sources] path deps:"
  while IFS= read -r line; do
    name="$(sed -E 's/^[[:space:]]*([A-Za-z0-9_]+).*/\1/' <<<"$line")"
    rel="$(sed -E 's/.*path[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/' <<<"$line")"
    [[ -z "$name" || -z "$rel" ]] && continue

    target="$(cd "$MAIN/$rel" 2>/dev/null && pwd || true)"
    if [[ -z "$target" ]]; then
      echo "  ! $name: '$rel' does not resolve from the main checkout either — SKIPPED" >&2
      echo "    (clone it next to the Nitro repo, then re-run this script)" >&2
      continue
    fi

    link="$WT/$rel"
    if [[ -f "$link/Project.toml" ]] && grep -qE "^name[[:space:]]*=[[:space:]]*\"$name\"" "$link/Project.toml"; then
      echo "  = $name -> $rel (already linked)"
      continue
    fi
    if [[ -e "$link" ]]; then
      echo "  ! $name: '$link' exists but is not the $name package — leaving it alone" >&2
      continue
    fi
    link_dir "$target" "$link"
    echo "  + $name -> $rel  ($target)"
  done < <(awk '/^\[sources\]/{f=1;next} /^\[/{f=0} f && /path[[:space:]]*=/' "$MAIN/Project.toml")
fi

# Manifest.toml is gitignored, so a fresh worktree has none. Copying the main checkout's (when it
# has one) reproduces the same resolution instead of re-resolving to whatever is newest.
#
# `copied_manifest` records whether the file below is OURS. Only a manifest this run created may be
# thrown away on a resolve failure — see the fallback further down.
copied_manifest=0
if [[ "$MAIN" != "$WT" && -f "$MAIN/Manifest.toml" && ! -f "$WT/Manifest.toml" ]]; then
  cp "$MAIN/Manifest.toml" "$WT/Manifest.toml"
  copied_manifest=1
  echo "manifest      : copied from the main checkout"
fi

# `resolve` before `instantiate`: a copied Manifest can predate a `[compat]` edit on this branch,
# and bare `instantiate` only warns about that ("dependencies or compat requirements have changed")
# while leaving the stale manifest in place — the next `Pkg.test` then re-resolves mid-run. resolve
# is conservative: it keeps the copied versions wherever they still satisfy Project.toml.
#
# ...and that conservatism is exactly why it can fail outright. `Pkg.resolve()` PRESERVES versions;
# it will not upgrade one to satisfy a raised bound. So a manifest copied from a checkout that still
# has HTTP 2.4.0, against a Project.toml that now says `HTTP = "~2.6"`, dies with:
#
#     ERROR: empty intersection between HTTP@2.4.0 and project compatibility 2.6
#
# The copy is an optimisation — reproduce the main checkout's resolution — never a requirement. When
# it cannot be reconciled, discard it and resolve fresh rather than leaving the worktree unusable:
# an unresolvable worktree means EVERY Pkg operation fails, which is the failure this script exists
# to prevent. Silence on the happy path, one loud line when the copy is dropped, so a surprising
# dependency version later is traceable to this (#128).
#
# TWO conditions on that discard, because deleting someone's manifest is not recoverable:
#
#   * only a manifest THIS RUN copied (`copied_manifest`). The script is safe to re-run and is
#     explicitly supported in the main checkout, where the manifest is the real one — and a
#     locally-resolved worktree manifest may hold `Pkg.develop`ed or pinned entries that no
#     `[sources]` entry would restore. Not ours, not ours to delete: fail instead, as before.
#   * only a RESOLVE failure. `resolve` and `instantiate` are separate commands here for exactly
#     this reason: instantiate failures are usually a registry or artifact download hiccup, and
#     deleting a good manifest over a flaky network — then re-resolving into the same network —
#     leaves the checkout with no manifest at all, which is strictly worse than what it started
#     with, under a message blaming a compat conflict that never happened.
echo "resolving + instantiating (julia --project=.) ..."
if ! julia --project="$WT" -e 'import Pkg; Pkg.resolve()'; then
  if [[ "$copied_manifest" == "1" ]]; then
    echo "manifest      : the copied manifest does not satisfy this branch's [compat] — discarding it and re-resolving"
    rm -f "$WT/Manifest.toml"
    julia --project="$WT" -e 'import Pkg; Pkg.resolve()'
  else
    echo "manifest      : resolve failed against an existing manifest this script did not create — leaving it alone." >&2
    echo "                Raise it yourself (e.g. Pkg.update(\"HTTP\") after a [compat] bump), or delete it to re-resolve." >&2
    exit 1
  fi
fi
julia --project="$WT" -e 'import Pkg; Pkg.instantiate()'

echo "done — worktree ready."
echo "  julia --project=. test/runtests.jl                    # full suite"
echo "  julia --project=. test/runtests.jl test/util_tests.jl  # single file"
echo
echo "Both re-dispatch through Pkg.test to provision [targets].test (PormG included),"
echo "and now REFUSE to run if any of it is missing rather than skipping quietly (#128)."
