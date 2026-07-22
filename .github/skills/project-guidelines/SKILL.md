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
| Core framework (`src/`, handlers, routing, middleware) | [`nitro-core.instructions.md`](../../instructions/nitro-core.instructions.md) | All `*.jl` under the package |
| App config & bootstrap (no `Nitro.config` singleton) | [`nitro-config.instructions.md`](../../instructions/nitro-config.instructions.md) | Application design and `serve` setup |
| Documentation (`docs/`) | [`nitro-docs.instructions.md`](../../instructions/nitro-docs.instructions.md) | Tutorial and API docs |
| Workers + PormG worker ext | [`workers.instructions.md`](../../instructions/workers.instructions.md) | `src/Workers/`, `ext/NitroPormGExt.jl`, worker tests |

## Review workflow lives in `changed-code-review`

The diff-review **slice order** and review method are owned by the [`changed-code-review`](../changed-code-review/SKILL.md) skill — this file is the rule index and checkpoint list that skill reads first. The slice order is intentionally **not** restated here; one home per fact is the point.

## Active architecture checkpoints

Review-time distillation of the rules. Each mirrors its **canonical** deep-dive section (the Rule index above links them); the deep-dive text wins on any conflict.

- **Entry module**: `src/Nitro.jl` exports the public API; new exports belong here intentionally.
- **Routing**: `path()`, `urlpatterns()`, `include_routes()` only — no macro or function route registrars.
- **Responses**: prefer `Res.json`, `Res.status`, `Res.send` for explicit status + content type; raw `Dict`/`String` returns are safe and auto-formatted (nitro-core §4) — advisory/style only, not a defect.
- **Guards vs middleware**: route auth in guards; cross-cutting behavior in middleware (`SessionMiddleware`, `CSRFMiddleware`, rate limits).
- **DB isolation**: no `PormG` import in `src/`; worker persistence only via `ext/NitroPormGExt.jl`.
- **Workers**: `user_id` / watchers on task APIs; `AbstractWorkerStore` for new storage features.
- **Tests**: run `Pkg.test()`; new behavior needs coverage under `test/`.
- **Docs**: examples must match current routing and generic model names (`nitro-docs.instructions.md`).

## Skills

The skill catalog (what each skill is for) lives in [`AGENTS.md`](../../../AGENTS.md) — one registry, not two. This file is only the rule index and review checkpoints.
