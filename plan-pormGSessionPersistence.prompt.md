## Plan: PormG Session Persistence

Add a reusable PormG-backed session store through Nitro's existing weak-dependency extension seam, keeping all direct PormG usage inside the extension layer and leaving core session middleware store-agnostic. This is a SPA/API-first design: sessions use **fixed TTL from last write** (no sliding expiry), and the store interface stays at exactly the 4 methods already declared in `src/types.jl`. Session regeneration (post-login ID cycling) belongs in core `src/cookies.jl` because it is pure composition of existing store methods with no PormG dependency — all store backends benefit automatically.

**Steps**
1. Confirm the extension loading boundary and public API surface. Reuse the existing weak dependency declared in `Project.toml` and keep direct `using PormG` usage confined to the Nitro PormG extension. Decide the exported constructor name and expected configuration inputs for the new store. This step blocks all implementation.
2. Define the persistence model and serialization contract inside the PormG extension. Add a session record model owned by the extension with, at minimum, a stable session identifier, serialized session payload, and expiry timestamp. Keep the schema database-agnostic so it works with either SQLite or PostgreSQL via PormG. **The expiry column must be declared with a database index** — without it, `cleanup_expired_sessions!` degrades to a full table scan at scale (the same issue Django solved with an indexed `expire_date` on `django_session`). This step depends on 1.
3. Implement the concrete store type in the extension. Add a `PormGSessionStore` that subtypes Nitro's session-store interface and implements exactly the 4 existing methods: `Base.get`, `set_session!`, `delete_session!`, and `cleanup_expired_sessions!`. Map Nitro's TTL semantics to a persisted `expires_at` absolute timestamp, and make payload round-tripping explicit with JSON serialization for `Dict{String,Any}` values. No sliding expiry — sessions expire at a fixed point from the last write; SPA clients re-authenticate when they receive a 401. The `SessionMiddleware` flow requires **no changes**. This step depends on 2.
4. Expose the store cleanly from the extension entrypoint. Update the extension module so consuming applications can instantiate the store without importing PormG from Nitro core, and ensure the existing password-hook behavior remains intact. No additional helpers belong in the extension. This step depends on 3.
   Separately, add `regenerate_session!(req; ttl)` to **`src/cookies.jl`** in core. It is purely: (a) generate a new session ID, (b) call `set_session!` with the current session data under the new ID, (c) call `delete_session!` on the old ID, (d) update `req.context[:session_id]` so the middleware writes the new cookie on the way out. Because it only calls the abstract store interface, every backend (`MemoryStore`, `PormGSessionStore`, future Redis store) gets session-fixation protection for free. This step is independent of the extension and can be implemented alongside step 3.
5. Add focused tests for the new backend. Extend the session-store tests to validate the PormG-backed implementation against the same interface expectations as `MemoryStore`, covering create, read, overwrite, delete, expiry handling, and cleanup. Specifically add: (a) a fixed-TTL expiry test that confirms a session written with `ttl=N` is absent after the expiry timestamp passes, (b) a `cleanup_expired_sessions!` test that confirms only expired rows are deleted and the index is exercised, (c) a `regenerate_session!` test against `MemoryStore` that confirms the old ID is gone and the new ID carries identical data — this lives in core session tests, not PormG extension tests, and (d) an integration test that exercises the full login → `regenerate_session!` → protected-route flow with `SessionMiddleware`. These tests can run in parallel with documentation work once step 3 is stable.
6. Add development wiring for the local PormG checkout. Document or temporarily configure test/development dependency resolution so Nitro loads the local PormG checkout during verification, without hard-coding that local path into Nitro's shipped source. This step can run in parallel with 5 after 3 is complete.
7. Update docs for the new persistent session option. Replace the older session tutorial guidance that suggests hand-rolled database storage with a documented PormG-backed path that follows Nitro's current `SessionMiddleware` architecture and the repository's Django-style routing conventions. This step depends on 4 and can run in parallel with 5.

**Relevant files**
- `c:/Sistemas/Nitro.jl/ext/NitroPormGExt.jl` — current extension boundary that already owns all direct PormG imports and should expose the new session store.
- `c:/Sistemas/Nitro.jl/src/types.jl` — defines `AbstractSessionStore`, `get_session`, `set_session!`, `delete_session!`, `cleanup_expired_sessions!`, and the `MemoryStore` reference behavior to mirror. No new methods needed here.
- `c:/Sistemas/Nitro.jl/src/middleware/session_middleware.jl` — current `SessionMiddleware` flow and the exact store type expected by the middleware. **No changes required.**
- `c:/Sistemas/Nitro.jl/Project.toml` — weak dependency and extension registration for PormG; likely only verification-oriented updates should be needed.
- `c:/Sistemas/Nitro.jl/src/cookies.jl` — where `regenerate_session!` will be added; already exports session cookie helpers consumed by the middleware.
- `c:/Sistemas/Nitro.jl/test/sessionstores_tests.jl` — base store-interface tests to expand for a persistent backend.
- `c:/Sistemas/Nitro.jl/test/session_tests.jl` — middleware-level session behavior to reuse for persistence integration coverage.
- `c:/Sistemas/Nitro.jl/docs/src/tutorial/cookies/sessions.md` — session tutorial that currently points users toward custom database wiring and should be updated to the supported PormG-backed path.
- `c:/Sistemas/Nitro.jl/docs/src/index.md` and `c:/Sistemas/Nitro.jl/docs/src/api.md` — public docs that describe `SessionMiddleware` and may need a short persistence example or API note.

**Verification**
1. Run the targeted session-store and middleware tests under `Pkg.test()` with PormG available, verifying both the existing memory store and the new PormG store continue to pass.
2. Add a test fixture or setup path that provisions the session table (with index) for both SQLite and PostgreSQL-compatible PormG flows, then verify expiry cleanup deletes only expired rows and leaves non-expired rows untouched.
3. Manually exercise a minimal Nitro app with the full login flow: first request creates a session, handler calls `regenerate_session!`, second request loads under the new ID, old ID is verified absent, expired sessions are treated as missing.
4. Verify `regenerate_session!` works identically against `MemoryStore` without PormG present — confirming it is store-agnostic.
5. Verify the extension still loads only when PormG is present and that Nitro core remains importable without PormG installed.

**Decisions**
- Included: a reusable Nitro feature implemented inside the PormG extension, owned by Nitro rather than by each consuming app.
- Included: a database-agnostic persistence model expressed through PormG, not a store tied only to SQLite or only to PostgreSQL.
- Included: schema ownership inside the Nitro PormG extension, so consumers get a ready-made session model and store.
- Excluded: importing PormG anywhere under `src/`, changing the core middleware contract, or hard-coding the developer's local PormG path into Nitro runtime code.
- Excluded: `touch_session!` / sliding expiry — a SPA API backend makes many calls per user action; updating expiry on every read would produce one DB write per API call with no security benefit.
- Excluded: background pruning workers; expired-session cleanup continues through the existing on-request probabilistic hook.
- Excluded: making `regenerate_session!` a PormG-extension concern — it is pure store-interface composition and belongs in core so all backends benefit.

**Further Considerations**
1. Serialization format should be fixed early. Recommendation: JSON text for the session payload, because Nitro already depends on JSON and the current store type is `Dict{String,Any}`.
2. Schema bootstrapping needs an explicit decision during implementation. Recommendation: keep runtime store operations separate from migrations, and use PormG migrations or setup helpers in tests rather than auto-creating tables on every request.
3. If extension code grows beyond one file, move to an extension subdirectory layout while keeping `NitroPormGExt` as the single public module entrypoint.
4. Session TTL strategy for SPAs: keep `max_age` short (e.g. 1–4 hours) and let the SPA handle silent re-authentication via a dedicated `/auth/refresh` endpoint rather than extending sessions on every request. This removes the need for sliding expiry at the framework level entirely.
