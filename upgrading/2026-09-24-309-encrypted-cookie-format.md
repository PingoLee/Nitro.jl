## Encrypted cookies — bound to their name and lifetime, and a cookie that does not open reads as absent

- **Version**: Unreleased
- **Nitro ref**: [#309](https://github.com/PingoLee/Nitro.jl/issues/309) ; `src/crypto.jl`, `src/cookies.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — every encrypted cookie issued before the upgrade reads as
  absent once (users re-login once where a cookie carried login state; preference cookies fall
  back to their defaults). `get_cookie` no longer throws `CookieError` for a bad cookie, and
  `encrypt_payload`/`decrypt_payload` take a required `purpose`.

### What changed

The encrypted-cookie token was AES-256-GCM under `sha256(secret)` with no associated data and
no timestamp. So a ciphertext from one cookie opened as any other — an app that encrypted an
attacker-influenced value (a `language` from a query parameter) handed the attacker a valid
`session_user` — and a captured cookie decrypted forever, since `Max-Age` is only a browser hint.

The token format is now **version 1**:

- The key is derived from `secret_key` with HKDF-SHA256 and a Nitro-specific label.
- The **cookie name** is sealed in as GCM associated data: a value set as `language` does not
  open as `session_user`.
- The **issued-at** time and the **expiry** the browser is told (`Max-Age`, which wins, or
  `Expires`) are sealed inside the ciphertext, and the server refuses the value once it has
  passed. A cookie with neither has no server-side expiry; `configcookies(maxage = …)` bounds
  every cookie that does not set its own.

A cookie that does not open — tampered, sealed under another key, copied from another cookie,
expired, or **in the old format** — now **reads as absent**: `get_cookie` returns its default,
the `Cookie{T}` extractor gets a `nothing` value, and `CookieAuthMiddleware` answers 401 as it
did before. The rejection is logged at `@debug` with the cookie's name, never its value. It used
to throw `CookieError`, which surfaced as a 500 on every request from a client carrying a stale
or junk cookie — and would have done that to every client at once on this format change. With no
key configured at all, an encrypted read or write still throws `CookieError`.

`Nitro.Crypto.encrypt_payload(secret, payload; purpose, expires = nothing)` and
`decrypt_payload(secret, token; purpose)` take a **required** `purpose` keyword (the cookie name,
for tokens `set_cookie!`/`get_cookie` must read). `decrypt_payload` itself still throws
`CookieError` for every failure above.

Apps built with an explicit `App` that called the argument-less `get_cookie(req, …)` /
`set_cookie!(res, …)` were writing **plaintext** cookies; those now read as absent too, in the
same single round — see [the #308 entry](2026-09-24-308-cookie-helpers-follow-serving-app.md).

### How to find the calls to migrate

```bash
# Code that expected get_cookie / an extractor to THROW on a bad cookie -- that branch is dead now.
grep -rnE 'CookieError' --include=*.jl .
# Direct uses of the primitives, which need `purpose =`.
grep -rnE '(encrypt|decrypt)_payload\(' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — a bad cookie was an exception
theme = try
    get_cookie(req, "theme", "light")
catch e
    e isa CookieError ? "light" : rethrow()
end

# ✓ after — it reads as the default
theme = get_cookie(req, "theme", "light")

# ✗ before
token = Nitro.Crypto.encrypt_payload(key, value)
# ✓ after — the purpose must match on both sides; for a cookie it is the cookie's name
token = Nitro.Crypto.encrypt_payload(key, value; purpose = "theme")
value = Nitro.Crypto.decrypt_payload(key, token; purpose = "theme")
```

Plan the deploy for one round of absent cookies. Nothing can migrate old tokens: they were
never bound to a name, which is the defect.
