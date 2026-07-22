---
name: nitro-issue-management
description: >-
  Manage the Nitro.jl backlog with the gh CLI — create/update/close GitHub
  issues and curate labels. GitHub Issues are the backlog's only home; release
  gating is the pre-publish label (a label query, not a synced index file).
  Covers the label taxonomy, the draft-before-create safety flow, scrubbing of
  private/local references, and cross-reference discipline. Adapted from
  PormG.jl's pormg-issue-management.
---

# Nitro.jl Issue Management

## Purpose

Use this skill for any work on the project backlog: creating or editing GitHub issues or
curating labels.

This is a process skill, not a code skill — it does not touch `src/`.

## Use This Skill For

- Creating one or many GitHub issues (including the one-time bulk migration from `todo.md`)
- Editing, closing, commenting on, or relabeling existing issues
- Adding or adjusting labels

## The backlog model

- **GitHub Issues are the backlog's only home.** There is no synced backlog or index file in the
  repo, and none should be created — a file that must mirror a label query is manual-sync
  duplication that rots. Views come from labels: `gh issue list --label workers`,
  `gh issue list --label pre-publish`, etc.
- **Release gating is the `pre-publish` label, nothing more.** "What must be settled before
  Nitro's first General-registry publish?" is answered live by
  `gh issue list --label pre-publish`.
- **Transitional note.** `todo.md` was the pre-migration backlog. It is deleted in the same
  reviewed pass that files the migrated issues (see the bulk workflow below). Until that pass
  lands, treat any unchecked `todo.md` item as unmigrated backlog — but do not partially rewrite
  the file; the conversion happens in one pass.

## Tooling

- Use the **`gh` CLI** (authenticated as the maintainer). Confirm with `gh auth status` and
  `gh repo view --json nameWithOwner,hasIssuesEnabled` before acting. Repo: `PingoLee/Nitro.jl`
  (public — see safety note below).
- Common ops: `gh issue create`, `gh issue edit`, `gh issue close`, `gh issue comment`,
  `gh issue list --state open --label <l>`, `gh issue view <n> --json title,labels,body`.
- Always pass rich markdown bodies via `--body-file <path>`, never inline `--body "…"` — heredocs
  and shell escaping mangle backticks, `$`, and code fences. Write the body to a file first.

## Label taxonomy

Reuse the GitHub defaults that fit (`enhancement`, `bug`, `documentation`); create the project
ones idempotently with `gh label create <name> --color <hex> --description "…" --force`.

| Kind | Labels |
|------|--------|
| Type | `enhancement`, `bug`, `documentation`, `tech-debt` |
| Subsystem | `routing`, `middleware`, `auth`, `sessions`, `workers`, `pormg-ext`, `performance`, `infrastructure` |
| Release gating | `pre-publish` (must be settled before Nitro's first General-registry publish) |

## Safety: issues are public and outward-facing

Creating issues publishes content on a public repo and notifies watchers — it is noisy to undo.

- **For any bulk creation (more than a couple of issues), draft first and get explicit
  confirmation before hitting the API.** A single targeted issue the user asked for can be
  created directly.
- **Scrub private/local references before posting.** Working notes may contain local machine
  paths, private reference-app internals (file names and layout of the internal Genie app), and
  personal workflow notes. None of that goes into a public issue body verbatim — generalize
  ("the reference Genie app") or drop it. Secrets, connection strings, and hostnames never
  appear in issues.

## Bulk migration / creation workflow

1. **Draft, then confirm.** Write every proposed issue (title, labels, full body) to a review file
   and show the user the plan (a title/label table is enough). Create nothing public until they
   approve. Surface grouping decisions (e.g. merging related sub-items into one issue) so they can
   adjust.
2. **One issue per top-level item.** Nested sub-items become a markdown task list (`- [ ]`) in the
   body; preserve the original context (the "why now", blockers, file references) — scrubbed per
   the safety rule above. Already-checked (`- [x]`) items are history, not issues: leave them out.
   Standing principles already canonical in the instruction files are rules, not tasks — leave
   them out too.
3. **Verify the parse before the API.** If you split a source file into per-issue bodies
   programmatically, print the parsed title/labels/first-body-line for every issue and eyeball it
   before any `gh` call — a malformed public issue is the cost of a parse bug.
4. **Labels first, then issues.** Create/refresh labels (idempotent `--force`), then loop:
   `gh issue create --title "<t>" --label "<comma,separated>" --body-file <f>`.
5. **Capture the real numbers.** You do not know an issue's number until it is created — record
   each returned URL/number into a map.
6. **Fix cross-references.** Never hardcode draft/sequence numbers in bodies. After creation,
   rewrite any `#N` sibling references to the **real** issue numbers
   (`gh issue edit <n> --body-file …`), otherwise `#11` etc. silently links to an unrelated old
   issue or PR.
7. **Verify after.** Check the open count, label assignment, and spot-check that a rich body (task
   lists, blockquotes, code fences) rendered: `gh issue view <n> --json body -q '.body'`.
8. **Delete the migrated source file in the same reviewed pass.** Once the issues exist and are
   verified, `todo.md` is removed — leaving a stale copy would recreate the two-homes problem
   this model exists to end.

## Closing a resolved issue

1. **Link the fix.** Prefer letting GitHub auto-close: put `Closes #N` (or `Fixes #N`) in the PR
   description or the commit message that lands the work, so the issue closes on merge *with a
   back-reference to the commit*. For a direct close, use
   `gh issue close <n> --comment "Fixed in <commit/PR>: <one-line summary>"` — always say what
   fixed it, never close silently.
2. **Partial progress ≠ closed.** If only some task-list items are done, do **not** close. Check
   the finished boxes (`- [ ]` → `- [x]`) in the body via `gh issue edit <n> --body-file …` and
   comment on what landed. Close only when every box is done — or split the remainder into a new
   issue and close the original with a pointer to it.
3. **Verify.** Confirm the issue is closed (`gh issue view <n> --json state,closed`).

## Do Not

- Bulk-create issues without showing a draft and getting confirmation first.
- Post local machine paths, reference-app internals, secrets, or connection details in a public
  issue body — scrub or generalize first.
- Create a synced backlog/index file in the repo — labels and `gh issue list` are the views.
- Close an issue that still has unfinished task-list items — check them off or split them out
  first.
- Close an issue without a comment/PR/commit reference saying what resolved it.
- Put draft/placeholder numbers in issue bodies and leave them — resolve to real `#numbers`.
- Inline rich bodies on the command line — use `--body-file`.
- Commit repo changes unless the user asks; backlog edits follow the normal
  commit-only-when-asked rule.
