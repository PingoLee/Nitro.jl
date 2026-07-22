# Managing Secrets

Unlike frameworks like Django that rely on a centralized `settings.py` file to hold global secrets, **Nitro.jl** does not manage your application configuration or secrets centrally. 

Nitro follows a **Dependency Injection** philosophy: your application is responsible for loading secrets (from `.env` files or environment variables) and explicitly passing them to the framework components that need them.

## Passing Secrets to Middleware

When you configure your server, you load the secret and pass it into the middleware parameters. 

```julia
using HTTP
using Nitro
using DotEnv

required_env(name::String) = get(ENV, name, nothing) === nothing ? error("$name must be set") : ENV[name]

# 1. Load your `.env` file (optional, depends on your deployment)
DotEnv.config()

# 2. Require the secret from the environment
SECRET_KEY = required_env("API_SECRET_KEY")

function health(req::HTTP.Request)
    return Res.send("ok")
end

urlpatterns("",
    path("/", health, method="GET"),
)

# 3. Pass the secret to the components that need it
serve(urlpatterns, middleware=[
    SessionMiddleware(),
    CSRFMiddleware(SECRET_KEY),
])
```

For local development, put a non-checked-in secret in `.env`. Avoid committed fallbacks such as `dev-secret` or `changeme` in application code.

## Passing Secrets to your Application Routes

If your custom routes or middleware need access to a secret (for example, to sign custom JWTs or interact with external APIs), you should package them into an `AppConfig` struct and pass them via the `context`.

```julia
struct AppConfig
    secret_key::SecretString
end

required_env(name::String) = get(ENV, name, nothing) === nothing ? error("$name must be set") : ENV[name]

config = AppConfig(SecretString(required_env("SECRET_KEY")))

function sign_payload(req::HTTP.Request, ctx::Context{AppConfig})
    secret = reveal(ctx.payload.secret_key)
    # Sign something with secret...
end

# Inject config into the context for all routes
serve(context=config)
```

For a comprehensive guide on building `AppConfig`, refer to the [BI App Config Example](bi_app_config.md).

## Keeping Secrets Out of Logs and REPL Output

Secrets stored as plain `String` fields are one accident away from disclosure: an
`@show config` while debugging, an `@info` log that includes the config struct, an
error message interpolating it, or a REPL auto-display of any value that (directly or
through nested fields) contains it — Julia's default `show` recursively prints every
field, secret included.

Wrap secrets in `SecretString` and all of those paths print a mask instead:

```julia
config = AppConfig(SecretString(required_env("SECRET_KEY")))

@show config
# config = AppConfig(SecretString("****"))

@info "startup" config          # logs the mask, never the key
"debug: $config"                # interpolates the mask, never the key
```

Read the value only where it is actually used, via `reveal`:

```julia
token = encode_jwt(payload, reveal(config.secret_key))
```

Because `reveal` is the single unwrap point, `grep -rn "reveal("` audits every place
the raw secret is touched. Comparing a `SecretString` with `==` (against another
`SecretString` or a plain string) is constant-time, so checks like
`config.api_key == client_token` are safe from timing attacks.

!!! warning
    `SecretString` guards against *accidental* disclosure only. Deliberate
    introspection (`dump`, `getfield`) still reaches the raw value — nothing in a
    running Julia process is hidden from reflection.

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

Those are already the defaults in `SessionMiddleware`. Only override them when you intentionally need a different policy, such as local HTTP development.

For HTTPS deployments, pair `Secure=true` cookies with `Strict-Transport-Security` so the
browser keeps using HTTPS after the first secure response.

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
