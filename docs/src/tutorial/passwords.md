# Password Hashing

Nitro provides a production-grade password hashing engine in `Nitro.Auth` that is compatible with Django 4.2+ and Spring Security 6.x hash formats. The engine supports multiple algorithms, automatic upgrade detection, and a delegating encoder that transparently verifies hashes regardless of which algorithm produced them.

## Supported Algorithms

| Algorithm | Format | Default Iterations / Cost | Interoperable With |
|---|---|---|---|
| `pbkdf2_sha256` | `pbkdf2_sha256$iterations$salt$hash` | 720 000 | Django 4.2+ |
| `bcrypt` | `$2a$` / `$2b$` / `$2y$` prefix | cost 12 | Spring Security, all standard BCrypt libs |
| `spring_sha256` | `sha256:iterations:key_length:salt_b64:hash_b64` | 310 000 | Spring Security 6.x `Pbkdf2PasswordEncoder` |

Future Argon2 support will use the standard PHC string format (`$argon2id$v=19$m=...,t=...,p=...$salt$hash`).

These format strings, iteration counts, and encoding choices are a **public API contract**. They will not change across versions.

## Quick Start

```julia
using Nitro.Auth

# Hash a password (uses pbkdf2_sha256 by default)
hash = make_password("my_secure_password")

# Verify a password against a stored hash
check_password("my_secure_password", hash)   # true
check_password("wrong_password", hash)       # false

# Check if a stored hash needs re-hashing (e.g. iteration count increased)
password_needs_upgrade(hash)                 # false (current defaults)
```

## Choosing an Algorithm

Pass the `algorithm` keyword to `make_password`:

```julia
# Django-compatible PBKDF2 (default)
hash = make_password("password"; algorithm="pbkdf2_sha256")

# BCrypt (Spring Security default)
hash = make_password("password"; algorithm="bcrypt")

# Spring Security PBKDF2
hash = make_password("password"; algorithm="spring_sha256")
```

You can query the supported list at runtime:

```julia
Nitro.Auth.SUPPORTED_ALGORITHMS
# ["pbkdf2_sha256", "bcrypt", "spring_sha256"]
```

## Changing the Default Algorithm

The default algorithm is `pbkdf2_sha256`. To change it globally:

```julia
using Nitro.Auth

set_default_algorithm!("bcrypt")

# Now make_password() uses BCrypt by default
hash = make_password("password")  # produces $2a$12$...
```

`DEFAULT_ALGORITHM()` returns the current default. Only algorithms listed in `SUPPORTED_ALGORITHMS` are accepted.

## Detecting Encoded Hashes

`is_password_usable` checks whether a string looks like an encoded password hash (as opposed to plain text):

```julia
is_password_usable("pbkdf2_sha256\$720000\$salt\$hash")  # true
is_password_usable("\$2a\$12\$hashvalue")                 # true
is_password_usable("sha256:310000:32:salt:hash")          # true
is_password_usable("plain_text")                          # false
```

This is used internally by the NitroPormG extension to decide whether a value needs hashing before database storage.

## Using Encoders Directly

For fine-grained control, instantiate an encoder directly:

```julia
using Nitro.Auth

# PBKDF2 with custom iterations
encoder = PBKDF2PasswordEncoder(iterations=500_000)
hash = encode(encoder, "password")
matches(encoder, "password", hash)         # true
upgrade_encoding(encoder, hash)            # false (same iterations)

# BCrypt with custom cost
encoder = BCryptPasswordEncoder(cost=14)
hash = encode(encoder, "password")
matches(encoder, "password", hash)         # true

# Spring Security PBKDF2
encoder = SpringSecurityPBKDF2PasswordEncoder(iterations=185_000)
hash = encode(encoder, "password")
matches(encoder, "password", hash)         # true
```

### Delegating Encoder

The `DelegatingPasswordEncoder` automatically detects the algorithm from the hash format and delegates to the correct encoder:

```julia
delegating = DelegatingPasswordEncoder()

# Verifies any supported format
matches(delegating, "password", pbkdf2_hash)   # true
matches(delegating, "password", bcrypt_hash)   # true
matches(delegating, "password", spring_hash)   # true
```

## Password Validation

`validate_password` enforces strength requirements with i18n support:

```julia
result = validate_password("weak")
result.valid    # false
result.errors   # ["Password must be at least 8 characters long", ...]
result.strength # :weak

result = validate_password("Str0ng!Pass#2024")
result.valid    # true
result.strength # :strong
```

Custom validators with localized messages:

```julia
messages = Dict(
    :min_length => "A senha deve ter pelo menos %d caracteres",
    :require_uppercase => "A senha deve conter pelo menos uma letra maiúscula",
    :require_digit => "A senha deve conter pelo menos um número",
)

validator = PasswordValidator(min_length=10, messages=messages)
result = validate(validator, "curta")
# result.errors includes the Portuguese messages
```

## Upgrade Detection

When you increase iteration counts or switch algorithms, `password_needs_upgrade` detects hashes produced with weaker settings:

```julia
old_hash = make_password("password"; iterations=100_000)
password_needs_upgrade(old_hash; min_iterations=720_000)  # true
```

A typical pattern in a login handler:

```julia
function login(req::HTTP.Request)
    body = json(req)
    stored_hash = lookup_user_hash(body["username"])  # your DB lookup

    if !check_password(body["password"], stored_hash)
        return Res.status(401, "invalid credentials")
    end

    if password_needs_upgrade(stored_hash)
        new_hash = make_password(body["password"])
        update_user_hash(body["username"], new_hash)  # your DB update
    end

    token = encode_jwt(Dict("sub" => body["username"], "exp" => trunc(Int, time()) + 3600), "secret")
    return Res.json(Dict("token" => token))
end

urlpatterns("",
    path("/api/login", login, method="POST"),
)
```

## Wire Format Specifications

### Django PBKDF2 (`pbkdf2_sha256`)

```
pbkdf2_sha256$<iterations>$<salt>$<hash_b64>
```

- **Algorithm**: PBKDF2-HMAC-SHA256
- **Iterations**: 720 000 (Django 4.2+ default)
- **Salt**: 22-character random alphanumeric string
- **Hash**: 32-byte derived key, base64-encoded
- **Interop**: A hash produced by `make_password` is accepted by Django's `check_password`, and vice versa.

### BCrypt

```
$2a$<cost>$<22-char-salt><31-char-hash>
```

- **Variants**: `$2a$`, `$2b$`, `$2y$` are all accepted
- **Cost**: 12 (default); range 4–31
- **Max input**: 72 bytes (longer passwords are truncated with a warning)
- **Interop**: Bitwise compatible with Spring Security and all standard BCrypt libraries.

### Spring Security PBKDF2 (`spring_sha256`)

```
sha256:<iterations>:<key_length>:<salt_b64>:<hash_b64>
```

- **Algorithm**: PBKDF2-HMAC-SHA256 (`SecretKeyFactoryAlgorithm.PBKDF2WithHmacSHA256`)
- **Iterations**: 310 000 (Spring Security 6.x default)
- **Key length**: 32 bytes
- **Salt**: 24-byte random, base64-encoded
- **Interop**: Matches Spring Security 6.x `Pbkdf2PasswordEncoder` output.

### Future: Argon2

```
$argon2id$v=19$m=<memory>,t=<time>,p=<parallelism>$<salt_b64>$<hash_b64>
```

Will use the standard PHC string format for interoperability. Not yet available — the API contract is defined so extensions can reference it today.

## Security Notes

- All password comparisons use **constant-time equality** to prevent timing side-channel attacks.
- Empty passwords are rejected by all encoders (`ArgumentError`).
- BCrypt silently truncates passwords longer than 72 bytes (with a logged warning). If this is a concern, use PBKDF2 or Spring PBKDF2 which have no length limit.
- The `DelegatingPasswordEncoder` falls back to constant-time plain-text comparison for unknown formats, with a warning. This is intentional for migration scenarios but should not be relied upon in production.

## PormG Integration

When `Nitro` and `PormG` are both loaded, the `NitroPormGExt` extension activates automatically. It hooks into PormG's `PasswordField` to:

1. **Auto-hash on write**: If `auto_hash=true` on a `PasswordField`, raw passwords are hashed via `make_password` before database storage. Already-encoded hashes pass through unchanged.
2. **Verify helper**: Use `check_password` from `Nitro.Auth` to verify passwords against stored hashes.
3. **Upgrade detection**: Use `password_needs_upgrade` to detect hashes that should be re-hashed with stronger parameters.

This keeps the core `Nitro.Auth` engine database-agnostic while providing seamless ORM integration when PormG is available.
