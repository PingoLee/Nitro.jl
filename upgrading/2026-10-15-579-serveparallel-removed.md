## `serveparallel()` is removed — call `serve()` (#579)

- **Version**: Unreleased
- **Nitro ref**: [#579](https://github.com/PingoLee/Nitro.jl/issues/579) ; `src/methods.jl`
- **Recorded**: 2026-10-15
- **Severity**: **breaking (removed function)** — a call to `Nitro.serveparallel` no longer
  starts a server.

### What changed

`Nitro.serveparallel(; kw...)` was a deprecated shim left over from the Oxygen.jl fork: it logged a
warning and forwarded every keyword to `serve()`. Since `serve()` lost its `parallel` keyword and
always runs each request on its own task (#525, see that entry), the shim had nothing left to say,
and it is gone. There is no replacement stub; the call now fails where it is made:

```
UndefVarError: `serveparallel` not defined in `Nitro`
```

It was never exported, so only a qualified `Nitro.serveparallel(...)` call, or an explicit
`using`/`import Nitro: serveparallel`, is affected. (After such an import the error names the
importing module instead of `Nitro`.)

### How to find the calls to migrate

```bash
rg -n 'serveparallel' <app>/src <app>/bin <app>/test
rg -n 'UndefVarError: `serveparallel`' <app's startup log>
```

### Migrate your app

```julia
# ✗ before
Nitro.serveparallel(; host = "0.0.0.0", port = 8080)

# ✓ after — the shim forwarded to the argument-less serve(), which serves the global app
serve(; host = "0.0.0.0", port = 8080)

# ✓ or, if your app already holds an `App` (app = App(mod = @__MODULE__)), serve that
serve(app; host = "0.0.0.0", port = 8080)
```

If the call still passes `docs`, `metrics` or `parallel`, delete them too: `serve()` rejects all
three (`parallel` since #525 — see that entry), and the shim passed them straight through.
