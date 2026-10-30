# Environment

Nitro resolves **one** environment for the process and exposes it as
[`current_env()`](@ref). It is one of exactly three values:

```
"dev"   "prod"   "test"
```

```julia
using Nitro

current_env()      # "dev"
```

## Resolution order

First one that is set wins:

| # | Source | Notes |
|---|--------|-------|
| 1 | `NITRO_ENV` | Nitro's own variable |
| 2 | `GENIE_ENV` | fallback, for apps migrating from Genie |
| 3 | `"dev"` | the default |

Empty or whitespace-only values count as **unset**, so a shell accident like
`export NITRO_ENV=$SOME_UNSET_VAR` falls through to the next source instead of failing.
Surrounding whitespace on a real value is trimmed (`" prod "` resolves to `"prod"`). Matching
is **case-sensitive** — `NITRO_ENV=PROD` is rejected, though the error says what you meant.

```bash
NITRO_ENV=prod julia --project -e 'using Nitro; println(current_env())'   # prod
GENIE_ENV=prod julia --project -e 'using Nitro; println(current_env())'   # prod
julia --project -e 'using Nitro; println(current_env())'                  # dev
```

`current_env()` reads the environment **fresh on every call** — it is not cached, so `withenv`
works as you would expect in tests.

## An unrecognised value is an error

Nitro validates against the three names above rather than accepting anything:

```
$ NITRO_ENV=prodution julia --project -e 'using Nitro; serve()'
ERROR: ArgumentError: Invalid `NITRO_ENV` value "prodution". Expected one of "dev", "prod", or "test".
```

This is stricter than Rails, ASP.NET Core, Spring or Genie, all of which accept arbitrary
names. The trade is deliberate: the typo that silently runs production as development is the
single most common failure of an unvalidated environment variable, and an unrecognised value
here is always a mistake rather than a choice.

`GENIE_ENV` is validated the same way, but its error points at the fix that does not break your
Genie half:

```
ERROR: ArgumentError: Invalid `GENIE_ENV` value "staging". Expected one of "dev", "prod", or "test". Nitro reads `GENIE_ENV` only as a fallback; set `NITRO_ENV` to override it.
```

**Where the error surfaces.** [`serve()`](@ref) resolves the environment before it binds a
listener, so a bad value fails at startup whether or not the banner is shown. The startup
banner always names the resolved environment, including the default:

```
 Nitro <version>  (8 threads)
2026-09-12 14:02:11
Environment: dev
Starting server at http://127.0.0.1:8080
```

## Bridging to PormG

**Name the environment at the `load` call.** Outside an interactive session PormG refuses a
`load`, `load_many` or `register_connection` that names no environment, rather than guess one: a
service, a script, a test run and a precompile worker are all outside one. Name it as the app
`Nitro.newapp` writes does:

```julia
# In your package's main(; root = pkgdir(@__MODULE__), kwargs...), as Nitro.newapp writes it
env = something(sync_pormg_env!(), current_env())
PormG.Configuration.load_many(["db"]; root, env)
```

That is a `PORMG_ENV` the deployment set, else `NITRO_ENV` (or `GENIE_ENV`), which
[`sync_pormg_env!`](@ref) publishes as `PORMG_ENV` and returns, else `current_env()`'s `"dev"`.
So `connection.yml` needs a block for every environment you run in, a `prod:` block for
`NITRO_ENV=prod`, and its `default_env:` is not read. Without a `PORMG_ENV` of its own, PormG
then uses the environment the startup banner reports.

With `PormG` loaded, Nitro also publishes the environment you set in `NITRO_ENV` (or
`GENIE_ENV`) to `ENV["PORMG_ENV"]`, the variable PormG's loader consults, so a `load` with no
`env=` gets it too, when it is set:

```julia
using Nitro, PormG

# ENV["PORMG_ENV"] has already been seeded from NITRO_ENV.
PormG.Configuration.load_many(["db"])
```

It is a **default, never a force**. PormG's precedence is unchanged:

```
env= kwarg  >  ENV["PORMG_ENV"]  >  in a REPL only: default_env: in connection.yml, else "dev"
```

so both of these still win over the bridge:

```julia
ENV["PORMG_ENV"] = "test"                      # set before `using PormG` -- survives untouched
PormG.Configuration.load("db"; env = "test")   # explicit kwarg -- always wins
```

**Only an environment you set is published.** With neither `NITRO_ENV` nor `GENIE_ENV` set,
`current_env()` reports `"dev"`, but that is Nitro's fallback, not a choice, so the bridge
writes nothing, and a `load` with no `env=` is left to PormG. The `current_env()` behind
`something(sync_pormg_env!(), …)` is how you choose that fallback for PormG too.

| `NITRO_ENV` / `GENIE_ENV` | `PORMG_ENV` before `using PormG` | a `load` with no `env=` uses |
|---|---|---|
| set, e.g. `prod` | unset or blank | `prod`, published by the bridge |
| set | set, e.g. `test` | `test`: yours survives |
| neither set | unset or blank | in a REPL, `default_env:` from `connection.yml`, else `"dev"`; anywhere else PormG refuses it |

!!! warning "Set `NITRO_ENV` before `using`"
    Nitro seeds `ENV["PORMG_ENV"]` once, when the PormG extension loads — that is, at
    `using PormG`. Setting `NITRO_ENV` *after* that point still changes what `current_env()`
    returns, but `PORMG_ENV` keeps the value it was seeded with, or stays unset.

    The seed is also skipped during **precompilation**, deliberately: a compile worker must
    not mutate the process environment. Load configuration at run time, from `main()` as the
    generated app does, not from a module body: a module body runs only at precompile time,
    where PormG's configuration does not survive into the session.

    This is the same rule as `RAILS_ENV`, `MIX_ENV` and `NODE_ENV`: the environment is a
    property of the process, decided before it starts, not during. If you must change it
    afterwards, call [`sync_pormg_env!`](@ref) with `force=true` — and note that any
    `PormG.Configuration.load*` call already made keeps the environment it resolved.

    ```julia
    ENV["NITRO_ENV"] = "prod"     # decided late
    sync_pormg_env!(force = true) # republish it
    ```

If the environment cannot be resolved when the extension loads — a typo in `NITRO_ENV` — the
bridge **warns and skips** rather than throwing. An `__init__` that threw would make
`using PormG` fail outright, taking down the REPL session you would use to diagnose it. The
fatal check stays in `serve()`.

## What this is *not* for

`current_env()` **reports** the environment. It must not **gate** behavior that matters for
security.

Do use it for: choosing which config file to load, log verbosity, the startup banner, deciding
which seed data to install.

Do **not** use it to decide whether to render error details, relax an authentication or CSRF
check, or expose a debug route. Django's `DEBUG` and Express's `NODE_ENV` are the cautionary
precedent here — a process-wide flag is the thing that is left on in production exactly once,
and Nitro's own error types are deliberately built so that no such switch exists (see
[`ValidationError`](@ref), whose `.cause` is opt-in per call rather than environment-gated).

For the same reason Nitro deliberately ships **no** `isdev()` / `isprod()` / `istest()`
predicates. Their only real contribution would be to make that kind of gating ergonomic.

```julia
# Fine.
config = load_config(current_env())

# Not fine -- this is the failure mode the design avoids.
if current_env() == "dev"
    show_full_stack_traces!()
end
```

## Environment *files* are still the app's job

Nitro resolves the environment **name**. Choosing what that name means — `config/env/dev.jl`,
a YAML block, a `.env` file — stays in the application layer, along with the typed config
struct it produces. See [Application Config Example](app_config.md) for the recommended shape and
[Managing Secrets](secrets.md) for keeping credentials out of it.
