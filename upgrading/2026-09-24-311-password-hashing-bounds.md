## `make_password` / `check_password` — password hashing is bounded work: a 4096-byte cap and bounded stored costs

- **Version**: Unreleased
- **Nitro ref**: [#311](https://github.com/PingoLee/Nitro.jl/issues/311) ; `src/Auth/passwords.jl`, `src/crypto.jl`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change. Input that used to be hashed or verified at unbounded cost is now
  refused. Every hash already stored with ordinary parameters verifies exactly as before, since the
  output is byte-identical, and a default-cost login is now about 14× cheaper.

### What changed

A login endpoint hashes whatever an unauthenticated client submits. The PBKDF2 loop was pure Julia,
and its cost grew with **password length × iterations**: about 2.5 s for a 16-byte password at the
default cost, and hours for a 1 MB one. Nothing capped the password, and verification trusted the
cost parameters written in the stored hash. PBKDF2 now runs in OpenSSL's libcrypto (about 0.2 s,
whatever the length), and every operation is bounded:

| Call | Before | After |
|---|---|---|
| `make_password(pw)` / `encode(enc, pw)`, `pw` over 4096 bytes | hashed | `ArgumentError` |
| `check_password(pw, h)` / `matches(enc, pw, h)`, `pw` over 4096 bytes | hashed: ~40 s at 4 KB, hours at 1 MB | `false`, before any hashing |
| A stored PBKDF2 or Spring hash whose iterations × 32-byte key blocks exceed 10 000 000 (10 000 000 iterations at the usual 32-byte key), or with iterations below 1 | run as written | `false`, plus a warning |
| A stored Spring hash with a key length outside 16–64 | run as written; `sha256:1:0:AAAA:` matched **any** password | `false`, plus a warning |
| A stored Spring hash whose key length differs from its hash's decoded length | derived, then `false` | `false`, without deriving |
| A stored bcrypt hash with a cost above 15 | run as written (31 is ~50 h) | `false`, plus a warning |
| `BCryptPasswordEncoder(cost = 16…31)`, `make_password(…; bcrypt_cost = 16…31)`, `DelegatingPasswordEncoder(bcrypt_cost = 16…31)` | accepted | `ArgumentError` (the range is now 4–15) |
| `PBKDF2PasswordEncoder` / `SpringSecurityPBKDF2PasswordEncoder` over the same work bound or with a key length above 64; `make_password(…; iterations > 10_000_000)`; `DelegatingPasswordEncoder(pbkdf2_iterations > 10_000_000)`; `password_needs_upgrade(h; min_iterations > 10_000_000)` | accepted | `ArgumentError` |
| `check_password(pw, nothing)` | `MethodError`, a `500` | `false`, after one dummy hash at the default cost |

The encoder ceilings match the verification bounds, so no encoder can mint a hash that its own
`matches` then refuses. Spring Security's own `BCryptPasswordEncoder` allows a cost up to 31, so a
Spring-imported bcrypt hash with a cost above 15 is now refused; re-hash those users.

`check_password` now also runs the dummy hash for a stored value that no encoder can verify (an
unusable `!` marker, plaintext, `$argon2…`). A login that looks the user up and passes `nothing`
for a miss therefore takes the same time whether or not the account exists. This is Django's
`authenticate` pattern.

The NitroPormGExt `PasswordField` hook, which PormG does not call yet, now hashes every non-blank
string. It no longer passes through values that merely look like a hash. The explicit route for a
hash you computed yourself is a field declared `auto_hash=false`.

### How to find the calls to migrate

```bash
# Every hashing and verifying call site -- check each for the edits below.
grep -rn "make_password(\|check_password(\|matches(" --include=*.jl .
# Encoders and helpers given an explicit cost, which may now be above the ceiling.
grep -rnE "(BCrypt|PBKDF2|SpringSecurityPBKDF2|Delegating)PasswordEncoder\(|bcrypt_cost *=|iterations *=|min_iterations *=" --include=*.jl .
# PormG password columns left at the default auto_hash=true.
grep -rn "PasswordField(" --include=*.jl .
```

For the enumeration fix, read each login handler rather than trusting a regex. The shape to find
is **any early return for an unknown user before `check_password` runs**: `isnothing(user) || …`,
an `if isnothing(user) return 401 end` above it, or a lookup that throws for a missing row.

At runtime, the signup error reads `Password exceeds the 4096-byte limit`, and a refused stored
hash logs `Stored password hash has out-of-range cost parameters`.

### Migrate your app

```julia
# ✗ before — a signup handler hashes whatever it is sent; over 4096 bytes is now a 500
function signup(req)
    body = getjson(req)
    save_user(body["username"], make_password(body["password"]))
end

# ✓ after — refuse over-long input yourself, as a 400
function signup(req)
    body = getjson(req)
    password = body["password"]
    ncodeunits(password) <= Nitro.Auth.MAX_PASSWORD_BYTES ||
        return Res.json(Dict("error" => "password too long"); status = 400)
    save_user(body["username"], make_password(password))
end
```

```julia
# ✗ before — an unknown user answers at once, a known one only after hashing: a timing oracle
user = find_user(username)
if isnothing(user) || !check_password(password, user.password_hash)
    return Res.json(Dict("error" => "invalid credentials"); status = 401)
end

# ✓ after — always go through check_password; `nothing` costs one dummy hash
user = find_user(username)
if !check_password(password, isnothing(user) ? nothing : user.password_hash)
    return Res.json(Dict("error" => "invalid credentials"); status = 401)
end
```

```julia
# ✗ before — the app hashes with make_password, and the column keeps PormG's default auto_hash=true
password = Models.PasswordField()

# ✓ after — declare it, so the hook never re-hashes an app-computed hash once PormG runs it
password = Models.PasswordField(auto_hash = false)
```

An app that configured a bcrypt cost above 15 must lower it to 15 or less. Its existing hashes at
that cost stop verifying, so re-hash them, for example with a password-reset flow.
