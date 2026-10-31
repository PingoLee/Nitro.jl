## `Nitro.newapp` — the generated boot finds `db/` from a `root` keyword, and a `main.jl` entry catches a failed start-up

- **Version**: 0.7.0
- **Nitro ref**: #798 ; `src/newapp.jl`, `ext/NitroPormGExt.jl` (`_newapp_pormg`);
  `docs/src/tutorial/bigger_applications.md`, `docs/src/tutorial/deployment.md`,
  `docs/src/tutorial/environment.md`
- **Recorded**: 2026-10-30
- **Severity**: behavior change (the generated app). Nitro's own API is unchanged. An app that
  `newapp` wrote earlier keeps working under the JIT. As a JuliaC executable it does not start, and
  if its boot fails before `serve`, the error's values can reach the log.

### What changed

The `main` that `Nitro.newapp(name; pormg = true)` writes found `db/` with `pkgdir(@__MODULE__)`.
In a JuliaC executable that is the temporary copy of the project the image was built from, which
JuliaC deletes afterwards, so the executable failed with `MissingConfigurationError` before it
listened. `@__DIR__` has the same problem. `main` now takes the folder as a keyword,
`root::AbstractString = pkgdir(@__MODULE__)`. The default keeps `MyApp.main()` working from any
directory under the JIT.

`newapp` also writes `main.jl`, the program (`julia --project main.jl`, or a JuliaC build's entry
file). Its `(@main)` calls `main` inside a `try`, and with PormG it passes
`root = get(ENV, "APP_ROOT", pwd())`. When start-up fails, the `catch` prints
`Nitro.startup_failure_text(e)` on `Core.stderr` and returns `1`, and it rethrows an
`InterruptException`. Without that catch, an exception from what `main` runs before `serve`
(`load_many`, `worker_startup`, `urlpatterns`) escapes raw. A compiled executable's fatal printer
writes the exception's fields, which can include a password or a key. `serve` already catches its
own errors this way (#749, #752); this covers the code before it.

### How to find the calls to migrate

In an app `newapp` wrote before this change:

```
grep -rn 'pkgdir(@__MODULE__)' src/
ls main.jl
```

A hit in `main`, or no `main.jl`, means the app has the old boot. Only an app that is, or will be,
built with JuliaC needs to change.

### Migrate your app

```julia
# ✗ before (src/MyApp.jl)
function main(; kwargs...)
    env = something(sync_pormg_env!(), current_env())
    PormG.Configuration.load_many(["db"]; root = pkgdir(@__MODULE__), env)
    PormG.Models.set_models(models, joinpath(pkgdir(@__MODULE__), "db"))
    # ...
end

# ✓ after (src/MyApp.jl)
function main(; root::AbstractString = pkgdir(@__MODULE__), kwargs...)
    env = something(sync_pormg_env!(), current_env())
    PormG.Configuration.load_many(["db"]; root, env)
    PormG.Models.set_models(models, joinpath(root, "db"))
    # ...
end
```

Then add `main.jl` next to `Project.toml`. Generate a throwaway app with
`Nitro.newapp("MyApp")` and copy its `main.jl`, or copy the one shown in the *Bigger Applications*
tutorial, and replace `MyApp` with your module's name. Run the executable from the app's
directory, or set `APP_ROOT` to the folder that holds `db/`.
