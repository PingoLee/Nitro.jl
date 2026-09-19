## `context()` is removed — read the app context from the request with `getcontext(req)` (#31)

- **Version**: Unreleased
- **Nitro ref**: #31; `src/methods.jl`, `src/Nitro.jl`, `src/handlers.jl`,
  `src/core/pipeline.jl`, `src/core/parambinding.jl`, `src/core/request.jl`,
  `test/appcontext_race_tests.jl` (new)
- **Recorded**: 2026-09-13
- **Severity**: **breaking, and it fails LOUDLY.** `context()` no longer exists, so a call site
  raises `UndefVarError: context not defined`. There is no silent-wrong-value path: the name is
  gone, not repurposed. The `Context{T}` *type* and the `ctx::Context{T}` handler parameter are
  untouched — only the zero-argument accessor function is removed.

### What changed

`context()` read the app context out of the process-wide `Nitro.CONTEXT[]` singleton. That made
it the last reader of a shared mutable cell on the request path, and the cell was exactly the
thing #31 had to stop being read: `internalrequest(context = ...)` used to inject its per-call
context by *writing* it and restoring it in a `finally`, while `serve()` dispatches every request
on `Threads.@spawn`. A live request entering the pipeline inside that window was seeded with
another caller's context, and `getcontext(req)` then returned the wrong tenant's config for that
request's whole lifetime.

The app context is now carried **on the request**. Nothing downstream of the pipeline's outermost
layer reads `ServerContext.app_context[]` any more, so there is no shared state left to observe
mid-flight. A function that takes no request cannot participate in that, which is why `context()`
goes rather than being rewired.

### How to find the calls to migrate

```bash
# 1. The call itself. `ServerContext()`/`RequestContext()` are excluded by CASE, and the
#    `\b` is what keeps this off `getcontext()`.
rg -n '\bcontext\(\)' --type julia

# 1b. Reading the singleton directly, which is the same change by another route.
rg -n 'CONTEXT\[\]\.app_context' --type julia

# 2. Explicit imports of the name, which will now fail at load time rather than at the call.
rg -n 'import\s+Nitro:.*\bcontext\b|using\s+Nitro:.*\bcontext\b' --type julia

# 3. NOT matches to rewrite: the `Context{T}` type and the `ctx::Context{T}` parameter are
#    unchanged. This grep should come back with things you LEAVE ALONE.
rg -n 'Context\{' --type julia
```

### Migrate your app

| before | after | note |
|---|---|---|
| `context()` | `getcontext(req)` | needs the request in scope |
| `context()` in a no-argument handler | declare `function(; context)` | the kwarg resolves per request |
| `context()` returning `missing` when unset | `getcontext(req)` returns `nothing` | the sentinel changed too |

```julia
# ✗ before
path("/whoami", function() return Res.json(context()) end, method="GET")

function audit(req)
    cfg = context()
    log_to(cfg.audit_sink, req.target)
end

# ✓ after
path("/whoami", function(; context) return Res.json(context) end, method="GET")

function audit(req)
    cfg = getcontext(req)          # or getcontext(req, AppConfig) on the request path
    log_to(cfg.audit_sink, req.target)
end
```

Note the sentinel change: `context()` returned `missing` when no context was configured,
`getcontext(req)` returns `nothing`. If you tested with `ismissing(...)`, switch to
`isnothing(...)`.

### One more behavior change, if you read the singleton directly

Middleware that reached `Nitro.CONTEXT[].app_context[]` instead of the request used to observe
the **override** while an `internalrequest(context = ...)` was in flight — that is precisely the
leak this change removes. It now observes the server's context, always. If a test relied on
driving middleware through `internalrequest(context = ...)` and reading the global, it will now
see the `serve(context = ...)` value; read `getcontext(req)` instead and it gets the override as
intended. Reading the singleton from the request path is no longer supported: the app context is
carried on the request, and nothing downstream of the pipeline's outermost layer reads that cell.
