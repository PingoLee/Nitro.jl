---
name: nitro-issue-cluster
description: Decide what to work on next and work it as a group — reconcile the project board against the issues, rank the sessions, build a cluster from contended files rather than shared labels, tier it by its worst member, order it by dependency then importance, land one commit and one UPGRADING entry per issue, and close out N issues at once. The selection-and-ordering layer above nitro-issue-workflow.
---

# Nitro Issue Cluster

## Purpose

Use this skill when several open issues would **edit the same code**, and fixing them one at a time
means the second fix rebases onto a function the first one rewrote.

This skill owns **which cluster runs next, which issues go together, in what order, and what "done"
means for a group**. It does not restate [`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md)
— that skill still owns provenance, isolation, implementation, the verify rungs, review, and the
approval gates. Read this one to pick and build the group; read that one for every step inside it.

## Use This Skill For

- "What should I pick up next?" — reconciling and re-ranking the board after a batch of new issues
  (every session spawns follow-ups, so this happens constantly)
- Two or more open issues whose fixes touch the same file, and ideally the same function
- A set of issues that turn on **one design decision** made once (a scoping model, a cache protocol)
- Mopping up the remainder of a subsystem right after a related fix merged

Not for: a single issue (use `nitro-issue-workflow`), filing or closing an issue (use
`nitro-issue-management`), issues that merely share a label, or a "let's clear the backlog" sweep
across unrelated subsystems.

## 0. Reconcile and rank the board

The [Nitro project board](https://github.com/users/PingoLee/projects/8) is where the plan lives: its
**Session** field holds the grouping, and execution order is stamped into each option's description.
It is the *plan's* home, not the backlog's — the backlog is GitHub Issues, per
[`nitro-issue-management`](../nitro-issue-management/SKILL.md).

**Batching is the point.** The expensive part of an issue is not the diff — it is loading the
subsystem, building the repro shape, and getting the review context right. A second issue in the
same function pays almost none of that, which is why a session closes three issues instead of one.
Everything below serves that: reconcile so nothing already done gets scheduled, rank so the
highest-value batch runs first, and write it back so the next session does not recompute it.

### Reconciliation is one-way

The board may say things the issues do not — that #79 and #81 belong together, that Session 6 runs
third. It may **not** disagree with the issues about **facts**: whether an issue is open, closed,
labelled, or superseded. **On any question of fact, GitHub Issues are the source of truth and the
board is corrected — never the reverse.** Never `gh issue close`, reopen, or relabel to make an issue
agree with a board cell.

Always reconcile before planning; a stale board schedules closed and superseded issues at full cost.

```bash
gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:8){
  items(first:99){ nodes{ id content{ ... on Issue { number state } }
    fieldValues(first:12){ nodes{ ... on ProjectV2ItemFieldSingleSelectValue {
      name field{ ... on ProjectV2SingleSelectField { name } } } } } } } } } }'
```

Then, for every item:

| Issue state | Board Status | Action |
|---|---|---|
| `CLOSED` | not `Done` | set `Done` |
| `OPEN` | `Done` | clear it — the issue was reopened, or the wrong item was marked |
| `OPEN` | `In Progress` you did not set | **leave it.** Another session is working it. A status you did not write is a signal, not an error |
| `OPEN`, superseded — see [`nitro-issue-management`](../nitro-issue-management/SKILL.md) → *Superseding an open issue* | on any session | take it off the session — a superseded issue is not work; it closes when the superseding change lands |

Also sweep for open issues that are on no board item at all, and compare against the item numbers
from the query above:

```bash
gh issue list --state open --limit 100 --json number -q '.[].number' | sort -n
```

### Rank the sessions

Group display order on the board is option order, which is numeric. Execution order is not, and
neither the field nor the item ordering can say "run Session 8 before Session 6" — so rank
explicitly, in descending priority:

1. **Breaking changes, while the repo is pre-publish.** Cheapest now; every session built on the old
   shape raises the cost. A session that changes a public signature or a `Service` field outranks
   one that does not.
2. **The publish gate.** `gh issue list --state open --label pre-publish` — empty is the gate. Its
   size is a scheduling input: one issue from empty is worth finishing. This is the one place the
   label ranks anything; *inside* a session it is a classification, never a promotion (§2).
3. **The importance ladder's top rung across members** (§2): a session holding a rung-1 or rung-2
   member — secret exposure, an authorization bypass, silently wrong behavior — outranks one whose
   members are all loud failures, performance, or docs.
4. **Leverage** — a session that taxes every other session. A test-harness fix that every
   `:network` item trips over, or a CI change every PR waits on, ranks above its own severity.

An area label describes the issue, never its blast radius. When you rank a session above where its
labels would put it, state the override and the reason in the same line — an unexplained override
reads as an error.

### Write it back

**Authentication.** Board writes need the `project` scope, which the default token does not carry:

```bash
gh auth status                 # look for 'project' in Token scopes
gh auth refresh -s project     # interactive browser flow — the USER runs this, not you
```

**Discover the IDs — never hardcode them.** Project, field, and option IDs are opaque and change
with the board. Resolve them every run:

```bash
gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:8){ id
  fields(first:20){ nodes{ ... on ProjectV2SingleSelectField { id name options{ id name color description } } } } } } }'
```

You want the project `id`, the **Status** field (`Todo` / `In Progress` / `Done`) and the
**Session** field with its full option list — ids, colors, and descriptions included. You need all
three per option for the next step.

**Adding a Session option — the footgun.** `updateProjectV2Field` **replaces the entire option
list**; it does not append. Sending only the new option deletes every existing one and orphans every
item grouped under them. `ProjectV2SingleSelectFieldOptionInput` accepts an optional `id`, and that
is what saves you: resend every existing option **with its `id`, `color`, and `description`**, then
append the new one without an `id`. Matching ids keep items attached and let you rename a group
safely. Pass it as a file — `-f` cannot express a list of objects:

```bash
gh api graphql --input payload.json      # {"query": "mutation ... updateProjectV2Field ...", "variables": {...}}
```

Verify the response lists every pre-existing option with its **original id** before moving on.

**Adding and stamping items.** `gh project item-add 8 --owner PingoLee --url <issue-url>` adds an
issue; then one `gh project item-edit` per field — Session and Status; the command is in §1. Add
issues **in the order you want them displayed** — row order is insertion order.

**Encode the rank in each option's description**, because the board cannot express it any other
way: `RUN 3rd. #A -> #B. #A first: <forced or preferred, and why>.` It surfaces on hover and carries
the forced-vs-preferred note (§2) with it. Restamp every description when the ranking changes; a
stale `RUN 1st` is worse than none. Mark finished groups `DONE. #79, #81, #82, #74.` rather than
deleting them — the history of what shipped together is what makes the next grouping decision easier.

Receipt: board 8's first ten Session options were created with empty descriptions. With six of them
done or partly done and four untouched, nothing on the board said which ran next, and the ranking had
to be re-derived from scratch each session.

## 1. Build the cluster

### The grouping key is the edit surface, not the label

A shared label — `bug`, `performance`, `tech-debt` — says nothing about whether two issues are
co-solvable. `bug` alone spans auth, workers, middleware, routing, static files, and docs tooling.
**Two issues belong in one cluster only if a single PR would touch the same file.** Same *function*
is a strong cluster; same file is a weak one; same label is not a cluster at all.

Area labels (`middleware`, `workers`, `routing`, `auth`, `sessions`, `pormg-ext`) are a cheap
**prefilter**, not the grouping key. Use them to narrow, then confirm against the code.

```bash
# 1. Prefilter by area label
gh issue list --state open --limit 100 --json number,title,labels \
  --jq '.[] | select([.labels[].name] | index("middleware")) | "\(.number) \(.title)"'

# 2. Pull the symbols and paths each candidate names
gh issue view <N> --json body --jq .body | grep -oE 'src/[A-Za-z0-9/_.]+[.]jl' | sort -u

# 3. Confirm the overlap is real, in the code — not just in the titles
grep -rn "<symbol>" src/ --include=*.jl | cut -d: -f1 | sort | uniq -c | sort -rn
```

Step 3 is the one that decides. Two issues that *sound* related but resolve to different files are
two sessions, not one.

### Admission tests

Every candidate must pass all four, or it does not join the group:

| Test | Fails when |
|---|---|
| **Contended edit** — a single PR touches the same file as another member | The overlap was in the titles, not the code |
| **One subsystem** — all members map to the same row of the architecture map | The group would inherit an escalation trigger it does not need (see §2) |
| **Independently landable** — each member is a complete fix, testable on its own | It is really one issue split in two; fix it as one, close the other as duplicate |
| **No open design question** — nothing in the group needs a decision the user has not made | That member stalls the whole branch mid-session |

**Cap the group at 4 issues.** "One session" is bounded by context, not by ambition: a six-issue
group runs out of room halfway and lands a partial branch, which is strictly worse than two clean
sessions. When more than four qualify, keep the four that score highest on **overlap first,
importance second** (§2) — tight overlap is what makes the group cheaper than four separate
sessions, so it outranks importance at selection time. Say which candidates you left out and why.

That cap is not a guess. The sibling [PormG board](https://github.com/users/PingoLee/projects/7) ran
16 sessions of this exact shape: the largest held 4 issues, the most common held 2, the mean was 2.4.
**Four is the observed ceiling of a working session, not an aspiration** — treat a proposed group of
five as evidence the overlap analysis was too loose, not as a reason to stretch.

### Third strike → a design issue, not a fourth patch

When the candidate you are grouping is the **third** to land in a cause-cluster that two merged fixes
already touched, stop scheduling patches. File (or find) the design issue that makes the cluster
unrepresentable, mark the open members superseded
([`nitro-issue-management`](../nitro-issue-management/SKILL.md) → *Superseding an open issue*), and
plan the design issue as the session. Each patch in such a cluster is correct and local, and the
cluster keeps reopening anyway, because the cause is a representation rather than a branch. The
sibling PormG board paid seven PRs on one join/CTE namespace before the map was split into typed
namespaces. Nitro's local instance is the global-router-state class: #34 and the two
[`nitro-test-troubleshooting`](../nitro-test-troubleshooting/SKILL.md) classes that trace to
`CONTEXT[]` all point at #31 as the design issue that makes them unrepresentable. A design issue
ranks by the sum of what it supersedes (§0).

### Confirm before starting

Present the proposed cluster to the user — the members, the shared file, the order, the derived
tier, and anything you excluded. **A cluster is a scope proposal, so it needs the user's agreement
before implementation**, the same way a plan does. Do not expand a group mid-session because a fifth
issue "is right there".

### Record the agreed cluster on the board

Cluster identity is expensive to derive — steps 1–3 above — and worthless if it is recomputed from
scratch next session. Once the user agrees, persist it as a `Session` option on the
[Nitro project board](https://github.com/users/PingoLee/projects/8), named
`Session <N>: <Edit Surface>` after the code it contends for, never after the label its members
share. `Active` marks the session currently being worked.

```bash
# add the option (§0 — updateProjectV2Field replaces the whole list), then stamp each member
gh project field-list 8 --owner PingoLee --limit 30      # get the Session field id
gh project item-edit --id <item-id> --field-id <field-id>   --project-id <project-id> --single-select-option-id <option-id>
```

Stamp the new option's description with its rank the moment it exists (§0 → *Write it back*); an
option with no `RUN nth` is a session nobody can place.

**The board records decisions, not speculation.** An option per agreed cluster; nothing for a
grouping you merely considered. A member dropped under §4 loses its `Session` value and returns to
the unassigned pool — leaving it stamped implies work that did not happen.

## 2. Tier, then order

### Tier is the maximum over members, never the average

Run the escalation table in [`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) §0 against
every member and take the highest result. One `src/Auth/` member puts the whole branch at `high`.

This is itself an argument for tight clusters: a docs issue riding along with a middleware issue
inherits `/security-review` and a mandatory delta re-review it did not need. If a cheap member is
dragging cost onto itself, drop it and run it separately at `quick`.

### Order = dependency first (hard), importance second (tiebreak)

**Order decides what survives.** A cluster can end early — context runs out, a member stalls under
§4, review sends one back. Whatever landed first is what you keep, so ordering is a risk decision,
not a convenience.

Two rules, applied in this sequence:

1. **Dependency depth is a hard constraint.** If one member rewrites a protocol and another adjusts a
   value that protocol computes, the rewrite goes first — otherwise you edit your own work twice.
   Importance never reorders across a real dependency.
2. **Importance breaks every remaining tie.** Among members with no dependency between them, the
   most important goes first, so an early abort keeps the fix that mattered most.

### The importance ladder

Score each member on the first rung it matches, highest wins:

| Rung | What | Why it ranks here |
|---|---|---|
| 1 | **Secret exposure or authorization bypass** — leaked credentials, missing scoping, a silent auth downgrade | Fails safe-looking and cannot be detected downstream |
| 2 | **Silently wrong behavior** — wrong result, no error, no log | The user never learns to distrust the output |
| 3 | **Loud failure** — a crash, a throw, a visibly wrong status | Bad, but self-announcing and diagnosable |
| 4 | **Performance, tech-debt, docs** | Real, but nothing is incorrect while it waits |

Rungs 1 and 2 outrank rung 3 on purpose, and it is the ordering most likely to feel wrong: a
`BoundsError` looks more urgent than a quietly-ignored keyword argument. It is not. A crash is
reported, reproduced, and fixed; a silent wrong answer ships.

**`pre-publish` is not on this ladder, and must not be added to it.** It is a *release-gating* label
— it answers "must this be settled before the first General-registry publish", which is a question
about scheduling, not about how much harm the defect does. Treat it exactly like `bug` or
`middleware`: a classification that describes the issue, never a promotion above one. A `pre-publish`
member that genuinely outranks its siblings does so on its own merits and the rungs above already
catch it — an unpinned dependency with `contents:write` in scope is rung 1 because it is a
credential-exposure defect, not because of the label it carries. Meanwhile the set also holds
open design questions, which belong at rung 4 however hard the gate presses.

The publish gate is real, but it applies to **which cluster you pick next** (§0), not to the order
*inside* one. Do not let it reach into this table.

State the resulting order and the reason for it before the first commit. Where a dependency forced a
low-importance member to the front, say that explicitly — it is the one case where the branch's
riskiest work is not its most valuable.

## 3. Run the members

Work each member through [`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) steps 1 and 3 —
scope, then implement. **Provenance is per issue, not per group** (§1 of that skill): check the
author of every member from metadata before reading any body, and quarantine any non-maintainer one.
A single third-party member puts the group at `high` and needs its scope confirmed separately.

Isolate **once** for the whole group: one worktree, one branch, named for the cluster rather than a
single issue.

```bash
# from inside the worktree, after EnterWorktree
bash scripts/worktree_setup.sh
git branch -m fix/cluster-<subsystem>-<slug>
```

### Commit discipline — this is what makes the group reviewable

**One commit per issue, and one `UPGRADING.md` entry per issue that owes one.** Never a single
squashed "fix middleware bugs" commit.

- Each commit message references its own issue: `fix(middleware): <what> (#79)`.
- Each commit is self-contained — its code *and* its tests *and* its docs.
- A member that owes an upgrade entry gets its **own** entry prepended to `## Unreleased`, carrying
  its own *"How to find the calls to migrate"* grep and `before → after`. The
  [`UPGRADING.md`](../../../UPGRADING.md) contract is per behavior change, not per branch — merging
  two changes into one entry makes `upgrade_guide` describe a migration nobody can follow.

This is the whole reason a 4-issue PR stays reviewable: it reads commit by commit, and any single
member can be reverted without unpicking the others.

### Verify: per-issue narrow, per-group broad

The efficiency win of clustering is paying the expensive rungs **once**. Split the rung table in
[`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) §4 accordingly:

| Rung | Scope | When |
|---|---|---|
| 1 — the changed test file alone | **Per issue** | Before that issue's commit |
| 2 — guard tests the change could trip | **Per issue** | Before that issue's commit |
| 3 — `docs_lint.jl` | Per group | Once, after the last commit |
| 4 — full suite | Per group | Once, after the last commit |
| 5 — thread-count 2 | Per group | Once, if **any** member triggers it |
| 6 — docs build | Per group | Once, if any member touched `docs/` |

Rungs 1 and 2 stay per issue on purpose. A member committed without its own narrow run is a member
whose failure you will attribute to the next one.

**Rung 2 is the union across members**, not the intersection — a guard that only one member could
trip still has to run.

## 4. The abort rule

**A group is not a commitment to finish all of it.** If a member turns out to need a design decision,
a much larger change than the issue described, or an unrelated prerequisite:

1. **Stop that member.** Do not implement a half-fix to keep the group intact.
2. **Land the members already complete.** They are independently landable — that was an admission
   test — and ordered by importance, so the remainder is the cheapest part of the group to lose.
3. **Drop the rest back to the backlog**, with a comment recording what you found, via
   [`nitro-issue-management`](../nitro-issue-management/SKILL.md).
4. **Say so explicitly** in the report and the PR body: which members landed, which did not, why.

Holding a finished fix hostage to an unfinished sibling is the failure mode this rule exists to
prevent. A stale cluster branch decays against `main` far faster than a single-issue one.

## 5. Review, land, close out

Review per [`changed-code-review`](../changed-code-review/SKILL.md) at the group's tier. Give the
reviewer **the member list and the commit-per-issue structure**, and ask it to review the diff
commit by commit — a reviewer handed a 4-issue diff as one blob reviews none of them well.

The three approval gates in
[`nitro-general.instructions.md`](../../instructions/nitro-general.instructions.md) — commit, push,
open PR — are unchanged and still separate. The commit gate covers the group's commits as one
approval; do not re-ask per member unless the user asked you to.

**The PR body carries one `Closes #N` line per member**, plus the group's tier, the order you worked
in, the rungs CI is covering, and any member dropped under §4.

```
Closes #79
Closes #81
Closes #82
```

Close-out follows [`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) §7, with two additions:

- **Verify every member actually closed.** A missing or malformed `Closes` line leaves a fixed issue
  open; worse, a member you dropped under §4 must **not** appear in that list. Check the final state
  of all N.
- **Re-check the cluster.** Fixing three issues in a subsystem often makes a fourth trivial or
  obsolete. Say so; file or close follow-ups via
  [`nitro-issue-management`](../nitro-issue-management/SKILL.md) rather than extending the branch.

## Anti-Patterns

- Do not plan on an unreconciled board — closed and superseded issues get scheduled at full cost
- Do not change an issue to agree with the board; the board is the derived view, always
- Do not overwrite an `In Progress` you did not set
- Do not call `updateProjectV2Field` without resending every existing option **with its id** — it
  replaces the list, and the items grouped under the dropped options are orphaned
- Do not hardcode project, field, or option ids into a script or a note — resolve them per run
- Do not leave a `RUN nth` description stale after a re-rank
- Do not schedule a third patch into a cause-cluster two merged fixes already touched — file the
  design issue and supersede the members
- Do not group by shared label — `bug` is not an edit surface
- Do not group across subsystems to "clear more backlog"
- Do not exceed four members, however well they overlap
- Do not average the tier across members, or let a cheap member argue the group down
- Do not let a docs-tier member ride a `high` branch — split it out and run it at `quick`
- Do not order by importance across a real dependency — the rewrite still goes first
- Do not rank a loud crash above a silent wrong answer because it looks more urgent
- Do not promote a member because it carries `pre-publish` — that is a release gate, not a severity
- Do not leave the ordering unstated, or the one case where a dependency demoted the important work
- Do not start implementing before the user has agreed to the cluster
- Do not add a fifth issue mid-session because it is adjacent
- Do not squash the group into one commit, or merge two members into one `UPGRADING.md` entry
- Do not skip a member's rung 1 and 2 because the group's full suite will run later
- Do not implement a half-fix to avoid breaking up the group
- Do not hold completed members back because a sibling stalled
- Do not hand a reviewer the whole group diff as one undifferentiated blob
- Do not put `Closes #N` on the PR for a member you dropped
