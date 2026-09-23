## `jwt_validator` / `encode_jwt` / `decode_jwt` — an empty string secret is an `ArgumentError`

- **Version**: Unreleased
- **Nitro ref**: [#264](https://github.com/PingoLee/Nitro.jl/issues/264) ; `src/Auth/keyset.jl`, `src/Auth/jwt.jl`, `src/Auth/validators.jl`
- **Recorded**: 2026-09-23
- **Severity**: behavior change — a plain string secret that is empty, or that HMAC treats as
  empty, used to be accepted and made every token signed with `""` authenticate. It is now
  refused loudly. No valid configuration changes which tokens verify.

### What changed

A `JWTKeyset` already refused an empty secret ([#260](2026-09-22-260-typed-jwt-keyset.md)); a
**single plain-string secret** did not. `jwt_validator("")` — which is exactly what
`get(ENV, "JWT_SECRET", "")` produces when the variable is unset — verified tokens against the
empty HMAC key, so anyone could forge a token the app accepted.

The rule is HMAC's, not `isempty`'s: HMAC-SHA256 zero-pads a short key, so `"\0"`, `"\0\0"`, and
any run of NUL bytes up to 64 are the empty key too. Every one of those is now refused:

| Call | Before | After |
|---|---|---|
| `jwt_validator("")` | a validator that accepts forged tokens | `ArgumentError`, at construction (app startup) |
| `encode_jwt(claims, "")` | a token anyone can forge | `ArgumentError` |
| `decode_jwt(token, "")` | verifies a token signed with `""` | `ArgumentError` |

From inside a custom validator, a `decode_jwt` that throws this `ArgumentError` is answered
with a `401` by the auth middleware, as any other validator failure is — it fails closed.

### How to find the calls to migrate

```bash
# An env var read with an empty-string default is the realistic trigger.
grep -rnE 'get\(ENV, *"[^"]*", *""\)' --include=*.jl .
# A literal empty secret passed directly.
grep -rnE '(jwt_validator|encode_jwt|decode_jwt)\([^)]*""' --include=*.jl .
```

At runtime, the startup error reads `the JWT secret is empty, or equivalent to the empty HMAC key`.

### Migrate your app

```julia
# ✗ before — an unset JWT_SECRET silently becomes "", and "" authenticates forged tokens
validator = jwt_validator(get(ENV, "JWT_SECRET", ""))

# ✓ after — read it with a `nothing` default and fail at startup when it is missing
jwt_secret = get(ENV, "JWT_SECRET", nothing)
isnothing(jwt_secret) && error("JWT_SECRET must be set")
validator = jwt_validator(jwt_secret)
```

A test suite that signed tokens with `""` for convenience needs a real (non-empty) test secret.
