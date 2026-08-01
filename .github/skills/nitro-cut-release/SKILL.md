---
name: nitro-cut-release
description: >-
  Cut a Nitro.jl release train — verify the pre-publish gate, bump Project.toml once, stamp the
  UPGRADING.md "Unreleased" entries with the new version, date and tag it, and open a fresh
  Unreleased. Maintainer-invoked; never run as a side effect of finishing a feature.
---

# Nitro.jl — Cut a Release Train

## Purpose

Nitro versions **per release train, not per PR** (see the *Upgrade-log contract* non-negotiable in
[`nitro-general.instructions.md`](../../instructions/nitro-general.instructions.md) and the
[`UPGRADING.md`](../../../UPGRADING.md) header). During a train, breaking/behavior PRs only append to
the **`## Unreleased`** section of `UPGRADING.md` and never touch `Project.toml`. This skill performs
the **cut**: the single, deliberate, maintainer-triggered step where the accumulated `Unreleased`
work becomes a numbered, tagged release.

**Maintainer-invoked only.** The natural trigger is *"I'm about to roll these changes into a
consuming app"* — the version marks that migration checkpoint. Never cut as the tail end of a feature
task, and never bump `Project.toml` outside this skill.

## The versioning model (`0.y.z`, pre-publish)

- `y` bumps on **breaking/behavior** trains; `z` on a purely-additive train or a hotfix to a tagged
  one. This matches Julia Pkg compat: a downstream `compat = "0.y"` accepts `0.y.*` and rejects the
  next breaking release.
- The version is chosen **at cut time**, not when work starts — so during a train `Project.toml`
  still carries the *previous* release's number. That is correct, not drift.
- `UPGRADING.md` carries only what **forces** an app edit. Additive features are documented in
  `docs/` and never appear here, so an empty `Unreleased` after a productive month is possible and
  simply means nothing broke.
- Tag history starts at `v0.1.0`. Earlier `Project.toml` numbers (`0.2.0`–`0.4.0`) and their
  `v0.1.0`/`v0.2.0` tags predate the policy, were per-PR bumps, and were deleted and reclaimed.

---

## Preconditions — check first, stop if unmet

```bash
git status --porcelain                 # must be clean
git rev-parse --abbrev-ref HEAD        # expect main, up to date with origin
grep -n '\*\*Version\*\*: Unreleased' UPGRADING.md    # must match at least once
gh issue list --label pre-publish      # the publish gate (informational for 0.y releases)
```

1. **Working tree clean, on `main`, synced with `origin`.** Stop otherwise.
2. **`## Unreleased` is non-empty.** If nothing carries `- **Version**: Unreleased`, **stop** —
   there is nothing to cut. An empty train is not a release.
3. **The suite is green on CI** for the commit you are about to tag — not just locally. CI covers
   Julia 1.12 on three OSes at 1 and 2 threads.
4. **Every entry carries its grep and its `before → after`.** Add missing ones now.
5. **`docs_lint` passes:** `julia .github/scripts/docs_lint.jl`.

Report anything unmet and stop. Do not "fix it while you're there."

---

## Steps

### 1. List the wave, then choose the version

Show every `## Unreleased` entry title with its `**Severity**`, so the maintainer sees exactly what
is shipping. Count them.

- **Default: bump the `y` slot** (`0.a.z → 0.(a+1).0`) — a train carrying any `breaking` or
  `behavior` entry is a migration checkpoint.
- **`z` bump** (`0.a.z → 0.a.(z+1)`) only if **every** entry is additive / no-action.

Show `current → proposed` and **get an explicit go-ahead** before editing anything. This is the last
cheap moment to change it.

### 2. Bump `Project.toml`

```toml
version = "<new>"
```

This is the **only** place the version moves. Do not add a comment explaining the bump —
CompatHelper strips every comment from `Project.toml` on the next dependency update.

**Then check what pins the old value.** A version bump can invalidate a compat bound elsewhere in the
repo, and the failure only surfaces in CI. This has bitten twice — `docs/Project.toml` pinned
`Nitro = "0.1, 0.2, 0.3"` and broke the docs build at `0.4.0`; `Project.toml` pinned
`PormG = "^0.1"` against `PormG@0.3.0` and took down all six test jobs:

```bash
rg -n 'Nitro\s*=\s*"' docs/Project.toml   # expect a floor (>= 0.1), not an enumerated list
```

### 3. Stamp `UPGRADING.md`

Use today's **real** date (`YYYY-MM-DD`) — never invent one; if unsure, ask.

- For **each** entry under `## Unreleased`, replace `- **Version**: Unreleased` with
  `- **Version**: <new>`.
- Replace the `## Unreleased — next \`<x>\`` heading (and its italic placeholder note) with
  `## <new> — <YYYY-MM-DD>`.
- Insert a **fresh empty** `## Unreleased — next \`<next-y>\`` block above the just-stamped section,
  carrying the same placeholder note the previous one had.
- **Sweep the prose.** Stamping the `- **Version**:` bullet does *not* fix an entry **body** that
  refers to itself as unreleased — that ships stale and points readers at a now-empty section:
  ```bash
  awk '/^## <new> —/,/^## [0-9]/' UPGRADING.md | grep -n 'Unreleased'   # expect: no prose hits
  ```
  Prefer version-neutral phrasing when *writing* an entry (``part of the `<y>.x` pre-publish wave``)
  so there is nothing to sweep.
- Leave already-stamped (older) entries untouched.

### 4. Verify the parser

```bash
julia --project=. test/runtests.jl test/upgrade_guide_tests.jl
julia --project=. -e 'using Nitro; upgrade_guide(from = v"<previous>")'
```

The stamped entries must parse at `<new>`, and the empty `## Unreleased` must yield no entries. Fix
any mismatch before committing.

### 5. Commit, then get approval to push

```bash
git add UPGRADING.md Project.toml
git commit -m "chore(release): cut <new>"          # entry titles in the body
```

**Stop here and show the diff.** The commit/push gate applies: pushing and tagging are
outward-facing and need explicit approval at that step, separately from approval to prepare the cut.

### 6. Tag and push

Tag the commit on `main` that carries the new `Project.toml` version — the merge commit of the
release PR, not the branch commit:

```bash
git tag -a v<new> <sha> -m "Nitro v<new>"          # entry titles in the body
git push origin main
git push origin v<new>                              # a plain `git push` does NOT carry tags
```

The **`v` prefix is required**: once Nitro is registered in General,
[`JuliaRegistries/TagBot`](../../workflows/TagBot.yml) takes over tagging and emits `vX.Y.Z`.
Matching it now keeps one continuous series. Pre-publish, TagBot never fires — nothing comments as
`JuliaTagBot` — so tags are manual until then.

### 7. Roll it out

The reason you cut. Work each consuming app through the newly-stamped entries, then bump that app's
Nitro pin to `<new>`:

```julia
Nitro.upgrade_guide(from = v"<app's pinned version>")
```

The pin **is** the app's rollout state — there are no per-entry rollout tables to update.

---

## Guardrails

- **One bump per cut.** Editing `Project.toml`'s version outside this skill is the per-PR churn this
  model removes.
- **Never cut an empty `## Unreleased`.**
- **Never** tag or push without explicit approval at that step.
- **Never** rewrite historical entries while cutting — fix errors in a separate commit with its own
  review.
- **Never** cut from a branch other than `main`, or with a dirty tree, or when CI is red or unknown.
- **`Unreleased` is a literal token**, not a version — `_parse_upgrading` in
  [`src/upgrading.jl`](../../../src/upgrading.jl) maps it to a high sentinel so uncut entries sort
  newest and `upgrade_guide` surfaces them by default. Stamping replaces it with a real
  `VersionNumber`.
- **The release marker needs its em-dash.** Write `## <new> — <date>`, never `## <new> <date>`: the
  parser tells a release marker from an entry title by that separator, and a marker without it
  swallows the release's first entry silently.
- **Never** invent a version to make a downstream pin work. If an app needs a different bound, that
  is a conversation, not a release.
- Once Nitro is published to General, this skill needs a registration step
  (`@JuliaRegistrator register`) and the pre-publish framing stops applying — update it then.
