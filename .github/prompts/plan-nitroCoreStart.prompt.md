---
description: "Implementation plan for Nitro.jl Core refactor — routing consolidation and session security"
---

# Nitro.jl Core Refactor Plan

Implement the Nitro Core section of [todo.md](todo.md). The goal is to stabilize the framework contract before proceeding to Auth, Workers, or BI app migrations.

## Phase 1: Routing Consolidation
The Django-style API in [src/routing.jl](src/routing.jl) is the source of truth. All old macros and the `route()` function must be deprecated or removed from public visibility.

- [ ] **Public API Alignment**: Update [src/Nitro.jl](src/Nitro.jl) to stop exporting `route` and old macro-based routing if they are being phased out.
- [ ] **Documentation Sweep**: Replace all usage of `@get`, `@post`, and `route()` in [README.md](README.md) with `path()` and `urlpatterns()`.
- [ ] **Docs Site Update**: Update [docs/src/api.md](docs/src/api.md) and [docs/src/index.md](docs/src/index.md) to remove `serveparallel()` and old routing macros.
- [ ] **Path Converters**: Implement the missing `<uuid:key>` converter in [src/routing.jl](src/routing.jl).

## Phase 2: Session Security & Cookie Config
Fix the hardcoded security settings in [src/middleware/session_middleware.jl](src/middleware/session_middleware.jl) to enable local development over HTTP without compromising production security.

- [ ] **Configure Session Cookies**: Modify `SessionMiddleware` to accept `secure`, `httponly`, and `samesite` parameters rather than hardcoding them.
- [ ] **Local Dev Support**: Ensure `secure=false` can be passed for local testing.
- [ ] **Validation Tests**: Update [test/sessiontests.jl](test/sessiontests.jl) to verify that session cookies respect these new configurations.

## Phase 3: Ergonomics & Extensions
- [ ] **Standardize Accessors**: Audit handlers to ensure use of `req.params`, `req.query`, `req.session`, and `req.ip`.
- [ ] **App Context Pipeline**: Implement a clean pattern for passing typed config via `serve(context=...)`.

## Definition of Done
- `README.md` and `/docs` only teach `path()` and `urlpatterns()`.
- `serve()` is the only documented entry point (parallel by default).
- Session middleware allows configurable cookie attributes.
- All core tests pass using the new routing style.

