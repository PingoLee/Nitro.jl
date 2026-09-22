## A JWT carrying no `kid` is now verified against every key in the keyset

- **Version**: Unreleased
- **Nitro ref**: [#253](https://github.com/PingoLee/Nitro.jl/issues/253) ; `src/Auth/jwt.jl`, `src/Auth/validators.jl`
- **Recorded**: 2026-09-21
- **Severity**: **behavior** — tokens that used to be rejected now authenticate, `principal.kid`
  reports a different value for kid-less tokens, and `jwt_validator` gains a construction-time
  `ArgumentError`. No app *has* to change, but three things an app may depend on moved.

### What changed

`decode_jwt` used to resolve a kid-less token to exactly one key — the keyset's `"default"` entry,
or failing that `first(keys(keyset))`, an arbitrary key under `Dict` iteration order — and verify
against only that one. A kid-less token signed with any *other* key in the same keyset was rejected
as `Invalid JWT signature`, which is live for the whole of a key rotation window and points the
operator at the shared secret and clock skew when the real cause is key selection.

Now a kid-less token is tried against every key, `"default"` first and then the rest by name, and
`principal.kid` reports whichever key verified it. A token that *names* a `kid` is unchanged: that
key and no other.

Three consequences:

1. **`principal.kid` / `identity_from = :kid`.** A kid-less token used to resolve to `"default"`
   (or an arbitrary key). It now resolves to the key that actually signed it. For
   `identity_from = :kid` that is also `principal.id`, and therefore what `kid_required` sees.
2. **A keyset may no longer hold the same secret under two names.** `jwt_validator` throws an
   `ArgumentError` at construction, because a kid-less token could otherwise be attributed to
   either entry depending on iteration order. The comparison is by **HMAC key**, not by string:
   HMAC-SHA256 pre-hashes any key longer than its 64-byte block and zero-pads any key shorter,
   so `K` and `sha256(K)` are one key, and so are `"a"` and `"a\0"`.

   Related, same guard: it is the first code in `jwt_validator` to inspect keyset **values**, so
   a keyset whose values are not `String`s now fails at construction with a named `ArgumentError`
   instead of surfacing later. Unwrap a `SecretString` before building the validator.

   One of those shapes was worse than a bad error message. `Vector{UInt8}` values used to be
   *accepted*: `String(::Vector{UInt8})` takes ownership of the buffer and leaves it empty, so
   reading the keyset blanked every secret in the caller's own `Dict` — after which a token signed
   with the empty string authenticated as any `kid`. That shape is now refused before anything
   reads it. The same trap still exists for code calling `decode_jwt` directly with a byte-vector
   keyset; tracked separately.

   A keyset whose **keys** are neither `String` nor `Symbol` (an integer-keyed `Dict`) is also
   refused now — no key id could ever resolve, so every request was a 401 with no startup signal.
3. **The no-match message changed for multi-key keysets only.** More than one candidate tried →
   `No key in the JWT keyset verified this token`. One candidate — a string secret, a single-key
   keyset, or any token naming its `kid` — still says `Invalid JWT signature`, byte for byte.

This is not a weakening. The token still has to verify against whichever key is tried, so
`principal.kid` is never a lie and `kid_required` is not loosened.

### How to find the calls to migrate

```bash
# 1. Keysets with more than one entry. Only these are affected at all.
rg -n -A6 'jwt_validator\(|decode_jwt\(' <app>/src

# 2. The breaking one: two keys sharing a secret. This now throws at STARTUP.
#    Look for a keyset whose values repeat, or two names reading the same env var.
rg -n -A8 'Dict\(' <app>/src | rg -n 'JWT_SECRET|jwt_secret'

# 3. Code that assumes a kid-less token resolves to "default".
rg -n '\.kid|kid_required|identity_from' <app>/src

# 4. Anything matching on the old error text.
rg -n 'Invalid JWT signature' <app>/src <app>/test
```

### Migrate your app

Most apps need no edit. These three do:

```julia
# ✗ before -- two names, one secret. Silently resolved to whichever came first.
keyset = Dict(
    "primary" => required_env("JWT_SECRET"),
    "legacy"  => required_env("JWT_SECRET"),
)
jwt_validator(keyset)   # ✓ before -- built fine
                        # ✗ after  -- ArgumentError at startup

# ✓ after -- give them distinct secrets
keyset = Dict(
    "primary" => required_env("JWT_SECRET_PRIMARY"),
    "legacy"  => required_env("JWT_SECRET_LEGACY"),
)
```

**Give them distinct secrets; do not simply delete one name.** Two names over one secret is most
plausibly a `kid` rename mid-rotation, so tokens naming the dropped `kid` are in flight right now
— and a `kid` the keyset does not know is `Unknown JWT key id`, i.e. a 401. Keep both names until
the old one has drained (one token lifetime), then remove it.

```julia
# ✗ before -- a kid-less token from a legacy issuer reported the "default" key
#             regardless of which secret actually signed it
if principal.kid == "default"
    treat_as_legacy_issuer(principal)
end

# ✓ after -- it reports the key that signed it, so match on that
if principal.kid == "legacy-issuer"
    treat_as_legacy_issuer(principal)
end
```

```julia
# ✗ before -- a test pinning the message for a multi-key keyset
@test_throws AuthError("Invalid JWT signature") decode_jwt(tok, two_key_keyset)

# ✓ after
@test_throws AuthError("No key in the JWT keyset verified this token") decode_jwt(tok, two_key_keyset)
```
