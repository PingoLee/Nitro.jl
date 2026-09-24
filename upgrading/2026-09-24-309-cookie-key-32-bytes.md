## Cookie `secret_key` — at least 32 bytes, or an `ArgumentError`

- **Version**: Unreleased
- **Nitro ref**: [#309](https://github.com/PingoLee/Nitro.jl/issues/309) ; `src/crypto.jl`
- **Recorded**: 2026-09-24
- **Severity**: breaking — a cookie key shorter than 32 bytes used to be accepted and is now
  refused at startup.

### What changed

Any key was accepted, down to one byte, although the docs always said a cookie key "must be 32
bytes". The key was stretched with a single unsalted SHA-256, so one captured cookie let an
attacker test tens of thousands of guesses per second per core offline; a key like `changeme`
fell at once.

Every place a cookie key enters Nitro now requires **at least 32 bytes** and throws an
`ArgumentError` otherwise:

- `configcookies(secret_key = …)` and `serve(secret_key = …)`
- `CookieConfig(secret_key = …)` and `Nitro.Cookies.load_cookie_settings!`
- the per-call `secret_key` of `get_cookie` / `set_cookie!`
- `SessionMiddleware(secret_key = …)` and `CookieAuthMiddleware(secret_key = …)`
- `Nitro.Crypto.encrypt_payload` / `decrypt_payload`

Length is all Nitro can check; the key must also be *random*. The key is now derived with
HKDF-SHA256, which is the right tool for a high-entropy key and gives nothing to a guessable one.

The error reads `the cookie secret_key is N bytes; it must be at least 32 random bytes`.

### How to find the calls to migrate

```bash
grep -rnE 'secret_key\s*=' --include=*.jl .
grep -rnE '(configcookies|CookieAuthMiddleware|SessionMiddleware|CookieConfig)\(' --include=*.jl .
grep -rnE '(encrypt|decrypt)_payload\(' --include=*.jl .
```

Then check the length of every key those calls receive — including test suites, which often use
a short literal for convenience.

### Migrate your app

```julia
# ✗ before — accepted, and guessable offline from one captured cookie
configcookies(secret_key = "changeme")

# ✓ after — generate once, keep it in the environment / secret manager, never in source:
#   julia -e 'using Nitro; println(bytes2hex(Nitro.Crypto.secure_random_bytes(32)))'
configcookies(secret_key = SecretString(ENV["COOKIE_SECRET"]))
```

Changing the key means every encrypted cookie issued under the old one reads as absent once —
which the token-format change in this same release does anyway.
