# Cookie Security

Security is paramount when handling user state. Nitro's cookie module is designed to be "secure by default" but gives you the tools to harden your application further.

## Automatic Encryption

Unlike standard cookies which are plain text, Nitro supports **AES-256 GCM encryption** out of the box. This prevents users from reading or tampering with the cookie contents.

### How to Enable
1. Set a `secret_key` in `configcookies()`.
2. Use `encrypted=true` when setting/getting.

```julia
# 1. Setup
configcookies(secret_key="k3y-must-be-32-bytes-long-!!!!!!!!")

# 2. Set (Encrypted)
set_cookie!(res, "session", "user_id=42", encrypted=true)
# Browser sees: "session=8a7s6d87a6sd876a..."

# 3. Get (Decrypted)
val = get_cookie(req, "session", encrypted=true)
# Server sees: "user_id=42"
```

> **Warning:** If you change your `secret_key`, all existing encrypted cookies will become unreadable (invalid).

## The Security Checklist

Every cookie you set for authentication should follow these rules:

| Attribute | Why? | How? |
|---|---|---|
| **HttpOnly** | Prevents XSS (JavaScript cannot steal the token). | `httponly=true` |
| **Secure** | Prevents network sniffing (HTTPS only). | `secure=true` |
| **SameSite** | Prevents CSRF attacks. | `samesite="Strict"` or `"Lax"` |
| **Encrypted** | Prevents tampering and information leakage. | `encrypted=true` |

### Example: The Perfect Auth Cookie

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