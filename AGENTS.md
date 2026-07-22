# Nitro.jl — Agent Context

Single source of truth for all AI agents (Claude Code, GitHub Copilot, Codex, Gemini CLI, etc.).

---

## Core Rules — Read First, Every Agent

Hard stops — getting these wrong produces broken or architecturally invalid code. These bullets are **summaries**; the **canonical** statement of each rule (with rationale and edge cases) lives in the linked deep-dive section, which wins on any conflict. CI ([`.github/scripts/docs_lint.jl`](.github/scripts/docs_lint.jl)) checks that referenced files and symbols exist — not wording — so keep the summaries in sync by hand.

- **Routing**: use `path()`, `urlpatterns()`, `include_routes()` exclusively. Path parameters use converters: `<int:id>`, `<str:slug>`, `<uuid:key>`. *Canonical: [nitro-core §3](.github/instructions/nitro-core.instructions.md).*
- **PormG isolation**: `PormG` may only be imported inside `ext/NitroPormGExt.jl` — never in `src/`. *Canonical: [nitro-core §6](.github/instructions/nitro-core.instructions.md).*
- **Responses**: prefer `Res.json()`, `Res.status()`, `Res.send()` so status and content type are explicit. Raw `Dict`/`String` returns are auto-formatted and **safe** (`text/plain`, no content-sniffing) — implicit, not a bug. The actual hard stop: never feed unescaped user input into `Res.html`/`Res.js`. *Canonical: [nitro-core §4](.github/instructions/nitro-core.instructions.md).*
- **Config**: no `Nitro.config` global. Applications define typed config structs. Bootstrap order: load config → resolve secrets → run initializers → `serve(context=...)`. *Canonical: [nitro-config](.github/instructions/nitro-config.instructions.md).*
- **Workers**: all task APIs require `user_id`. New storage backends implement `AbstractWorkerStore`. DB logic lives exclusively in `ext/NitroPormGExt.jl`. *Canonical: [workers](.github/instructions/workers.instructions.md).*

---

## Deep-Dive Rules — Read When Working in That Area

Detailed constraints, idioms, and examples. Read the relevant file before writing code in that area.

**How this loads, per agent.** Each rule file carries an `applyTo:` glob in its front-matter. **GitHub Copilot** honors that glob and auto-attaches the file when you touch a matching path. **Claude Code, Codex, Gemini CLI and other agents do _not_ auto-apply `applyTo`** — they must open and read the relevant file themselves, driven by the table below. Treat the *When to read* column as a hard prerequisite, not a hint: e.g. the non-consuming response-write path in nitro-core §4 is load-bearing, and editing `src/core.jl` without reading it risks a silent, suite-wide regression.

| Area | Rule file | When to read |
|------|-----------|--------------|
| Core framework, routing, security | [`.github/instructions/nitro-core.instructions.md`](.github/instructions/nitro-core.instructions.md) | Any `src/*.jl` change |
| Config & bootstrap | [`.github/instructions/nitro-config.instructions.md`](.github/instructions/nitro-config.instructions.md) | App config or `serve()` design |
| Documentation | [`.github/instructions/nitro-docs.instructions.md`](.github/instructions/nitro-docs.instructions.md) | `docs/**/*.md` edits |
| Workers + PormG ext | [`.github/instructions/workers.instructions.md`](.github/instructions/workers.instructions.md) | `src/Workers/`, `ext/`, worker tests |

---

## Skills (`.github/skills/`)

Each skill is a `SKILL.md` file describing a workflow (the [Agent Skills](https://docs.github.com/en/copilot/concepts/agents/about-agent-skills) open format, also used by Claude Code). Read the relevant file and follow the steps.

**Invocation, per agent.** These `.github/skills/` files are **read-and-follow** workflows, not registered slash commands. Copilot surfaces them as agent skills; in Claude Code as configured here they are **not** auto-registered as `/<name>` commands — open the `SKILL.md` and execute its steps when the task matches (or when the user names it). This is the single skill registry: do not maintain a second copy elsewhere.

| Skill | File | Purpose |
|-------|------|---------|
| `changed-code-review` | [`.github/skills/changed-code-review/SKILL.md`](.github/skills/changed-code-review/SKILL.md) | Pre-push / pre-PR git diff review in ordered slices |
| `add-route` | [`.github/skills/add-route/SKILL.md`](.github/skills/add-route/SKILL.md) | New endpoint: handler, `path()`, guards, tests |
| `deploy-checklist` | [`.github/skills/deploy-checklist/SKILL.md`](.github/skills/deploy-checklist/SKILL.md) | Pre-production env, deps, proxy, and test audit |
| `nitro-typed-multipart-proposal` | [`.github/skills/nitro-typed-multipart-proposal/SKILL.md`](.github/skills/nitro-typed-multipart-proposal/SKILL.md) | Typed mixed multipart (`MultipartForm{T}`) design |
| `nitro-issue-management` | [`.github/skills/nitro-issue-management/SKILL.md`](.github/skills/nitro-issue-management/SKILL.md) | GitHub backlog: file/label/close issues (`pre-publish` gating label) |
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
