# Changelog

All notable changes to Nitro.jl are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Security

A security review hardened the auth, crypto, CORS, rate-limiting, and response
layers. Several defaults changed in the secure direction — see **Migration**
below for the breaking ones.

- **IP extraction is no longer header-trusting by default.** `ExtractIP` /
  `extract_ip` and `RateLimiter` ignore `X-Forwarded-For`, `X-Real-IP`,
  `CF-Connecting-IP`, and `True-Client-IP` unless the proxy is explicitly
  trusted. Previously these spoofable headers were always honored, letting a
  client forge its IP to evade rate limiting or poison audit logs.
- **CORS rejects wildcard + credentials.** `Cors(allowed_origins=["*"],
  allow_credentials=true)` now throws instead of reflecting an arbitrary
  `Origin` together with `Access-Control-Allow-Credentials: true`.
- **CSPRNG for tokens, salts, and session IDs.** CSRF tokens, password salts,
  and session identifiers now use OpenSSL's CSPRNG (`secure_random_bytes` /
  `secure_uuid4`) instead of the non-cryptographic default RNG.
- **Raw string responses are not content-sniffed.** Returning a `String` from a
  handler now yields `text/plain; charset=utf-8` (was: sniffed, which could
  serve attacker-influenced strings as `text/html` → reflected XSS). Use
  `Res.html` / `Res.js` / `Res.css` / `Res.xml` to emit those types explicitly.
- **JWT expiration is enforced.** Tokens without an `exp` claim are bounded by
  `iat + exp_timeout` (default 15 minutes) and rejected once stale; pass
  `require_exp=true` to demand an explicit `exp`. `encode_jwt(...; expires_in=…)`
  stamps an `exp`.
- **Rate limiter fails closed.** On an internal limiter error the request now
  gets `503 Service Unavailable` instead of being let through. Set
  `fail_open=true` to restore availability-first behavior.
- **CSRF token comparison is constant-time.**
- No plaintext password fallback: an unknown/corrupted hash format fails to
  match instead of comparing the password as plaintext.
- OpenSSL `RAND_bytes` and GCM tag (`EVP_CIPHER_CTX_ctrl`) return values are
  checked; decrypt errors no longer leak the underlying exception to callers.
- `Regex` path parameters are length-capped (256 bytes) to bound ReDoS exposure.

### Fixed

- `encode_jwt` no longer fails on string-only payloads (`_json_dict` widened to
  `Dict{String, Any}`), so integer `iat`/`exp` claims can always be stamped.

### Migration

These changes are breaking in the secure direction:

- **Behind a reverse proxy?** Rate limiting now keys on the proxy's socket IP by
  default, so all clients share one bucket. Trust the proxy to restore
  per-client limits:
  ```julia
  RateLimiter(...; trusted_proxies=[ip"127.0.0.1"])  # preferred
  # or, only when clients cannot reach Nitro directly:
  RateLimiter(...; trust_forwarded=true)
  ```
  The same options exist on `ExtractIP(...)`.
- **Using `Cors(allowed_origins=["*"], allow_credentials=true)`?** Replace `"*"`
  with the explicit origins you trust.
- **Returning raw HTML strings from handlers?** Wrap them in `Res.html(...)`;
  bare strings are now served as `text/plain`.
- **Decoding JWTs that lack an `exp` claim?** They are now bounded by
  `iat + exp_timeout` (15 min default) and rejected when stale. Mint tokens with
  `encode_jwt(...; expires_in=…)` / an explicit `exp`, raise `exp_timeout`, or
  pass `require_exp=false`/a longer fallback as appropriate.
- **Relying on the rate limiter passing traffic when it errors?** It now returns
  `503`; set `fail_open=true` to keep the old behavior.
