---
name: add-route
description: >-
  Add a Nitro.jl API route end-to-end: handler, path() registration, guards,
  tests, and Pkg.test(). Use when the user asks for a new endpoint, route, or
  handler in Nitro.jl or a Nitro-based app.
disable-model-invocation: true
---

# Add Route Workflow

Implementation workflow (not a review). Follow `nitro-core.mdc` and `nitro-docs.mdc` throughout.

## Scope

| Target | Handler location | Route registration |
|--------|------------------|-------------------|
| **Nitro.jl package** | `src/` or existing handler modules; often inline in `test/` for behavior tests | `urlpatterns` in the relevant test file or example |
| **Application using Nitro** | `src/Handlers/<Domain>Handlers.jl` | `src/Routes.jl` (or `src/Routes/*.jl`) via `path()` / `include_routes()` |

Do not use `@get`, `@post`, `serveparallel()`, or function-style route registrars.

## Steps

### 1. Handler

- Add a function with `req::HTTP.Request` and typed path parameters (`id::Int`, `slug::String`, etc.).
- Return via `Res.json(...)`, `Res.status(...)`, or `Res.send(...)` — never raw `Dict` or `String`.
- Use extractors (`Query{T}`, `Json{T}`, `Form{T}`, `Files{...}`) when the route has a typed body or query contract.

### 2. Register the route

```julia
path("/api/items/<int:id>", ItemHandlers.get_item, method="GET")
```

- Use Django converters: `<int:id>`, `<str:slug>`, `<uuid:key>`.
- Compose groups with `include_routes("api/", api_routes)` when appropriate.

### 3. Guards and middleware

- Auth required? Add `guards=[login_required()]` (and `role_required` / `permission_required` if needed).
- Mutations with cookies/session? Ensure `SessionMiddleware` and `CSRFMiddleware` are in the app pipeline (`nitro-core.mdc`).
- Do not put route-specific auth in global middleware when a guard is enough.

### 4. Tests

- Add tests under `test/` (or the app’s test suite).
- Cover success (expected status and body shape) and failure (401/403/422 when guards or validation apply).
- For framework changes, extend an existing test file when the domain matches.

### 5. Documentation (if user-facing)

- Update `docs/` when the change is a public API or tutorial-worthy behavior (`nitro-docs.mdc`).
- Use generic examples (Products, Users) — no production-domain models.

### 6. Verify

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Fix failures before finishing. Report what files were added or changed.

## Checklist before done

- [ ] `path()` + `urlpatterns` only
- [ ] Handler uses `Res.*` and typed `req`
- [ ] Guards applied where needed
- [ ] Tests added and `Pkg.test()` passes
- [ ] No `PormG` import in `src/` (DB logic stays in `ext/` or the app)
