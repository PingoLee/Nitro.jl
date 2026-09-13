---
description: Nitro.jl app configuration — no framework singleton, typed app config, bootstrap order, secrets
applyTo: "**/*.jl"
---

# Nitro.jl Configuration & Bootstrap

When designing configuration, bootstrapping applications, or proposing developer ergonomics for **Nitro.jl**, follow these rules:

## 1. Config ownership
- **Nitro provides the pipeline, not the schema**: Hooks and conventions for loading app config are fine; the config object lives in the application layer.
- **No global `Nitro.config` singleton**: Do not add a Genie-style mutable framework-wide config object.
- **Typed app config**: Applications define their own structs (`AppConfig`, `ServerConfig`, `AuthConfig`, `WorkerConfig`, `DatabaseConfig`, etc.).

## 2. Bootstrap flow
- **Explicit startup only**: load config → resolve secrets/env → run initializers → build routes/middleware → `serve(context=...)`.
- **Use app context for shared config**: Inject through Nitro app context, not hidden globals.
- **No implicit auto-loading** that obscures startup order.

## 3. Separation of concerns
- **Framework config stays small**: host/port, cookies, middleware composition, request handling.
- **App config stays in the app**: auth, workers, PormG, feature flags, business rules.
- **Do not move app-specific config into Nitro `src/`**.

## 4. Environment strategy
- Environment **files** (`config/env/dev.jl`, etc.) are an **app** convention, not core Nitro.
  Environment **resolution** is core Nitro as of [#55](https://github.com/PingoLee/Nitro.jl/issues/55):
  `current_env()` ([`src/environment.jl`](../../src/environment.jl)) resolves and validates
  `NITRO_ENV` (then `GENIE_ENV`, then `"dev"`) against a closed set, and `NitroPormGExt`
  publishes it to `ENV["PORMG_ENV"]` as a default. Apps consume the name; they no longer
  derive it. `current_env()` **reports** and must never **gate** — see `src/errors.jl`.
- **Secrets must not be committed**; use env vars or non-committed local config.
- Allow env vars to override file-based app config for deployment.

## 5. PormG and external integrations
- PormG connection settings and model loading are **app-owned** or live in `ext/NitroPormGExt.jl`.
- Keep Nitro core database-agnostic; integration hooks stay generic.

## 6. Developer experience
- Document one recommended app bootstrap pattern in docs when touching tutorials.
- Config must be swappable in tests without mutating framework-global state.
- **Multiple Nitro apps in one process is supported — build on `App`, not the singleton
  ([#31](https://github.com/PingoLee/Nitro.jl/issues/31)).** `App` is the public application
  handle (`src/context.jl`): its own router, middleware, cookie config, lifecycle hooks and app
  context. Every public routing, serving and cookie function takes one as its first argument.

  ```julia
  app = App(mod = @__MODULE__)
  urlpatterns(app, "", Routes.urlpatterns(config))
  serve(app; port = 8080, context = config)
  ```

  **Pass `mod = @__MODULE__` at the call site.** It is what `serve(revise = :lazy|:eager)`
  tracks, and a `@__MODULE__` *default* would expand inside Nitro rather than in your module —
  which is why `App` does not have one.

  The process-wide `CONTEXT[]` singleton (`src/Nitro.jl`, `src/methods.jl`) still backs the
  argument-less forms and is the single-app convenience layer. Prefer an explicit `App` in new
  code and in tests: it is what lets two apps coexist, and it keeps a test off shared state that
  `resetstate()` would otherwise have to scrub. `instance()` is **gone** — it re-included the
  whole package from disk; `App` replaces it outright.
