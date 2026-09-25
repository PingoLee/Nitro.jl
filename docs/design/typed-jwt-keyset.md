# Design: Typed JWT Keyset (`JWTKeyset`)

> **Status:** design record for [#260](https://github.com/PingoLee/Nitro.jl/issues/260), written
> before the code it describes. It replaces the bare `Dict` keyset as the thing `encode_jwt`,
> `decode_jwt` and `jwt_validator` reason about; a `Dict` still works and is lifted into one.

## Context

A Nitro JWT keyset used to be an `AbstractDict` of `kid => secret` and nothing else. It could not say
which of its keys signs, so every question that metadata would answer was re-answered by hand, in
control flow, in `src/Auth/jwt.jl`. The same question — *which key?* — was patched three times:

| Issue | What was patched |
|---|---|
| [#45](https://github.com/PingoLee/Nitro.jl/issues/45) | `first(keys(...))` raised a `BoundsError` on an empty keyset |
| [#253](https://github.com/PingoLee/Nitro.jl/issues/253) | a kid-less token was verified against one key, so a rotation window rejected valid tokens |
| #253 rider | `encode_jwt` signed with `first(keys(...))` and stamped that `kid` — a coin flip under `Dict` order |

Each patch was correct and local. The cluster kept reopening because the cause is a
**representation**, not a branch.

The same representation carried a sharper defect. `_lookup_key` coerced with `String(keyset[kid])`,
and `String(::Vector{UInt8})` **takes ownership of the buffer and empties it**. Reading a byte-vector
keyset therefore destroyed the caller's secrets, after which every entry was `""` and a token signed
with the empty string authenticated as any `kid`. #259 refused that shape in `jwt_validator`, but the
exported `decode_jwt` path still read it. A guard in one of two entry points is the wrong shape; a
constructor that owns the value contract makes it unrepresentable.

## Decision

```julia
JWTKeyset("default" => primary; verify = ["legacy" => old, "partner" => partner_secret])
```

A keyset holds **exactly one signing key** and any number of **verify-only** keys. The signer also
verifies. The signing key is the one positional argument, so "exactly one" is enforced by the
constructor's signature rather than by a check.

### Roles describe *use*, not lifecycle

RFC 7517 (JWK Set) models this with `use` / `key_ops`. The issue first proposed lifecycle roles —
`active`, `retiring`, `incoming` — which describe a keyset that is one issuer's rotation set.

A real consumer showed why that vocabulary is wrong. Its keyset is a **client registry**: each `kid`
is a permanent service identity (`"reporting-client"`, `"batch-client"`, …), authorized by `kid`
through `identity_from = :kid` / `kid_required` — the pattern Nitro's own tutorial documents. Lifting
that keyset under lifecycle roles would label every client `retiring`, which is false, and would say
nothing true about why those keys exist. `retiring` and `incoming` also had no behavioral difference
from each other — both verify, neither signs — so they were two names for one thing.

Two roles say exactly what the code needs and nothing it cannot check:

| Role | Signs | Verifies |
|---|---|---|
| `sign` (one per keyset) | ✅ | ✅ |
| `verify` | ❌ | ✅ |

A rotation window is expressed with the same two roles: the new key signs, the old one verifies.

### What a key may claim: per-key scopes

The roles say which key may **sign**, and nothing about what a verifying key may **claim**
([#321](https://github.com/PingoLee/Nitro.jl/issues/321)). Unscoped, every key in a keyset is
fully trusted for every claim. A client-registry key can sign `{"role": "admin"}`, or under
`identity_from = :claim` any `sub`, and the validator believes it. `identity_from = :kid` pins who
the principal is, not what it may assert. That is fine for a rotation window, where every key
belongs to one issuer. It is a hazard for the client registry above. #321 documented it, and the
only mitigations were `kid_required` on every claim-guarded route or one keyset and validator per
trust domain. Both are opt-in discipline, and a new route that forgets `kid_required` is silently
exposed.

[#349](https://github.com/PingoLee/Nitro.jl/issues/349) makes the policy a property of the key:

```julia
JWTKeyset("self" => s; verify = ["partner" => p],
          claims = Dict("partner" => ["sub", "action", "role" => ["reader"]]))
```

The decisions, and why:

| Question | Decision | Why |
|---|---|---|
| Names or values? | Both: a name allows any value, `name => values` pins it | Names alone cannot say "a partner may be a reader, never an admin", which is the registry's actual policy |
| What a pin accepts | Strings, and lists of strings whose every element is pinned. Nothing else | `in` compares with `==`, under which `true == 1`; a non-string pin would admit more than it names |
| A disallowed claim | **Reject** the token (`AuthError` → `401`) | Dropping is silent: a dropped `sub` becomes a `Principal` with `id = nothing`, and the issuer never learns its tokens are out of policy |
| Where it is checked | `_decode_jwt`, after the signature verifies and the claims parse, before `validate_claims` | The scope lives on the keyset, so `decode_jwt` and `jwt_validator` both enforce it. That is #260's lesson again: a guard in one of two entry points is the wrong shape |
| Always allowed | `iat`, `exp`, `nbf`, `jti` | Every token carries them and none grants authority. `sub`, `iss` and `aud` say who and for whom, so they must be listed |
| Unscoped keys | Trusted for every claim, as before | A rotation window is one issuer and needs no scope. The change is additive |
| `identity_from = :claim` | Nothing special | `sub` is a claim like any other, so a key not scoped for it cannot name an identity |

The scope follows the key that **verified** the token, not the header `kid`. A kid-less token is
scoped by whichever key's HMAC matched, and a string secret has no keys and so no scope.
`verify = false` has no verifying key and applies none. A scope naming a kid the keyset does not
hold is an `ArgumentError`, because accepting that typo would leave the key it meant to restrict
unscoped.

Prior art: Spring Security grants authorities per client registration, not per issuer, and OAuth
scopes bound what one client's token may assert. FastAPI's `Security` scopes are the per-route
analogue, and that is the shape `kid_required` already has.

### What the type answers, so no call site has to

- **"Which key signs?"** The signing key. `_signing_kid`, and the `ArgumentError` it threw for a
  multi-key keyset with no `"default"`, are deleted — that deletion is #260's acceptance test.
- **"Which keys verify a kid-less token?"** Every key, signing key first and then the rest by name.
  The order is computed once, at construction, not sorted per request.
- **"Which key verifies a token naming a `kid`?"** That one, or `AuthError("Unknown JWT key id")`.
  A forged token still costs exactly one HMAC.
- **"May two entries share a secret?"** No — checked by HMAC key, not by string, because
  HMAC-SHA256 pre-hashes a key longer than its block and zero-pads a shorter one (`K` and
  `sha256(K)` are one key, and so are `"a"` and `"a\0"`). The check moves from `jwt_validator` onto
  the constructor, so a direct `decode_jwt` caller gets it too.
- **"Can a secret be something that is not a string?"** No. A value must be an `AbstractString` or a
  `SecretString`, checked with `isa` **before anything reads it**, so a `Vector{UInt8}` is refused and
  left intact. An empty secret is refused as well: it is the value the byte-vector trap produced, and
  an unset environment variable produces it just as easily.

### Signing as a peer

`encode_jwt` loses its `kid=` keyword. A keyset stamps its signing key's `kid`, and a plain string
secret signs a kid-less token. An app that calls another service **as** one of the identities in a
shared registry builds a one-key keyset for that purpose, once, next to its configuration:

```julia
outbound = JWTKeyset("partner-caller" => partner_secret)
encode_jwt(claims, outbound; expires_in = 60)    # header kid = "partner-caller"
```

Keeping `kid=` — even as an assertion that it names the signing key — would have left "which key
signs" as a call-site decision whose meaning depended on the type of the second argument, which is
the question this record exists to delete.

## Lifting a `Dict`

A `Dict{String,String}` is the documented form, so it keeps working. It is lifted by `JWTKeyset(d)`:

| `Dict` shape | Result |
|---|---|
| has a `"default"` entry | `"default"` signs; every other entry verifies |
| exactly one entry | that entry signs |
| two or more entries, no `"default"` | `ArgumentError`: name one `"default"`, or build a `JWTKeyset` |
| empty | `ArgumentError` |

`"default"` stops being a magic string three functions have to agree about; it is the lift rule's one
input. Keys may be `String`s or `Symbol`s; a `Dict` holding both `"a"` and `:a` is refused rather than
silently shadowed. Values may be `SecretString`s.

Where the lift happens matters:

- **`jwt_validator` lifts once, at construction.** The validator holds a snapshot. Mutating the `Dict`
  in place afterwards no longer "rotates" keys under a running server — the construction-time checks
  could not see such a mutation, so it was a hole rather than a feature.
- **A direct `decode_jwt` / `encode_jwt` caller passing a `Dict` lifts on every call.** It is correct,
  and it is the path that closes the byte-vector trap, but it repeats the construction checks per
  call. Build the `JWTKeyset` once, at configuration time. That also moves a misconfiguration to
  startup: a request-time guard that wraps `decode_jwt` in a bare `catch` would otherwise turn a
  keyset error into a 401 on every request, with nothing at startup to say why.

## Display

`JWTKeyset` prints key ids and roles only — `JWTKeyset(sign="default", verify=["legacy", "partner"])`
— in `show`, `MIME"text/plain"` `show`, and `JSON.lower`, the same discipline as `SecretString` and
`App`. A scoped keyset adds `scoped=[...]` to `show`, and a `claims` map of kid to claim names to
`JSON.lower`. Pinned values are never printed. Secrets are stored as `SecretString` and revealed only at the HMAC. As with `SecretString`,
`dump` and field reflection are not covered.

## Nitro.jl Constraints

- **Type stability (nitro-core §7).** `_verify_candidates` is dispatched per secret type and returns
  a concrete `Vector{Tuple{Nullable{String}, String}}`; the `with_kid` tuple stays `Nullable{String}`.
- **Auth semantics unchanged.** `identity_from = :kid`, `kid_required`, and `principal.kid` keep
  meaning *the key that verified the signature*. A string secret's header `kid` is still an unverified
  label that `jwt_validator` discards.
- **HS256 only.** Unchanged since #45.

## Non-goals

Each of these was considered and deliberately left out, so the type has no field or hook reserved
for it:

- **Per-key `alg`.** It is the only route to RS256 or a fetched JWKS, and #45 locked Nitro to HS256
  on purpose. Adding it later is a clean break, which is cheap pre-publish; a reserved field that
  accepts one value is not worth carrying.
- **Rotation owned by the type** — a verify key with a sunset time that stops verifying on its own.
  The roles are static labels; rotating means building a new keyset.
- **Environment-driven loading.** Keysets are built in code from values the app already resolved.
  Loading them from the environment belongs with
  [#162](https://github.com/PingoLee/Nitro.jl/issues/162).
- **Remote JWKS endpoints** — fetching, caching and refresh. A separate concern on top of this type.
