---
name: project-guidelines
description: >-
  Nitro.jl review checkpoints, rule index, and diff-review surface areas.
  Use at the start of a changed-code review or large refactor so heuristics
  match the current codebase layout.
---

# Nitro.jl Project Guidelines (Review Index)

Read this file at the start of a **changed-code review** or large refactor so heuristics match the current codebase layout.

## Rule index

| Area | Rule file | When it applies |
|------|-----------|-----------------|
| Core framework (`src/`, handlers, routing, middleware) | `nitro-core.instructions.md` | All `*.jl` under the package |
| App config & bootstrap (no `Nitro.config` singleton) | `nitro-config.instructions.md` | Application design and `serve` setup |
| Documentation (`docs/`) | `nitro-docs.instructions.md` | Tutorial and API docs |
| Workers + PormG worker ext | `workers.instructions.md` | `src/Workers/`, `ext/NitroPormGExt.jl`, worker tests |

## Package layout (review slices)

Review diffs in this order when using the `changed-code-review` skill:

1. **`src/Workers/`** — queue API, registry, execution, authorization
2. **`src/`** (excluding Workers) — `Nitro.jl`, routing, extractors, middleware, `Res`, errors
3. **`ext/`** — `NitroPormGExt.jl` and other weak deps (only place for `PormG`)
4. **`test/`** — regressions and extension tests
5. **Remaining** — `docs/`, `.github/`, `Project.toml`, CI workflows

## Active architecture checkpoints

- **Entry module**: `src/Nitro.jl` exports the public API; new exports belong here intentionally.
- **Routing**: `path()`, `urlpatterns()`, `include_routes()` only — no macro or function route registrars.
- **Responses**: `Res.json`, `Res.status`, `Res.send` — not raw `Dict` or `String` from handlers.
- **Guards vs middleware**: route auth in guards; cross-cutting behavior in middleware (`SessionMiddleware`, `CSRFMiddleware`, rate limits).
- **DB isolation**: no `PormG` import in `src/`; worker persistence only via `ext/NitroPormGExt.jl`.
- **Workers**: `user_id` / watchers on task APIs; `AbstractWorkerStore` for new storage features.
- **Tests**: run `Pkg.test()`; new behavior needs coverage under `test/`.
- **Docs**: examples must match current routing and generic model names (`nitro-docs.instructions.md`).

## Skills (explicit invocation)

| Skill | Use when |
|-------|----------|
| `changed-code-review` | Pre-push or pre-PR review of local git diff |
| `add-route` | Add handler, `path()`, guards, and tests for a new endpoint |
| `deploy-checklist` | Pre-production audit (env, deps, proxy, tests) |
| `nitro-typed-multipart-proposal` | Designing or implementing typed mixed multipart extractors |
