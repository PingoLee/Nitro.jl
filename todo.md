# Nitro.jl Refactor TODO

This file tracks what Nitro itself should do, and what should live in reusable apps/packages.

## External Reference App
- Reference migration target: BI server currently built with Genie.jl.
- Local path for context gathering in future chats: /home/pingo03/app/bi_server
- Reference ORM/Persistence: /home/pingo03/app/PormG.jl
- Start context gathering from these areas first:
  - `Project.toml` for dependencies and local package sources
  - `routes.jl` for endpoint surface area
  - `src/JwtAuth.jl`, `src/Security.jl`, and `src/WebServer.jl` for auth/cookie/security behavior
  - `src/Workers.jl` and `src/CtrlWorkerBi.jl` for job orchestration and queue semantics
  - `src/CtrlApiBpa.jl` for PormG/DataFrame-heavy API behavior
- When opening a new chat, mention that Nitro.jl is the framework repo and `bi_server` is the external Genie app being migrated to Nitro.

## Architecture Direction
- [ ] Keep Nitro core focused on HTTP, routing, middleware, request/response ergonomics, cookies, sessions, static files, SPA fallback, SSE, and websockets.
- [ ] Do not put JWT business logic, worker queues, cron schedulers, or ORM-specific code inside Nitro core.
- [ ] Treat authentication and background processing as reusable apps/packages that can be installed in multiple Nitro projects.
- [ ] Keep PormG integration outside Nitro core; Nitro should only provide clean extension points for apps that use PormG.
- [ ] Use this config philosophy consistently: Nitro should give a clean app-config pipeline, but the config object should live in the app layer, not inside Nitro core.

## Nitro Core

### Routing
- [x] Make `path()`, `urlpatterns()`, and `include_routes()` the only documented routing API.
- [x] Remove old routing macros and old route-registration style from the public API.
- [x] Remove or deprecate exported `route()` usage from docs/examples so the framework story is consistent.
- [x] Add missing path converters needed for real apps, especially `<uuid:key>`.
- [x] Verify nested route modules work cleanly for multi-file app structures.

### Request/Response Ergonomics
- [x] Standardize on `req.params`, `req.query`, `req.session`, and `req.ip` for handler ergonomics.
- [x] Keep `Res.json()`, `Res.status()`, and `Res.send()` as the default response style in examples and docs.
- [x] Provide lazy request accessors via `LazyRequest` (JSON, form, text, headers).
- [x] Implement `req.input` (or `req.data`) as a unified accessor that merges path parameters, query string, and body (JSON or Form).
    - *Decision*: Nitro provides this "merged" view to simplify simple handlers, but keep typed `Extractors` as the recommended way for complex validation.
- [x] Improve docs for request parsing so Genie users have a clear migration path.
- [x] Add `req.form` and `req.json` shorthands to `HTTP.Request` extension in `src/core.jl`.
- [x] Ensure `Res` module includes common helper for file downloads and custom redirects.

### Security Foundation
- [x] Keep Nitro security primitives generic: cookie helpers, session middleware, bearer middleware, guards, CORS, IP extraction, and rate limiting.
- [x] Create a unified `Nitro.Auth` module for authentication (JWT, Cookies, Passwords, CSRF).
- [x] Implement a cookie-auth middleware hook so reusable auth apps can authenticate from signed/encrypted cookies without duplicating middleware wiring.
- [x] Fix `SessionMiddleware` cookie configuration so `secure` is configurable and works in local development over plain HTTP.
- [x] Review default cookie settings for `HttpOnly`, `Secure`, `SameSite`, and expiration behavior.
- [x] Add docs for recommended middleware order: global prefix -> custom middleware -> defaults -> router.

### Sessions
- [x] Keep session support in core, but make the storage contract reusable via `AbstractSessionStore`.
- [x] Define and document a store interface for memory, Redis, database, or custom backends.
- [x] Implement `MemoryStore` as a default provider.
- [x] Ensure session middleware can use external stores without depending on PormG directly.
- [x] Add tests for persistent session stores via adapters, not core-specific database code.

### Extension Points
- [ ] Document how external apps/packages plug into Nitro via middleware, route modules, and package extensions.
- [ ] Provide one official example of a reusable Nitro app package.
- [x] Verify weak-dependency patterns stay clean and do not leak app dependencies into `src/`.
- [x] Integrated `Bcrypt.jl` as a standard dependency for secure auth.

## Auth Module (Nitro.Auth)

> **Status**: Core implementation finished and integrated into Nitro.jl.

- [x] Implement JWT encode/decode with support for multiple keys and `kid` rotation.
- [x] Validate `iat`, `exp`, `nbf`, issuer, and audience claims where configured.
- [x] Add support for access-token and refresh-token flows.
- [x] Support both bearer-token auth and cookie-based auth in a unified `req.user` context.
- [x] Provide login/logout helpers (`set_auth_cookie!`, `clear_auth_cookie!`) that handle cookies safely.
- [x] Expose reusable guards like `login_required`, `role_required`, and claim-based/permission-based guards.
- [x] Provide middleware that injects authenticated user/claims into the request context (`req.user`).
- [x] Add CSRF protection strategy for cookie-based auth.
- [x] Ported and expanded `PormG` Passwords module:
    - [x] `PasswordEncoder` abstract interface.
    - [x] `PBKDF2PasswordEncoder`, `BCryptPasswordEncoder`.
    - [x] `SpringSecurityPBKDF2PasswordEncoder` for legacy compatibility.
    - [x] `DelegatingPasswordEncoder` for multi-algorithm support.
    - [x] `PasswordValidator` with i18n support (`Printf`-based).
- [x] Keep the module storage-agnostic via `AbstractSessionStore`.
- [x] Add comprehensive tests for invalid signature, expired tokens, i18n passwords, and cross-encoder matching.

## Workers App

> **Strategy**: Same as auth — module-first inside the app, extract to `NitroWorkers.jl`
> only when a second app needs it, or when independent horizontal scaling becomes necessary.
>
> **Do NOT design as a separate process yet.** Workers hold live Julia `Task` references,
> process-local database connections, and `Channel`-backed queues. A separate worker process
> means another Julia cold start, re-established DB connections, and IPC overhead — not worth
> it for a single-machine server. Keep everything in-process with `Threads.@spawn`.
