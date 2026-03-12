---
applyTo: "**/*.jl"
description: "Nitro.jl database rules — PormG.jl weak dependency, extension isolation, core purity"
---

# Nitro.jl Database & Persistence Instructions

When integrating database functionality into **Nitro.jl**, follow the PormG.jl integration rules precisely:

## Persistence: PormG.jl Extension
- **Weak Dependency**: PormG.jl is the dedicated ORM but must remain a Julia weak dependency.
- **Extension Isolation**: Any code importing or directly depending on `PormG` MUST live inside `ext/NitroPormGExt/`.
- **Core Purity**: Never import `PormG` inside `src/`. The core web server must remain fundamentally database-agnostic.
- **Connection Management**: Do not manage raw database connections in route handlers. Use the middleware/context provided by the `NitroPormGExt` extension.
