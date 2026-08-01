# Upgrading Nitro

Nitro is pre-1.0. In Julia's `0.y.z` convention the **`y` slot is the breaking slot**, so the API
still changes when a change makes it better — and every such change has to be rolled out by hand in
each app that depends on it. That stays true for the whole `0.x` era.

Breaking changes are a pain. The point of everything below is to make them *mechanical* rather than
archaeological: each one ships with the search that finds your affected call sites and the exact
edit to make, so you — or an agent working for you — can apply it without reverse-engineering what
changed. This page covers the versioning model, how to scope an upgrade to your app, and how to hand
the work to an AI agent.

The change log itself lives in
[`UPGRADING.md`](https://github.com/PingoLee/Nitro.jl/blob/main/UPGRADING.md) in the Nitro
repository — one entry per breaking change, newest first. You rarely need to open it:
[`upgrade_guide`](@ref Nitro.upgrade_guide) renders exactly the slice that applies to you.

## How Nitro versions: release trains

Nitro bumps **per release train, not per pull request**.

- **`y` is the breaking slot.** Any release that forces an edit in your app bumps `y` and carries a
  matching `UPGRADING.md` entry. Pin `Nitro = "0.1"` and Pkg will hold you there until you choose to
  move.
- **`z` is safe.** A purely additive train, or a hotfix to a tagged one. Nothing to port.
- **During a train,** every breaking or behavior-changing PR appends its entry to the
  `## Unreleased` section of `UPGRADING.md` without bumping `Project.toml` — that still holds the
  last cut train's version.
- **Cutting a train** bumps `y` once, stamps every `Unreleased` entry with that number, dates and
  tags the section, and opens a fresh empty `## Unreleased`.

So one `y` bump can carry several entries. They are applied together, newest-first, as one rollout.

!!! info "Tracking `HEAD` instead of a release"
    If you `dev` or path-depend on Nitro rather than installing a released version, you are running
    the last cut train **plus** whatever has accumulated under `## Unreleased` since.
    `upgrade_guide` includes that uncut work by default, because it is what your app is actually
    running — pass `to = pkgversion(Nitro)` to scope to the released surface only.

!!! warning "`0.1.0` is the baseline"
    Nitro carried `0.2.0`–`0.4.0` in `Project.toml` before the release-train policy existed, with
    per-PR bumps and no rollout log. Those numbers and their tags were reclaimed: the versioned
    history starts at `0.1.0`, and `UPGRADING.md` has no entries below it.

## Upgrading an app

Your app's Nitro dependency pin **is** its rollout state. There is nothing else to track — no
per-app checklist, no status table.

### 1. Scope the work to your version

```julia
using Nitro

Nitro.upgrade_guide(from = v"0.1.0")   # the version your app currently pins
```

This prints every entry newer than your pin, newest first — each with its *"How to find the calls to
migrate"* recipe and its concrete `before → after`. If nothing applies, you get a single line:

```
# Nitro: nothing to port between 0.1.0 and Unreleased.
```

To scope to a released version instead of `HEAD`, pass `to`:

```julia
Nitro.upgrade_guide(from = v"0.1.0", to = v"0.2.0")
```

Without a Julia session handy you can do the same by eye: open
[`UPGRADING.md`](https://github.com/PingoLee/Nitro.jl/blob/main/UPGRADING.md), read from the
top, and stop at the first entry whose `- **Version**:` is **≤ your pin**. Everything above that
line is what changed since you pinned.

### 2. Find the call sites

Each entry carries a grep tuned to that specific change. Run it inside your app rather than reading
your whole codebase — for example, the `with_kid` entry's:

```
rg -n 'with_kid' <app>/src
```

### 3. Apply the `before → after`

Every entry shows the ✗ old form and the ✓ new one. Edit each call site to the ✓ form.

### 4. Verify against your own tests

Run your app's test or integration suite against the upgraded Nitro. An entry is done for your app
only when the code is updated **and** the tests pass — not when the edit compiles.

### 5. Bump the pin

Once green, bump your app's Nitro dependency to the version you upgraded to. That pin is the app's
rollout state, so the next `upgrade_guide` call scopes correctly from there.

## Driving the upgrade with an AI agent

The workflow above is mechanical — scope, grep, apply, verify — which makes it a good fit for a
coding agent.

### Make the rollout self-triggering

Add one line to your app's `AGENTS.md` or `CLAUDE.md`:

> Before bumping the Nitro dependency, run `Nitro.upgrade_guide(from = v"<current pin>")` and apply
> what it lists.

That single line is what makes the whole thing work unattended: an agent asked to bump Nitro in that
repo picks up the rollout on its own, instead of bumping the pin and leaving the code behind.

### Consume the entries as data

For a scripted or agent-driven rollout, `structured = true` returns the entries as data instead of
printing them:

```julia
entries = Nitro.upgrade_guide(from = v"0.1.0", structured = true)

for e in entries
    println(e.version, " — ", e.title)
    # e.body holds the full markdown: severity, grep recipe, before → after
end
```

Each element is a `(; version, title, body)` named tuple, newest-first — enough to drive a per-entry
loop, or to decide up front whether a bump needs a human at all.

!!! tip "Work newest-first, and finish each entry"
    Entries can supersede each other — a later entry may retype or rename something an earlier one
    described, so applying them bottom-up produces code that matches the *older* contract. The
    printed output is ordered newest-first for exactly this reason; keep that order, and run the
    tests before moving to the next entry.

## API Reference

```@docs
Nitro.upgrade_guide
```
