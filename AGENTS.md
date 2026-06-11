# Nitro.jl — Agent Context

Single source of truth for all AI agents (Claude Code, GitHub Copilot, Codex, Gemini CLI, etc.).

---

## Core Rules — Read First, Every Agent

Hard stops. Getting any of these wrong produces broken or architecturally invalid code.

- **Routing**: use `path()`, `urlpatterns()`, `include_routes()` exclusively. Path parameters use converters: `<int:id>`, `<str:slug>`, `<uuid:key>`.
- **PormG isolation**: `PormG` may only be imported inside `ext/NitroPormGExt.jl` — never in `src/`.
- **Responses**: always use `Res.json()`, `Res.status()`, `Res.send()` — never return raw `Dict` or `String` from handlers.
- **Config**: no `Nitro.config` global. Applications define typed config structs. Bootstrap order: load config → resolve secrets → run initializers → `serve(context=...)`.
- **Workers**: all task APIs require `user_id`. New storage backends implement `AbstractWorkerStore`. DB logic lives exclusively in `ext/NitroPormGExt.jl`.

---

## Deep-Dive Rules — Read When Working in That Area

Detailed constraints, idioms, and examples. Read the relevant file before writing code in that area.

| Area | Rule file | When to read |
|------|-----------|--------------|
| Core framework, routing, security | [`.github/instructions/nitro-core.instructions.md`](.github/instructions/nitro-core.instructions.md) | Any `src/*.jl` change |
| Config & bootstrap | [`.github/instructions/nitro-config.instructions.md`](.github/instructions/nitro-config.instructions.md) | App config or `serve()` design |
| Documentation | [`.github/instructions/nitro-docs.instructions.md`](.github/instructions/nitro-docs.instructions.md) | `docs/**/*.md` edits |
| Workers + PormG ext | [`.github/instructions/workers.instructions.md`](.github/instructions/workers.instructions.md) | `src/Workers/`, `ext/`, worker tests |

---

## Skills (`.github/skills/`)

Each skill is a `SKILL.md` file describing a workflow (the [Agent Skills](https://docs.github.com/en/copilot/concepts/agents/about-agent-skills) open format, also used by Claude Code). Read the relevant file and follow the steps.

| Skill | File | Purpose |
|-------|------|---------|
| `changed-code-review` | [`.github/skills/changed-code-review/SKILL.md`](.github/skills/changed-code-review/SKILL.md) | Pre-push / pre-PR git diff review in ordered slices |
| `add-route` | [`.github/skills/add-route/SKILL.md`](.github/skills/add-route/SKILL.md) | New endpoint: handler, `path()`, guards, tests |
| `deploy-checklist` | [`.github/skills/deploy-checklist/SKILL.md`](.github/skills/deploy-checklist/SKILL.md) | Pre-production env, deps, proxy, and test audit |
| `nitro-typed-multipart-proposal` | [`.github/skills/nitro-typed-multipart-proposal/SKILL.md`](.github/skills/nitro-typed-multipart-proposal/SKILL.md) | Typed mixed multipart (`MultipartForm{T}`) design |
| `project-guidelines` | [`.github/skills/project-guidelines/SKILL.md`](.github/skills/project-guidelines/SKILL.md) | Review index & diff order — pre-PR code review |

---

## Entry Point

Package module: `src/Nitro.jl` — public exports and includes for core subsystems.

## Tests

Full suite:
```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Targeted (faster feedback):
```bash
# single file
julia --project=. test/runtests.jl test/workers_tests.jl

# by tag or name
julia --project=. test/runtests.jl --tags core --name "Session stores"

# parallel
julia -t auto --project=. test/runtests.jl --workers 2
```
