Plan

Recommended direction: keep src/Auth/passwords.jl as the single password engine, bring over only additive generic pieces from PormG into Nitro core, and make a thin NitroPormG weak-dependency layer for PasswordField and model write behavior. The key discovery is that PormG PasswordField currently only stores auto_hash metadata; the actual create, update, bulk_insert, and bulk_update paths still validate and format raw text, so a write hook is needed before extension-side auto-hash can be real.

Compatibility contract (non-negotiable, verified by inspection of both codebases)

Both Nitro and PormG already produce identical wire formats for all three algorithms. These formats must never change:
- Django PBKDF2: `pbkdf2_sha256${iterations}${salt}${hash}` — matches Django 4.2+ defaults (720 000 iterations, PBKDF2-HMAC-SHA256, base64 hash). A hash produced by Nitro must be accepted by Django's `check_password` and vice versa.
- BCrypt (Spring Security default): `$2a$`, `$2b$`, or `$2y$` prefix with cost factor 12. Bitwise compatible with Spring Security and all standard BCrypt libraries.
- Spring Security PBKDF2: `sha256:{iterations}:{key_length}:{salt_b64}:{hash_b64}` — matches Spring Security 6.x `Pbkdf2PasswordEncoder` with `SecretKeyFactoryAlgorithm.PBKDF2WithHmacSHA256`.
- Future Argon2: format TBD by the Argon2 backend, but must follow the standard PHC string format `$argon2id$v=19$m=...,t=...,p=...$salt$hash` so it remains interoperable.

The format strings, iteration counts, and encoding choices are treated as a public API contract. No phase of this migration may alter them.

1. Phase 1: Core convergence in Nitro. Bring missing generic features from PormG into src/Auth/passwords.jl and src/Auth.jl, but keep Nitro.Auth canonical. All additions are strictly additive — no existing function signature or behaviour changes:
   - `make_password(raw; algorithm=DEFAULT_PASSWORD_ALGORITHM, ...)` already exists in Nitro. Verify the keyword argument name matches PormG's (`algorithm::String`, not `::Symbol`) so call sites are source-compatible.
   - Replace the hardcoded `const DEFAULT_PASSWORD_ALGORITHM = "pbkdf2_sha256"` with a mutable `Ref`, matching PormG's `_DEFAULT_ALGORITHM = Ref{String}("pbkdf2_sha256")`, and expose `set_default_algorithm!(algorithm::String)` as PormG does. The existing `DEFAULT_ALGORITHM()` accessor remains unchanged. This is the only behavioural gap between the two codebases.
   - Add `SUPPORTED_ALGORITHMS` constant listing `["pbkdf2_sha256", "bcrypt", "spring_sha256"]` (Argon2 commented out, matching PormG).
   - Argon2 API scaffolding behind a feature gate: define the public contract (types, function signatures, PHC format parser) so the extension can reference them today; the real implementation lands when the backend is ready.
   - Do not change existing PBKDF2, BCrypt, Spring, or DelegatingPasswordEncoder logic.
2. Phase 2: Tests and docs migration.
   - Tests: port PormG's test suite for passwords verbatim into test/auth_module_tests.jl. Do NOT simplify, combine, or remove any test case — the PormG test suite is the compatibility oracle. If a test case already exists in Nitro with identical coverage, deduplicate by keeping the more explicit version. Wire any new `@testset` blocks in test/runtests.jl without removing existing ones. Cross-compatibility tests (a hash produced by Nitro verified by a Django hash string fixture, and vice versa) must be included as static assertion tests using recorded hash strings from real Django and Spring Security instances.
   - Docs: port the algorithmic descriptions, security rationale, and format specifications from PormG docs verbatim, but adapt all framing to Nitro's scope: replace `using PormG:` with `using Nitro:`, replace model-layer examples with handler-layer examples, and replace PormG-specific context with Nitro router/middleware context. The technical content (iteration counts, format diagrams, security notes) does not change. If the password material grows too large for docs/src/tutorial/sessions_and_auth.md, split it into docs/src/tutorial/passwords.md and register it in docs/make.jl.
3. Phase 3: Upstream PormG seam. Add a small additive pre-write hook in PormG's single-row and bulk write pipeline. The hook runs after validation and before field formatting and SQL parameterization. Concrete hook contract:
   - PormG calls `normalize_field_value(field, value)` for every field in the write payload before formatting.
   - Default implementation: `normalize_field_value(field, value) = value` (no-op, fully backward-compatible).
   - The NitroPormG extension overrides this for `PasswordField`: if `field.auto_hash` is true and the value is a plain `String` that does not look like an encoded hash (checked via `Nitro.Auth.is_password_usable`), call `Nitro.Auth.make_password(value)` and return the result. Otherwise return the value unchanged.
   - The hook must be applied consistently to `create`, `update`, `bulk_insert`, and `bulk_update` in PormG — the integration tests for Phase 4 will verify all four paths.
4. Phase 4: NitroPormG extension. Ship a weak-dependency extension registered via Project.toml, with optional public stubs only if Nitro needs them in src/exts.jl. The extension should detect PasswordField with auto_hash=true, hash raw passwords with Nitro.Auth.make_password, pass already-encoded hashes through unchanged, and reuse Nitro.Auth.check_password plus Nitro.Auth.password_needs_upgrade for verify and rehash helpers.
   - Error handling: if the value arriving at the hook is not a String (e.g. already a typed hash object or nil), the hook must not attempt hashing; it should pass the value through untouched. Invalid or unexpected types are a PormG validation concern, not a Nitro.Auth concern.
   - Phase 4 can be skeletonised (module, stubs, unit tests with mocked PormG) before Phase 3 lands. However, integration tests that exercise actual create/update/bulk round-trips are blocked on Phase 3 existing in PormG. Mark those tests as `@test_skip` with a note until Phase 3 is merged upstream.
5. Phase 5: Future Argon2. Add Argon2 additively in Nitro.Auth now as a feature-gated contract, not as a hard dependency or replacement. When the backend is ready, the NitroPormG extension should inherit it automatically through Nitro.Auth. The PHC string format must be used so hashes remain interoperable with other frameworks.

Verification

1. Keep all existing hash formats working by re-running test/auth_module_tests.jl unchanged.
2. Add static cross-compatibility assertions: include recorded hash strings produced by real Django 4.2 and Spring Security 6.x instances, and assert that `check_password` returns true for them. These are regression guards — if any algorithm implementation drifts, these tests will catch it immediately.
3. Add round-trip integration tests (not mocks) for create, update, bulk_insert, and bulk_update: write a plain password, read it back from the database, and confirm the stored value is a valid encoded hash that verifies with Nitro.Auth.check_password. Additionally confirm that passing an already-encoded hash through the same path stores it unchanged (idempotency). These tests require a live PormG connection (SQLite in-memory is sufficient) and are blocked on Phase 3.
4. Add an integration case proving a PormG model can store a hashed password and validate it through Nitro.Auth.
5. Build the docs and confirm the auth manual reflects the new canonical Nitro.Auth plus extension split, with Nitro-scoped examples.

Decisions

- Nitro.Auth stays canonical.
- ORM password behavior belongs in the extension, not Nitro core.
- PormG needs a small upstream seam because PasswordField metadata alone is not enough today.
- Argon2 should be additive and gated, never introduced by removing current behavior.
- Hash wire formats are a public compatibility contract. They are frozen. No migration step may change them.
- Tests are ported verbatim from PormG. They are the compatibility oracle, not a starting point for simplification.
- Docs are adapted to Nitro scope in framing and examples, but all algorithmic and security content is kept identical to PormG.


