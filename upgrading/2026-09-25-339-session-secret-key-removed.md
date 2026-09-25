## `SessionMiddleware(secret_key = …)` — removed; it was accepted and never used (#339)

- **Version**: Unreleased
- **Nitro ref**: [#339](https://github.com/PingoLee/Nitro.jl/issues/339) ;
  `src/middleware/session_middleware.jl`
- **Recorded**: 2026-09-25
- **Severity**: **breaking.** Passing the keyword is now a `MethodError` at construction, and a
  `config::CookieConfig` carrying a `secret_key` is an `ArgumentError`. Nothing about the session
  cookie itself changes. It was never encrypted or signed.

### What changed

`SessionMiddleware` accepted a `secret_key` and did nothing with it: the session-id cookie was
always written and read raw. The key only reached the middleware's `CookieConfig`, where nothing
read it. A caller passing it reasonably believed the session cookie was encrypted or signed. Since
#309 it also had to pass the 32-byte key rule, for no benefit.

The cookie holds a random UUIDv4 (122 random bits) and the data stays in the store, so there is
nothing to hide. Signing the id would not stop session fixation (unknown ids are refused and
`rotate_on_auth` rotates on login) or session swapping (the `__Host-` cookie-name default from
#329 does that). So the keyword is gone instead of made real. A `config` whose `secret_key` is set
is refused rather than ignored, since it was the same silent no-op.

### How to find the calls to migrate

```bash
grep -rnE 'SessionMiddleware\(.*secret_key' --include=*.jl .
# calls split over several lines, or with a nested call such as `store = MemoryStore()` before the key:
rg -U -n --type julia 'SessionMiddleware\((?:[^()]|\([^()]*\))*secret_key'
```

And any `config` you pass it:

```bash
rg -U -n --type julia 'SessionMiddleware\((?:[^()]|\([^()]*\))*config\s*='
```

### Migrate your app

```julia
# ✗ before
SessionMiddleware(store = store, secret_key = ENV["SESSION_SECRET"])
SessionMiddleware(store = store, config = CookieConfig(secret_key = key, secure = true))

# ✓ after — drop the key; nothing it did goes away
SessionMiddleware(store = store)
SessionMiddleware(store = store, config = CookieConfig(secure = true))
```

If `SESSION_SECRET` existed only for this keyword, it can be retired from your environment. Keep
any secret your app still uses elsewhere, for example `CSRFMiddleware`, `configcookies`, or
`CookieAuthMiddleware`.
