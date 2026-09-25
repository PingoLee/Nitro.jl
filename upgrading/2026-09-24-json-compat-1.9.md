## JSON compat moves to `^1.9` — an app pinning an older JSON 1.x must move too

- **Version**: Unreleased
- **Nitro ref**: [#306](https://github.com/PingoLee/Nitro.jl/issues/306) ; `Project.toml` `[compat]`,
  `src/utilities/bodyparsers.jl`
- **Recorded**: 2026-09-24
- **Severity**: **breaking (dependency resolution)** — an app carrying its own JSON bound below
  `1.9` does not resolve against this release.

### What changed

Nitro's bound moved from `JSON = "^1.3"` to `JSON = "^1.9"` (resolving 1.9.0), and StructTypes.jl
left Nitro's dependencies.

The floor is not cosmetic. Every typed parse of client JSON now passes Nitro's own StructUtils
style, which never interns a client string as a `Symbol` (#306). JSON.jl wraps a caller's style and
forwards its `lift` calls to it only from **1.5.2**; releases 1.3.0–1.5.0 replaced the style
outright, so Nitro's methods would silently not run and JSON.jl's own conversion would intern enum
names again. 1.9.0 is the release this was verified against.

### How to find the calls to migrate

```bash
# The app's own bound — this is what blocks resolution.
rg -n '^JSON\s*=' <app>/Project.toml
```

### Migrate your app

```toml
# ✗ before — will not resolve against this release
JSON = "^1.3"

# ✓ after
JSON = "^1.9"
```

An app that does not pin JSON itself needs no change: it inherits the bound from Nitro. An app that
uses StructTypes itself already declares it, so Nitro dropping it changes nothing there.
