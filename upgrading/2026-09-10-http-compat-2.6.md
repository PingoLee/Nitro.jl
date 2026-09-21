## HTTP compat moves to `~2.6` — an app pinning `~2.4` must move too

- **Version**: 0.4.0
- **Nitro ref**: `Project.toml` `[compat]`; `src/core.jl`, `src/utilities/bodyparsers.jl`
- **Recorded**: 2026-09-10
- **Severity**: **breaking (dependency resolution)** — an app carrying its own `HTTP = "~2.4"`
  bound does not resolve against this release.

### What changed

Nitro's bound moved from `HTTP = "~2.4"` to `HTTP = "~2.6"` (resolving 2.6.7).

**The pin stays tight — `~`, not `^` — on purpose.** Core reaches into HTTP internals that no
public API covers: `BytesBody.data` in `_body_bytes` and in the non-consuming response write path
(`src/utilities/bodyparsers.jl`, `src/core.jl`). A caret bound would let Pkg resolve an untested
minor release, and the failure mode there is not a load error — advancing the `BytesBody` read
cursor corrupts reuse of a module-level `const` response, which serves a truncated body on the
*second* request and nothing on the first.

Verified against 2.6.7 before the bound moved: `BytesBody` still carries `data`, `next_index` and
`closed`; `EmptyBody`, `AbstractBody`, `Stream` and `forceclose` all still exist; and
`appendheader` still folds duplicate field lines only when they are **adjacent**, which is the
assumption `ExtractIP` depends on to keep a client-sent `X-Forwarded-For` from being read as the
proxy-appended one.

### How to find the calls to migrate

```bash
# The app's own bound — this is what blocks resolution.
rg -n '^HTTP\s*=' <app>/Project.toml

# Does the app use HTTP directly? Then HTTP's own 2.5/2.6 changes are yours to review,
# not something Nitro mediates.
rg -n 'using HTTP|import HTTP' <app>/src
```

### Migrate your app

```toml
# ✗ before — will not resolve against this release
HTTP = "~2.4"

# ✓ after
HTTP = "~2.6"
```

An app that does not pin HTTP itself needs no change: it inherits the bound from Nitro.
