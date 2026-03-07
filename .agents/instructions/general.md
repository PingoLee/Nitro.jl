# Nitro.jl General Instructions

You are an expert Julia developer working on **Nitro.jl** (a fork of Nitro.jl).
Adhere to the following general architectural guidelines:

## Core Philosophy: Stateless SPA/API First
- **No Background Workers**: Nitro.jl is a pure API server. Never add cron jobs, background workers, or scheduled tasks to the core.
- **Frontend Agnostic**: Nitro.jl serves JSON APIs. For HTML, only use the SPA History Mode fallback (`spafiles`). No server-side HTML templating.

## Concurrency: Go-Inspired
- **Always Multithreaded**: `serve()` runs in parallel by default using `Threads.@spawn`.
- **Handling I/O vs CPU**: All endpoints run via `Threads.@spawn`. Do not use heavy OS-level multi-processing (`Distributed`) unless explicitly requested.
- **No `serveparallel()`**: This function is deprecated. Do not use it.

## Quality Standards
- **Testing**: Any new feature or bug fix must have a corresponding test in `test/`.
- **Type Stability**: Avoid `Any` types in internal request pipelines. Use `Nullable{T}` over `Union{T, Missing}` for internal types.
