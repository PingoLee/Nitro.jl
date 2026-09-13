# Nitro Board — Reference

The *why* behind the steps in [`SKILL.md`](SKILL.md). Load a section from here only when you reach
the step that points at it — the checklist in `SKILL.md` is complete on its own, and this file exists
so the rationale is not paid for on every invocation.

Most invocations of this skill are *"what should I pick up next?"* and never reach §4. Those runs
should not carry the write-back footguns in context at all.

Nothing here is optional-but-nice. Every section documents a failure that has actually bitten this
repo, in a way that is invisible from reading the board.

---

## A. Why planning is its own deliverable (SKILL.md §0)

The board work and the cluster work once lived in one skill with no boundary between them. A session
invoked to plan the board asked *"what should this session actually run?"* as part of ranking, read
the answer as authorization, and went on to write, test, review, and commit code the user had not
asked for. The board half of that session was what they wanted; the rest was unrequested.

That is the whole reason §0 exists, and why the consent question has to be asked **in its own words,
after the board is written**. A ranking question and a work order look identical in a transcript once
the answer is a single word.

The hand-off costs more now than it did then. Since the merge-gate change in
[`nitro-general.instructions.md`](../../instructions/nitro-general.instructions.md), a "yes" to
*"shall I start work on X?"* runs all the way to an open PR without stopping again. The yes collected
here is the last one before a branch exists — which raises the bar on asking it cleanly, not lowers
it.

---

## B. The sweep goes past board membership (SKILL.md §1)

Reconciling board 8 after 16 sessions found **one** open issue off the board and **26** on it with no
`Session` value. It looked complete while two thirds of the backlog sat there unschedulable: nothing
in §2 ranks an item whose `Session` is empty, so those issues were invisible to every planning pass
that only checked membership.

This is why the projection in §1 selects the `Session` value alongside `state` and `Status` — the
empty-`Session` count is the number that says whether the board is actually usable, and it costs
nothing extra to read once the query is projected.

---

## C. `updateProjectV2Field` replaces the entire option list (SKILL.md §4)

It does not append. Sending only the new option **deletes every existing one** and orphans every item
grouped under them.

`ProjectV2SingleSelectFieldOptionInput` accepts an optional `id`, and that is what saves you: resend
every existing option with its `id`, `color`, and `description`, then append the new one without an
`id`. Matching ids keep items attached, and they also let you rename a group safely — a rename with
the id present is a rename, a rename without it is a delete plus a create.

This is why §4 builds the payload **file-to-file with `jq`** rather than by retyping the options. The
mechanical part — carrying nineteen options forward byte-for-byte — is exactly what an agent is worst
at and what `jq` is perfect at, and every description that passes through the transcript on its way
back to the API is a description that can come back subtly different.

`-f` cannot express a list of objects, so the mutation goes through `--input`.

---

## D. The 450-character cap, and why the grammar is ASCII (SKILL.md §4)

The API rejects the **whole mutation** over the limit — one long description fails *every* option in
the batch, not just its own. That is why §4 checks lengths before submitting instead of discovering
it in an error.

Stated honestly because it matters for how you count: the limit is known only from the API rejecting
a batch with the message *"Settings option description is too long (maximum is 450 characters)"*.
Whether it counts characters or bytes is **unconfirmed**.

Keeping descriptions ASCII makes the two identical, which is the real reason the grammar says ASCII
and `--` rather than an em-dash. A 445-character description with a dozen em-dashes is ~470 bytes and
would fail the whole batch — and the error names the cap, not which option blew it.

---

## E. The description is a struct in a string, and it mixes volatile with stable (SKILL.md §4)

`RUN 2nd | TIER standard | READY. FILES: … ORDER: … WHY: …` packs six fields into one string because
the board has nowhere else to put them. That works, but the fields have wildly different volatility:

| Field | Changes | Cost of that change today |
|---|---|---|
| `RUN nth` | every re-rank | rewrite **every** description, resend the full option list |
| state (`READY`/`BLOCKED`) | most sessions | same |
| `TIER` | rarely | same |
| `FILES:` / `ORDER:` / `WHY:` | when the cluster changes | same |

Every row pays the cost of the most volatile one. Re-ranking — the single most common board edit —
means reproducing roughly 8.5 KB of description text that did not change, just to move a number.

The `jq` recipe in §4 removes most of that cost without changing the board: unchanged descriptions
are carried by `jq` from the API's own response and never enter the transcript. **That is a mitigation,
not a fix.**

The structural fix is to split by volatility — `RUN` becomes a ProjectV2 **Number** field and state a
**single-select**, leaving only `FILES:`/`ORDER:`/`WHY:` in the description. Re-ranking then becomes N
tiny `item-edit` calls that touch no description and never invoke the replace-all path at all, and the
board gains sortable/groupable rank and state columns for free — impossible today because both are
buried in a string.

It is not done because it is a one-way migration through the exact mutation described in §C, and the
`jq` recipe made it non-urgent. Do it deliberately, in its own session, not as a side effect of a
planning run.

---

## F. Parallel sessions: what survives filesystem isolation (SKILL.md §3)

Disjoint `FILES:` is the first gate and it is **necessary but not sufficient**. Three constraints
outlive the worktree boundary:

**Verification serializes.** Two sessions cannot run the full suite (rungs 4–6) concurrently
regardless of file disjointness. The reason is contention for machine resources, *not* port
collisions — no Nitro test binds a fixed port: `get_free_port()` is called at ~47 sites, and
`PORT`/`localhost` were deliberately removed from `NitroCommon`. So sessions can *edit* in parallel
and must *queue* to verify. See
[`nitro-test-troubleshooting`](../nitro-test-troubleshooting/SKILL.md) §5.

**A worktree run is weaker than it reports.** Until
[#128](https://github.com/PingoLee/Nitro.jl/issues/128) lands, a worktree silently skips the entire
`PormGWorkerStore` testset and still exits 0 — so a parallel session verifying a store-interface
change is not verifying what it thinks it is. That makes #128 a *prerequisite* for trusting parallel
sessions, not merely a leverage item to schedule high.

**Uncommitted work is invisible.** Neither `git log` nor `git diff main...<branch>` shows it, so a
session can look idle while holding edits to the file you are about to plan onto. Check what is
actually in flight per [`nitro-issue-workflow`](../nitro-issue-workflow/SKILL.md) §2.

Why per-session `FILES:` rather than a conflict matrix: a pairwise matrix is O(n²) to maintain and
goes stale the moment a session is added, silently. Recording each session's own surface and deriving
the pairing keeps one source of truth per session.

---

## G. Two reporting failures worth not repeating (SKILL.md §5)

A session that had just written 19 ranked options echoed them all back in full, **twice**, before the
user asked plainly for a table of what fits in one Claude session. The descriptions are written for
the *next* session to read off the board, which already has a URL — re-rendering them in the
transcript is pure cost with no reader.

Separately, board 8's first ten Session options were created with **empty descriptions**. With six of
them done or partly done and four untouched, nothing on the board said which ran next, and the
ranking had to be re-derived from scratch every session. That is what the `RUN`/`WHY` grammar exists
to prevent — an option with no description is not a plan, it is a label.
