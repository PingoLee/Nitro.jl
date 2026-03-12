---
applyTo: "**/*.jl"
description: "Nitro.jl core architecture rules — philosophy, concurrency, quality standards, backward compatibility"
---

# Nitro.jl Global Architecture Rules

You are an expert Julia developer working on **Nitro.jl** (a fork of Nitro.jl).
Whenever you write code, write tests, or propose architecture for this repository, you MUST adhere to the following strict guidelines:

## 1. Core Philosophy: Stateless SPA/API First
- **No Background Workers**: Nitro.jl is a pure API server. Never add cron jobs, background workers, or scheduled tasks to the core. Those belong in a separate worker process.
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
- Use path converters for parameters (`<int:id>`, `<str:slug>`, `<uuid:key>`).
- Sub-routers should be logically separated into their own files and imported using `include_routes()`.

## 4. Request and Response Ergonomics
- **Request Properties**: Use the strict shorthand property accessors (`req.params`, `req.query`, `req.session`, `req.ip`) instead of `req.context` lookup.
- **Response Builders**: Always return responses using the global `Res` module functions (`Res.json()`, `Res.status()`, `Res.send()`). Avoid returning raw dictionaries or raw strings directly from handlers.

## 5. Security & Middleware
- **Linear Execution**: Middleware executes strictly Top-Down: Global Prefix Middleware -> Custom Middleware -> Defaults -> Router.
- **Guards vs Middleware**: Use Guards (`login_required`, `role_required`) for route-level authentication/authorization. Use Middleware (`SessionMiddleware`, `RateLimiter`) for global or router-level mutation/checks.

## 6. Persistence: PormG.jl Extension
- PormG.jl is the dedicated ORM but is a **Weak Dependency**.
- Any code importing `PormG` MUST live inside `ext/NitroPormGExt/`.
- Never import `PormG` in `src/`. The core web server must remain database-agnostic.

## 7. Quality Standards
- **Testing**: Any new feature or bug fix must have a corresponding test in `test/`. Use `Pkg.test()` for verification.
- **Type Stability**: Crucial for high-throughput HTTP handling. Avoid `Any` types in internal request pipelines. Use `Nullable{T}` over `Union{T, Missing}` for internal types.

## 8. No Backward Compatibility with Nitro.jl
- Nitro.jl is a **new framework**. There is zero obligation to maintain backward compatibility with Nitro.jl APIs.
- Old patterns (macro routing, `serveparallel()`, `@staticfiles`, `@dynamicfiles`) are permanently deleted, not deprecated.
