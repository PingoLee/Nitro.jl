## `NITRO_ENV` now seeds `ENV["PORMG_ENV"]`, which overrides `default_env:` in `connection.yml` (#55)

- **Version**: Unreleased
- **Nitro ref**: #55; `src/environment.jl` (new), `src/core.jl`, `src/exts.jl`,
  `ext/NitroPormGExt.jl`, `docs/src/tutorial/environment.md`
- **Recorded**: 2026-09-12
- **Severity**: **behavior change, and it changes SILENTLY** — part of the `0.1.x` pre-publish
  wave. Only apps that load PormG *and* rely on `default_env:` are affected; nothing throws and
  nothing is logged, the app simply connects to a different environment's database section.

### What changed

Nitro now resolves an environment of its own — `NITRO_ENV`, then `GENIE_ENV`, then `"dev"` —
exposes it as `current_env()`, and, when the PormG extension loads, publishes it to
`ENV["PORMG_ENV"]` unless that variable is already set. That is what lets an app call
`PormG.Configuration.load_many(["db"])` with no `env=`.

The catch is where `ENV["PORMG_ENV"]` sits in PormG's precedence:

```
env= kwarg  >  ENV["PORMG_ENV"]  >  default_env: in connection.yml  >  "dev"
```

`PORMG_ENV` ranks **above** `default_env:`. Before this change it was normally absent, so
`default_env:` decided. Now it is always present once PormG is loaded, so `default_env:` is
never consulted — and with no `NITRO_ENV` set, the value Nitro publishes is `"dev"`.

An app with `default_env: prod` in its `connection.yml` and no `NITRO_ENV` in its environment
therefore moves from **prod** to **dev**, silently, and connects to the wrong database.

Two things are unaffected. An explicit `env=` at the call site still wins — it outranks
`PORMG_ENV`. And a `PORMG_ENV` the app sets itself is never overwritten; the bridge is a
default, not a force.

This direction is deliberate: PormG's own guidance is that a server should let its host resolve
the environment and pass it down, with `default_env:` a convenience for scripts and single-env
apps. A Nitro app is a server.

### How to find the calls to migrate

```bash
# 1. Does any connection.yml rely on `default_env:`? Any hit needs the edit below.
rg -n '^\s*default_env\s*:' <app> --glob '*.yml' --glob '*.yaml'

# 2. Does the app set NITRO_ENV (or GENIE_ENV, or PORMG_ENV) anywhere already?
#    If one of these is set wherever the app runs, you are already fine.
rg -n 'NITRO_ENV|GENIE_ENV|PORMG_ENV' <app> .env* Dockerfile* docker-compose* *.service 2>/dev/null

# 3. Per-call `env=` keeps working, and can now be dropped -- but only after step 1 or 2.
rg -n 'Configuration\.load(_many)?\(' <app>/src
```

### Before → after

Set the environment where the process is launched, and delete the file default:

```yaml
# connection.yml -- before
default_env: prod
prod:
  adapter: postgresql
  # ...
```

```yaml
# connection.yml -- after: `default_env:` is inert once PormG is loaded under Nitro
prod:
  adapter: postgresql
  # ...
```

```bash
# and set it where the process starts -- systemd unit, Dockerfile, compose, CI
NITRO_ENV=prod
```

If you would rather not touch deployment, keep the old behavior by setting `PORMG_ENV`
yourself before `using PormG` — the bridge never overwrites a value that is already there.
One exception: a **blank** or whitespace-only `PORMG_ENV` counts as unset and *is* seeded, so
`PORMG_ENV=` in a `.env` file or `PORMG_ENV: ""` in a compose file will not hold the bridge
off. Give it a real value:

```julia
# before
using Nitro, PormG
PormG.Configuration.load_many(["db"])     # picked up `default_env:`

# after -- explicit, and equivalent
ENV["PORMG_ENV"] = "prod"
using Nitro, PormG
PormG.Configuration.load_many(["db"])
```

### The second half: these variables are now validated, and `GENIE_ENV` is now read

This part affects apps that do **not** use PormG too.

`NITRO_ENV` was previously read in exactly one place, printed on the banner, and never checked —
`NITRO_ENV=staging` started a server fine. `GENIE_ENV` was not read at all. Now `serve()`
resolves both and throws `ArgumentError` on anything outside `"dev"` / `"prod"` / `"test"`.

So a box exporting `NITRO_ENV=staging` — or a Genie migrant with `GENIE_ENV=staging` still
exported, which is precisely the audience the fallback was added for — goes from *starts* to
*refuses to start*, having changed nothing.

```bash
# Any hit whose value is not dev/prod/test is a box that will stop booting.
rg -n 'NITRO_ENV|GENIE_ENV' <app> .env* Dockerfile* docker-compose* deploy/ 2>/dev/null
```

```bash
NITRO_ENV=staging     # before: started, banner said "staging"
NITRO_ENV=prod        # after:  pick one of dev/prod/test
```

Blank is not affected: an empty or whitespace-only value counts as unset and falls through, so
`export NITRO_ENV=$SOME_UNSET_VAR` is harmless. Matching is case-sensitive — `PROD` throws, with
a "did you mean" hint.

If an app genuinely needs an environment outside the three, drive PormG through `PORMG_ENV`
directly (unvalidated, and it suppresses the bridge) and leave **both** `NITRO_ENV` and
`GENIE_ENV` unset — `GENIE_ENV` is validated too, so leaving `GENIE_ENV=staging` in place
still refuses to boot.

### The third half: `current_env` is a new export and can collide

`Nitro` now exports `current_env`. If your app defines its own `current_env` **in the same
module** that does `using Nitro`, yours shadows Nitro's and nothing breaks. But if it lives in
a submodule that exports it — `MyApp.Config`, `MyApp.Env` — and both are brought in:

```julia
using Nitro
using MyApp.Config      # also exports `current_env`
```

then the name resolves to neither, and you get `UndefVarError: current_env not defined` at the
point of **use**, not at load. So it survives `using`, survives precompilation, and fires when
that code path first runs.

This is likely to hit exactly the apps this change is aimed at — a per-app environment resolver
in a `Config` submodule is the shape #55 exists to delete.

```bash
rg -n 'export current_env|function current_env|current_env\s*=' <app>
```

Pick one: delete the app's own resolver and use Nitro's (the point of this change), or
disambiguate with `import MyApp.Config: current_env`, or qualify at each call site. The same
applies in principle to `sync_pormg_env!`, though a collision there is unlikely.

An app that does not use PormG, does not rely on `default_env:`, defines no colliding
`current_env`, and sets `NITRO_ENV`/`GENIE_ENV` either to a recognised value or not at all,
needs no change.
