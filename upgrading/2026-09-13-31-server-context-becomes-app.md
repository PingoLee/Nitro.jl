## `ServerContext` is now the exported `App`, and every public function takes one (#31)

- **Version**: 0.4.0
- **Nitro ref**: #31; `src/context.jl`, `src/methods.jl`, `src/Nitro.jl`, and every `src/` file
  that named the type; `test/app_tests.jl` (new), `docs/src/`
- **Recorded**: 2026-09-13
- **Severity**: **breaking, and it fails LOUDLY.** `ServerContext` no longer exists under that
  name, so every reference raises `UndefVarError: ServerContext not defined`. There is no
  silent-wrong-value path — the name is gone, not repurposed, and `App` is a straight rename of
  the same concrete struct with the same three fields.

### What changed

Every public API bound to the process-wide `CONTEXT[]` singleton, so two apps with different
config could not coexist. `ServerContext` already supported that, but it was not exported and its
name read like internals — and, more to the point, the `(ctx, …)` methods were defined in
`Nitro.Core` while `src/methods.jl` *shadowed* those names in `Nitro`, so `using Nitro` could not
reach a single one of them.

`App` is now exported, and `src/methods.jl` carries an `(app::App, …)` method for all fourteen
public functions: `serve`, `terminate`, `internalrequest`, `urlpatterns`, `url`, `router`,
`staticfiles`, `spafiles`, `dynamicfiles`, `configcookies`, `get_cookie`, `set_cookie!`,
`getexternalurl`, `worker_startup`.

The singleton stays. The argument-less forms are unchanged and still work; `App` is what you reach
for when you want a second app, or a test that touches no global.

`App` also gains a `show` that prints only its module and serving state. The default would have
walked `service`, whose router and middleware closures capture the cookie/JWT `secret_key`, DB
credentials and API keys — the same disclosure the `NitroStreamHandler` override prevents for
`HTTP.Server`.

### How to find the calls to migrate

```bash
# 1. The type name, anywhere.
rg -n '\bServerContext\b' --type julia

# 2. Direct reads of the singleton. These still WORK, but each one is a place an explicit
#    `App` is now the better answer -- especially in tests.
rg -n 'Nitro\.CONTEXT\[\]' --type julia

# 3. NOT a match to rewrite: `Context{T}`, `getcontext`, and `serve(context = ...)` are the
#    app-context PAYLOAD and are unchanged. Only the handle was renamed.
rg -n 'Context\{|getcontext' --type julia
```

### Migrate your app

| before | after | note |
|---|---|---|
| `Nitro.Core.ServerContext()` | `App(mod = @__MODULE__)` | now exported; no `Nitro.Core.` prefix |
| `ServerContext(service=…, mod=…)` | `App(service=…, mod=…)` | same fields, same order |
| `Nitro.CONTEXT[]` in app code | `app` you constructed | the singleton still exists, but an explicit handle is preferable |
| `urlpatterns("", routes)` | `urlpatterns(app, "", routes)` | argument-less form still works |

```julia
# ✗ before
ctx = Nitro.Core.ServerContext()
Nitro.Core.Routing.urlpatterns(ctx, "", Routes.urlpatterns(config))
Nitro.Core.serve(ctx; port = 8080, context = config)

# ✓ after
app = App(mod = @__MODULE__)
urlpatterns(app, "", Routes.urlpatterns(config))
serve(app; port = 8080, context = config)
```

**Pass `mod = @__MODULE__` yourself.** It is what `serve(revise = :lazy|:eager)` tracks, and `App`
deliberately has no default for it: a `@__MODULE__` default would expand where `App` is *defined*
(inside Nitro) rather than where it is called, silently binding every app to the framework module.
Leaving it `nothing` is fine if you do not use `revise`; `serve` warns if you ask for `revise`
without it.
