---
name: changed-code-review
description: >-
  Review changed code before push or PR by reading git diff in ordered slices
  for src/Workers, core src/, ext/, test/, and remaining paths, then report
  bugs, security issues, regressions, and missing coverage in Nitro.jl.
---

# Changed Code Review

## Purpose

Use this skill when the user wants a review of local changes before pushing, opening a pull request, or sending code to GitHub.

This is a review workflow, not an implementation workflow. The default job is to inspect the diff efficiently and report concrete risks.

## Use This Skill For

- Reviewing uncommitted or staged local changes before push
- Reviewing a feature branch before opening a pull request
- Inspecting changed files while keeping context small and ordered
- Looking specifically for bugs, regressions, security issues, and missing tests

## Primary Output

- Findings first, ordered by severity
- Each finding should name the concrete risk, why it matters, and where it appears
- Use file references (with line links when available)
- Keep summaries brief and secondary
- If no findings are discovered, state that explicitly and call out residual testing gaps or uncertainty

## Diff Collection Workflow

### Default review target

The default branch is `main` on `origin`. Review targets in priority order:

1. **Unstaged (default):** working tree changes not yet staged — use `git diff`
2. **Staged:** when the user explicitly says they have already staged — use `git diff --staged`
3. **All local (staged + unstaged):** when the user wants a full picture — use `git diff HEAD`
4. **Already pushed:** when the user wants to review what was just pushed — use `git diff origin/main~1 origin/main`

If the working tree is clean and nothing is staged, state that and stop.

### Ordered diff slices

Review in this exact order to save context:

1. `src/Workers` — queue store interface, API, authorization, execution, startup recovery
2. `src` (core, excluding Workers) — `Nitro.jl`, routing, extractors, middleware, `Res`, errors, `Auth`
3. `ext` — weak extensions (`NitroPormGExt.jl`); only place `PormG` may appear
4. `test` — unit and extension tests
5. Every other changed path (`docs/`, `.github/`, `Project.toml`, CI workflows)

Do not start with a whole-repo patch if the change can be reviewed in slices.

### Recommended commands

Use `git diff --name-only` first to learn the surface area. Then inspect patches in ordered slices:

```bash
# Unstaged review (default)
git diff -- src/Workers
git diff -- src ":(exclude)src/Workers"
git diff -- ext
git diff -- test
git diff -- . ":(exclude)src" ":(exclude)ext" ":(exclude)test"
```

For staged review add `--staged`. For all local changes use `git diff HEAD --`.

If one slice is empty, skip it and continue to the next.

## Review Priorities

### Bugs and regressions

Prioritize:

- Incorrect control flow, missing edge-case handling, or wrong conditional logic
- **Routing API drift**: reintroduced `@get`/`@post`, `serveparallel()`, or function-style `get()`/`post()` registrars
- **Response contract drift**: handler returns raw `Dict`/`String` instead of `Res.json` / `Res.status`
- **Middleware order**: session/CSRF/guards applied after routing or in wrong pipeline position
- **Extractor/handler mismatch**: path converters, typed extractors, or `validate` behavior inconsistent with route signature
- **Workers API drift**: `submit_task` / `get_task_status` / `cancel_task` called without `user_id` where authorization is required
- **Store interface incompleteness**: new `AbstractWorkerStore` method in registry without both in-memory and PormG implementations
- **Zombie recovery**: persistent `RUNNING` tasks left orphaned when startup recovery is disabled or bypassed
- **Extension boundary violations**: `PormG` or SQL in `src/` instead of `ext/`
- **Type stability**: new `Any` or untyped hot-path fields in request handling
- **Docs/examples** that show deleted APIs while core code was updated (or the reverse)

### Security issues

Check aggressively for:

- Raw SQL string interpolation instead of parameterized queries or ORM APIs in `ext/`
- Logging or printing session data, CSRF tokens, JWTs, or credentials
- New routes missing `login_required`, `role_required`, or `CSRFMiddleware` where mutations occur
- Worker task APIs that skip watcher/`user_id` checks on read, cancel, or list
- `Res.json` or error paths that leak stack traces or internal DB errors to clients
- Dynamic `eval`/`include`/`run` built from request input
- File upload/path handling without sanitization (path traversal via `FormFile.filename` or staged paths)
- CORS or cookie settings that weaken `SameSite`/secure defaults without explicit justification
- Secrets committed in docs, tests, or CI config

### Tests

Verify for changed behavior:

- New or changed logic has tests under `test/` (including `test/extensions/` when touching `ext/`)
- Worker authorization and store backends have targeted tests, not only happy-path submits
- Assertions match real response shapes (`Res` payloads, HTTP status codes)
- Run or recommend `Pkg.test()` when the diff touches runtime behavior

Flag Quasar/app-layer repos separately; this skill targets **Nitro.jl** only.

### Other folders

In the final pass, review `docs/`, `.github/workflows/`, `Project.toml`, and root config for:

- Tutorial examples using deleted routing or `serveparallel()`
- CI changes that skip tests, hide failures, or expose secrets
- Version or dependency bumps with breaking API changes undocumented in docs
- `News.md` or changelog text that no longer matches behavior

## Review Method

1. Read the `project-guidelines` skill (`.github/skills/project-guidelines/SKILL.md`) for the rule index and active checkpoints.
2. Identify the changed file set with `git diff --name-only` (or `git diff HEAD --name-only` for all local).
3. Read the `src/Workers` slice first when present.
4. Read the core `src/` slice (excluding Workers) for routing, middleware, and extractors.
5. Read the `ext/` slice for PormG/worker persistence alignment with core interfaces.
6. Read `test/` for coverage gaps.
7. Read the remaining diff for docs, CI, and config risks.
8. Report findings before any summary.

## Project-Specific Heuristics

Always re-read the `project-guidelines` skill (step 1) so newly active rules are included. Permanent baselines:

- Flag any `import PormG` or DB access in `src/` (belongs in `ext/NitroPormGExt.jl` only)
- Flag macro routing (`@get`, `@post`, etc.) or `serveparallel()` in code or docs
- Flag handlers returning raw dicts/strings instead of `Res` helpers
- Flag worker task submit/list/cancel without `user_id` where the new API requires it
- Flag `AbstractWorkerStore` changes missing parallel updates in `InMemoryWorkerStore` and `PormGWorkerStore`
- Flag serializing or persisting live `Task` objects
- Flag new public exports in `src/Nitro.jl` without doc/test consideration
- Flag `SessionMiddleware`/`CSRFMiddleware` changes that break SPA cookie/CSRF assumptions documented in `docs/`
- Flag docs using domain-specific production models instead of generic examples (`nitro-docs.instructions.md`)
- Flag missing tests for authorization, validation, or store edge cases

## After Reporting Findings

After reporting:

- If findings are blocking (bugs, security issues, missing tests for changed behavior): offer to fix them inline in the same conversation.
- If findings are advisory only (style, doc gaps, architecture notes): state the residual risk clearly and let the developer decide.
- Do **not** generate a review markdown file in the project unless the user explicitly asks for one.

## Anti-Patterns

- Do not lead with a summary when concrete findings exist
- Do not review only `src/Workers` while skipping paired `ext/NitroPormGExt.jl` changes
- Do not rely on a single giant diff when ordered slices are available
- Do not treat auto-generated docs build artifacts as primary sources of truth
- Do not approve missing authorization on worker APIs, `PormG` in core `src/`, or weakened CSRF/session defaults as minor issues
