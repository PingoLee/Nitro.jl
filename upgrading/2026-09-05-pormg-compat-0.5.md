## The `PormG` pin moves to `^0.5`, which is a breaking PormG release (#PormG 0.5.0)

- **Version**: 0.3.0
- **Nitro ref**: `Project.toml` (`[compat]`); `ext/NitroPormGExt.jl` (unchanged)
- **Recorded**: 2026-09-05
- **Severity**: **breaking for the app, not for Nitro** — Nitro's own PormG surface needs no edit,
  but a consuming app pinned to Nitro now resolves PormG `0.5.x`, and PormG 0.5.0 carries 22
  breaking entries of its own.

### What changed

`[compat]` moves from `PormG = "^0.4"` to `PormG = "^0.5"`. Nothing in `ext/NitroPormGExt.jl`
changed: every symbol it reaches — `PormG.Models.Model` and the `CharField`/`TextField`/
`DateTimeField`/`FloatField` constructors, `PormG.connection`, `PormG.Configuration.load`,
`PormG.Dialect.create_table`/`create_index`, `PormG.ConnectionPool.fetch` and
`PormG.register_ignore_tables!` — still resolves on 0.5.0, and the extension's two forward-compat
hooks are `isdefined`-guarded. The extension tests pass unchanged.

None of PormG 0.5.0's 22 breaking entries touches Nitro, because Nitro's ORM use is deliberately
narrow: two flat models with no relations, no CTEs, no `cjoin_on`, no `F(...)` expressions, no
`bulk_update`, no Django import, and no `AutoField`. The entries cluster on exactly those features.

**The break is transitive.** If your app uses PormG directly — and an app that gave Nitro a
`PormGSessionStore` or `PormGWorkerStore` almost certainly does — upgrading Nitro drags your PormG
with it, and *your* query code is what has to move.

### How to find the calls to migrate

Do not grep for this one. Run PormG's own guide, which renders only the slice newer than your pin,
and follow each entry's migration note:

```bash
# From PormG's environment, not Nitro's -- PormG is a weakdep here.
julia --project=../PormG.jl -e 'using PormG; PormG.upgrade_guide(from = v"0.4.0")'
```

The entries most likely to reach an ordinary app, in rough order of blast radius:

| PormG entry | What breaks |
|---|---|
| #481 | `F("alias.col")` is removed; use `Joined(alias, col)` |
| #444 | CTE columns are `CTE(name, path)`, not `"<cte>__col"` strings |
| #411 | A wrong-typed filter value raises `FilterError`, not `InvalidValueError` |
| #408/#409/#417 | `AutoField` is retired |
| #345/#346 | Django-import app prefix moves to `db_table`; `ignore_table` and `Model_to_str`'s `settings` are gone |
| #358 | Row-level writes no longer auto-resync PostgreSQL sequences — call `resync_sequences` yourself |

### Migrate your app

```julia
# Nitro side: nothing. Your Project.toml already tracks Nitro; the PormG bound follows.
# App side: work PormG's guide above, then re-run your suite.
```

If you do not use PormG at all, there is nothing to do — it is a weak dependency, and the extension
only loads when you load PormG yourself.
