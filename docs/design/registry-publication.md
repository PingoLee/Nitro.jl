# Registry publication: the one thing that blocks it, and the ways out

Design record for why `@JuliaRegistrator register` on Nitro fails today, which mechanism is
responsible, which plausible mechanisms are *not*, and what each escape route actually costs.
Written out of [#117](https://github.com/PingoLee/Nitro.jl/issues/117), **which this record
replaces** — the issue is closed, and this file is the durable memory. Publishing is not gated on a
label query: it is the maintainer's judgment, and the time has not come. What follows is the
lead-time half, so the decision is not made in ignorance of it.

> **TL;DR for Nitro contributors:** #117's three "Done when" boxes are all satisfied at HEAD —
> `3aac753` replaced the `[sources]` **path** entry with `url` + `rev` and deleted `PORMG_REV` and
> both sibling-checkout steps. But its premise was still true, for a reason nobody had written
> down: **`[sources]` is not what blocks publication, and never was.**
> Registrator reads `[deps]` **and `[weakdeps]`**, and errors on any UUID in either that no registry
> knows. `PormG` is a weakdep and is not in General, so registration fails at the front door —
> before `[sources]` is ever looked at, which it never is. §4 lists everything else that was checked
> and cleared, so it is not re-investigated. **No route is chosen here, and no timetable is
> implied** — publishing is the maintainer's judgment, not something a backlog clears the way for.

## 1. The single gate: for registration, a weakdep is a dep

The pipeline is `@JuliaRegistrator register` → `RegistryTools.register()` → `check_deps!` →
`findpackageerror!`. The whole record hinges on one line of it:

```julia
# JuliaRegistries/RegistryTools.jl, src/register.jl:355-370
function check_deps!(pkg::Project, regdata::Vector{RegistryData}, status::ReturnStatus)
    for deps in [pkg.deps, pkg.weakdeps]
        ...
        for (name, uuid) in deps
            findpackageerror!(name, uuid, regdata, status)
```

`findpackageerror!` (`src/register.jl:193-220`) searches every available registry for the UUID,
falls back to the stdlib table, and otherwise adds `:dependency_not_found` to the `ReturnStatus`.
That is an error, not a warning: the bot refuses and posts it.

**The gate, in one sentence: registration requires every UUID in `[deps]` *and* `[weakdeps]` to
already exist in the registry being registered into.**

Nitro fails it on exactly one name. Every other entry in `Project.toml` was checked against
`JuliaRegistries/General` one by one:

| Section | Names | In General |
|---|---|---|
| `[deps]`, non-stdlib | Bcrypt, DataStructures, HTTP, JSON, LRUCache, MIMEs, OpenSSL, PrecompileTools, Reexport | **all** — including HTTP at 2.7.1, which satisfies the `~2.7` pin |
| `[deps]`, stdlib | Base64, Dates, Printf, Random, SHA, Sockets, UUIDs | exempt (stdlib table) |
| `[weakdeps]` | Mustache, OteraEngine, ProtoBuf, Revise, TimeZones | **all** |
| `[weakdeps]` | **PormG** (`7d8d7541-4d3d-4580-80a2-17064efb0993`) | **no** |

Verified against RegistryTools at the state of its default branch on 2026-09-21. That loop is the
kind of line that could be narrowed upstream — if a later RegistryTools stops treating weakdeps as
registration-blocking, re-check it before acting on this record.

## 2. What `[sources]` does, and why it is not this

From the [Pkg documentation](https://pkgdocs.julialang.org/v1/toml-files/), verbatim:

> Sources are only used when the environment containing them is the active environment being
> resolved. If a package is used as a dependency in another project, its `[sources]` section is
> **not** consulted (except when that package itself was added by URL or path, in which case
> recursive collection applies as described above).

**The carve-out does not rescue PormG either.** The workflow file already records the reason, from
reading Pkg 1.12's `Operations.jl` for a neighbouring question: `collect_project` resolves
`[sources]` only in its `project.deps` loop, while the `project.weakdeps` loop builds a bare
`PackageSpec` with no path and no repo. So even a consumer who runs
`pkg> add https://github.com/PingoLee/Nitro.jl` never fetches PormG through Nitro's pin.

That leaves the `[sources]` entry load-bearing for exactly one thing — `Pkg.test` copying
`test_project.sources = source_env.project.sources` into the environment it generates, which is why
`Pkg.test()` has PormG when the project environment does not. And `register.jl` contains no
`sources` match at all: Registrator has no code path that reads the section.

**Two different questions were being answered by one sentence.** #117 says a path entry makes Nitro
*unresolvable from a registry* — that is about a **consumer** resolving Nitro once it is published,
and it is fixed. What #117 never said, and what is still true, is that Nitro cannot get **into** a
registry at all. Those are decided by different code in different repositories, and the second does
not care what `[sources]` says.

Once PormG is registered, the `[sources]` entry becomes dead weight for consumers and survives only
to feed `Pkg.test`'s generated environment.

## 3. Why `3aac753` was right anyway, and why the issue outlived it

This record is not a regression report. The url + rev migration removed the second pin
(`PORMG_REV`), deleted the hand-rolled sibling checkout, stopped Nitro's resolvability depending on
the state of a shared working tree, and made a clean machine resolve and load Nitro. That is all
three of #117's "Done when" boxes, and each was worth having on its own terms.

It simply answered a different question from the one in the issue's title. The commit cited
[#21](https://github.com/PingoLee/Nitro.jl/issues/21) and closed #208/#209; it never referenced
#117, so the merge never closed it and the issue sat on — carrying a title whose causal claim §2
disproves.

**It is closed now, and this record replaces it.** Keeping it open would have implied a to-do with a
due date, and there is none: the `[sources]` cleanup is genuinely done, and what remains is a
standing cost to be paid *if and when* someone decides to publish. That is a thing to know, not a
thing to finish, which makes it a design record rather than a backlog item.

## 4. Cleared, so nobody re-investigates

Everything below was checked and is **not** what blocks publication. Each row names the file that
actually decides it.

| Candidate blocker | What actually decides it | Verdict |
|---|---|---|
| RegistryCI registry-consistency tests | `RegistryCI/src/registry_testing.jl:195-215` requires every `Deps.toml` UUID to exist in General — and has **zero** weakdep checks. `WeakDeps.toml` and `WeakCompat.toml` are unchecked | not a blocker |
| AutoMerge `meets_compat_for_all_deps` | reads `Deps.toml` / `Compat.toml` only | not a blocker |
| AutoMerge `meets_project_toml_check` | checks that `name`/`uuid`/`version` parse and match the PR; does not reject a `[sources]` section | not a blocker |
| AutoMerge's `Pkg.add` + `import` sandbox | a weakdep is never installed, so the sandbox never sees PormG | passes |
| PormG's own registrability | PormG's `Project.toml` has no `[sources]`; every dep and weakdep (CSV, DataFrames, Decimals, OrderedCollections, Tables, TimeZones, YAML, LibPQ, SQLite, Revise…) is in General; compat entries are upper-bounded | clean |

> **The registry's own consistency tests would happily accept a Nitro whose `WeakDeps.toml` names a
> UUID General has never heard of.** The only thing that stops it is the registration front door. So
> every check you would reach for *after* forming the registration PR comes back green, and the
> failure arrives from the one place nobody reads. That is why this was easy to misdiagnose as a
> `[sources]` problem.

## 5. The routes, and what each actually costs

| Route | `pkg> add Nitro` works | PormG's API becomes a public compat surface | Reversible |
|---|---|---|---|
| **A.** Publish PormG to General, then Nitro | yes | **yes** | no — a registered version cannot be withdrawn |
| **B.** LocalRegistry.jl | only after `Pkg.Registry.add` | no | yes |
| **C.** Stay unregistered (today) | no | no | yes |
| **D.** Move `ext/NitroPormGExt.jl` out of Nitro | yes, **without deciding anything about PormG** | no | yes, but it is an API split |

### A. Publish PormG to General

The only route ending in a bare `add Nitro`, and it is feasible as-is — see the last row of §4. The
cost is not technical: PormG's API becomes a public semver surface under AutoMerge's rules, and the
release-train model that makes breaking changes cheap in *this* repo stops being cheap over there.
Registration is public and irreversible. Afterwards Nitro's `[sources]` entry is deleted and the
two-pins rule in the agent ruleset goes with it — `[compat]` alone.

### B. LocalRegistry.jl — and a correction

[#12](https://github.com/PingoLee/Nitro.jl/issues/12) and #117 both list this as though it were a
step toward General. **It is not.** Registrator resolves a package's deps against the registries
available to *the registry being registered into*; a General registration of Nitro is checked
against General, which does not know PormG whatever a private registry says.

So LocalRegistry means **both** packages live in the private registry, and every consumer must
`Pkg.Registry.add` it before `add Nitro` resolves. It is a decision **not to publish to General at
all** — a legitimate one, but it should be recorded as that rather than listed alongside the others
as a partial step.

### C. Stay unregistered

The honest status quo: `pkg> add https://github.com/PingoLee/Nitro.jl` works today. The cost is no
version resolution for consumers — and that the docs must stop claiming otherwise, which is the
`README.md` and `docs/src/tutorial/first_steps.md` correction landing with this record.

### D. Move the extension out of Nitro

The route the other three obscure. Move `ext/NitroPormGExt.jl` and `test/extensions/pormg_*` into a
`NitroPormG.jl` that depends on both. Nitro's `[weakdeps]`, `[extensions]`, `[extras]`,
`[targets].test` and `[sources]` all lose PormG, `check_deps!` has nothing left to complain about,
and **Nitro becomes registrable without any decision about PormG at all.** Honestly costed:

- `src/exts.jl`'s partial definitions (`pormg_nitro_worker`, `pormg_nitro_session`,
  `sync_pormg_env!`) become a **public** extension point rather than an internal one, so the thing
  they extend has to be designed rather than implied.
- The worker/session/env extension tests leave Nitro's suite and stop gating Nitro changes — and
  `test/runtests.jl`'s incomplete-environment refusal
  ([#128](https://github.com/PingoLee/Nitro.jl/issues/128)) loses the dependency it was built
  around.
- Two hard stops need a new home: nitro-core §6 (`PormG` may be imported only inside
  `ext/NitroPormGExt.jl`) and workers §6 (worker DB logic lives only there).
- It inverts the dependency direction: today Nitro optionally knows about PormG; afterwards a third
  package knows about both. That is the standard Julia answer, and a new release surface.

**What it buys that A does not:** it is the only route that publishes Nitro without making PormG's
API public.

## 6. The acceptance test #117 is missing

#117's stated test — *a clean machine with no sibling checkout can resolve and load Nitro* — **is
already true**, which is exactly why the issue looks done. The test that is not:

> Every UUID in `[deps]` **and** `[weakdeps]` exists in the target registry.

Cheap to check by hand before opening any registration PR: list the six `[weakdeps]` UUIDs and look
each one up. Five are in General; `PormG = "7d8d7541-4d3d-4580-80a2-17064efb0993"` is not. That is
the whole gate.

**Not a gate, but owed the day registration lands: restore TagBot.** The
[TagBot](https://github.com/JuliaRegistries/TagBot) workflow was removed in
[#332](https://github.com/PingoLee/Nitro.jl/issues/332). Before registration it has nothing to do,
because nothing comments as `JuliaTagBot`. Its job-level `if:` skipped every other comment, but a
`workflow_dispatch` still ran a mutable `@v1` tag with `contents: write` and the deploy key, for no
benefit. Re-add the standard `.github/workflows/TagBot.yml` from TagBot's README,
pinned by commit SHA like every other action (`test/ci_workflow_tests.jl` enforces the pin).
[`nitro-cut-release`](../../.github/skills/nitro-cut-release/SKILL.md) already emits the `vX.Y.Z`
tags TagBot will continue.

## 7. Decision: not taken

The finding is what ships. **No route is chosen, and no timetable is implied** — it is a maintainer
decision with a public, irreversible arm (A) and an architectural arm (D), and neither should be
taken as a side effect of documenting the blocker. Readiness to publish is subjective and separate
from this record: nothing here says Nitro *should* be published, only what it would cost when
someone decides it should be.

This record is the memory, not an open issue. It is deliberately not tracked as a to-do, because a
standing open item invites someone to "clear" it and treat an empty backlog as permission.

Re-read this record when any of the following becomes true:

- Someone outside asks for `pkg> add Nitro`, which makes C's cost concrete rather than theoretical.
- PormG is published for its own reasons, which collapses the decision into A at no extra cost.
- The PormG extension grows large enough that D is worth doing on its own merits.
- A RegistryTools release changes `check_deps!`'s treatment of weakdeps (§1), retiring the gate.

## 8. See also

- [#117](https://github.com/PingoLee/Nitro.jl/issues/117) — closed in favour of this record; its
  title asserted a cause (`[sources]`) that §2 disproves.
- [#12](https://github.com/PingoLee/Nitro.jl/issues/12) — closed as a two-line stub; §5B is why it
  is not a substitute for this record.
- [#21](https://github.com/PingoLee/Nitro.jl/issues/21) — the supply-chain half, closed by the same
  commit that satisfied #117's checkboxes.
- [`Project.toml`](../../Project.toml) — both pins, and the `[weakdeps]` list §6 tells you to walk.
- [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) — the PormG-pin comment block, and
  the `Operations.jl` reading §2 builds on.
- [`docs/design/agent-security.md`](agent-security.md) — its re-read triggers include publication to
  the General registry.
