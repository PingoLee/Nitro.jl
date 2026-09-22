## `encode_jwt` refuses a multi-key keyset with no `"default"` and no `kid=`

- **Version**: Unreleased
- **Nitro ref**: [#253](https://github.com/PingoLee/Nitro.jl/issues/253) ; `src/Auth/jwt.jl`
- **Recorded**: 2026-09-21
- **Severity**: **breaking** — a call that used to mint a token now throws an `ArgumentError`. It
  fails at the call that mints the token, not at the one that verifies it, which is the point:
  the tokens it used to produce were already wrong, just silently.

  **Note where it lands.** `encode_jwt` is called from a request handler — a login route, a token
  refresh — not from bootstrap. So this surfaces as a **500 on that route in production**, not as
  a server that refuses to start. Restarting the app and watching it come up does not verify the
  migration; exercising the route that mints tokens does.

> **Superseded in this train by [#260](2026-09-22-260-typed-jwt-keyset.md).** `kid=` no longer
> exists, so the `kid = "primary"` migration below would now be a `MethodError`. If you have
> not applied this entry yet, apply #260's instead: it covers the same calls and ends in the
> same place — a keyset that says which key signs. The `"default"` route below is still valid.

### What changed

`encode_jwt(claims, keyset)` with no `kid=` resolved the signing key through the same helper the
verify path used: `"default"` if present, otherwise `first(keys(keyset))`. That second arm picked a
key by `Dict` iteration order and then **stamped it into the token's `kid` header**, so the token's
own statement of who signed it was a coin flip.

Signing now needs exactly one unambiguous answer, found in one of three ways:

1. an explicit `kid=`;
2. a `"default"` entry in the keyset;
3. a keyset holding exactly one key.

Anything else is an `ArgumentError` naming the fix. Verifying is unaffected — it is *supposed* to
be able to consider several keys, and [the kid-less trial entry](2026-09-21-253-jwt-kidless-key-trial.md)
covers that half.

An empty keyset and a `kid=` that is not in the keyset both still raise
`AuthError("Unknown JWT key id")`, unchanged.

### How to find the calls to migrate

```bash
# Every signing call. Any one passing a Dict WITHOUT `kid =` is a candidate.
rg -n 'encode_jwt\(' <app>/src <app>/test

# Narrow to the ones that can actually break: a keyset with 2+ entries and no "default".
# If the keyset is built once and reused, look at its definition rather than the call.
rg -n -A6 'keyset\s*=\s*Dict\(' <app>/src
```

A call passing a plain `String` secret, a single-key keyset, or a keyset with a `"default"` entry
needs no edit.

### Migrate your app

```julia
keyset = Dict(
    "primary" => required_env("JWT_SECRET_PRIMARY"),
    "rotated" => required_env("JWT_SECRET_ROTATED"),
)

# ✗ before -- signed with whichever key Dict iteration happened to yield, and
#             stamped THAT kid into the header
token = encode_jwt(claims, keyset; expires_in = 900)

# ✓ after -- say which key signs
token = encode_jwt(claims, keyset; kid = "primary", expires_in = 900)
```

If every token your app mints is signed by the same key, naming that key `"default"` is the other
way through — it keeps the call sites unchanged and makes the intent explicit in one place:

```julia
keyset = Dict(
    "default" => required_env("JWT_SECRET_PRIMARY"),   # the signer
    "rotated" => required_env("JWT_SECRET_ROTATED"),   # verify-only, for the rotation window
)
token = encode_jwt(claims, keyset; expires_in = 900)   # ✓ unchanged
```

### Why this is a guard, not a design

A keyset is a `Dict{String,String}`, so it cannot say which of its keys is the *active* signer —
which is why the question has to be re-answered at every call. Under a keyset type carrying per-key
roles (RFC 7517's `use` / `key_ops`), the active key signs and there is nothing to disambiguate,
and this `ArgumentError` becomes unreachable. Its deletion is the acceptance test for that work.
