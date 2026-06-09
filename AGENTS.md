# Nitro.jl — Agent Context

Single source of truth for all AI agents (Claude Code, Cursor, Codex, Gemini CLI, etc.).

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
| Core framework, routing, security | [`.cursor/rules/nitro-core.mdc`](.cursor/rules/nitro-core.mdc) | Any `src/*.jl` change |
| Config & bootstrap | [`.cursor/rules/nitro-config.mdc`](.cursor/rules/nitro-config.mdc) | App config or `serve()` design |
| Documentation | [`.cursor/rules/nitro-docs.mdc`](.cursor/rules/nitro-docs.mdc) | `docs/**/*.md` edits |
| Workers + PormG ext | [`.cursor/rules/workers.mdc`](.cursor/rules/workers.mdc) | `src/Workers/`, `ext/`, worker tests |
| Review index & diff order | [`.cursor/rules/project-guidelines.mdc`](.cursor/rules/project-guidelines.mdc) | Pre-PR code review |

---

## Skills (`.cursor/skills/`)

Each skill is a `SKILL.md` file describing a workflow. Read the relevant file and follow the steps.

| Skill | File | Purpose |
|-------|------|---------|
| `changed-code-review` | [`.cursor/skills/changed-code-review/SKILL.md`](.cursor/skills/changed-code-review/SKILL.md) | Pre-push / pre-PR git diff review in ordered slices |
| `add-route` | [`.cursor/skills/add-route/SKILL.md`](.cursor/skills/add-route/SKILL.md) | New endpoint: handler, `path()`, guards, tests |
| `deploy-checklist` | [`.cursor/skills/deploy-checklist/SKILL.md`](.cursor/skills/deploy-checklist/SKILL.md) | Pre-production env, deps, proxy, and test audit |
| `nitro-typed-multipart-proposal` | [`.cursor/skills/nitro-typed-multipart-proposal/SKILL.md`](.cursor/skills/nitro-typed-multipart-proposal/SKILL.md) | Typed mixed multipart (`MultipartForm{T}`) design |

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
