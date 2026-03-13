# Plan: Security Foundation & Auth App (Module First)

Implement core security primitives in Nitro.jl and scaffold an internal "Auth App" module to support Genie.jl migrations and future modularization into an external `NitroAuth.jl` package.

## Context

### Current State (Nitro.jl)
- **Cookies**: `src/cookies.jl` — Robust engine with encryption (AES-256-GCM), cookie parsing/formatting, and `CookieConfig` type.
- **Sessions**: `src/middleware/session_middleware.jl` — Implements `SessionMiddleware` using `MemoryStore{String, Dict{String, Any}}` hardcoded. Fixed cookie configuration (supports `secure`, `httponly`, `samesite`).
- **Auth Middleware**: `src/middleware/auth_middleware.jl` — Functional `BearerAuth` middleware injects user into `req.context[:user]`.
- **Guards**: `src/middleware/guards.jl` — Contains `login_required` and `role_required` but hardcoded to check `req.session` (not unified with `BearerAuth`).
- **Crypto**: `src/crypto.jl` — AES-256-GCM encryption/decryption and URL-safe Base64.

### Available Existing Implementations (to Reuse)

**PormG.jl (`/home/pingo03/app/PormG.jl/src/Passwords.jl`)**:
- Framework-agnostic password hashing module.
- Supports multiple algorithms: PBKDF2-SHA256 (720k iterations), BCrypt, Spring Security compatible.
- ✅ **NO Argon2** (disabled due to precompilation issues).
- Provides: `make_password(password)`, `check_password(password, hash)`, `validate_password(pwd)`, password strength validation.
- ✅ **Reuse Strategy**: Copy or extend directly into `src/auth/passwords.jl`.

**bi_server (`/home/pingo03/app/bi_server/src/JwtAuth.jl` + `Security.jl`)**:
- JWT encoding/decoding with HMAC-SHA256 (via JWTs.jl and MbedTLS.jl).
- Key ID (kid) support for key rotation.
- IAT (issued-at) validation with 30s clock skew for distributed systems.
- ✅ **Reuse Strategy**: Extract logic, create Nitro.jl-native JWT module adapted to HTTP.jl patterns.

**bi_server (`/home/pingo03/app/bi_server/src/WebServer.jl`)**:
- Auth cookie helpers: `set_auth_cookie!`, `clear_auth_cookie!`, cookie attribute defaults (HttpOnly, Secure, SameSite=Lax).
- Token extraction from Authorization header and Cookie header.
- Middleware pattern for route protection.
- ✅ **Reuse Strategy**: Adapt cookie management and middleware patterns to Nitro.jl's HTTP.jl style.

### Key Gaps
- No `AbstractSessionStore` interface; Redis/DB stores not possible.
- Auth context is inconsistent: `BearerAuth` → `req.context[:user]`, but Guards → `req.session`.
- No JWT claim validation (exp, iat, nbf, kid rotation) integrated into Nitro.jl.
- No CSRF protection.
- No higher-level auth helpers (`set_auth_cookie!`, `clear_auth_cookie!`) in Nitro.jl core.

## Steps (Prioritized)

### Proposed Strategy: Stateless Primitives & Pluggable Validation
**Goal**: Keep Nitro.jl core database-agnostic while enabling apps to use `PormG` for user lookups.

1. **Stateless JWT Primitives**: `src/Auth/jwt.jl` and `src/Auth/claims.jl` will focus on cryptographic validation (signature, `exp`, `iat`, `nbf`) without hitting a database.
2. **Pluggable `UserProvider`**: The `BearerAuth` and `SessionMiddleware` will accept an optional `validator::Function`. 
   - Nitro Core: Validates the token/session cryptographically.
   - App Layer (using `PormG`): Performs the database lookup (e.g., `User.find(id)`) if needed.
3. **Consistency**: This matches the `bi_server` pattern where `JwtAuth.jl` and `Security.jl` are pure logic, and the controllers handle model-specific behavior.

### Validator Factories (Optional Helpers)
**Goal**: Reduce boilerplate for common auth patterns while keeping Nitro core pure.

Provide optional factory functions in `src/Auth/validators.jl` that generate validators for common scenarios:

```julia
# PormG-backed JWT validator
function pormg_jwt_validator(user_model::Type; check_active=true)
    return function(claims::Dict)
        user_id = claims["sub"]
        user = user_model.find(user_id)
        if user === nothing
            return nothing
        end
        if check_active && !user.is_active
            return nothing
        end
        return user
    end
end

# Session-based validator (lookup user by session_id)
function session_user_validator(store::AbstractSessionStore)
    return function(session_id::String)
        session_data = get_session(store, session_id)
        return session_data !== nothing ? session_data.get(:user, nothing) : nothing
    end
end

# No-op validator (public endpoints, no user required)
pormg_no_auth() = _ -> nothing
```

**Usage in App**:
```julia
using Nitro
using Nitro.Auth
using PormG  # only in app layer

# Single line for PormG apps
validator = pormg_jwt_validator(User; check_active=true)
path("/api/profile", get_profile, middleware=[BearerAuth(validator)])

# Completely database-agnostic in Nitro core; no PormG imported.
```

**Implementation Notes**:
- These factories are **optional**. Apps can write their own validators if they need custom logic (e.g., permission checks, audit logging).
- Factories live in `src/Auth/validators.jl` **only if there's a weak dependency on PormG** (via package extensions). Otherwise, apps copy the pattern.
- Documentation includes 3-5 example validators for common scenarios.

### Phase 1: Session Store Interface & Unified Auth Context
**Goal**: Enable pluggable session stores and align auth access patterns.

1. **Define `AbstractSessionStore` in `src/types.jl`**
   - Methods: `get_session(store, session_id)`, `set_session!(store, session_id, data)`, `delete_session!(store, session_id)`, `cleanup_expired_sessions!(store)`.
   - Update `MemoryStore` to fulfill this interface.
   - Add `Session` type: `Session{T <: AbstractSessionStore}` to hold store reference and config.

2. **Unify Auth Context**
   - Add `req.user` property shorthand via `Base.getproperty` extension in `src/core.jl` (returns `req.context[:user]`).
   - Update `BearerAuth` to populate `req.context[:user]`.
   - Update `SessionMiddleware` to populate `req.context[:user]` with user data if session is authenticated.
   - Refactor `src/middleware/guards.jl` to check `req.context[:user]` instead of `req.session`.

3. **Refactor `SessionMiddleware`**
   - Accept `store::AbstractSessionStore` instead of hardcoding `MemoryStore`.
   - Constructor: `SessionMiddleware(store::AbstractSessionStore; config::CookieConfig = ...)`.

### Phase 2: Auth App Module Scaffold & High-Level Helpers
**Goal**: Provide structured internal auth module ready for extraction. Reuse proven patterns from bi_server and PormG.

1. **Create `src/Auth/` directory and module**
   - `src/Auth.jl` — Main module file that exports public API.
   - Register as `Nitro.Auth` submodule in `src/Nitro.jl`.

2. **Implement `src/Auth/cookies.jl`**
   - Adapt `set_auth_cookie!` and `clear_auth_cookie!` patterns from `bi_server/src/WebServer.jl`.
   - Integrate with Nitro.jl's `HTTP.Response` and existing `src/cookies.jl` utilities.
   - Example: `set_auth_cookie!(res, token; ttl=86400, secure=dev ? false : true)`.

3. **Implement `src/Auth/passwords.jl`**
   - **Copy or adapt** `PormG.jl/src/Passwords.jl` directly (framework-agnostic, no dependencies conflict).
   - Provides: `make_password(password)`, `check_password(password, hash)`, `validate_password(pwd)`.
   - Supports PBKDF2, BCrypt, Spring Security hashes; ~~no Argon2 (precompilation issues)~~.
   - **Note**: PormG already uses this, so consistency is built-in.

4. **Implement `src/Auth/jwt.jl`**
   - Adapt JWT encode/decode patterns from `bi_server/src/JwtAuth.jl`.
   - Add dependencies: `JWTs.jl`, `MbedTLS.jl`.
   - Support `kid` (key ID) for rotation; validate claims: `exp`, `iat`, `nbf`, `iss`, `aud`.
   - API: `encode_jwt(payload, secret; kid=nothing)`, `decode_jwt(token, secret_or_keyset)`, `validate_iat(claims; timeout=300)`.

5. **Implement `src/Auth/claims.jl`**
   - Extract claim validation logic from `bi_server/src/Security.jl`.
   - Provide `validate_claims(claims; exp_timeout=3600, iat_skew=30)` for centralized validation.
   - Support issuer (`iss`) and audience (`aud`) checks when configured.

6. **Update or move `src/middleware/guards.jl` → `src/Auth/guards.jl`**
   - Ensure `login_required`, `role_required`, and `permission_required` guards work with unified `req.user` context.
   - Make guards work with both session-based and JWT-based auth sources.

### Phase 3: CSRF Protection & Cookie Security Review
**Goal**: Add CSRF middleware and harden cookie defaults.

1. **Implement `src/middleware/csrf_middleware.jl`**
   - Double Submit Cookie pattern: Token in cookie + token in request header/body.
   - Validate on unsafe methods (POST, PUT, PATCH, DELETE).
   - API: `CSRFMiddleware(secret)` with handler for generating/validating tokens.

2. **Review & Harden `CookieConfig` in `src/types.jl`**
   - Ensure defaults: `httponly=true`, `samesite=Lax`, `secure` conditional on dev/prod context.
   - Document: "Secure by Default" philosophy in comments.

3. **Documentation**
   - Add `docs/src/tutorial/sessions_and_auth.md` showing session store interface.
   - Add migration guide for Genie.jl session/auth patterns.

## Relevant Files

**Core Updates**:
- `src/types.jl` — `AbstractSessionStore` interface, `CookieConfig` review.
- `src/core.jl` — Add `req.user` shorthand property.
- `src/middleware/session_middleware.jl` — Refactor for `AbstractSessionStore`.
- `src/middleware/guards.jl` — Update to use `req.user` context (will be moved to Auth module in Phase 2).

**New Auth Module**:
- `src/Auth.jl` — Main Auth module.
- `src/Auth/cookies.jl` — `set_auth_cookie!`, `clear_auth_cookie!` (adapted from `bi_server/src/WebServer.jl`).
- `src/Auth/jwt.jl` — JWT encode/decode with claim validation (adapted from `bi_server/src/JwtAuth.jl`).
- `src/Auth/claims.jl` — Claim validation helpers (extracted from `bi_server/src/Security.jl`).
- `src/Auth/passwords.jl` — Password hashing/verification (copy/adapt from `PormG.jl/src/Passwords.jl`).
- `src/Auth/validators.jl` — Optional factory functions for common validator patterns (PormG, session, no-auth).
- `src/Auth/guards.jl` — Guardrails for auth checks (moved from `src/middleware/guards.jl`).

**New Middleware**:
- `src/middleware/csrf_middleware.jl` — CSRF token validation.

**Source Reference Files (to adapt from)**:
- `bi_server/src/JwtAuth.jl` — JWT patterns
- `bi_server/src/Security.jl` — IAT validation and middleware patterns
- `bi_server/src/WebServer.jl` — Cookie management helpers
- `PormG.jl/src/Passwords.jl` — Password hashing implementation

## Verification Strategy

1. **Unit Tests** (`test/sessionstores_tests.jl`):
   - Test `MemoryStore` fulfills `AbstractSessionStore` interface.
   - Test session expiration and cleanup.
   - Test `req.user` shorthand access.

2. **Integration Tests** (`test/auth_tests.jl`):
   - Verify `BearerAuth` and `SessionMiddleware` both populate `req.context[:user]` consistently.
   - Verify guards (`login_required`, `role_required`) work against unified auth context.
   - Test CSRF middleware accepts valid tokens and rejects invalid ones.

3. **Auth Module Tests** (`test/auth_module_tests.jl`):
   - JWT encode/decode with multiple keys and `kid` rotation.
   - Claim validation (exp, iat, nbf).
   - Password hashing and verification.
   - `set_auth_cookie!` and `clear_auth_cookie!` behavior (secure=true/false).

4. **Security Tests** (`test/security_tests.jl`):
   - Verify expired sessions are cleaned up.
   - Verify CSRF middleware rejects cross-origin POST requests without valid tokens.
   - Verify cookie flags (HttpOnly, Secure, SameSite) are set correctly.

## Decisions & Trade-offs

### Password Hashing: Reuse PormG.jl Implementation
- **Decision**: Copy or adapt `PormG.jl/src/Passwords.jl` directly into `src/auth/passwords.jl`.
- **Rationale**: 
  - Framework-agnostic, no dependency conflicts.
  - Already battle-tested in production (PormG.jl).
  - Supports PBKDF2 (720k iterations), BCrypt, Spring Security compatible hashes.
  - Argon2 is disabled in PormG due to precompilation issues; no need to re-solve that here.
  - Ensures consistency: bi_server uses PormG for passwords → Nitro can reuse same.

### JWT Implementation: Adapt bi_server Patterns
- **Decision**: Extract JWT logic from `bi_server/src/JwtAuth.jl` and create Nitro.jl-native `src/auth/jwt.jl`.
- **Rationale**:
  - bi_server's patterns are proven and Genie-tested.
  - Adapt to HTTP.jl request/response model (remove Genie dependencies).
  - Reuse KID (key rotation) and IAT validation with 30s clock skew logic.
  - Dependencies: `JWTs.jl`, `MbedTLS.jl` (widely available, low overhead).

### Cookie Management: Adapt bi_server Patterns
- **Decision**: Create `src/auth/cookies.jl` by adapting `bi_server/src/WebServer.jl` patterns.
- **Rationale**:
  - Cookie attributes and defaults are consistent with bi_server.
  - Integrate with Nitro.jl's existing `src/cookies.jl` for encryption/encoding.
  - Provide high-level `set_auth_cookie!` and `clear_auth_cookie!` helpers for apps.

### Unified Auth Context: `req.user` vs `req.context[:user]`
- **Decision**: Implement both. Use `req.user` as a shorthand property (via `Base.getproperty` extension) that internally reads `req.context[:user]`.
- **Rationale**: Ergonomic shorthand for handlers and guards while maintaining consistency with the context-based storage model.

### Session Store Interface: Abstract vs Dynamic
- **Decision**: Use abstract type `AbstractSessionStore` with required methods.
- **Rationale**: Enforces contract and enables type stability for performance-critical HTTP path.

### Auth Module Scope: Nitro Core vs External Package
- **Decision**: Place the Auth module in `src/Auth/` as part of Nitro core initially.
- **Rationale**: Enables shared patterns across users. Extract to `NitroAuth.jl` only when a second external app needs to reuse it (per `todo.md` strategy).

### Stateless Auth: Nitro Core vs Database (PormG)
- **Decision**: Keep Nitro.jl's internal Auth module **purely stateless**. No direct `PormG` dependency.
- **Rationale**: 
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
