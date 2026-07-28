# Changelog

Notable changes to Nitro.jl. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org) as applied by Julia's Pkg.

**Pre-publish versioning policy (`0.y.z`)**: `y` bumps on breaking changes, `z` bumps on
everything else (features and fixes). This matches Julia's Pkg compat semantics — a
downstream `compat = "0.y"` bound accepts `0.y.*` and rejects the next breaking release.

## [0.4.0] — Unreleased

Claim-based identity & authorization (#46): a declarative, safe-by-default auth layer.
Nitro is pre-registry, so this release favors the clean architecture over compatibility
shims; each break below includes its migration.

### Added

- **`Principal`** — the canonical authenticated principal (resolves the `req.user`
  contract, #4). An immutable, dict-like wrapper over verified claims with typed fields:
  `id` (normalized identity), `kid` (keyset-verified key id), `source` (`:claim`/`:kid`).
  Claims read through dict-style; JSON serialization is exactly the claims object.
- **`jwt_validator` identity configuration** — `identity_claim="sub"` (default) or any
  claim; `identity_from=:kid` to make the verified signer the principal (requires a
  keyset).
- **`jwt_validator(...; profile=:strict)`** — production preset: requires
  `issuer`/`audience` at construction, forces `require_exp=true`.
- **`required_claims=[...]`** on `decode_jwt`/`validate_claims`/`jwt_validator` — reject
  tokens missing named claims.
- **`claim_required(claim, value; kind=:equals|:contains)`** — declarative claim guard;
  `role_required`/`permission_required` are now thin aliases over it (behavior
  unchanged).
- **`kid_required(allowed)`** — authorize by *verified* key id (403 when the signing key
  isn't allowed for the route). Only keyset-verified kids count; a `kid` header on a
  single-secret token is never trusted.
- Documented auth error contract: **401** unauthenticated / **403** authenticated-but-
  unauthorized / **302** `login_required` redirect. New `docs/src/tutorial/authentication.md`.

### Fixed

- `CookieAuthMiddleware` no longer turns a throwing validator (e.g. expired JWT) into a
  500 — it returns the same 401 as `BearerAuth` (#24). It also gains the two-argument
  validator form and the `(user, claims)` tuple contract, aligning both auth middlewares.
- `session_user_validator` no longer mistakes the request object passed by middleware
  arity-dispatch for session data.
- `RateLimiter(strategy=:sliding_window)` no longer holds its internal lock while the
  downstream handler runs (#15). One slow request used to serialize every other request
  through the same limiter, defeating Nitro's per-request `Threads.@spawn` concurrency;
  rate-limit rejections also had to queue behind it. The limit decision and the
  `X-RateLimit-*` values are now computed under the lock and the handler is called after
  it is released — emitted header values are unchanged. `strategy=:fixed_window` was
  already correct.

### Breaking (pre-release; architecture over compat)

- **`jwt_validator` (without `user_validator`) returns a `Principal`** instead of the raw
  claims object. Dict-style *reads* (`user["sub"]`, `get`, `haskey`, iteration, JSON
  shape, `==`) are unchanged. Migrations:
  - `req.user.sub` property sugar → `req.user["sub"]` (`.id`/`.claims`/`.kid`/`.source`
    are the only properties).
  - Mutating the principal (`req.user["k"] = v`) → build your own user object in a
    `user_validator`, or copy with `Dict(req.user)`.
- **`user_validator` now receives the `Principal`** (dict-compatible superset of the old
  claims argument) and the tuple contract is `(user, principal)` — so
  `req.context[:auth_claims]` now holds the `Principal`, not a raw claims dict.
- `jwt_validator(...; with_kid=...)` is now a construction-time `ArgumentError` — the kid
  flows through the `Principal` instead.

## [0.3.0] and earlier

Pre-changelog history; see the git log.
