# Managing Secrets

Unlike frameworks like Django that rely on a centralized `settings.py` file to hold global secrets, **Nitro.jl** does not manage your application configuration or secrets centrally. 

Nitro follows a **Dependency Injection** philosophy: your application is responsible for loading secrets (from `.env` files or environment variables) and explicitly passing them to the framework components that need them.

## Passing Secrets to Middleware

When you configure your server, you load the secret and pass it into the middleware parameters. 

```julia
using HTTP
using Nitro
using DotEnv

# 1. Load your `.env` file (optional, depends on your deployment)
DotEnv.config()

# 2. Get the secret from the environment, with a safe development fallback
SECRET_KEY = get(ENV, "API_SECRET_KEY", "fallback-secret-for-dev")

# 3. Pass the secret to the components that need it
serve(
    middleware=[
        SessionMiddleware(), # See notes below on Sessions
        CSRFMiddleware(SECRET_KEY)
    ]
)
```

## Passing Secrets to your Application Routes

If your custom routes or middleware need access to a secret (for example, to sign custom JWTs or interact with external APIs), you should package them into an `AppConfig` struct and pass them via the `context`.

```julia
struct AppConfig
    secret_key::String
end

config = AppConfig(get(ENV, "SECRET_KEY", "dev-secret"))

function sign_payload(req::HTTP.Request, ctx::Context{AppConfig})
    secret = ctx.payload.secret_key
    # Sign something with secret...
end

# Inject config into the context for all routes
serve(context=config)
```

For a comprehensive guide on building `AppConfig`, refer to the [BI App Config Example](bi_app_config.md).

## Do Sessions Need Encryption?

A very common question for users coming from other frameworks is: **"Does `SessionMiddleware` encrypt the session data, and do I need to pass a secret to it?"**

The short answer is **No, session cookies do not need to be encrypted in Nitro.**

### Why?
Nitro uses **Server-Side Sessions** by default (backed by `MemoryStore`). When you use `SessionMiddleware`, the data you put into `req.session` never leaves your server. 

Instead, Nitro generates a random, cryptographically secure `UUIDv4` identifier (e.g., `550e8400-e29b-41d4-a716-446655440000`) and sends **only** that UUID to the browser in the `nitro_session` cookie.

Because the UUID is completely random and has 122 bits of entropy, it is impossible for an attacker to guess or mathematically reverse it. There is no user data inside the cookie to encrypt.

### How to Secure Sessions
Instead of encrypting the UUID, you secure the session by configuring the cookie transport attributes. You should ensure that `SessionMiddleware` uses:
- `HttpOnly=true` (Prevents JavaScript XSS from stealing the UUID)
- `Secure=true` (Ensures the UUID is only sent over HTTPS so it cannot be intercepted on public Wi-Fi)
- `SameSite="Lax"` or `"Strict"` (Prevents CSRF attacks)

```julia
# Secure session configuration for production
SessionMiddleware(
    secure = true,
    httponly = true,
    samesite = "Lax"
)
```

## When ARE Secrets Used?

While standard sessions don't need a secret, other parts of Nitro do rely heavily on `SECRET_KEY`:

1. **CSRF Protection**: `CSRFMiddleware(secret)` uses your secret to perform an HMAC-SHA256 signature on the CSRF tokens. This ensures attackers cannot forge valid CSRF bypass cookies.
2. **Encrypted Cookies**: If you manually call `set_cookie!(..., encrypted=true)`, the `Cookies` module uses AES-256-GCM to fully encrypt the payload using the `secret_key` you provide to the framework.
3. **JWT and Auth**: If you use the `Nitro.Auth` module helpers like `encode_jwt(payload, keys)` or `jwt_validator`, you use your secrets to sign the tokens.
