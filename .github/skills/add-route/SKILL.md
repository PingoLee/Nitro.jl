---
name: add-route
description: >-
  Add a Nitro.jl API route end-to-end: handler, path() registration, guards,
  tests, and Pkg.test(). Use when the user asks for a new endpoint, route, or
  handler in Nitro.jl or a Nitro-based app.
---

# Add Route Workflow

Implementation workflow (not a review). Follow `nitro-core.instructions.md` and `nitro-docs.instructions.md` throughout.

## Scope

| Target | Handler location | Route registration |
|--------|------------------|-------------------|
| **Nitro.jl package** | `src/` or existing handler modules; often inline in `test/` for behavior tests | `urlpatterns` in the relevant test file or example |
| **Application using Nitro** | `src/Handlers/<Domain>Handlers.jl` | `src/Routes.jl` (or `src/Routes/*.jl`) via `path()` / `include_routes()` |

Follow routing and response rules from `nitro-core.instructions.md`.

## Steps

### 1. Handler

- Add a function with `req::HTTP.Request` and typed path parameters (`id::Int`, `slug::String`, etc.).
- Return via `Res.json(...)`, `Res.status(...)`, or `Res.send(...)` so status and content type are explicit. A raw `Dict`/`String` return also works and is **safe** (auto-formatted; see `nitro-core.instructions.md` §4) — prefer the builder for intent, but do not treat a raw return as a defect.
- Use extractors (`Query{T}`, `Json{T}`, `Form{T}`, `Files{...}`) when the route has a typed body or query contract; unwrap with `.payload`.

### 2. Register the route

```julia
path("/api/items/<int:id>", ItemHandlers.get_item, method="GET")
```

- Use Django converters — the registry has exactly five: `<int:…>`, `<str:…>`, `<float:…>`, `<bool:…>`, `<uuid:…>`.
- Compose groups with `include_routes("api/", api_routes)` when appropriate.
- Register with `urlpatterns(prefix, routes)` (prefix required, `""` for root) **before** calling `serve()`.

### 3. Guards and middleware

- **`path()` has no `guards` keyword.** Its keywords are `method`, `methods`, `name`, and `middleware`. Guards are attached by wrapping them in `GuardMiddleware` and passing that as route-scoped middleware:

```julia
path("/api/admin/items", ItemHandlers.list_items, method="GET",
     middleware=[GuardMiddleware(login_required(), role_required("admin"))])
```

- Available guards: `login_required`, `role_required`, `permission_required`, `claim_required`, `kid_required` (the middle two are thin aliases over `claim_required`).
- Mutations with cookies/session? Ensure `SessionMiddleware` and `CSRFMiddleware` are in the app pipeline (`nitro-core.instructions.md`).
- Do not put route-specific auth in global middleware when a guard is enough.

### 4. Tests

- Add tests under `test/` (or the app's test suite).
- Cover success (expected status and body shape) and failure (401/403/422 when guards or validation apply).
- For framework changes, extend an existing test file when the domain matches.

### 5. Documentation (if user-facing)

- Update `docs/` when the change is a public API or tutorial-worthy behavior (`nitro-docs.instructions.md`).
- Use generic examples (Products, Users) — no production-domain models.

### 6. Verify

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Fix failures before finishing. Report what files were added or changed.

## Checklist before done

- [ ] `path()` + `urlpatterns(prefix, routes)` only — no macro/function registrars
- [ ] Handler takes a typed `req` and returns via `Res.*` (raw returns are safe, just less explicit)
- [ ] Guards applied where needed, via `middleware=[GuardMiddleware(...)]` — not a `guards=` keyword
- [ ] Tests added and `Pkg.test()` passes
- [ ] No `PormG` import in `src/` (DB logic stays in `ext/` or the app)
