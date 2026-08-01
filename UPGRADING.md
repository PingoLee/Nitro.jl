# Upgrading Nitro — consumer-app rollout log

Tracks **breaking / behavior changes in Nitro** that require source-code changes in the applications
that depend on it. Nitro is pre-publish (single maintainer, no external users), so breaking changes
are intentional and cheap on the *Nitro* side — but each one still has to be rolled out by hand in
every consuming app. This file is that rollout checklist.

> 🚀 **Upgrading an app? Don't read this file top to bottom.** Run
> `Nitro.upgrade_guide(from = v"<your pinned version>")` — it renders only the entries newer than
> your pin, newest-first. The full how-to (versioning model, the apply recipe, driving it with an AI
> agent) lives in the docs: **[Upgrading Nitro](https://pingolee.github.io/Nitro.jl/dev/upgrading/)**.
> This file is the change log those tools read; the sections below are the rules for *writing* an
> entry.

## Writing an entry

- One `##` entry per breaking change, **newest first**. New entries land in **`## Unreleased`** with
  `- **Version**: Unreleased` and **no `Project.toml` bump**; the maintainer stamps them with a
  release number when cutting a train (`nitro-cut-release`).
- Each entry records: the Nitro **version** it shipped in, what changed, why, a *"How to find the
  calls to migrate"* grep, and the concrete **before → after** code edit.
- **Not for additive features.** This log is only what **forces** an app edit. A new opt-in
  capability (middleware, extractor, kwarg, function) requires no change to keep an app working →
  document it in `docs/`, not here.
- **No per-entry rollout tables.** An app's own Nitro dependency pin *is* its rollout state, and
  `upgrade_guide(from = <that pin>)` derives what it still needs — so there is nothing to maintain
  per app.
- **Keep the prose version-neutral.** Write *"part of the `0.1.x` pre-publish wave"*, never *"part of
  the current `## Unreleased` wave"* — stamping rewrites the `- **Version**:` bullet, not the body,
  so self-referential prose ships stale.
- Entries are version-stamped from **`0.1.0`** onward. `0.1.0` is the baseline of the release-train
  policy: earlier `Project.toml` numbers (`0.2.0`–`0.4.0`) and their tags predate it and were
  reclaimed, so nothing below `0.1.0` exists to port from.

---

## Unreleased — next `0.2.0`

_Changes merged but not yet cut into a release. A consumer dev'ing Nitro at HEAD is running these,
and `Nitro.upgrade_guide` surfaces them by default. When the maintainer next rolls changes into a
consuming app, `nitro-cut-release` stamps every entry below with `0.2.0`, dates them, and tags it._

---

## 0.1.0 — 2026-07-31

## `jwt_validator` returns a `Principal`, not the raw claims object (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46, #4; `src/Auth/`, `src/middleware/`, `docs/src/tutorial/authentication.md`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (return type)** — part of the `0.1.x` claim-based identity wave.

### What changed

`jwt_validator` used without a `user_validator` set `req.user` to the decoded claims object, so apps
reached into it with property sugar (`req.user.sub`) and sometimes mutated it. It now yields a
`Principal`: an immutable, dict-like wrapper over the *verified* claims with typed fields `id`
(normalized identity), `kid` (keyset-verified key id) and `source` (`:claim` / `:kid`).

Dict-style **reads** are unchanged — `user["sub"]`, `get`, `haskey`, iteration, `==`, and the JSON
serialization (which is exactly the claims object) all behave as before. Only property access and
mutation break.

### How to find the calls to migrate

```bash
rg -n 'user\.[a-z_]+' <app>/src        # property sugar on req.user
rg -n 'req\.user\[[^]]+\]\s*='  <app>/src   # mutation of req.user
```

`.id`, `.claims`, `.kid` and `.source` are the only valid properties; every other `req.user.<name>`
is a claim read that must become an index.

### Migrate your app

```julia
# ✗ before — property sugar over the claims object
subject = req.user.sub
email   = req.user.email

# ✓ after — index the Principal
subject = req.user["sub"]
email   = req.user["email"]
# or use the normalized identity field
subject = req.user.id

# ✗ before — mutating the claims in place
req.user["tenant"] = tenant_id

# ✓ after — the Principal is immutable; build your own user object in a
# user_validator, or copy out of it
u = Dict(req.user)
u["tenant"] = tenant_id
```

---

## `user_validator` receives the `Principal`; the tuple contract is `(user, principal)` (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46; `src/Auth/`, `src/middleware/`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (callback argument + context key)** — part of the `0.1.x` claim-based
  identity wave.

### What changed

A `user_validator` used to be handed the raw claims dict, and a validator returning a tuple returned
`(user, claims)`. It now receives the `Principal` — a dict-compatible superset of the old argument —
and the tuple contract is `(user, principal)`. Consequently `req.context[:auth_claims]` now holds
the `Principal` rather than a raw claims dict.

Because `Principal` supports the same dict reads, a validator that only *indexes* its argument keeps
working untouched. What breaks is a validator that treats the argument as a mutable `Dict`, calls
`Dict`-only methods on it, or annotates the parameter with `::Dict`.

### How to find the calls to migrate

```bash
rg -n 'user_validator' <app>/src
rg -n 'auth_claims' <app>/src
```

Then check each validator body for `::Dict` annotations, `setindex!`/`push!`/`delete!` on the
argument, and any downstream code that reads `req.context[:auth_claims]` expecting a plain dict.

### Migrate your app

```julia
# ✗ before — annotated and mutated as a Dict
function load_user(claims::Dict)
    claims["seen_at"] = now()
    return (fetch_user(claims["sub"]), claims)
end

# ✓ after — accept the Principal, copy before mutating, return (user, principal)
function load_user(principal)
    user = fetch_user(principal["sub"])   # or principal.id
    return (user, principal)
end

# ✗ before — downstream consumer assumed a dict
claims = req.context[:auth_claims]
claims["extra"] = 1

# ✓ after — it is a Principal; copy out if you need a mutable dict
principal = req.context[:auth_claims]
claims = Dict(principal)
claims["extra"] = 1
```

---

## `jwt_validator(...; with_kid=...)` is now a construction-time `ArgumentError` (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46; `src/Auth/`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (removed kwarg)** — part of the `0.1.x` claim-based identity wave.

### What changed

`with_kid` existed to opt into surfacing the token's key id. The kid now always flows through the
`Principal` (`req.user.kid`, populated only when the key id was *verified* against a keyset), so the
kwarg is redundant and is rejected at construction time rather than silently ignored. Passing it
throws an `ArgumentError` when the validator is built — at bootstrap, not per-request.

Note the tightened trust rule that comes with it: only a keyset-verified kid is exposed. A `kid`
header on a single-secret token is never trusted and leaves `req.user.kid` unset.

### How to find the calls to migrate

```bash
rg -n 'with_kid' <app>/src
```

### Migrate your app

```julia
# ✗ before
validator = jwt_validator(keyset = ks, with_kid = true)

# ✓ after — drop the kwarg; read the verified kid off the Principal
validator = jwt_validator(keyset = ks)

# in a handler or guard:
signing_key = req.user.kid          # nothing unless keyset-verified

# to authorize on it, prefer the declarative guard over a manual check
path("/admin", admin_handler, middleware = [kid_required(["ops-2026"])])
```

---

## Template for new entries

<!--
Copy the block below into the `## Unreleased` section at the top of the log for each new
breaking/behavior change. Do NOT bump `Project.toml` — the version moves once, at cut time
(the `nitro-cut-release` skill rewrites `Version: Unreleased` → the release number).

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
