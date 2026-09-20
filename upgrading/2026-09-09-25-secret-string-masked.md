## `SecretString` now serializes to `"****"` instead of its raw value (#25)

- **Version**: Unreleased
- **Nitro ref**: #25; `src/crypto.jl`, `docs/src/tutorial/secrets.md`
- **Recorded**: 2026-09-09
- **Severity**: **breaking (JSON output shape)** — a security fix; part of the `0.1.x` pre-publish
  wave.

### What changed

`SecretString` masked only the *display* path (`Base.show`). It defined no JSON lowering, so every
serialization path reflected the wrapper's fields and emitted the secret in plaintext:

```julia
JSON.json(AppConfig("app", SecretString("SUPER-SECRET-XYZ")))
# before → {"name":"app","key":{"value":"SUPER-SECRET-XYZ"}}
```

That path is the framework's primary output: `Res.json`, the automatic struct-to-JSON return in
`format_response`, and any structured logging that JSON-encodes a containing struct. A handler
returning a config struct shipped the raw secret to the client, contradicting the type's own
documented promise that an accidental display "never prints the secret".

`SecretString` now defines a `JSON.lower` method, so JSON emits the same `"****"` the display mask
uses — for the value bare, as a struct field, and nested inside a `Dict`, `Vector` or `Tuple`.

**What this forces.** Any app that *relied* on serializing a `SecretString` to move the secret
around — an internal config endpoint, a JSON payload built from a config struct, a worker task
**result** — now transmits `"****"` and must unwrap explicitly with `reveal`. For one-way output
the failure is silent at the Nitro boundary: nothing throws, the receiving end simply gets four
asterisks. Grep before you upgrade rather than after.

**Round-tripping a struct through JSON now throws.** `lower` has no matching `StructUtils.lift`, so
a struct holding a `SecretString` no longer parses back:

```julia
JSON.parse(JSON.json(cfg), AppConfig)   # after → ArgumentError at the parse site
```

This is deliberate. A `lift` would reconstruct `SecretString("****")`, which parses cleanly and then
fails an auth comparison somewhere far away with no indication why — trading a loud failure at the
boundary for a silent wrong value downstream. If you round-trip config through JSON, carry the
secret as a separate `reveal`ed field rather than re-parsing the wrapper.

**If you use `PormGSessionStore`,** a `SecretString` placed in `req.session` is now persisted as the
literal `"****"`. That round-trip was already lossy — before this change it wrote `{"value":"<raw>"}`
and read back a plain `Dict`, so the secret was also being written to your session table in
plaintext. The new behavior is strictly safer, but it is a change: do not keep secrets in the
session.

The redaction boundary is display **and** JSON. `dump`, `getfield`, and non-JSON serializers
(ProtoBuf, template engines) still reach the raw value — unchanged, and still documented as such.

### How to find the calls to migrate

```bash
# Structs holding a SecretString, and every place one is serialized or returned
rg -n 'SecretString' <app>/src <app>/test
rg -n 'Res\.json|JSON\.json' <app>/src          # cross-reference against the hits above
```

A hit matters only where the serialized value is *consumed as the secret* downstream. Returning a
config struct to a browser was the bug this fixes — leave those masked.

### Migrate your app

```julia
# ✗ before — relied on JSON reflecting the wrapper to pass the secret onward
payload = JSON.json(Dict("api_key" => config.api_key))
# now yields {"api_key":"****"}

# ✓ after — unwrap explicitly at the point of use
payload = JSON.json(Dict("api_key" => reveal(config.api_key)))
```

```julia
# ✗ before — an internal endpoint that leaked the key to the client. Note the shape:
#   the wrapper was *reflected*, not flattened, so audit your captured responses and
#   logs for {"value":"…"} — grepping for "secret_key":"<raw>" will find nothing.
get_config(req) = Res.json(config)          # shipped {"secret_key":{"value":"<raw>"}}

# ✓ after — same call, now masked. If a caller genuinely needs the value, build an
#   explicit payload with `reveal` rather than returning the config struct.
get_config(req) = Res.json(config)          # {"secret_key":"****"}
```
