## `configcookies` / `CookieConfig` — the cookie key is held as a `SecretString`, and `configcookies` returns `nothing`

- **Version**: Unreleased
- **Nitro ref**: [#307](https://github.com/PingoLee/Nitro.jl/issues/307) ; `src/crypto.jl`, `src/types.jl`, `src/cookies.jl`, `src/methods.jl`
- **Recorded**: 2026-09-24
- **Severity**: breaking — code that read `CookieConfig.secret_key` as a `String`, used the value
  `configcookies` returned, or passed a non-string key has to change. An app that passed a
  `SecretString` key was encrypting every cookie under the public key `SecretString("****")`,
  so after this change its cookies are encrypted under the real key for the first time: no
  cookie it issued before decrypts any more.

### What changed

`configcookies(secret_key = SecretString(k))` stored the key with `string(v)`. `SecretString` is
deliberately not an `AbstractString`, so `string` went through its masking `show`, and the stored
key was the literal text `SecretString("****")`, shared by every app that did this. Anyone could
decrypt and forge those cookies. A `Base.SecretBuffer` failed the same way.

Every entry point for a cookie key now normalizes through one rule:

| Passed as `secret_key` | Before | After |
|---|---|---|
| `String` / `AbstractString` | stored as a `String` | stored as a `SecretString` |
| `SecretString` | stored as `"SecretString(\"****\")"` — a public key | stored as-is; it **is** the key |
| `Vector{UInt8}`, `Base.SecretBuffer`, anything else | `string(v)` of it — its display form | `ArgumentError`, without reading the value |
| `""` | accepted; the first encrypted read or write threw `CookieError` | `ArgumentError` at `configcookies`/`CookieConfig` (startup), and on a per-call `secret_key = ""` |

That covers `configcookies`, `serve(secret_key = …)`, `CookieConfig(secret_key = …)`, the
per-call `secret_key` of `get_cookie`/`set_cookie!`, `SessionMiddleware(secret_key = …)` and
`CookieAuthMiddleware(secret_key = …)`. `CSRFMiddleware` also accepts a `SecretString` now.

So:

- **`CookieConfig.secret_key` is `Union{SecretString, Nothing}`.** `==` against a `String` still
  works (constant-time); anything that needs the raw text must call `reveal`.
- **`configcookies` returns `nothing`** (both forms). It used to return the `CookieConfig`, which
  put the key in front of every REPL auto-display.
- **`set_cookie!` refuses a `SecretString` or `Base.SecretBuffer` *value*** with an
  `ArgumentError`, since `string(value)` would have written `SecretString("****")` into the
  cookie. Pass `reveal(value)` if the secret really belongs there.
- `CookieConfig`, `LifecycleMiddleware` and the closures `SessionMiddleware`, `CSRFMiddleware` and
  `CookieAuthMiddleware` return no longer print the key through `show` or `repr`.

### How to find the calls to migrate

```bash
# Reads of the stored key, which is a SecretString now.
grep -rnE '\.secret_key\b' --include=*.jl .
# Uses of configcookies' return value.
grep -rnE '=\s*configcookies\(' --include=*.jl .
# Non-string keys, and SecretString values written into a cookie.
grep -rnE 'secret_key\s*=\s*(Vector\{UInt8\}|Base\.SecretBuffer|codeunits)' --include=*.jl .
grep -rnE 'set_cookie!\(.*SecretString' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before
cfg = configcookies(secret_key = ENV["COOKIE_SECRET"])
some_hmac(cfg.secret_key, data)               # a String

# ✓ after — keep the key in your own typed config, and unwrap it where it is used
config = AppConfig(cookie_secret = SecretString(ENV["COOKIE_SECRET"]))
configcookies(secret_key = config.cookie_secret)          # a String works too
some_hmac(reveal(config.cookie_secret), data)

# ✗ before — written as the literal text SecretString("****")
set_cookie!(res, "token", config.api_token)
# ✓ after
set_cookie!(res, "token", reveal(config.api_token))
```

If you passed a `SecretString` key before, nothing in your code changes, but no encrypted cookie
issued before the upgrade decrypts any more: it was encrypted under the public placeholder key,
not yours.
