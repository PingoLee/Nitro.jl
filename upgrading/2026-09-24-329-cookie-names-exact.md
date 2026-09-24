## `get_cookie` / `parse_cookies` — cookie names match exactly, the first one wins, and a request's `Set-Cookie` is ignored

- **Version**: Unreleased
- **Nitro ref**: [#329](https://github.com/PingoLee/Nitro.jl/issues/329) ; `src/cookies.jl`, `src/types.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — a cookie read under a name spelled with different case, or
  supplied in a request's `Set-Cookie` header, is no longer found; a `Domain` outside
  `[A-Za-z0-9.-]` is refused everywhere.

### What changed

| | Before | After |
|---|---|---|
| Cookie-name matching in `get_cookie` (and so in the `Cookie{T}`/`Session{T}` extractors, `SessionMiddleware`, `CSRFMiddleware`) | case-insensitive | **exact** — cookie names are case-sensitive (RFC 6265 §4.1.1) |
| A name sent twice | `get_cookie` took the first, `parse_cookies` the last | both take the **first** (RFC 6265 §5.4 sends the most specific path first; Go and npm `cookie` agree) |
| Several `Cookie` headers in a header list | `parse_cookies` read only the first | every one is read, in order |
| A `Set-Cookie` header on a **request** | read as a cookie | ignored; only a **response** is read from `Set-Cookie`, and only from it |
| `domain` in `format_cookie` and `CookieConfig(domain = …)` | rejected only a space and `:` | the strict validator every other path used: trimmed, lowercased, `[A-Za-z0-9.-]` only, else `ArgumentError` — `CookieConfig` now checks at construction |

Case-insensitive matching was a prefix bypass ("Cookie Crumbles"): on browsers that check the
`__Host-` prefix case-sensitively, anyone could plant `__HOST-csrf_token=attacker`, and it was
returned for `__Host-csrf_token` because it was sent first. A lax `Domain` let untrusted input
inject attributes (`domain = "evil.com; Secure"`).

Header **names** (`Cookie`, `cookie`, `SET-COOKIE`) are still matched case-insensitively, as HTTP
requires.

### How to find the calls to migrate

```bash
# Reads whose name must now match the cookie exactly as it was set.
grep -rnE 'get_cookie\(|parse_cookies\(|Cookie\{|Cookie\("' --include=*.jl .
# Code (usually tests) that put cookies in a REQUEST's Set-Cookie header.
grep -rnE 'Request\(.*"Set-Cookie"' --include=*.jl .
# Domains taken from configuration or user input.
grep -rnE 'domain\s*=' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — set as "Theme", read as "theme", found anyway
set_cookie!(res, "Theme", "dark")
get_cookie(req, "theme")                  # now `nothing`

# ✓ after — one spelling
set_cookie!(res, "theme", "dark")
get_cookie(req, "theme")

# ✗ before — a test that simulated a client cookie with the wrong header
HTTP.Request("GET", "/", ["Set-Cookie" => "sid=abc"])
# ✓ after
HTTP.Request("GET", "/", ["Cookie" => "sid=abc"])
```
