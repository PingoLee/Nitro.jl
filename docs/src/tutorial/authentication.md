# Authentication

Nitro's auth layer is a set of **primitives plus a small declarative surface**, not a
framework: you own the user model and login flow; Nitro owns token verification, the
principal contract, and route guards. The design follows established precedents — the
principal mirrors ASP.NET's `ClaimsPrincipal` / Spring's `Authentication` (identity claim
defaults to `sub`), `claim_required` mirrors ASP.NET's `RequireClaim`, and the 401/403
split follows RFC 6750.

!!! note "Scope: Nitro verifies tokens, your application issues them"

    Nitro.Auth is the **resource-server** half of a token system. It verifies an access
    token's signature and claims, builds a `Principal` from them, and authorizes routes on
    that principal. **Refresh-token lifecycles, rotation, revocation and denylisting are
    your application's** — Nitro ships no refresh endpoint, no `jti`, and no revocation
    store, and `encode_jwt` is a signing primitive rather than a token service.

    That split is deliberate and follows Spring, whose declarative model this page's guards
    already mirror: token *validation* lives in Spring Security, while refresh issuance and
    rotation live in Spring Authorization Server — a separate project, because rotation with
    reuse detection needs server-side state that a stateless verifier must not pretend to
    have. §4's *[Token lifetime and renewal](#Token-lifetime-and-renewal)* shows the two
    routes Nitro supports for keeping a user signed in past one token's lifetime.

## 1. Pick your model

| Model | Credential | Typical client | Identity | Start here |
|---|---|---|---|---|
| **Session auth** | Session cookie | Browsers (stateful) | `user_id` in `getsession(req)` | [Sessions & Auth](sessions_and_auth.md) |
| **Bearer / JWT** | `Authorization: Bearer <jwt>` | SPAs, mobile, APIs | `sub` claim | §4 below |
| **Service / capability token** | Bearer JWT, no `sub` | Machine-to-machine | the `action`/scope claim | §5 below |
| **Key-scoped (signer) auth** | Bearer JWT signed by a per-caller key | Multi-tenant services | the verified `kid` | §5 below |

The models compose: one app can serve browser sessions on HTML routes and bearer tokens on
API routes. Whatever the model, the result of authentication is the same artifact — the
**principal** attached to the request.

## 2. The principal

Auth middleware (`BearerAuth`, `CookieAuthMiddleware`) attaches the authenticated identity
at `req.context[:user]`, read with `getuser(req)`. With `jwt_validator` the attached value
is a `Principal` — an immutable, dict-like wrapper over the **verified** claims:

```julia
function whoami(req::HTTP.Request)
    user = getuser(req)
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
- **Two context slots.** Without a `user_validator`, the `Principal` *is* `getuser(req)`. With
  one, your returned user object lands in `req.context[:user]` and the `Principal` rides
  along at `req.context[:auth_claims]` — so the guards still see the verified metadata even
  when your user object is a plain struct.
- **Custom validators** can opt into the same contract by returning a `Principal` (or a
  `(user, principal)` tuple). A `(nothing, principal)` tuple is *not* authenticated — a nil
  user is a 401, the same as returning `nothing`.
- **The claim guards resolve claims in three steps.** `claim_required` (and its
  `role_required`/`permission_required` aliases) reads `req.context[:user]` when it is
  dict-like; otherwise `req.context[:auth_claims]`; otherwise the raw `getsession(req)` dict,
  which serves session-based apps.
- **A dict-like `:user` is authoritative, and an absent claim means denial.** It is *not*
  topped up from `:auth_claims`: the token's claims are verified but **stale**, while your
  user object is the result of a fresh lookup, so a demoted user's unexpired `role=admin`
  must not out-rank it. If you want token claims authorized on, merge them into the object
  your `user_validator` returns.
- **A non-dict `:user` blocks the session fallback.** An auth middleware vouched for the
  request with a struct identity, so an unauthenticated session dict is never promoted into
  a claims source for it — the guard denies instead.
- **`login_required` is authentication, not authorization**, so it does not use that
  resolution: it trusts any non-empty `req.context[:user]` as-is, and falls back to the
  session only when it carries the login marker (`session_key`, default `"user_id"`).

!!! warning "Revocation and the struct-user path"

    The two rules above are deliberately asymmetric, and the asymmetry decides how fast a
    revocation takes effect. With a **dict-like** user object your fresh lookup is what the
    guards read, so a demotion applies on the next request. With a **struct** user object the
    guards read the token's claims instead — verified, but issued in the past and *not*
    re-checked against your lookup — so a demoted user keeps whatever the token says for the
    rest of its TTL.

    ```julia
    # `user_validator` does a fresh lookup on every request...
    jwt_validator(secret; user_validator = p -> load_user(p["sub"]))
    ```

    If `load_user` returns a struct, `role_required("admin")` still authorizes off the token.
    To make revocation effective within the token TTL, return a **dict** that merges your
    fresh state, and keep the token's claims out of it unless you mean them:

    ```julia
    user_validator = function (p)
        u = load_user(p["sub"])
        u === nothing && return nothing            # 401 — user is gone
        Dict{String,Any}("sub" => p["sub"], "role" => u.role, "permissions" => u.permissions)
    end
    ```

    Short token lifetimes are the other half of this; Nitro cannot revoke a signed token it
    did not issue.

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

!!! warning "Three exceptions propagate instead (#254)"
    `InterruptException`, `StackOverflowError` and `OutOfMemoryError` are **not** mapped to a
    401 — they travel on to the server's error path as a `500`. They are not failures of the
    credential; they are the runtime reporting on itself, and Julia describes a stack overflow
    as *"program state may be corrupted, so further execution might be unreliable"*. A worker in
    that state must not quietly go on authenticating people.

    Be aware of what that `500` looks like from the client: auth middleware runs *outside*
    Nitro's serializer, so the response is a **bodyless `500` with no log line and no
    access-log entry** — unlike a `500` raised inside a handler, which is logged with a
    backtrace and carries the usual JSON body. The server itself keeps serving normally.

    This is request-reachable, not theoretical: `JSON.parse` raises `StackOverflowError` on a
    deeply-nested value, so a bearer token whose header segment is base64url of `[[[[…` gets
    there. Reaching it through *this* path takes an `Authorization` header of about 8.3 KB
    (nesting depth ~3100 on a request task) — above nginx's default 8k header buffer and
    Apache's `LimitRequestFieldSize` of 8190, so a default-configured proxy refuses it, and a
    cookie cannot carry it at all at the 4 KB browser cap. Nitro served directly accepts it.
    The same overflow reached through a request **body** or a query parameter needs only
    ~6.2 KB and nothing gates that, which is why the body parsers take the same narrowing.

    If your own validator wraps work in a `try`, narrow it the same way — catch the failures you
    expect, not everything:

    ```julia
    # ✗ a bare catch also eats a corrupted-state condition
    user = try lookup(token) catch; nothing end

    # ✓ name what you are handling
    user = try
        lookup(token)
    catch e
        e isa MyDBError || rethrow()
        nothing
    end
    ```

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

Every token is **always** signature-verified and **always** time-bounded: an `exp` claim is
honored, and a token without one is accepted only as a short-lived access token bounded by
`iat + exp_timeout` (15 minutes by default). There is no permissive mode; hardening below is
opt-in *on top of* these defaults.

**HMAC-SHA256 is the only algorithm, and a header that says otherwise is rejected** — not
ignored. A token whose header advertises anything but `alg: "HS256"` (including `"none"`, or
no `alg` at all) fails with `AuthError("Unsupported JWT algorithm")` before any key is
resolved. Nitro never loads a public key and never dispatches on `alg`, so the classic
RS256→HS256 confusion attack does not apply either way; the explicit check is there so the
guarantee is *stated* rather than emergent, and so a later refactor cannot weaken it
silently. The `alg` gate sits inside the `verify` branch, so
`decode_jwt(...; verify=false)` — offline inspection, not authentication — still parses a
token whatever algorithm its header claims.

A `kid` that is **present** in the header but absent from the keyset is
`AuthError("Unknown JWT key id")` — no falling back to another key, which is what would let a
revoked signer keep working.

A token carrying **no** `kid` at all is a different case, and the framework is less strict
there than the paragraph above may suggest: it resolves to the keyset's `"default"` entry, or,
failing that, to an arbitrary first key — and it verifies against **only** that one key. A
kid-less token signed with a *different* key in the same keyset is therefore rejected as
`AuthError("Invalid JWT signature")`, which points at the signature rather than at key
selection. If you accept kid-less tokens from an external issuer, have it stamp a `kid`.

**Structural checks are not scoped to `verify`, and that includes `verify=false`.** A token
whose header or claims segment is not a JSON *object*, or whose `kid` is not a string, is
rejected as malformed on both paths — `AuthError("Invalid JWT header")`,
`AuthError("Invalid JWT claims")`, `AuthError("Invalid JWT key id")`. These are the same
kind of check as "a JWT has three segments", not a policy decision about algorithms, and
`with_kid=true` promises a `String` it cannot deliver from a numeric `kid`. If you inspect
foreign tokens offline, this is the one part of the path that got stricter.

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
required_env(name::String) = get(ENV, name, nothing) === nothing ? error("$name must be set") : ENV[name]

keyset = Dict(
    "primary" => required_env("JWT_SECRET_PRIMARY"),
    "rotated" => required_env("JWT_SECRET_ROTATED"),
)
validator = jwt_validator(keyset)
```

`required_env`, not `get(ENV, "JWT_SECRET_PRIMARY", "")`. An empty-string fallback does not
disable the key — it installs `""` as a live HMAC signing key under a trusted `kid`, so a token
signed with the empty secret verifies. Every key in a keyset must be required from the
environment; see [Managing Secrets](secrets.md).

`decode_jwt` selects the key by the token's `kid` header, and the *verified* key id is
exposed as `getuser(req).kid`. The trust boundary matters: **a `kid` is only trusted when it
was resolved against a keyset** — with a single string secret the header `kid` is an
attacker-writable label, so it is never exposed on the `Principal`, `kid_required` denies,
and `identity_from=:kid` is a construction-time `ArgumentError`.

Lower-level pieces (`encode_jwt`, `decode_jwt`, claim validation for
`exp`/`iat`/`nbf`/`iss`/`aud`) are covered in [Sessions & Auth](sessions_and_auth.md).

### Token lifetime and renewal

A token lives exactly as long as its `exp` says, or — with no `exp` — until
`iat + exp_timeout` (15 minutes by default). After that the validator throws and the request
is a 401. **Nitro never re-issues a token**, and it cannot: verifying a signature says
nothing about whether the subject is still entitled to a new one. Two routes keep a user
signed in past that point, and both already exist.

**A browser app: make the session the long-lived thing, not the token.** `SessionMiddleware`
and a session store are what Nitro ships for this, with `regenerate_session!` /
`rotate_on_auth` covering fixation on login — see
[Sessions & Auth](sessions_and_auth.md). A cookie-borne session is renewed by the store,
so there is no second token to rotate.

**An API or SPA that needs a refresh endpoint: your application owns it.** Mint two tokens
that differ by a claim, and let an ordinary guard keep the long-lived one away from your
ordinary routes:

```julia
# At login: a short access token, and a long-lived one marked for one purpose only.
access  = encode_jwt(Dict("sub" => user.id, "token_use" => "access"),  secret; expires_in=900)
refresh = encode_jwt(Dict("sub" => user.id, "token_use" => "refresh"), secret; expires_in=60*60*24*14)

# The refresh endpoint accepts ONLY the refresh token — a stolen access token cannot mint more.
urlpatterns("",
    path("/auth/refresh", refresh_handler, method="POST", middleware=[
        BearerAuth(validator),
        GuardMiddleware(claim_required("token_use", "refresh")),
    ]),
)

# ...and every ordinary route refuses the refresh token in the other direction.
GuardMiddleware(claim_required("token_use", "access"))
```

`token_use` is the claim name AWS Cognito uses for exactly this discriminator. Prefer it to
`typ`: `encode_jwt` already writes a JOSE header `typ: "JWT"`, and a payload claim of the
same name reads as that header to anyone debugging a token.

What the recipe above does **not** give you, and what your `refresh_handler` still owns:

- **Rotation** — issuing a new refresh token with each use, so a captured one has a bounded life.
- **Reuse detection** — recognizing that an already-spent refresh token came back, which is the
  signal that it was stolen, and invalidating the whole family when it does. This is the part
  that needs a store; [RFC 6749 §6](https://www.rfc-editor.org/rfc/rfc6749#section-6) and the
  OAuth 2.0 Security BCP describe the shape.
- **Revocation** — the same limit §2's *Revocation and the struct-user path* describes: Nitro
  cannot revoke a signed token it did not issue, so a fresh lookup in your `user_validator` is
  what makes a demotion take effect inside the token's TTL.

Short access-token lifetimes are what keep all three from being urgent.

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
  a custom validator, the `Principal` at `req.context[:auth_claims]` when your
  `user_validator` returned a non-dict user object, or (last) the raw session dict of a
  session-authenticated app. Full precedence and its rationale: §2.
- `kid_required` has **no** session fallback and never trusts a claim named `"kid"` —
  only the keyset-verified key id carried by a `Principal`. No trusted kid ⇒ 403.
- Guards deny with a shared constant `403 Forbidden` response; bodies are stable and safe
  to assert on in tests.

## 7. Session-based auth

`SessionMiddleware`, the `getsession(req)` API, session regeneration, and bridging sessions
into `getuser(req)` are covered in [Sessions & Auth](sessions_and_auth.md).

## 8. Auth cookies & CSRF

`set_auth_cookie!` / `clear_auth_cookie!` and `CSRFMiddleware` for cookie-authenticated
browsers: see [Sessions & Auth](sessions_and_auth.md) and [Cookies](cookies/basics.md).

## 9. Passwords

Password hashing (PBKDF2, BCrypt, Spring/Django-compatible encoders, validation and
upgrade flows): see [Passwords](passwords.md).

## 10. OAuth2

Nitro ships no OAuth2 client. The authorization-code flow is an application concern: exchange
the provider's `code` for tokens yourself, then mint your own session or JWT with the pieces
above — `set_cookie!` and the session store (§7), or `encode_jwt` and a validator (§4).

There used to be a walkthrough here built on [Umbrella.jl](https://github.com/jiachengzhang1/Umbrella.jl).
It was inherited from Oxygen.jl and removed: Umbrella ships adapters for Genie, Oxygen and Mux,
not for Nitro, so the page documented an integration that does not exist.

## 11. Hardening checklist

- Secrets from the environment, never committed; rotate via keysets — [Secrets](secrets.md).
- `profile=:strict` (+ `required_claims`) on production validators (§4).
- Access tokens only, short-lived (`expires_in`/`exp`). Refresh, rotation and revocation
  are your application's — see the scope note at the top of this page and §4's *Token
  lifetime and renewal*.
- Behind a reverse proxy, declare `trusted_proxies` **and** the `forwarded_header` your proxy
  writes before trusting client IPs for auth-adjacent rate limiting —
  [Behind a Reverse Proxy](reverse_proxy.md).
