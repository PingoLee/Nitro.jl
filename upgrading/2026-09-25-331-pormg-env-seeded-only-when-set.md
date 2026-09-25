## `sync_pormg_env!` — `PORMG_ENV` is seeded only from a `NITRO_ENV`/`GENIE_ENV` you set, so `default_env:` decides again without one (#331)

- **Version**: Unreleased
- **Nitro ref**: [#331](https://github.com/PingoLee/Nitro.jl/issues/331) ;
  `ext/NitroPormGExt.jl`, `src/environment.jl`, `src/exts.jl`, `docs/src/tutorial/environment.md`
- **Recorded**: 2026-09-25
- **Severity**: **behavior change, and it changes SILENTLY.** It affects apps that load PormG,
  set **neither** `NITRO_ENV` nor `GENIE_ENV`, and have a `default_env:` other than `dev` in
  `connection.yml`. Nothing throws and nothing is logged; the app connects to a different
  environment's database section than it did on the previous release. Code that reads
  `ENV["PORMG_ENV"]` directly, with neither variable set, now gets a `KeyError`. It partly
  reverses the [#55 entry](2026-09-12-55-nitro-env-seeds-pormg-env.md).

### What changed

Since #55, loading PormG published Nitro's environment to `ENV["PORMG_ENV"]`, and `PORMG_ENV`
outranks `default_env:` in PormG's precedence:

```
env= kwarg  >  ENV["PORMG_ENV"]  >  default_env: in connection.yml  >  "dev"
```

With no `NITRO_ENV` set, the value published was Nitro's own fallback, `"dev"`. That is a
default nobody chose, and it outranked the `default_env:` somebody did write. A production box
relying on `default_env: prod` connected to its **dev** database. Meanwhile the tutorial promised
that "PormG's precedence is unchanged".

Now the bridge publishes only an environment that was actually set:

| `NITRO_ENV` / `GENIE_ENV` | `PORMG_ENV` at `using PormG` | Before | After |
|---|---|---|---|
| set, e.g. `prod` | unset or blank | seeded `prod` | seeded `prod` (unchanged) |
| any | set, e.g. `test` | kept `test` | kept `test` (unchanged) |
| **neither set** | unset | seeded `"dev"`, so `default_env:` was ignored | **left unset**, so `default_env:` decides, then PormG's `"dev"` |
| **neither set** | blank (`PORMG_ENV=`) | overwritten with `"dev"` | **removed**, so `default_env:` decides |

`current_env()` is unchanged: with nothing set it still returns `"dev"`, and the banner still
says `Environment: dev`. So on the rows above, the banner and PormG can now disagree. Nothing is
gated on `current_env()`, so that difference is cosmetic, but it is a reason to set `NITRO_ENV`
anyway.

`sync_pormg_env!` changes with it:

- It returns `nothing` when `PORMG_ENV` ends up unset; it used to always return a `String`.
- `force = true` still overwrites an existing `PORMG_ENV`, but only with an environment that
  was set. With neither variable set it writes nothing.

The #55 entry promised that `ENV["PORMG_ENV"]` was "always present once PormG is loaded". That
no longer holds: with neither `NITRO_ENV` nor `GENIE_ENV` set, it is absent, and code that
reads it with `ENV["PORMG_ENV"]` throws a `KeyError`.

### How to find the calls to migrate

```bash
# 1. Does any connection.yml name a default_env other than dev? Only those apps can move.
rg -n '^\s*default_env\s*:' <app> --glob '*.yml' --glob '*.yaml'

# 2. Is NITRO_ENV (or GENIE_ENV, or PORMG_ENV) SET -- exported, not merely read -- wherever
#    the app runs? If one is, the bridge behaves exactly as before. Hits that only READ one
#    are step 4's business, not an answer to this.
rg -n 'NITRO_ENV|GENIE_ENV|PORMG_ENV' <app> .env* Dockerfile* docker-compose* *.service deploy/ 2>/dev/null

# 3. Code that uses sync_pormg_env!'s return value as a String.
rg -n 'sync_pormg_env!' <app>/src <app>/test

# 4. Code that reads PORMG_ENV assuming the bridge always set it. With nothing set, it throws.
rg -n 'ENV\["PORMG_ENV"\]' <app>/src <app>/test
```

**Check both directions** for an app that hits step 1 but not step 2. A server that followed the
#55 entry, by deleting `default_env:` and setting `NITRO_ENV`, is fine. One that did not was
running on dev and now moves to its `default_env:`. That also means a developer laptop whose
committed `connection.yml` says `default_env: prod`, with no `NITRO_ENV` exported, now connects
to **prod**.

### Migrate your app

Pick the environment explicitly wherever the process starts. This was the recommended setup
after #55 and is unaffected by this change:

```bash
# systemd unit, Dockerfile, compose, CI -- and your shell profile for local work
NITRO_ENV=prod    # or dev / test
```

To keep a laptop on dev without exporting anything, make the file say so:

```yaml
# connection.yml -- before: `default_env: prod` was ignored while Nitro published "dev"
default_env: prod

# after: the file is honoured again, so name the environment it should pick
default_env: dev
```

A caller of `sync_pormg_env!` that used the return value:

```julia
# ✗ before -- always a String
env = sync_pormg_env!()
@info "PormG environment" env

# ✓ after -- `nothing` means PormG resolves its own (default_env:, then "dev")
env = something(sync_pormg_env!(), "<PormG default>")
@info "PormG environment" env
```

The same applies to a direct read of the variable:

```julia
# ✗ before -- KeyError now, when neither NITRO_ENV nor GENIE_ENV is set
env = ENV["PORMG_ENV"]

# ✓ after
env = get(ENV, "PORMG_ENV", nothing)   # `nothing`: PormG resolves its own
```
