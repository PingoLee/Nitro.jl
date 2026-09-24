## `claim_required` / `role_required` / `permission_required` — the session counts only while it is logged in (#337)

- **Version**: Unreleased
- **Nitro ref**: [#337](https://github.com/PingoLee/Nitro.jl/issues/337) ; `src/middleware/guards.jl`
- **Recorded**: 2026-09-24
- **Severity**: **behavior change (auth).** The fix fails closed: a route that was admitted is
  now a `403`. It closes a standing grant left behind by an incomplete logout.

### What changed

The claim guards resolve claims from `req.context[:user]`, then `req.context[:auth_claims]`, then,
when no auth layer set either, the raw `getsession(req)` dict. That last step never checked that
the session was logged in. A logout that deleted or nulled `session["user_id"]` but left
`session["role"] = "admin"` behind was still authorized as admin by
`GuardMiddleware(role_required("admin"))` on the next request.

The session is now a claims source only while it carries the **login marker**: `session_key`
(default `"user_id"`) holding an identity. That is the same test `login_required` has always
applied to the session, including #313's refusal of `nothing`, `false` and `""`. Without it the
claim guards answer `403`.

The three guards take a new `session_key` keyword, with the same name and default as
`login_required(; session_key)`.

Unaffected:

- Apps that authenticate through an auth layer (`BearerAuth`, `CookieAuthMiddleware`, your own
  middleware setting `req.context[:user]`). The session fallback is not reached there.
- Session-only apps whose login writes `session["user_id"]` and whose logout clears it. A
  logged-in session still authorizes as before.

### How to find the calls to migrate

```bash
grep -rnE 'role_required|claim_required|permission_required' --include=*.jl .
```

Only routes where no auth middleware runs before the guard read the session. For each of those,
find the key your login handler writes:

```bash
grep -rnE 'session\[("|:)[a-z_]+("|)\] *=' --include=*.jl .
```

If it is not `"user_id"`, pass it as `session_key`. If `login_required(session_key = ...)` already
names a custom key on the same route, the claim guards need the same one.

### Migrate your app

```julia
# ✗ before — login writes session["uid"]; the claim guard read any session
login(req) = (getsession(req)["uid"] = user.id; getsession(req)["role"] = user.role; ...)
path("/admin", admin; middleware = [GuardMiddleware(
    login_required(session_key = "uid"), role_required("admin"))])

# ✓ after — name the login marker on the claim guard too
path("/admin", admin; middleware = [GuardMiddleware(
    login_required(session_key = "uid"), role_required("admin"; session_key = "uid"))])
```

A logout should still delete the claim keys it granted (`role`, `permissions`), not just the
marker. The guard no longer depends on that, but other code that reads the session may.
