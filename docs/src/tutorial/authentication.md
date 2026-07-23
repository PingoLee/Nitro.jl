# Authentication

!!! warning "Outline / work in progress"
    This page is a **skeleton**, not finished documentation. It fixes the *structure*
    of Nitro's authentication story so sections can be filled consistently, and it is a
    coverage checklist: each `🔍`/`📝`/`🟡` marker is a gap to resolve (or an issue to
    file) before that section is written. It is intentionally **not** in the site nav
    (`docs/make.jl`) until it is filled in against a settled `req.user` contract (#4).

Status legend: ✅ written elsewhere · 🟡 blocked on an open contract change · 🔍 needs a
code check before documenting (candidate review task) · 📝 gap, nothing to point at yet.

## 1. Overview — pick your model

- What Nitro provides vs. what the app owns (`Nitro.Auth` is primitives, not a framework). ✅ (intro of `sessions_and_auth.md`)
- Decision guide: **session auth** (browser, stateful) vs **bearer/JWT** (API, stateless) vs **service/capability tokens** (machine-to-machine). 📝 (no side-by-side "which do I use" exists)
- The `req.user` contract — what an "authenticated principal" is. 🟡 (#4; also #24 — Dict vs struct)

## 2. Principals & the request context

- `req.user`, `req.context[:user]`, `req.context[:auth_claims]` — who sets each, expected shape. 🟡 (#4)
- How guards resolve the principal (`_request_user`), incl. the raw-session fallback. 🔍 (fallback is a bypass surface — login_required just changed; `role_required`/`permission_required` still fall back — is that intended?)

## 3. Bearer / JWT auth

- `BearerAuth(validator)` — header + optional cookie extraction, `(user, claims)` tuple form. ✅ partial (`sessions_and_auth.md` "JWT Helpers")
- `CookieAuthMiddleware(validator)`. 🔍 (does not catch validator exceptions → 500 instead of 401 — #11)
- Error/status taxonomy across the auth layer (401 consts vs 302 vs 403 vs 500). 🔍 (no single documented contract; ties to #11)

## 4. JWT internals

- `encode_jwt` / `decode_jwt` — HS256, `verify`, `require_exp`, `exp_timeout`, `iat_skew`. ✅ partial
- Claim validation: `exp`/`iat`/`nbf`/`iss`/`aud`. ✅ (one line today; expand)
- Key rotation: keyset + `kid`, `_resolve_secret`, `with_kid`. ✅ partial
- **JWT security checklist**: is `alg=none` rejected? algorithm pinned to HS256 on decode? `aud` as array supported? behavior when `kid` present but not in keyset? 🔍 (candidate issue — verify against `src/Auth/jwt.jl`, none of this is documented or clearly tested)

## 5. Service & capability tokens

- Tokens keyed by `action`/scope, no `sub`/`user_id`. ✅ (just added to `sessions_and_auth.md`)
- Authorize by claim with `role_required(...; role_key="action")`; `action_required` alias. ✅
- `iat`-only tokens + `exp_timeout` replay bound. ✅
- **Depends on the login_required follow-up being merged** before this reads true on `main`. 🟡

## 6. Guards & authorization

- `login_required`, `role_required`, `permission_required` — signatures, what each checks. ✅ partial (scattered)
- A single guards matrix (input shape, pass/deny condition, status code). 📝
- Non-Dict principals (structs) are rejected by guards. 🔍 (#24)
- Composing guards with `GuardMiddleware`; order vs middleware. ✅ (nitro-core §5)

## 7. Session-based auth

- `SessionMiddleware` + a `SessionAuthMiddleware` bridge to `req.user`. ✅ ("Unified Auth Context")
- The unused `validator` kwarg on `SessionMiddleware`. 🟡 (#4 / audit)
- Session regeneration on login (fixation). ✅ ("Session Regeneration")

## 8. Auth cookies & CSRF

- `set_auth_cookie!` / `clear_auth_cookie!` / `extract_auth_token`. ✅ partial
- `CSRFMiddleware` for cookie auth. ✅ partial (🔍 token not session-bound + thin tests — #10)

## 9. Passwords

- Encoders (PBKDF2 / BCrypt / delegating / legacy) + `PasswordValidator`. ✅ (`passwords.md` — link, don't duplicate)

## 10. OAuth2

- Authorization-code flow. ✅ (`oauth2.md` — link)

## 11. Hardening / deployment

- Refresh-token lifecycle (or documented "access tokens only"). 🟡 (#7)
- Baseline security-response headers. 🔍 (no middleware ships — #13)
- Secrets from env, not committed; rotate. ✅ (`secrets.md`)
- Reverse proxy, `trusted_proxies`, client-IP trust for auth rate-limiting. 🔍 (spoofable in trusted mode — #16)
