# Plan: Remaining Security/Auth Cleanup

The original security/auth refactor is mostly implemented in Nitro.jl. This file now tracks only the remaining work still worth doing in core or Nitro.Auth.

## Current Status

Already implemented:
- `AbstractSessionStore` and `MemoryStore`
- `req.user` request ergonomics
- `Nitro.Auth` module with JWT, cookies, passwords, guards, and validators
- Cookie auth and bearer auth middleware
- `CSRFMiddleware`
- Session/auth documentation and auth-module test coverage

What remains is contract cleanup and a small amount of scope clarification.

## Remaining Goals

1. Finalize the `SessionMiddleware` auth contract.
2. Make auth guards rely on a single authenticated-user path.
3. Decide whether Nitro.Auth includes refresh-token support.
4. Add focused tests and docs for the finalized behavior.

## Remaining Work

### Phase 1: Finalize SessionMiddleware Contract

#### Problem
- `SessionMiddleware` still accepts a `validator` keyword, but the contract is not finalized.
- The current design intentionally avoids repopulating `req.user` from raw session data, which is better than the original plan, but the public API still looks half-finished.

#### Required Decision
Pick one direction and make it explicit in code and docs:

1. Remove `validator` from `SessionMiddleware` entirely.
   - Keep session middleware responsible only for `req.session`.
   - Leave authenticated-user resolution to auth middleware or app code.

2. Keep `validator`, but define a strict contract.
   - The validator must transform session state into an authenticated principal.
   - Do not copy the full session dictionary into `req.user`.
   - Document exactly when the validator runs and what it returns.

#### Implementation Targets
- `src/middleware/session_middleware.jl`
- `src/types.jl`
- `docs/src/tutorial/sessions_and_auth.md`
- `todo.md`

### Phase 2: Complete Auth-Context Unification

#### Problem
- `req.user` exists and is the right ergonomic target.
- Guards still retain session-based fallback behavior instead of relying on a single canonical auth context.

#### Required Cleanup
- Update guards so route authorization consistently works from `req.user`.
- If compatibility fallback is kept, make it an explicit transitional behavior and document it clearly.
- Ensure cookie auth, bearer auth, and any session-derived auth all feed the same guard contract.

#### Implementation Targets
- `src/middleware/guards.jl`
- `src/Auth/guards.jl`
- `src/core.jl`
- `test/auth_tests.jl`
- `test/middlewaretests.jl`

### Phase 3: Refresh-Token Scope Decision

#### Problem
- Access-token flows are implemented.
- Refresh-token support is not clearly finished as a public Nitro.Auth feature.

#### Required Decision
Pick one direction and align code, docs, and TODOs:

1. Implement refresh-token helpers and lifecycle support.
   - Token issuance helper
   - Rotation or replacement rules
   - Cookie/header transport guidance
   - Revocation strategy expectations

2. Narrow Nitro.Auth scope to access tokens only.
   - Remove any wording that suggests refresh-token support already exists.
   - Leave refresh-token lifecycle policy to app-layer auth packages.

#### Implementation Targets
- `src/Auth/jwt.jl`
- `src/Auth/cookies.jl`
- `src/Auth.jl`
- `docs/src/tutorial/sessions_and_auth.md`
- `todo.md`

### Phase 4: Focused Verification

#### Tests Still Needed
- `SessionMiddleware` behavior after the validator contract is finalized
- Guard behavior when only `req.user` is present
- Guard behavior when no authenticated principal is present
- Refresh-token behavior, if Nitro.Auth keeps that scope

#### Test Files
- `test/sessionstores_tests.jl`
- `test/auth_tests.jl`
- `test/auth_module_tests.jl`
- `test/middlewaretests.jl`

## Success Criteria

- `SessionMiddleware` has a clear, documented, test-covered contract.
- Guards authorize against one canonical authenticated-user path.
- Nitro.Auth scope is explicit about refresh tokens.
- Docs and TODOs match the shipped behavior.

## Non-Goals

These were part of the earlier broad refactor and no longer belong in this follow-up plan:
- Reintroducing session-driven `req.user` population from raw session dictionaries
- Adding database-specific auth lookups inside Nitro core
- Expanding Nitro core to depend on PormG or app-layer user models
  - Violates `nitro-database.instructions.md` (core purity).
  - Most auth logic (JWT signature, `exp`, `iat`) is cryptographic, not model-aware.
  - Apps can pass a `validator::Function` to `BearerAuth` or `SessionMiddleware` if they need to check `PormG` models (e.g., `User.find(id)`).
  - Keeps Nitro core lightweight and database-agnostic while still supporting apps that use `PormG`.

## Success Criteria
- [ ] `AbstractSessionStore` interface is documented and `MemoryStore` fulfills it.
- [ ] `req.user` shorthand works alongside `req.context[:user]`.
- [ ] Guards work with both `SessionMiddleware` and `BearerAuth` auth sources.
- [ ] JWT is created with claim validation and `kid` rotation support.
- [ ] CSRF middleware is functional and tested.
- [ ] Auth module can be imported as `Nitro.Auth` with stable API.
- [ ] No new external dependencies added to core (or only weak dependencies for optional features).
- [ ] Migration guide from Genie.jl session/auth patterns is documented.
