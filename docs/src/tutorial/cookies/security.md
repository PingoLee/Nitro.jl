# Cookie Security

Security is paramount when handling user state. Nitro's cookie module is designed to be "secure by default" but gives you the tools to harden your application further.

## Automatic Encryption

Unlike standard cookies which are plain text, Nitro supports **AES-256 GCM encryption** out of the box. This prevents users from reading or tampering with the cookie contents.

### How to Enable
1. Set a `secret_key` in `configcookies()`: at least **32 random bytes**, read from the
   environment. A shorter key is refused with an `ArgumentError` at startup.
2. Every `set_cookie!`/`get_cookie` then encrypts and decrypts by default; `encrypted=true`
   says so explicitly.

```julia
# Generate a key ONCE, store it in your secret manager / .env, never in source:
#   julia -e 'using Nitro; println(bytes2hex(Nitro.Crypto.secure_random_bytes(32)))'

# 1. Setup
configcookies(secret_key = SecretString(ENV["COOKIE_SECRET"]))

# 2. Set (Encrypted)
set_cookie!(res, "cart", "item-17,item-42", encrypted=true, maxage=86400)
# Browser sees: "cart=AdDn3j4rX0x..."

# 3. Get (Decrypted)
val = get_cookie(req, "cart", encrypted=true)
# Server sees: "item-17,item-42"
```

### What an encrypted cookie guarantees

The value is sealed with AES-256-GCM under a key derived from `secret_key` (HKDF-SHA256 with a
Nitro-specific label). Beyond hiding and authenticating the value, the seal carries two more
things the browser cannot change:

- **The cookie's name.** A value sealed for `cart` does not open as `session_user`, so an
  attacker cannot copy the ciphertext of a cookie whose value they influence into another one.
- **Its lifetime.** The `Max-Age` (or `Expires`) the browser is told is sealed in too, and the
  server refuses the value once it has passed — `Max-Age` alone is only a hint to the browser,
  and a copied cookie would otherwise decrypt forever. A cookie with neither has **no**
  server-side expiry; set `maxage` on it, or give every cookie one with
  `configcookies(maxage = …)`.

A cookie that does not open — tampered, sealed under another key, copied from another cookie,
expired, or written before the current format — reads as **absent**: `get_cookie` returns your
default, and the `Cookie{T}` extractor a `nothing` value. The rejection is logged at `@debug`
with the cookie's name, never its value.

> **Warning:** If you change your `secret_key`, every existing encrypted cookie reads as absent
> from then on.

!!! warning "Identity does not belong in a cookie"
    Encryption proves Nitro sealed a value; it does not make the cookie a login. The server
    cannot revoke it, so a copy outlives logout until it expires. Keep *who the user is* in
    [`SessionMiddleware`](../sessions_and_auth.md) (the cookie is only a random id, and the data
    stays on the server) or in a JWT with an `exp` claim — see
    [Sessions and Auth](../sessions_and_auth.md).

## The Security Checklist

Every cookie you set for authentication should follow these rules:

| Attribute | Why? | How? |
|---|---|---|
| **HttpOnly** | Prevents XSS (JavaScript cannot steal the token). | `httponly=true` |
| **Secure** | Prevents network sniffing (HTTPS only). | `secure=true` |
| **SameSite** | Prevents CSRF attacks. | `samesite="Strict"` or `"Lax"` |
| **Encrypted** | Prevents tampering and information leakage. | `encrypted=true` |

### Example: The Perfect Auth Cookie

Here `token` is a signed JWT carrying its own `exp`, so the server can still refuse it after
the cookie is copied (see the warning above):

```julia
set_cookie!(res, "auth_token", token,
    httponly = true,    # No JS access
    secure   = true,    # HTTPS only
    samesite = "Strict",# No cross-site usage
    encrypted= true,    # Tamper-proof
    maxage   = 3600     # Expires in 1 hour
)
```

## Advanced: SameSite Policy

* **`Strict`**: The cookie is sent ONLY for first-party requests. Best for critical actions (like changing passwords).
* **`Lax`** (Default): Sent on navigation (clicking a link) but not on embedded requests (images/frames). Good balance for most apps.
* **`None`**: Sent on all requests. Requires `Secure=true`. Use this for APIs serving 3rd party SPAs.

```julia
# For an API serving a separate Frontend domain:
set_cookie!(res, "session", id, samesite="None", secure=true)
```

## Transport Security and HSTS

`secure=true` protects the cookie transport once the browser is already speaking HTTPS,
but it does not tell the browser to avoid plaintext HTTP on the first visit. For public
HTTPS deployments, also set `Strict-Transport-Security` at your reverse proxy or in an
application middleware.

Use [`SecurityHeaders`](@ref), which carries HSTS alongside the rest of the baseline set:

```julia
using Dates

serve(middleware=[
    SecurityHeaders(hsts = Day(365)),
    SessionMiddleware(store=MemoryStore(), secure=true),
])
```

HSTS is **off** unless you ask for it, and deliberately so: a browser honours `max-age` even
after you stop sending the header, so a value sent by mistake keeps a hostname HTTPS-only for
that long with no way to recall it. Nitro speaks plain HTTP behind a proxy and cannot detect
whether TLS terminated upstream, so enable it only when you know it did.

!!! warning "Do not hand-roll this by mutating the response"
    A middleware that calls `HTTP.setheader(response, ...)` on the response an inner layer
    returned is a bug, even though it appears to work. That response may be a shared module-level
    `const` — Nitro's auth rejections are exactly that — and Nitro serves every request on its own
    thread, so mutating it in place both leaks headers across requests and races. Build a new
    response with `add_response_headers` instead, which is what `SecurityHeaders` does. This page
    used to show the mutating version.

If TLS terminates at a load balancer or reverse proxy, prefer setting HSTS there so every
response is covered consistently — and if you set it in both places, keep the two values in
agreement.