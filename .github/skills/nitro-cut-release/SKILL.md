---
name: nitro-cut-release
description: >-
  Cut a Nitro.jl release — verify the pre-publish gate, confirm the Project.toml version matches the
  open CHANGELOG cycle, stamp the "Unreleased" heading with a date, tag it, and open the next cycle.
  Maintainer-invoked; never run as a side effect of finishing a feature.
---

# Nitro.jl — Cut a Release

## Purpose

Nitro versions **per cycle, not per PR**. During a cycle, PRs append entries to the open
`## [0.y.0] — Unreleased` section of [`CHANGELOG.md`](../../../CHANGELOG.md) and leave
`Project.toml` alone. This skill closes a cycle: it stamps the heading with a date, tags it, and
opens the next one.

**Maintainer-invoked only.** Never cut a release as the tail end of a feature task — the user asks
for it explicitly, or it does not happen.

## The versioning model (`0.y.z`, pre-publish)

- `y` bumps on **breaking** changes; `z` on everything else. This matches Julia Pkg compat: a
  downstream `compat = "0.y"` accepts `0.y.*` and rejects the next breaking release.
- The version number for a cycle is chosen **when the cycle opens**, not when it ships. So
  `Project.toml` normally already carries the version named in the open `Unreleased` heading — the
  two must agree before you cut.
- If a cycle opened as a `z` release and a **breaking** change later lands in it, raise both
  `Project.toml` and the `Unreleased` heading to the next `y` at that moment — not at cut time.
- Nitro is pre-registry, so a breaking entry's inline `before → after` migration *is* the
  compatibility story. There are no deprecation shims.

---

## Preconditions — check first, stop if unmet

```bash
git status --porcelain                 # must be clean
git rev-parse --abbrev-ref HEAD        # expect main, up to date with origin
gh issue list --label pre-publish      # the publish gate (informational for 0.y releases)
```

1. **Working tree clean, on `main`, synced with `origin`.** Stop otherwise.
2. **The suite is green on CI** for the commit you are about to tag — not just locally. CI covers
   Julia 1.12 on three OSes at 1 and 2 threads.
3. **`Project.toml` `version` equals the version in the open `Unreleased` heading.** If they differ,
   resolve *before* cutting: decide which is right and say why.
4. **The `Unreleased` section is non-empty** and every entry describes shipped behavior. An empty
   cycle is not a release.
5. **Every breaking entry carries a `before → after` migration.** Add missing ones now.
6. **`docs_lint` passes:** `julia .github/scripts/docs_lint.jl`.

Report anything unmet and stop. Do not "fix it while you're there."

---

## Steps

### 1. Confirm the version with the user

State the version you are about to cut and why (`y` bump because entries include breaking changes,
or `z` because they do not). Get an explicit go-ahead. This is the last cheap moment to change it.

### 2. Stamp the heading

Replace `— Unreleased` with the release date (ISO, UTC):

```diff
-## [0.4.0] — Unreleased
+## [0.4.0] — 2026-07-31
```

Leave the entries themselves untouched — they were written when the work landed and are the record.

### 3. Reconcile `Project.toml`

The version should already match. If it does not, set it now:

```toml
version = "0.4.0"
```

Do **not** add a comment explaining the bump — CompatHelper strips every comment from
`Project.toml` on the next dependency update. Rationale belongs in the CHANGELOG entry.

### 4. Commit, then get approval to push

```bash
git add CHANGELOG.md Project.toml
git commit -m "release: v0.4.0"
```

**Stop here and show the diff.** The commit/push gate applies: pushing and tagging are
outward-facing and need explicit approval at that step, separately from approval to prepare the
release.

### 5. Tag and push

```bash
git tag -a v0.4.0 -m "v0.4.0"
git push origin main
git push origin v0.4.0
```

Existing tags are `v`-prefixed (`v0.1.0`, `v0.2.0`) — match that. Check `git tag` first: a heading
in the CHANGELOG does not guarantee a tag exists for it.

TagBot (`.github/workflows/TagBot.yml`) handles the GitHub release from the tag once the package is
registered; before registration, create the GitHub release manually if you want one:

```bash
gh release create v0.4.0 --title "v0.4.0" --notes-file <extracted-section>
```

### 6. Open the next cycle

Add a fresh empty section above the one you just stamped, and bump `Project.toml` to the version that
cycle will carry:

```markdown
## [0.5.0] — Unreleased
```

Choose `y` or `z` by what you *expect*; it is cheap to raise later when the first breaking change
lands. Commit as a separate `chore: open 0.5.0 cycle` commit so the release commit stays clean.

### 7. Verify

```bash
git tag --list 'v*'                          # the new tag is present
git show v0.4.0 --stat                       # points at the release commit
julia .github/scripts/docs_lint.jl           # still green
```

Confirm the CHANGELOG has exactly one `Unreleased` section and it is the new empty one.

---

## Guardrails

- **Never** tag or push without explicit approval at that step.
- **Never** rewrite historical CHANGELOG entries while cutting — fix errors in a separate commit with
  its own review.
- **Never** cut from a branch other than `main`, or with a dirty tree.
- **Never** cut when CI is red or unknown for the target commit; local green is not CI green.
- **Never** put comments in `Project.toml` — CompatHelper deletes them silently.
- **Never** invent a version to make a downstream pin work. If an app needs a different bound, that
  is a conversation, not a release.
- Once Nitro is published to the General registry, this skill needs a registration step
  (`@JuliaRegistrator register`) and the pre-publish framing above stops applying — update it then.
