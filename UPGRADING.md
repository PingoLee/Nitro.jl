# Upgrading Nitro — consumer-app rollout log

Tracks **breaking / behavior changes in Nitro** that require source-code changes in the applications
that depend on it. Nitro is pre-publish (single maintainer, no external users), so breaking changes
are intentional and cheap on the *Nitro* side — but each one still has to be rolled out by hand in
every consuming app. This file is the contract for *writing* that rollout log; the log itself lives
in [`upgrading/`](upgrading/).

> 🚀 **Upgrading an app? Don't read the log by hand.** Run
> `Nitro.upgrade_guide(from = v"<your pinned version>")` — it renders only the entries newer than
> your pin, newest-first. The full how-to (versioning model, the apply recipe, driving it with an AI
> agent) lives in the docs: **[Upgrading Nitro](https://pingolee.github.io/Nitro.jl/dev/upgrading/)**.

## Where the entries live

**One file per change, under [`upgrading/`](upgrading/)**, named `YYYY-MM-DD-<slug>.md` — the date
from the entry's own `- **Recorded**:` bullet, so the directory sorts newest-first, and a slug
leading with the issue number when there is one (`2026-09-18-121-encoded-filename-routes.md`).
**The slug is lowercase** — digits, dots and dashes only; `test/upgrade_guide_tests.jl` pins the
whole name against `^\d{4}-\d{2}-\d{2}-[a-z0-9.-]+\.md$`, and the extension must be `.md`.

This used to be one `UPGRADING.md` with every entry prepended under a single `## Unreleased`
header. That header was **one anchor line**, so any two concurrent sessions that both owed an entry
conflicted *every time*, in the one file whose whole job is to be the compatibility story
([#192](https://github.com/PingoLee/Nitro.jl/issues/192)). A file per entry makes the conflict
unrepresentable rather than merely resolvable.

Consequences worth knowing before you add one:

- **Every `.md` in `upgrading/` is an entry.** There is no name-pattern filter in the reader, on
  purpose — one would make a mis-named entry vanish from `upgrade_guide` silently, which is exactly
  the failure [#89](https://github.com/PingoLee/Nitro.jl/issues/89) was about. Put nothing else in
  the directory; this contract and the template stay here, and this file is **not** parsed.
- **There are no `## <version> — <date>` release markers any more.** An entry states its own release
  in its `- **Version**:` bullet, which is the only thing `upgrade_guide` ever scoped by. Release
  dates are recorded in *Release trains* below.
- **Order inside one version is presentation only.** `upgrade_guide(from = …)` scopes by version,
  never by position.

## Writing an entry

- **One `##` entry per breaking change, in a new file.** It carries `- **Version**: Unreleased` and
  **no `Project.toml` bump**; the maintainer stamps it with a release number when cutting a train
  (`nitro-cut-release`).
- **One entry per file, and no `---` line anywhere in it.** The parser still splits a file on a
  column-0 `---`, so a stray horizontal rule truncates your entry and a second `##` entry in the
  same file is absorbed into the first. Both are caught by `test/upgrade_guide_tests.jl`.
- Each entry records: the Nitro **version** it shipped in, what changed, why, a *"How to find the
  calls to migrate"* grep, and the concrete **before → after** code edit.
- **Not for additive features.** This log is only what **forces** an app edit. A new opt-in
  capability (middleware, extractor, kwarg, function) requires no change to keep an app working →
  document it in `docs/`, not here.
- **No per-entry rollout tables.** An app's own Nitro dependency pin *is* its rollout state, and
  `upgrade_guide(from = <that pin>)` derives what it still needs — so there is nothing to maintain
  per app.
- **Keep the prose version-neutral.** Write *"part of the `0.1.x` pre-publish wave"*, never *"part of
  the current unreleased wave"* — stamping rewrites the `- **Version**:` bullet, not the body, so
  self-referential prose ships stale.
- **Every entry needs a `- **Recorded**:` bullet.** Without it the entry is dropped outright, and
  its date is what names the file. This warns at run time and fails the suite, but it is cheaper to
  get right than to diagnose.
- **Keep `## ` out of column 0 inside an entry body.** A fenced example showing a literal markdown
  heading must indent it, or the entry-title scan in `test/upgrade_guide_tests.jl` counts it as a
  second entry and the suite goes red.
- Entries are version-stamped from **`0.1.0`** onward. `0.1.0` is the baseline of the release-train
  policy: earlier `Project.toml` numbers (`0.2.0`–`0.4.0`) and their tags predate it and were
  reclaimed, so nothing below `0.1.0` exists to port from.

## Release trains

Cut by the maintainer via `nitro-cut-release`, which stamps every `Unreleased` entry with the new
number and adds its row here. Entries not listed under a number are uncut — a consumer dev'ing
Nitro at HEAD is running them, and `upgrade_guide` surfaces them by default.

| Train | Cut |
|---|---|
| Unreleased — next `0.5.0` | — |
| `0.4.0` | 2026-09-21 |
| `0.3.0` | 2026-09-09 |
| `0.2.0` | 2026-08-10 |
| `0.1.0` | 2026-07-31 |

## Template for new entries

Copy the block below into a **new file** `upgrading/<YYYY-MM-DD>-<slug>.md` for each new
breaking/behavior change. Do NOT bump `Project.toml` — the version moves once, at cut time
(the `nitro-cut-release` skill rewrites `Version: Unreleased` → the release number).

<!--
## `<api>` — <one-line summary of the change>

- **Version**: Unreleased
- **Nitro ref**: <issue / PR / commit> ; <src file>
- **Recorded**: <YYYY-MM-DD>
- **Severity**: breaking | behavior change | deprecation

### What changed
<what the old API did vs. the new contract>

### How to find the calls to migrate
<error message to grep for, or the call pattern>

### Migrate your app
```julia
# ✗ before
...
# ✓ after
...
```
-->
