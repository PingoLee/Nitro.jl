## JWT keysets are a `JWTKeyset` with one signing key, and `encode_jwt` loses `kid=`

- **Version**: Unreleased
- **Nitro ref**: [#260](https://github.com/PingoLee/Nitro.jl/issues/260) ; `src/Auth/keyset.jl`, `src/Auth/jwt.jl`, `src/Auth/validators.jl`
- **Recorded**: 2026-09-22
- **Severity**: **breaking** — `encode_jwt(...; kid = ...)` no longer exists, and a `Dict` keyset
  with two or more keys and no `"default"` entry is now an `ArgumentError` everywhere, including
  when it is only used to verify. Both fail loudly; neither changes which tokens verify.

### What changed

A keyset used to be a bare `Dict` of `kid => secret`, which cannot say which of its keys signs.
It is now a `Nitro.Auth.JWTKeyset`: exactly **one signing key**, plus any number of keys that
only **verify**. `encode_jwt`, `decode_jwt` and `jwt_validator` accept a `JWTKeyset`, a plain
string secret, or a `Dict`, which is lifted into a keyset:

| `Dict` shape | Result |
|---|---|
| has a `"default"` entry | `"default"` signs; every other entry verifies — **unchanged behavior** |
| exactly one entry | that entry signs — **unchanged behavior** |
| two or more entries, no `"default"` | **`ArgumentError`** — no key is marked to sign |
| empty | **`ArgumentError`** — was `AuthError("Unknown JWT key id")` |

Four things an app can hit:

1. **`encode_jwt(claims, keyset; kid = "x")` is a `MethodError`.** A keyset signs with its
   signing key and stamps that `kid`; there is no call-site choice any more. To sign **as** a
   particular identity — calling a peer service with the key it knows you by — build a one-key
   keyset for that purpose. This replaces the migration the `encode_jwt` entry for
   [#253](2026-09-21-253-encode-jwt-signing-key.md) recommended in the same train.
2. **A multi-key `Dict` with no `"default"` is refused**, even by `jwt_validator` and
   `decode_jwt`, which used to verify with it. That shape is typical of a registry of client
   keys (`Dict("service-a" => …, "service-b" => …)`); name the key your app signs with.
3. **`jwt_validator` keeps a snapshot.** It lifts a `Dict` once, at construction. Mutating the
   `Dict` afterwards used to change which keys verified under a running server; it no longer
   does. Rebuild the validator to rotate.
4. **Keyset checks now run on every path, not only in `jwt_validator`.** Two entries that are
   the same HMAC key, an empty secret, and a non-string secret (a `Vector{UInt8}` in particular)
   are `ArgumentError`s from a direct `decode_jwt` or `encode_jwt` call too. A direct call with a
   `Dict` lifts it — and re-runs those checks — **on every call**.

   That last point has a sharp edge in code that wraps `decode_jwt` in a bare `catch` and answers
   401: a keyset misconfiguration that used to be invisible now makes **every request a 401, with
   nothing at startup to say why**. Build the keyset once, at configuration time, so it fails
   there instead.

A `JWTKeyset` accepts `SecretString` values directly, so `reveal` is no longer needed when
building one.

### How to find the calls to migrate

```bash
# 1. The MethodError: every signing call that passes kid=.
rg -n -A3 'encode_jwt\(' <app>/src <app>/test | rg 'kid\s*='

# 2. Keysets that may have no "default" entry. Check each Dict: two or more keys and no
#    "default" is now refused, wherever it is used.
rg -n -A6 'jwt_validator\(|decode_jwt\(|encode_jwt\(' <app>/src
rg -n -B2 -A6 '=\s*Dict(\{[^}]*\})?\(' <app>/src | rg -i 'secret|key'

# 3. Direct decode_jwt calls with a Dict. Move the keyset construction to config.
rg -n 'decode_jwt\(' <app>/src
```

A call that passes a plain `String` secret needs no edit.

### Migrate your app

A rotation window or a client registry with no `"default"`:

```julia
# ✗ before -- verified fine; signing needed kid=
keyset = Dict("primary" => required_env("JWT_SECRET_PRIMARY"),
              "rotated" => required_env("JWT_SECRET_ROTATED"))
validator = jwt_validator(keyset)
token = encode_jwt(claims, keyset; kid = "primary", expires_in = 900)

# ✓ after -- say once which key signs
keyset = JWTKeyset("primary" => required_env("JWT_SECRET_PRIMARY");
                   verify = ["rotated" => required_env("JWT_SECRET_ROTATED")])
validator = jwt_validator(keyset)
token = encode_jwt(claims, keyset; expires_in = 900)
```

Signing as a peer — one shared keyset, but an outbound call signed with a key that is not the
app's own signing key:

```julia
# ✗ before
token = encode_jwt(claims, api_keys; kid = "partner-caller", expires_in = 60)

# ✓ after -- built once, next to the rest of the auth config
outbound = JWTKeyset("partner-caller" => api_secrets["partner-caller"])
token = encode_jwt(claims, outbound; expires_in = 60)
```

A direct `decode_jwt` call — move the lift out of the request path:

```julia
# ✗ before -- the Dict is lifted, and checked, on every request
auth_keys = Dict("default" => secret, "client-a" => client_a_secret)
claims, kid = decode_jwt(token, auth_keys; with_kid = true)

# ✓ after -- lifted once; a bad keyset stops the app at boot
auth_keys = JWTKeyset(Dict("default" => secret, "client-a" => client_a_secret))
claims, kid = decode_jwt(token, auth_keys; with_kid = true)
```

`identity_from = :kid`, `kid_required` and `principal.kid` are unchanged: they still mean the key
that verified the signature.

### Why

The same question — *which key?* — was patched three times in `src/Auth/jwt.jl` (#45, #253 and
its rider) because a `Dict` cannot say which key signs. The byte-vector trap, where reading a
`Vector{UInt8}` keyset emptied the caller's secrets, was closed by #253 only for `jwt_validator`.
A type whose constructor owns the value contract makes both unrepresentable. The rationale,
including why the roles are *sign*/*verify* rather than rotation stages, is in
`docs/design/typed-jwt-keyset.md`.
