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

The *rationale* behind the steps lives in [`reference.md`](reference.md) — each step points at the
section to open when you reach it. Most invocations are "what should I pick up next?" and never reach
§4, so the write-back footguns are not paid for on every run. **Every query below is projected
through `--jq` on purpose:** the raw GraphQL responses are deeply nested and an unprojected read is
the single largest cost in this skill.

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

The incident this rule was written from, and why the hand-off costs more since the merge-gate change:
[`reference.md`](reference.md) §A.

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
      name field{ ... on ProjectV2SingleSelectField { name } } } } } } } } } }' \
  --jq '.data.user.projectV2.items.nodes[] | [
      .id,
      (.content.number // "-"),
      (.content.state  // "-"),
      ([.fieldValues.nodes[] | select(.field.name == "Status")  | .name] | first // "NO-STATUS"),
      ([.fieldValues.nodes[] | select(.field.name == "Session") | .name] | first // "NO-SESSION")
    ] | @tsv'
```

One line per item: `<item-id> <issue#> <state> <status> <session>`. **Never run this unprojected** —
the raw response is ~99 items × 12 nested field values and it is the most expensive read in the
skill, for information that fits in five columns. `NO-SESSION` is not padding; it is the count §1
below actually cares about.

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
as invisible to §2 as an issue never added: nothing ranks them. The projection above already carries
it, so it is one `grep`, not a second query:

```bash
# ... | grep -c 'NO-SESSION'
```

Why that count is the one that says whether the board is usable at all:
[`reference.md`](reference.md) §B.

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

| Constraint | What it means for scheduling |
|---|---|
| **Verification serializes** | Sessions can *edit* in parallel and must *queue* to run rungs 4–6 — machine-resource contention, not port collisions |
| **A worktree run is weaker than it reports** | Until [#128](https://github.com/PingoLee/Nitro.jl/issues/128) lands it silently skips `PormGWorkerStore` and still exits 0 — a prerequisite for trusting parallel sessions, not just a leverage item |
| **Uncommitted work is invisible** | `git log` and `git diff main...<branch>` do not show it — check what is in flight per [`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) §2 |

The evidence behind each, and why a per-session surface beats a conflict matrix:
[`reference.md`](reference.md) §F.

## 4. Write it back

**Authentication.** Board writes need the `project` scope, which the default token does not carry:

```bash
gh auth status                 # look for 'project' in Token scopes
gh auth refresh -s project     # interactive browser flow — the USER runs this, not you
```

**Discover the IDs — never hardcode them.** Project, field, and option IDs are opaque and change
with the board. Resolve them every run, but **snapshot to a file rather than into the transcript** —
the option list carries every description, and you need it byte-for-byte, not approximately:

```bash
gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:8){ id
  fields(first:20){ nodes{ ... on ProjectV2SingleSelectField { id name options{ id name color description } } } } } } }' \
  > .claude/worktrees/board.json          # gitignored scratch

# Read only what you need to think with:
jq -r '.data.user.projectV2 | "PROJECT \(.id)", (.fields.nodes[] | select(.name) | "FIELD \(.name) \(.id)")' \
  .claude/worktrees/board.json
jq -r '.data.user.projectV2.fields.nodes[] | select(.name=="Session") | .options[]
       | "\(.id)\t\(.name)\t\(.description|length)"' .claude/worktrees/board.json
```

That second line gives you the option ids **and** the length check the cap below needs, without a
single description entering context.

**`updateProjectV2Field` replaces the entire option list — it does not append.** Sending only the new
option deletes every existing one and orphans every item grouped under them. The rule: resend every
existing option **with its `id`, `color`, and `description`**, then append the new one without an
`id`. Full reasoning, including why a rename needs the id: [`reference.md`](reference.md) §C.

**Build that payload file-to-file, never by retyping.** `jq` carries the unchanged options straight
from the snapshot, so only the description you are actually changing is written out:

```bash
jq --arg target 'Session 4' \
   --arg desc   'RUN 1st | TIER standard | READY. FILES: ... ORDER: ... WHY: ...' \
   '{ query: "mutation($fid:ID!,$opts:[ProjectV2SingleSelectFieldOptionInput!]!){
        updateProjectV2Field(input:{fieldId:$fid,singleSelectOptions:$opts}){
          projectV2Field{ ... on ProjectV2SingleSelectField { options{ id name } } } } }",
      variables: {
        fid: (.data.user.projectV2.fields.nodes[] | select(.name=="Session") | .id),
        opts: [ .data.user.projectV2.fields.nodes[] | select(.name=="Session") | .options[]
                | {id, name, color, description}
                | if .name == $target then .description = $desc else . end ]
      } }' .claude/worktrees/board.json > .claude/worktrees/payload.json

jq -e '[.variables.opts[] | select((.description|length) > 450)] | length == 0' \
   .claude/worktrees/payload.json          # non-zero exit = something is over the cap

gh api graphql --input .claude/worktrees/payload.json    # -f cannot express a list of objects
```

To **add** an option instead of editing one, append `+ [{name: "...", color: "GRAY", description: "..."}]`
to `opts` — no `id` on the new entry, ids intact on every old one. Verify the response lists every
pre-existing option with its **original id** before moving on.

Re-ranking is the common case and it is the expensive one, because `RUN nth` lives inside a string
that is otherwise stable. The recipe above makes that cheap; the structural fix, and why it has not
been done, is [`reference.md`](reference.md) §E.

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

**Descriptions are capped at ~450, and one long one fails *every* option in the batch.** The `jq -e`
guard above is the check — run it before submitting, not after the error. Whether the API counts
characters or bytes is unconfirmed, which is the real reason the grammar is ASCII:
[`reference.md`](reference.md) §D.

Mark finished groups `DONE. #79, #81, #82, #74.` rather than deleting them — the history of what
shipped together is what makes the next grouping decision easier.

**The board records decisions, not speculation.** An option per agreed cluster; nothing for a
grouping you merely considered — and never an option with an empty description
([`reference.md`](reference.md) §G).

## 5. What to hand back

The board is the durable artifact; the table in the conversation is what the user reads. Write the
board back, then report **one ranked table, one row per session** — the question behind every
invocation is "what can I work in one sitting?", and a session is the unit that answers it.

**Every session gets a row, rank 1 through n.** No top-N, no truncation, and above all no
parenthetical standing in for the rows you dropped — *"8th–14th unchanged in relative order: 40, 27,
29, 30, 31, 25, 26"* is not a report, it is seven missing rows. A rank means nothing except against
the full list, and an issue whose number appears nowhere in the table reads as missing from the
**board**: that is how a user came to report issue #7 as absent when it had been on the board, in
Session 25 at rank 13, for three weeks. Sessions nobody will start this week still get a row —
`Start now?` is exactly where "not this week, and here is why" belongs. A session you deliberately
left unranked gets a row too, with `—` in the `#` column.

| # | Issues (one session) | Session | Tier | Start now? |
|---|---|---|---|---|
| 3 | #108 → #127 → #30 | Worker Execution & Lifecycle | high | After #128 |
| 4 | #55 → #31 → #32 | App Context & Bootstrap | high | #55 only — #31/#32 need the app-handle decision |
| 5 | #66, #7, #117 | Publish Gate Decisions | high | No — all three are open decisions, not code |

(Three *contiguous* rows, shown to fix the column format. A real report carries every rank.)

`→` is a forced order inside the session; a comma means any order. **`Start now?` carries the
blocker, never a bare yes/no.** Below the table add only what it cannot: which rows have disjoint edit
surfaces (§3), and any ranking tension you resolved (§2).

**Check the table adds up before sending it, the way §4 checks the payload before submitting it.**
Every open issue in §1's projection appears in exactly one row. Sum the `Issues` column, compare it
against the open count you already have, and state the result in the report — *"14 sessions, 31 open
issues, all accounted for"*. A table that silently omits work is the one failure mode the reader
cannot detect for themselves, and that sum is the whole guard against it.

**Do not dump the board, and do not render a second copy of it.** This constrains the
**descriptions**, never the row count. The `FILES:`/`ORDER:`/`WHY:` strings are written for the next
session to read off the board, which already has a URL — and with the §4 recipe they never enter the
transcript in the first place, so echoing them back means fetching them on purpose to do it.
**Dropping rows is not a way to comply with this rule**; the two constraints point in opposite
directions on purpose. Receipt: [`reference.md`](reference.md) §G.

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
- Do not truncate that table, or compress the rows you dropped into a parenthetical — every session
  is a row, and an issue number absent from the table reads as absent from the board
- Do not send the table without stating the issue count it accounts for
