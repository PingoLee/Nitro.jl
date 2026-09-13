---
name: nitro-board
description: Reconcile the Nitro project board against GitHub Issues, rank the sessions, and write the plan back so the next session does not recompute it. Answers "what should I pick up next?" and stops there — planning only, no implementation. Records each session's edit surface so parallel Claude sessions can be scheduled safely.
---

# Nitro Board

## Purpose

The [Nitro project board](https://github.com/users/PingoLee/projects/8) is where the *plan* lives.
The **backlog** is GitHub Issues ([`nitro-issue-management`](../nitro-issue-management/SKILL.md));
the board is the derived view that says what runs next, in what order, and why.

This skill owns that view end to end: reconcile it against the issues, rank the sessions, and write
the ranking back. It is the planning layer *underneath*
[`nitro-issue-cluster`](../nitro-issue-cluster/SKILL.md) — that skill builds and works a cluster and
links here rather than restating any of this.

## Use This Skill For

- **"What should I pick up next?"** — the most common reason to be here
- Reconciling the board after a batch of new issues (every session spawns follow-ups)
- Recording an agreed cluster, its rank, and its edit surface
- Working out which sessions can run in **parallel Claude sessions**
- Any "update the board", "plan the session", "build the board" request

Not for: filing, labelling, or closing issues (`nitro-issue-management`); implementing anything at
all (see the stop rule immediately below).

## 0. This skill is a deliverable — stop when the board is written

**Reconciling and ranking is a complete unit of work. Do not continue into implementation.**

Report the ranking, write it back, stop. "What should I pick up next?", "update the board", "plan
the session" are answered *entirely* by this skill.

**A user choosing which work ranks first is answering a planning question. It is not authorization to
implement it.** Neither is approving a ranking, agreeing with a recommendation, or picking an option
from a list of candidate sessions.

**What "stop" forbids, concretely.** While in this skill, do not: create a branch, call
`EnterWorktree`, edit anything under `src/`, `test/`, `docs/`, or `ext/`, run the test suite, commit,
push, or open a PR. **And do not delegate any of it** — spawning a subagent, a worktree, or a
parallel session to do the work is doing the work. §3 is about *scheduling* parallel sessions, never
about launching them.

Reading is allowed, and bounded: enough to reconcile, rank, and fill in `FILES:` for a session.
`FILES:` is normally *recorded from an already-agreed cluster*, not derived from scratch — if you
find yourself opening functions to size a fix, you have left planning. Say what you would need to
look at, and stop.

Work begins when the user asks for it. Offer it as its own question, in those words — "shall I start
work on X?" — after the board is written; a yes to *that* is the authorization. Nothing else is.

If the ranking makes the next step obvious, say what it is and offer it. Do not take it. Hand off to
[`nitro-issue-cluster`](../nitro-issue-cluster/SKILL.md) for a multi-issue session or
[`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) for a single issue. Note what that hand-off
costs: once the user says yes, that workflow runs to an open PR without stopping again, so the yes
you collect here is the last one before a branch exists.

**Do not ask a question whose answer doubles as consent.** "What should this session run?", offered
as a menu of implementation options, reads as a planning question and gets answered as one — and
then the answer looks like a work order. In planning mode, ask about *the plan*: which ranking is
right, which grouping to record, whether a design direction is settled. Keep "shall I start work on
X?" as its own separate question, asked in those words, after the board is written.

Receipt: this rule exists because the board work and the cluster work lived in one skill with no
boundary between them. A session invoked to plan the board asked "what should this session actually
run?" as part of ranking, read the answer as authorization, and went on to write, test, review, and
commit code the user had not asked for. The board half of that session was what they wanted; the
rest was unrequested.

## 1. Reconcile

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

**An `In Progress` with no branch, PR, or worktree behind it is stale, not live.** Check before
leaving it alone — `git worktree list`, `gh pr list --state open`, and the issue's own assignees. Say
what you found and let the user decide; do not silently clear a marker another session may own.

Also sweep for open issues that are on no board item at all, and compare against the item numbers
from the query above:

```bash
gh issue list --state open --limit 100 --json number -q '.[].number' | sort -n
```

**Every open issue belongs on the board.** An issue filed during a session — including follow-ups
this session just filed — is invisible to the next planning pass until it is added.

**Membership is not the whole sweep — also count the open items whose `Session` is empty.** They are
as invisible to §2 as an issue never added: nothing ranks them. The query above already returns field
values, so check it in the same pass.

Receipt: reconciling board 8 after 16 sessions found **one** open issue off the board and **26** on it
with no `Session` — it looked complete while two thirds of the backlog sat there unschedulable.

## 2. Rank the sessions

Group display order on the board is option order, which is numeric. Execution order is not, and
neither the field nor the item ordering can say "run Session 8 before Session 6" — so rank
explicitly, in descending priority:

1. **Breaking changes, while the repo is pre-publish.** Cheapest now; every session built on the old
   shape raises the cost. A session that changes a public signature or a `Service` field outranks
   one that does not.
2. **The publish gate.** `gh issue list --state open --label pre-publish` — empty is the gate. Its
   size is a scheduling input: one issue from empty is worth finishing. This is the one place the
   label ranks anything; *inside* a session it is a classification, never a promotion.
3. **The importance ladder's top rung across members** (see
   [`nitro-issue-cluster`](../nitro-issue-cluster/SKILL.md) §2, which owns the ladder): a session
   holding a rung-1 or rung-2 member — secret exposure, an authorization bypass, silently wrong
   behavior — outranks one whose members are all loud failures, performance, or docs.
4. **Leverage** — a session that taxes every other session. A test-harness fix that every
   `:network` item trips over, or a CI change every PR waits on, ranks above its own severity.

An area label describes the issue, never its blast radius. When you rank a session above where its
labels would put it, state the override and the reason in the same line — an unexplained override
reads as an error.

**Say when you override the order itself.** The list above is descending priority, not a formula:
criterion 1 is an argument about *cost*, and a live rung-1 defect is an argument about *harm*. Those
can point opposite ways. Resolving it either way is fine; leaving the tension unstated is not.

## 3. Parallel sessions

Two Claude sessions can work the board at once. The board is what makes that safe, because it
records each session's **edit surface**.

**Disjoint `FILES:` is the first gate, and it is necessary but NOT sufficient.** Record the surface
per session (§4) and derive the gate from it — never store a pairwise conflict matrix, which is
O(n²) to maintain and silently goes stale the moment a session is added.

Three constraints survive filesystem isolation, so clear all of them before calling two sessions
parallel-safe:

- **Verification serializes.** Two sessions cannot run the full suite (rungs 4–6) concurrently,
  regardless of file disjointness. Note the reason is **contention for machine resources**, not port
  collisions: no Nitro test uses a fixed port — `get_free_port()` is called at ~47 sites and
  `PORT`/`localhost` were deliberately removed from `NitroCommon`. Sessions can *edit* in parallel
  and must *queue* to verify. See
  [`nitro-test-troubleshooting`](../nitro-test-troubleshooting/SKILL.md) §5.
- **A worktree run is weaker than it reports.** Until [#128](https://github.com/PingoLee/Nitro.jl/issues/128)
  lands, a worktree silently skips the entire `PormGWorkerStore` testset and still exits 0 — so a
  parallel session verifying a store-interface change is not verifying what it thinks. #128 is a
  prerequisite for trusting parallel sessions, not merely a leverage item.
- **Uncommitted work is invisible.** `git log` and `git diff main...<branch>` do not show it. Check
  what is actually in flight before starting, per
  [`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) §2.

## 4. Write it back

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
issue; then one `gh project item-edit` per field — Session and Status:

```bash
gh project item-edit --id <item-id> --project-id <project-id> \
  --field-id <field-id> --single-select-option-id <option-id>
gh project item-edit --id <item-id> --project-id <project-id> --field-id <field-id> --clear
```

Add issues **in the order you want them displayed** — row order is insertion order.

### The description grammar

The board cannot express rank, tier, or edit surface any other way, so each Session option's
description carries all three in a fixed shape. It surfaces on hover, so it has to stay scannable.

**Write it as one line of plain ASCII** — that is what the field actually renders, and it keeps the
length countable (see the cap below). Use `--`, not an em-dash:

```
RUN 2nd | TIER standard | READY. FILES: scripts/worktree_setup.sh, test/runtests.jl,
test/extensions/pormg_worker_tests.jl. ORDER: #128 solo. WHY: rung 2 + LEVERAGE -- a worktree
silently skips ~100 PormG assertions and still exits 0, taxing every session below and gating
Session 4's #108.
```

(Wrapped here for reading only; the stored value is a single line.)

- **`RUN nth`** — execution rank. Restamp **every** description when the ranking changes; a stale
  `RUN 1st` is worse than none.
- **`TIER`** — `quick` / `standard` / `high` from
  [`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) §0, so the cost is visible before
  anyone opens the issues.
- **State** — `READY`, `IN PROGRESS`, `BLOCKED BY #N`, `NOT STARTABLE` (an open design question), or
  `DONE`.
- **`FILES:`** — the edit surface. This is the parallel-safety key (§3); a session without it cannot
  be scheduled against another.
- **`ORDER:`** — member sequence, with *forced* (a real dependency) vs *preferred* (an importance
  tiebreak) named explicitly.
- **`WHY:`** — why this rank. The one line that stops the next session re-deriving it.

**Descriptions are capped at ~450.** The API rejects the whole mutation over the limit — one long
description fails *every* option in the batch, not just its own. Check lengths before submitting
rather than discovering it in an error.

Receipt, stated honestly because it matters for how you count: the limit is known only from the API
rejecting a batch with the message *"Settings option description is too long (maximum is 450
characters)"*. Whether it counts characters or bytes is **unconfirmed**. Keeping descriptions ASCII
makes the two identical, which is why the grammar above says ASCII — a 445-character description
with a dozen em-dashes is ~470 bytes and would fail the whole batch.

Mark finished groups `DONE. #79, #81, #82, #74.` rather than deleting them — the history of what
shipped together is what makes the next grouping decision easier.

**The board records decisions, not speculation.** An option per agreed cluster; nothing for a
grouping you merely considered.

Receipt: board 8's first ten Session options were created with empty descriptions. With six of them
done or partly done and four untouched, nothing on the board said which ran next, and the ranking had
to be re-derived from scratch each session.

## 5. What to hand back

The board is the durable artifact; the table in the conversation is what the user reads. Write the
board back, then report **one ranked table, one row per session** — the question behind every
invocation is "what can I work in one sitting?", and a session is the unit that answers it.

| # | Issues (one session) | Session | Tier | Start now? |
|---|---|---|---|---|
| 3 | #108 → #127 → #30 | Worker Execution & Lifecycle | high | After #128 |
| 5 | #55 → #31 → #32 | App Context & Bootstrap | high | #55 only — #31/#32 need the app-handle decision |

`→` is a forced order inside the session; a comma means any order. **`Start now?` carries the
blocker, never a bare yes/no.** Below the table add only what it cannot: which rows have disjoint edit
surfaces (§3), and any ranking tension you resolved (§2).

**Do not dump the board, and do not render a second copy of it.** The `FILES:`/`ORDER:`/`WHY:`
descriptions are written for the next session to read off the board, which already has a URL.

Receipt: a session that had just written 19 ranked options echoed them all back in full, twice, before
the user asked plainly for a table of what fits in one Claude session.

## Anti-Patterns

- **Do not implement anything from this skill** — §0 is the whole point
- Do not treat a user's answer about ranking, or their agreement with a recommendation, as
  authorization to start the work
- Do not plan on an unreconciled board — closed and superseded issues get scheduled at full cost
- Do not change an issue to agree with the board; the board is the derived view, always
- Do not overwrite an `In Progress` you did not set — but do check whether it is stale, and say so
- Do not leave a newly filed issue off the board
- Do not stop the sweep at board membership — an open item with an empty `Session` is unschedulable
  in exactly the same way, and there are usually more of them
- Do not call `updateProjectV2Field` without resending every existing option **with its id** — it
  replaces the list, and the items grouped under the dropped options are orphaned
- Do not hardcode project, field, or option ids into a script or a note — resolve them per run
- Do not exceed 450 characters in a description; the whole mutation fails, not just that option
- Do not leave a `RUN nth` description stale after a re-rank
- Do not omit `FILES:` — a session without an edit surface cannot be scheduled in parallel
- Do not store a pairwise parallel-conflict matrix; record each session's files and derive it
- Do not promise two sessions can run fully in parallel — verification serializes on machine
  resources, and disjoint files are only the first gate
- Do not rank a loud crash above a silent wrong answer because it looks more urgent
- Do not promote a session because a member carries `pre-publish` — that is a release gate, not a
  severity
- Do not leave an override of the ranking order unstated
- Do not report the board by echoing every option's description, or by rendering a second copy of it
  — §5's one-row-per-session table is the deliverable, and `Start now?` needs the blocker, not a bare
  yes/no
