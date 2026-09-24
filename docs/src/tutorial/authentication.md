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
- **A validator returns an identity, never a yes/no.** `nothing`, `missing`, a `Bool`, `""`
  and an empty dict are not identities: each is a 401, alone or as the user half of a tuple.
  A predicate such as `BearerAuth(t -> t == API_KEY)` therefore authenticates nobody, the
  right key included. Name the caller instead:
  `BearerAuth(t -> t == API_KEY ? "api-client" : nothing)`. A user id of `0` is an identity.
- **The claim guards resolve claims in three steps.** `claim_required` (and its
  `role_required`/`permission_required` aliases) reads `req.context[:user]` when it is
  dict-like; otherwise `req.context[:auth_claims]`; otherwise the raw `getsession(req)` dict,
  which serves session-based apps — but only while it is logged in: it must carry the login
  marker (`session_key`, default `"user_id"`) with an identity as its value, the same test
  `login_required` applies. A logout that clears `user_id` but leaves `role` behind authorizes
  nothing. Pass the same `session_key` to both guards if your login writes a different key.
- **A dict-like `:user` is authoritative, and an absent claim means denial.** It is *not*
  topped up from `:auth_claims`: the token's claims are verified but **stale**, while your
  user object is the result of a fresh lookup, so a demoted user's unexpired `role=admin`
  must not out-rank it. If you want token claims authorized on, merge them into the object
  your `user_validator` returns.
- **A non-dict `:user` blocks the session fallback.** An auth middleware vouched for the
  request with a struct identity, so an unauthenticated session dict is never promoted into
  a claims source for it — the guard denies instead.
- **`login_required` is authentication, not authorization**, so it does not use that
  resolution: it trusts any identity at `req.context[:user]` as-is, and falls back to the
  session only when it carries the login marker (`session_key`, default `"user_id"`) with an
  identity as its value. It refuses the same non-identities the auth middleware does, so a
  `false`, a `""` or a `session["user_id"] = nothing` left behind by a logout is not a login.

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

    That `500` is handled like one raised in a handler: Nitro's error boundary wraps the whole
    middleware chain (#256), so it is logged with a backtrace, recorded in the access log, and
    carries the usual JSON body. The server itself keeps serving normally.

    A crafted token does not get there. `JSON.parse` raises `StackOverflowError` on a
    deeply-nested value, and a bearer token of base64url `[[[[…` used to reach it in about
    4.1 KB — inside nginx's and Apache's default header limits, and not stopped by the 4 KB
    browser cookie cap either, since an attacker's request is not a browser's. `decode_jwt` now
    caps the header segment at 1 KB, rejects JSON nested deeper than 512 levels as malformed,
    and decodes the claims only after the signature verifies, so that token is an ordinary
    `AuthError` and a 401 (#314). What still propagates is the runtime reporting on itself —
    most likely from your own validator code.

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

A token carrying **no** `kid` at all is a different case: it is tried against every key in the
keyset — see [Tokens that carry no `kid`](#Tokens-that-carry-no-kid) below.

**Structural checks are not scoped to `verify`, and that includes `verify=false`.** A token
whose header or claims segment is not a JSON *object*, or whose `kid` is not a string, is
rejected as malformed on both paths — `AuthError("Invalid JWT header")`,
`AuthError("Invalid JWT claims")`, `AuthError("Invalid JWT key id")`. These are the same
kind of check as "a JWT has three segments", not a policy decision about algorithms, and
`with_kid=true` promises a `String` it cannot deliver from a numeric `kid`. If you inspect
foreign tokens offline, this is the one part of the path that got stricter.

**On the verifying path the claims are decoded only after the signature verifies**, in the order
RFC 7519 §7.2 gives: an unsigned or forged token reaches exactly one JSON parse, of its header.
So a forged token with a malformed claims segment fails a header or signature check — with a
single key, `AuthError("Invalid JWT signature")` — never an encoding or claims error; with
`verify=false` the claims are decoded straight away. On both
paths the encoded header segment is capped at **1 KB** (`AuthError("Invalid JWT header: …")`)
and every segment's JSON is capped at 512 levels of nesting — Nitro's own header is under 100
bytes, and `encode_jwt` refuses a `kid` long enough to mint past the cap.

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

### Observing a claim before you require it

A claim has three positions, not two:

| Tier | How | Token missing the claim |
|------|-----|-------------------------|
| ignored | not named | authenticates, nothing said |
| **observed** | `warn_claims = [...]` | **authenticates, and the issuer is reported once** |
| required | `required_claims = [...]` | rejected |

The middle tier is for a claim you intend to enforce but cannot yet, because a legacy issuer
still omits it. Without it the only way to run that window is to not ask for the claim at all —
so the app learns nothing, you flip `required_claims`, and you find out who was non-compliant
from the resulting 401s in production.

```julia
validator = jwt_validator(keyset;
    required_claims = ["iss"],   # enforced today
    warn_claims     = ["sub"],   # expected; still missing from one legacy issuer
)
```

A token missing an observed claim still authenticates. The first time the validator sees a given
`(claim, kid, iss)` combination it logs one warning naming that issuer; after that the same
combination goes only to `@debug`, so a chatty legacy issuer cannot flood the log. When the
warnings stop, the rollout is finished and the claim can move to `required_claims` — a claim may
not be in both lists, and trying is a construction-time `ArgumentError`.

The signal carries the claim name, the **keyset-verified** `kid`, and `iss`. Never the token, and
never any other claim value. With a single string secret the header `kid` is an unverified label,
so it is reported as `nothing` rather than repeated back.

`identity_claim` is just a claim name, so this is also how you watch for tokens that produce a
`Principal` with no `id`: put that claim — `"sub"` by default — in `warn_claims`.

### Key rotation and the `kid` trust model

A keyset is a [`JWTKeyset`](@ref Nitro.Auth.JWTKeyset): **exactly one signing key**, plus any
number of keys that only verify. The signing key verifies too.

```julia
required_env(name::String) = get(ENV, name, nothing) === nothing ? error("$name must be set") : ENV[name]

keyset = JWTKeyset(
    "current" => required_env("JWT_SECRET_CURRENT");                # signs and verifies
    verify = ["previous" => required_env("JWT_SECRET_PREVIOUS")],   # verifies only
)
validator = jwt_validator(keyset)
```

`required_env`, not `get(ENV, "JWT_SECRET_CURRENT", "")`. An empty-string fallback does not
disable the key — it would install `""` as a live HMAC key under a trusted `kid`, so a token
signed with the empty secret verifies. `JWTKeyset` refuses an empty secret for exactly that
reason, but the error then surfaces as a missing key rather than a missing variable; require
every key from the environment. See [Managing Secrets](secrets.md).

A single string secret is held to the same rule: `jwt_validator("")` — or a secret of only
`"\0"` bytes, which HMAC treats as empty — is an `ArgumentError` at startup, and `encode_jwt`
and a verifying `decode_jwt` refuse it too. That is why the quick start above reads
`JWT_SECRET` with a `nothing` default rather than `""`.

The roles describe what a key is **for**, not where it is in a rotation. A rotation window is
"the new key signs, the old one verifies". A registry of service identities — each caller signs
with its own key, and `identity_from=:kid` makes the signer the principal — is "this service's
key signs, every client's key verifies".

A plain `Dict` of `kid => secret` still works, and is lifted into a `JWTKeyset`:

| `Dict` shape | Result |
|---|---|
| has a `"default"` entry | `"default"` signs; every other entry verifies |
| exactly one entry | that entry signs |
| two or more entries, no `"default"` | `ArgumentError` — no key is marked to sign |
| empty | `ArgumentError` |

`jwt_validator` lifts a `Dict` **once, at construction** — app startup — and keeps that
snapshot: mutating the `Dict` afterwards does not change what a running validator accepts. A
direct `decode_jwt` or `encode_jwt` call with a `Dict` lifts it on **every** call. Build the
keyset once, next to your configuration, so a misconfiguration fails at startup — a request-time
auth check that wraps `decode_jwt` in a bare `catch` would otherwise turn it into a 401 on every
request, with nothing at startup to say why.

`decode_jwt` selects the key by the token's `kid` header, and the *verified* key id is
exposed as `getuser(req).kid`. The trust boundary matters: **a `kid` is only trusted when it
was resolved against a keyset** — with a single string secret the header `kid` is an
attacker-writable label, so it is never exposed on the `Principal`, `kid_required` denies,
and `identity_from=:kid` is a construction-time `ArgumentError`.

#### What a keyset refuses

The constructor owns every check, so they apply on every path — `jwt_validator`, and a direct
`decode_jwt` or `encode_jwt` call alike:

  * **Two keys that are the same HMAC key.** A kid-less token could otherwise be attributed to
    either. Keys are compared the way HMAC does, not the way `String` does — HMAC-SHA256
    pre-hashes any key longer than its 64-byte block and zero-pads any key shorter, so for a
    secret over 64 bytes `K` and `sha256(K)` are one key, as are `"a"` and `"a\0"`, even though
    each pair reads as two.
  * **A secret that is not a string.** A value must be an `AbstractString` or a `SecretString`
    (which is accepted as is — no need to `reveal` it). A `Vector{UInt8}` is refused **without
    being read**: converting one to a `String` empties the caller's buffer.
  * **An empty secret, a duplicate `kid`, and a `kid` that is not a `String` or `Symbol`.**

#### Tokens that carry no `kid`

A `kid` is a *hint*, not a requirement, and a foreign issuer may omit it. When a token names
no key, **every key in the keyset is tried**, the signing key first and then the rest by name,
and `principal.kid` reports whichever key actually verified the signature — which is honest,
because that key *is* the signer. This is what makes a rotation window work: while an external
issuer is still signing with the old secret, its kid-less tokens keep authenticating.

A token that *does* name a `kid` is checked against that key and no other, so naming one is
still both faster and more precise. A forged **kid-less** token costs one HMAC per key in the
set; keysets are small and operator controlled, and a forged token that names a `kid` still
costs exactly one.

#### Signing with a keyset

A keyset signs with its signing key and stamps that key's `kid` into the header; a plain string
secret signs a token with no `kid`. There is no `kid=` keyword — which key signs is the keyset's
to say, not the call site's. To call another service **as** one identity of a shared registry,
build a one-key keyset for that purpose, once:

```julia
encode_jwt(claims, keyset)                         # signs with, and stamps, "current"

as_partner = JWTKeyset("partner-caller" => required_env("JWT_SECRET_PARTNER"))
encode_jwt(claims, as_partner; expires_in = 60)    # signs as "partner-caller"
```

When no key verifies a kid-less token against a multi-key keyset, the error says so
(`No key in the JWT keyset verified this token`) rather than `Invalid JWT signature` — the
signature may be perfectly valid, and the operator should be looking at key selection, not at
clock skew and shared secrets.

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
per-route subsets where needed. Router middleware wraps route middleware, so a router-level
guard runs before any route-level auth layer: put the `BearerAuth` on the router, not only on
its routes. See the service-token section of [Sessions & Auth](sessions_and_auth.md) for
`iat`-only tokens and `exp_timeout`.

## 6. Guards & authorization

Guards are per-route checks composed with `GuardMiddleware(guards...)`; each either
returns `nothing` (pass) or a response (deny). They run after auth middleware, in order.

| Guard | Passes when | Denies with |
|---|---|---|
| `login_required(; redirect_url, session_key)` | An auth middleware attached an identity, **or** the session carries one under `session_key` | 302 → `redirect_url` |
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
