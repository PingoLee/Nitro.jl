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
- Environment-specific files (`config/env/dev.jl`, etc.) are an **app** convention, not core Nitro.
- **Secrets must not be committed**; use env vars or non-committed local config.
- Allow env vars to override file-based app config for deployment.

## 5. PormG and external integrations
- PormG connection settings and model loading are **app-owned** or live in `ext/NitroPormGExt.jl`.
- Keep Nitro core database-agnostic; integration hooks stay generic.

## 6. Developer experience
- Document one recommended app bootstrap pattern in docs when touching tutorials.
- Config must be swappable in tests without mutating framework-global state.
- **Multiple Nitro apps in one process is the design target, not the current state.** The
  process-wide `CONTEXT[]` singleton (`src/Nitro.jl`, `src/methods.jl`) still backs the top-level
  API, so two apps in one process share a router and an app context, and
  `internalrequest(context=…)` races a live server — tracked in
  [#31](https://github.com/PingoLee/Nitro.jl/issues/31). Do not write docs or tests that assume it
  already works. **Do** write new code against the explicit `(ctx::ServerContext, …)` methods (or
  `instance(...)`), which is the path to closing that gap.
