# Authentication

Nitro's auth layer is a set of **primitives plus a small declarative surface**, not a
framework: you own the user model and login flow; Nitro owns token verification, the
principal contract, and route guards. The design follows established precedents — the
principal mirrors ASP.NET's `ClaimsPrincipal` / Spring's `Authentication` (identity claim
defaults to `sub`), `claim_required` mirrors ASP.NET's `RequireClaim`, and the 401/403
split follows RFC 6750.

## 1. Pick your model

| Model | Credential | Typical client | Identity | Start here |
|---|---|---|---|---|
| **Session auth** | Session cookie | Browsers (stateful) | `user_id` in `req.session` | [Sessions & Auth](sessions_and_auth.md) |
| **Bearer / JWT** | `Authorization: Bearer <jwt>` | SPAs, mobile, APIs | `sub` claim | §4 below |
| **Service / capability token** | Bearer JWT, no `sub` | Machine-to-machine | the `action`/scope claim | §5 below |
| **Key-scoped (signer) auth** | Bearer JWT signed by a per-caller key | Multi-tenant services | the verified `kid` | §5 below |

The models compose: one app can serve browser sessions on HTML routes and bearer tokens on
API routes. Whatever the model, the result of authentication is the same artifact — the
**principal** attached to the request.

## 2. The principal

Auth middleware (`BearerAuth`, `CookieAuthMiddleware`) attaches the authenticated identity
at `req.context[:user]`, readable as `req.user`. With `jwt_validator` the attached value
is a `Principal` — an immutable, dict-like wrapper over the **verified** claims:

```julia
function whoami(req::HTTP.Request)
    user = req.user
    user["sub"]      # claims read through dict-style
    user.id          # normalized identity (the configured identity claim, default "sub")
    user.kid         # keyset-verified key id, or nothing
    user.source      # where `id` came from: :claim or :kid
    return Res.json(user)   # serializes as the claims object — no metadata leaks
end
```

The contract:

- **`id === nothing` still means authenticated.** A service token without a `sub` claim
  authenticates; it simply has no subject identity. Guards that need an identity claim can
  demand one (`required_claims=["sub"]`).
- **A `Principal` is read-only.** It is a verified security artifact; enrich it by
  building your own user object in a `user_validator`, or copy it with `Dict(principal)`.
- **Two context slots.** Without a `user_validator`, the `Principal` *is* `req.user`. With
  one, your returned user object lands in `req.context[:user]` and the `Principal` rides
  along at `req.context[:auth_claims]` — so guards like `kid_required` still see the
  verified metadata.
- **Custom validators** can opt into the same contract by returning a `Principal` (or a
  `(user, principal)` tuple).
- **Guards resolve the principal** from `req.context[:user]` first. Only when no auth
  middleware attached one do `login_required`/`claim_required` fall back to the raw
  `req.session` dict — that fallback serves session-based apps, and `login_required`
  accepts it only when it carries the login marker (`session_key`, default `"user_id"`).

## 3. The error contract

One rule, everywhere:

| Status | Meaning | Returned by |
|---|---|---|
| **401** | *Not authenticated* — credential missing, malformed, expired, or failed verification | `BearerAuth`, `CookieAuthMiddleware` |
| **403** | *Authenticated but not authorized* — the principal lacks the required claim/kid | `claim_required`, `role_required`, `permission_required`, `kid_required` |
| **302** | Browser redirect to login (session-flavored apps) | `login_required` (`redirect_url`, default `/login`) |

A **throwing validator is a 401, never a 500**: both auth middlewares catch validator
exceptions (e.g. `jwt_validator` throwing `AuthError` on an expired token) and return the
same 401 as any other invalid credential. This matches RFC 6750: `invalid_token` → 401,
`insufficient_scope` → 403.

## 4. JWT validation

### Quick start — safe by default

```julia
using Nitro
using Nitro.Auth

jwt_secret = get(ENV, "JWT_SECRET", nothing)
isnothing(jwt_secret) && error("JWT_SECRET must be set")

validator = jwt_validator(jwt_secret)

urlpatterns("",
    path("/profile", profile, method="GET", middleware=[BearerAuth(validator)]),
)
```

Every token is **always** signature-verified (HMAC-SHA256 — the header `alg` is never
trusted) and **always** time-bounded: an `exp` claim is honored, and a token without one
is accepted only as a short-lived access token bounded by `iat + exp_timeout` (15 minutes
by default). There is no permissive mode; hardening below is opt-in *on top of* these
defaults.

### Configuring identity

```julia
jwt_validator(secret)                            # id = "sub" claim (default)
jwt_validator(secret; identity_claim="action")   # id = a custom claim
jwt_validator(keyset; identity_from=:kid)        # id = the verified key id (signer == principal)
```

`identity_from=:kid` says "the key-holder *is* the principal" — the right model when each
caller signs with its own key. It requires a keyset (see the trust model below) and makes
the coupling between identity and key rotation explicit. If per-subject identity might
ever be needed, put a stable `sub` in the token now — even if it currently equals the
`kid` — so identity never has to be retrofitted onto a rotation field.

### Production profile

```julia
validator = jwt_validator(jwt_secret;
    profile = :strict,
    issuer = "https://auth.example.com",
    audience = "product-api",
    required_claims = ["sub"],
)
```

`profile=:strict` refuses to construct without `issuer` and `audience`, and forces
`require_exp=true`. `required_claims` (usable in either profile) rejects tokens missing
any named claim. All configuration errors surface at construction — app startup — not at
request time.

### Key rotation and the `kid` trust model

```julia
keyset = Dict(
    "primary" => get(ENV, "JWT_SECRET_PRIMARY", ""),
    "rotated" => get(ENV, "JWT_SECRET_ROTATED", ""),
)
validator = jwt_validator(keyset)
```

`decode_jwt` selects the key by the token's `kid` header, and the *verified* key id is
exposed as `req.user.kid`. The trust boundary matters: **a `kid` is only trusted when it
was resolved against a keyset** — with a single string secret the header `kid` is an
attacker-writable label, so it is never exposed on the `Principal`, `kid_required` denies,
and `identity_from=:kid` is a construction-time `ArgumentError`.

Lower-level pieces (`encode_jwt`, `decode_jwt`, claim validation for
`exp`/`iat`/`nbf`/`iss`/`aud`) are covered in [Sessions & Auth](sessions_and_auth.md).

## 5. Service & capability tokens

Tokens that authorize an *action* rather than identify a *user* carry an `action` (or
scope) claim and often no `sub`. Authentication works unchanged; authorization is a claim
guard:

```julia
urlpatterns("",
    path("/reports/generate", generate_report, method="POST", middleware=[
        BearerAuth(jwt_validator(jwt_secret)),
        GuardMiddleware(claim_required("action", "reports:generate")),
    ]),
)
```

When callers sign with per-caller keys, authorize by **signer** instead — possession of an
allowed key, for that route, *is* the authorization (the same per-route pattern as Envoy's
`jwt_authn` requirements):

```julia
validator = jwt_validator(keyset; identity_from=:kid)

urlpatterns("",
    # only tokens verified against these key ids may reach this route
    path("/sync", sync_handler, method="POST", middleware=[
        BearerAuth(validator),
        GuardMiddleware(kid_required(["service-a", "service-b"])),
    ]),
)
```

A router-wide default allowlist is just the same guard at the router level, with tighter
per-route subsets where needed. See the service-token section of
[Sessions & Auth](sessions_and_auth.md) for `iat`-only tokens and `exp_timeout`.

## 6. Guards & authorization

Guards are per-route checks composed with `GuardMiddleware(guards...)`; each either
returns `nothing` (pass) or a response (deny). They run after auth middleware, in order.

| Guard | Passes when | Denies with |
|---|---|---|
| `login_required(; redirect_url, session_key)` | An auth middleware attached a non-empty principal, **or** the session carries `session_key` | 302 → `redirect_url` |
| `claim_required(claim, value; kind=:equals)` | `principal[claim] == value` | 403 |
| `claim_required(claim, value; kind=:contains)` | `value in principal[claim]` (a list) | 403 |
| `role_required(role; role_key="role")` | alias: `claim_required(role_key, role)` | 403 |
| `permission_required(perm; permissions_key="permissions")` | alias: `claim_required(permissions_key, perm; kind=:contains)` | 403 |
| `kid_required(allowed)` | The principal's **verified** `kid` is in `allowed` | 403 |

Notes:

- The claim guards read any dict-like principal — a `Principal`, a plain claims dict from
  a custom validator, or (fallback) the raw session dict of a session-authenticated app.
- `kid_required` has **no** session fallback and never trusts a claim named `"kid"` —
  only the keyset-verified key id carried by a `Principal`. No trusted kid ⇒ 403.
- Guards deny with a shared constant `403 Forbidden` response; bodies are stable and safe
  to assert on in tests.

## 7. Session-based auth

`SessionMiddleware`, the `req.session` API, session regeneration, and bridging sessions
into `req.user` are covered in [Sessions & Auth](sessions_and_auth.md).

## 8. Auth cookies & CSRF

`set_auth_cookie!` / `clear_auth_cookie!` and `CSRFMiddleware` for cookie-authenticated
browsers: see [Sessions & Auth](sessions_and_auth.md) and [Cookies](cookies/basics.md).

## 9. Passwords

Password hashing (PBKDF2, BCrypt, Spring/Django-compatible encoders, validation and
upgrade flows): see [Passwords](passwords.md).

## 10. OAuth2

Nitro ships no OAuth2 client. The authorization-code flow is an application concern: exchange
the provider's `code` for tokens yourself, then mint your own session or JWT with the pieces
above — `set_cookie!` and the session store (§7), or `jwt_encode` and a validator (§4).

There used to be a walkthrough here built on [Umbrella.jl](https://github.com/jiachengzhang1/Umbrella.jl).
It was inherited from Oxygen.jl and removed: Umbrella ships adapters for Genie, Oxygen and Mux,
not for Nitro, so the page documented an integration that does not exist.

## 11. Hardening checklist

- Secrets from the environment, never committed; rotate via keysets — [Secrets](secrets.md).
- `profile=:strict` (+ `required_claims`) on production validators (§4).
- Access tokens only, short-lived (`expires_in`/`exp`); refresh-token lifecycles are an
  application concern today.
- Behind a reverse proxy, declare `trusted_proxies` **and** the `forwarded_header` your proxy
  writes before trusting client IPs for auth-adjacent rate limiting —
  [Behind a Reverse Proxy](reverse_proxy.md).
