# Nitro.jl Utils

Quick commands and prompt snippets for using repo skills.

## Main skill: code review

Skill: `changed-code-review`

Use this when we want a pre-push or pre-PR review of local changes.

### Prompt commands for AI agents

Copy one of these into Codex / Cursor / Claude Code:

```text
Use the changed-code-review skill and review my unstaged changes in this repo.
```

```text
Use the changed-code-review skill and review my staged changes.
```

```text
Use the changed-code-review skill and review all local changes against HEAD.
```

```text
Use the changed-code-review skill and review what was just pushed to origin/main.
```

### Expected review behavior

The review should:

1. Read `AGENTS.md`
2. Read `.cursor/rules/project-guidelines.mdc`
3. Review diffs in this order:
   - `src/Workers`
   - `src` excluding `src/Workers`
   - `ext`
   - `test`
   - remaining paths such as `docs/`, `.github/`, `Project.toml`
4. Report findings first:
   - bugs
   - regressions
   - security issues
   - missing tests

## Git commands used by the code review skill

### See changed files first

```bash
git diff --name-only
```

### Review unstaged changes

```bash
git diff -- src/Workers
git diff -- src ":(exclude)src/Workers"
git diff -- ext
git diff -- test
git diff -- . ":(exclude)src" ":(exclude)ext" ":(exclude)test"
```

### Review staged changes

```bash
git diff --staged -- src/Workers
git diff --staged -- src ":(exclude)src/Workers"
git diff --staged -- ext
git diff --staged -- test
git diff --staged -- . ":(exclude)src" ":(exclude)ext" ":(exclude)test"
```

### Review all local changes

```bash
git diff HEAD --name-only
git diff HEAD -- src/Workers
git diff HEAD -- src ":(exclude)src/Workers"
git diff HEAD -- ext
git diff HEAD -- test
git diff HEAD -- . ":(exclude)src" ":(exclude)ext" ":(exclude)test"
```

### Review what was just pushed

```bash
git diff origin/main~1 origin/main
```

## Repo-specific review checks

During review, watch for these Nitro.jl rules:

- routing must use `path()`, `urlpatterns()`, `include_routes()`
- no `PormG` import in `src/`
- handlers should return `Res.json()`, `Res.status()`, or `Res.send()`
- worker task APIs require `user_id`
- worker DB logic belongs in `ext/NitroPormGExt.jl`

## Other useful skill prompts

```text
Use the add-route skill to add a new endpoint with handler, path(), guards, and tests.
```

```text
Use the deploy-checklist skill to audit this repo before production deploy.
```

```text
Use the nitro-typed-multipart-proposal skill to design typed mixed multipart support.
```
