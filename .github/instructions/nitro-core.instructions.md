---
description: Nitro.jl core architecture — philosophy, concurrency, routing, security, PormG isolation, quality standards
applyTo: "**/*.jl"
---

# Nitro.jl Core Architecture & Implementation Rules

You are an expert Julia developer working on **Nitro.jl**.
Whenever you write code, write tests, or propose architecture for this repository, you MUST adhere to the following strict guidelines:

## 1. Core Philosophy: Stateless SPA/API First
- **No Background Workers in core routing**: Nitro.jl is a pure API server. Scheduled/cron logic does not belong in the HTTP core; background task queues use the optional `Workers` module and separate startup configuration.
- **Frontend Agnostic**: Nitro.jl serves JSON APIs. If it serves HTML, it is exclusively via the SPA History Mode fallback (`spafiles`). Do not implement server-side HTML templating logic unless explicitly requested.

## 2. Concurrency: Go-Inspired
- **Always multithreaded**: `serve()` runs in parallel mode by default using `Threads.@spawn`.
- **Handling I/O vs CPU**: All endpoints run via `Threads.@spawn`. Do not add heavy OS-level multi-processing (`Distributed` or multi-process clustering) unless explicitly requested. Julia's thread pool is sufficient.
- **No `serveparallel()`**: This function is deprecated. Do not use or suggest it.

## 3. Routing: Django-Style ONLY
- The ONLY way to define routes is via `path()`, `urlpatterns()`, and `include_routes()`.
- **Macro routing is DELETED**: `@get`, `@post`, `@put`, `@patch`, `@delete`, `@route`, `@stream`, `@websocket` do not exist. Never suggest or recreate them.
- **Function routing is DELETED**: `get()`, `post()`, `put()`, `patch()`, `delete()` as route registration functions do not exist.
- The internal `route()` function exists only as plumbing for `path()` and `urlpatterns()`. It is NOT public API.
- **Path Converters**: The registry in `src/routing.jl` defines exactly five — `<int:…>`, `<str:…>`, `<float:…>`, `<bool:…>`, `<uuid:…>`. An unknown converter name throws at `path()` time. Adding one means adding it to `CONVERTERS` *and* to the docs conventions.
- **Modularity**: Sub-routers should be logically separated into their own files and imported using `include_routes()`.

## 4. Request and Response Ergonomics
- **Request Properties**: Use the strict shorthand property accessors (`req.params`, `req.query`, `req.session`, `req.ip`) instead of `req.context` lookup.
- **Response Builders**: Always return responses using the global `Res` module functions (`Res.json()`, `Res.status()`, `Res.send()`, `Res.html()`). Raw returns *are* auto-formatted as a convenience — a `Dict`/struct becomes a JSON body, a `String`/primitive becomes `text/plain`. That auto-formatting is **not** an XSS hole: raw strings are deliberately served as `text/plain` *without* content-sniffing, so an attacker-influenced value can never be reclassified as `text/html`/JS. The reason to prefer `Res.*` is **intent, not safety** — it makes the status code and content type explicit instead of inferred from the return type.
- **`Res` is the response-building namespace for handlers (#28).** `Res` ([`src/response.jl`](../../src/response.jl)) provides exactly **`json`, `html`, `send`, `status`, `file`, `redirect`**. There are no top-level `html()`/`js()`/`css()`/`xml()`/`text()`/`binary()`/`file()`/`redirect()` constructors any more; the bare names `text`, `json` and `binary` now belong **exclusively to the request-body parsers** in [`src/utilities/bodyparsers.jl`](../../src/utilities/bodyparsers.jl) (`json(req)`, `json(req, T)`, `text(res)`, …). One name, one direction.
  - **Two *content* builders live outside `Res`, both for extensions, neither for handler code:** `Util.response` (content-sniffing, used by the templating extensions — see the sink rule below) and `protobuf` in [`ext/ProtoBufExt.jl`](../../ext/ProtoBufExt.jl). Middleware and core also construct fixed error and redirect responses with `HTTP.Response(...)` directly (auth rejections, CORS preflights, guard denials, `NOT_FOUND`) — those carry no caller content and are not sinks. Application handlers use `Res`.
  - **There are three markup/script sinks, and a review must grep for all three.** (1) `Res.html(...)`. (2) `Res.send(...; content_type=...)` naming a markup or script type — `Res.send` defaults to `text/plain`, but `content_type` is an opt-in escape hatch, so `Res.send(x; content_type="text/html")` is exactly as dangerous as `Res.html(x)`. (3) **Template rendering** — `mustache(...)` and `otera(...)` ([`ext/MustacheExt.jl`](../../ext/MustacheExt.jl), [`ext/OteraEngineExt.jl`](../../ext/OteraEngineExt.jl)) build their response through `Util.response` ([`src/utilities/misc.jl`](../../src/utilities/misc.jl)), which **content-sniffs with `HTTP.sniff`** when no `mime_type` is given and honours an explicit `mime_type="text/html"` otherwise — and neither engine HTML-escapes by default. A grep for `html(` alone misses sinks 2 and 3; grep `content_type`, `mustache(` and `otera(` too.
  - **There is one `file` and one `redirect`, and both changed defaults.** `Res.file(path)` now serves **inline** — `Content-Disposition` is emitted only when you pass `disposition=` or `filename=` — which is what `staticfiles`/`spafiles`/`dynamicfiles` depend on. `Res.redirect(url)` is **302**; pass `status=307` to preserve the request method and body.
- **Reusing/sharing a `Response` across requests is SAFE in Nitro — the upstream footgun is handled in core.** Upstream HTTP.jl 2.x has a footgun: a `Response` built from a **`String`** stores its body as a single-use `BytesBody` read cursor, and HTTP's own write path (`_write_response_body_to_stream!`) *consumes and then closes* that cursor. So under raw `HTTP.serve!`/`listen!`, a `String`-bodied `Response` reused across requests serves a truncated/empty body on the 2nd+ send (silent in some versions, a hard `truncated fixed-length HTTP/1 body` parse error in others). **Nitro neutralizes this**: `src/core.jl`'s `_write_response_body!` writes `BytesBody.data` directly (non-destructively), so a shared/`const` `Response` can be emitted any number of times. This is *why* the module-level `const` error responses in `src/middleware/auth_middleware.jl` (`INVALID_HEADER`, `EXPIRED_TOKEN`, `MISSING_COOKIE`) are correct, not bugs — and module-level `const` response objects are an **endorsed** Nitro pattern (full rationale, the cross-framework comparison, and the design patterns: [`docs/design/response-body-lifecycle.md`](../../docs/design/response-body-lifecycle.md)). Three rules follow:
  - **Do NOT** reintroduce HTTP's consuming write path or route response bodies through `_write_response_body_to_stream!`. The non-consuming write is load-bearing and is coupled to the `HTTP.BytesBody.data` internal field, which `test/http_internals_contract_tests.jl` canaries and `test/middleware/authmiddleware_tests.jl` covers behaviorally. A regression there silently empties every reused response.
  - If you ever need reuse-safety *outside* Nitro's write path (e.g. handing a `Response` straight to raw `HTTP.serve!`), give it a `Vector{UInt8}` body — HTTP writes those non-destructively (HTTP.jl #1254). The `String`→`BytesBody` consume-and-close-on-write is **intentional** upstream behavior (HTTP.jl #1272), not a bug to wait on.
  - **Header-adding middleware must NOT mutate the response it gets back from an inner layer** (it may be a shared `const`, and Nitro is multithreaded). Build a new response with `add_response_headers(resp, extra)` or own the headers first with `own_response_headers(resp)` (both in `src/utilities/misc.jl`) — never `append!`/`setheader`/`set_cookie!` on a returned response. In-place mutation leaks per-request headers (an echoed `Origin`, a session `Set-Cookie`) across requests and races other threads. Nitro's CORS/session/CSRF/rate-limiter middleware all follow this; regression: `test/middleware/shared_response_mutation_tests.jl`.

## 5. Security & Middleware
- **Linear Execution**: Middleware executes strictly Top-Down: Global Prefix Middleware -> Custom Middleware -> Defaults -> Router.
- **Guards vs Middleware**:
  - Use **Guards** (`login_required`, `role_required`, `permission_required`, `claim_required`, `kid_required`) for route-specific authentication or authorization. Guards are functions that run before the handler and can abort the request early. `role_required` and `permission_required` are thin aliases over `claim_required`.
  - **Guards attach through `GuardMiddleware`, not a `guards=` keyword.** `path()` takes `method`, `methods`, `name`, and `middleware` only — a guard reaches a route as `middleware=[GuardMiddleware(login_required(), …)]`, or app-wide in the `serve(middleware=…)` pipeline.
  - **Auth error contract**: `401` = unauthenticated (auth middleware; a throwing validator maps to 401, never 500), `403` = authenticated but not authorized (guards), `302` = `login_required` browser redirect. The authenticated principal is the `Principal` type (`src/types.jl`) — an immutable dict-like wrapper over verified claims with typed `id`/`kid` fields.
  - Use **Middleware** (e.g., `SessionMiddleware`, `RateLimiter`) for global, application-wide, or router-wide checks and mutations.
- **Session Management**: Ensure `SessionMiddleware` is configured properly in the global pipeline for stateful apps. Access session data directly via `req.session`.

## 6. Persistence: PormG.jl Extension (Weak Dependency)
- **Extension Isolation**: Any code importing or directly depending on `PormG` MUST live inside `ext/NitroPormGExt.jl`.
- **Core Purity**: Never import `PormG` in `src/`. The core web server must remain database-agnostic.
- **Connection Management**: Do not manage raw database connections in route handlers. Use the middleware/context provided by the `NitroPormGExt` extension.

## 7. Quality Standards
- **Testing**: Any new feature or bug fix must have a corresponding test in `test/`. Use `Pkg.test()` for verification.
- **Type Stability**: Crucial for high-throughput HTTP handling. Avoid `Any` types in internal request pipelines. Nitro's optional-value alias is `Nullable{T} = Union{T, Nothing}` (`src/types.jl`) — write `Nullable{T}` rather than spelling out `Union{T, Nothing}`, and do not reach for `Missing`, which Nitro does not use for absence.
