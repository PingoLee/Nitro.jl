# Nitro.jl Configuration & Bootstrap Instructions

When designing configuration, bootstrapping applications, or proposing developer ergonomics for **Nitro.jl**, follow these rules strictly:

## 1. Config Ownership
- **Nitro provides the pipeline, not the schema**: Nitro.jl may provide hooks and conventions for loading app config into runtime, but the actual config object must live in the application layer.
- **No global `Nitro.config` singleton**: Do not add a Genie-style mutable framework-wide config object.
- **Typed app config**: Applications should define their own typed config structs such as `AppConfig`, `ServerConfig`, `AuthConfig`, `WorkerConfig`, or `DatabaseConfig`.

## 2. Bootstrap Flow
- **Explicit startup flow only**: Prefer this order: load config -> resolve secrets/env -> run initializers -> build routes/middleware -> call `serve(context=...)`.
- **Use app context for shared config**: Shared application config should be injected through Nitro app context, not hidden globals.
- **Do not hide config loading in framework magic**: Avoid implicit file auto-loading behavior that makes startup order difficult to reason about.

## 3. Separation of Concerns
- **Framework config stays small**: Nitro core should only manage transport/runtime concerns such as server host/port, cookies, middleware composition, and request handling.
- **App config stays in the app**: Auth settings, worker settings, PormG settings, feature flags, and application business rules belong to the application.
- **Do not move app-specific config into `src/`**: Nitro core must remain reusable across unrelated projects.

## 4. Environment Strategy
- **Environment-specific config belongs to the app**: If an app wants `config/env/dev.jl`, `config/env/prod.jl`, or similar, that is an application convention, not a Nitro core responsibility.
- **Secrets must not be committed**: Do not recommend checked-in plaintext secrets files. Sensitive values should come from environment variables or non-committed local config.
- **Prefer reproducible overrides**: Allow environment variables to override file-based app config when needed for deployment.

## 5. PormG and External Integrations
- **PormG config is app-owned**: Connection settings, repositories, model loading, and database wiring belong to the app or a weak-dependency extension, not Nitro core.
- **Keep Nitro database-agnostic**: Do not add framework-level assumptions about PormG schema, connection lifecycle, or repository structure.
- **If Nitro exposes integration hooks, keep them generic**: Hooks should support external apps without importing their dependencies into core `src/`.

## 6. Developer Experience
- **Document one recommended app bootstrap pattern**: Nitro should provide a clear example for how an app loads config and starts the server.
- **Optimize for testability**: Config must be easy to swap in tests without mutating framework-global state.
- **Support multi-app scenarios**: Configuration design must work cleanly when multiple Nitro applications exist in the same Julia process or test suite.

## 7. Migration Guidance
- **Genie-style config structure is acceptable at the app layer**: Apps may adopt folders like `config/env/` and `config/initializers/` if useful.
- **Do not copy Genie's global mutable config model**: Preserve the structure benefits, but reject the singleton design.
- **When migrating from Genie, move config loading into explicit app bootstrap code** instead of relying on framework-global side effects.