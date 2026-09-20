## PormG compat moves to `^0.4` — apps on the PormG extension must upgrade PormG too

- **Version**: 0.2.0
- **Nitro ref**: `Project.toml` `[compat]`; `ext/NitroPormGExt.jl`
- **Recorded**: 2026-08-10
- **Severity**: **breaking (dependency resolution)** — an app still bounded to PormG `0.3` does not
  resolve against this release.

### What changed

Nitro's bound moved from `PormG = "^0.3"` to `PormG = "^0.4"`. PormG 0.4.0 is a breaking release
train of its own, carrying 17 entries.

**Nitro itself needed no source change.** Every one of those 17 entries was checked against
`ext/NitroPormGExt.jl` with its own *"How to find the calls to migrate"* grep, and all came back
empty — Nitro's PormG surface is two models with no foreign keys, no `ManyToManyField`, no bulk
writes, no introspection, and no `catch` that reads a PormG error type.

**Your app's surface is not that narrow.** Its own models, queries, and migrations are exactly what
PormG 0.4.0 changes, so the work is in PormG's guide, not this one. The runtime change most likely
to reach an app silently is **SQLite now enforcing foreign keys** (PormG #276): writes that
succeeded on SQLite and only failed in PostgreSQL now raise `IntegrityError` on both. Nitro's own
`nitro_session` and `nitro_task` tables declare no foreign keys, so that enforcement does not touch
them.

### How to find the calls to migrate

```bash
# Does this app use the PormG extension at all? If not, only the dependency bound matters.
rg -n 'pormg_nitro_session|pormg_nitro_worker|PormGSessionStore|PormGWorkerStore' <app>/src

# The app's own PormG bound — this is what must move.
rg -n 'PormG' <app>/Project.toml
```

### Migrate your app

```julia
# 1. Raise the app's own bound in Project.toml [compat]:
#      PormG = "^0.4"
#
# 2. Run PormG's guide from PormG's OWN environment — it is a weak dependency here, so it does not
#    load from the app's env — and apply every entry it lists before bumping the bound:
#      julia --project=/path/to/PormG.jl -e 'using PormG; PormG.upgrade_guide(from = v"0.3.0")'
#
# 3. Re-run the app's suite against SQLite specifically. Foreign-key enforcement is the change that
#    passes a code review and fails at runtime.
```
