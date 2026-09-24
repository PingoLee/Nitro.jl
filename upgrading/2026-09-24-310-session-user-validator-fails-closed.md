## `session_user_validator` — an anonymous session no longer authenticates, and the default key is `"user_id"` (#310)

- **Version**: Unreleased
- **Nitro ref**: [#310](https://github.com/PingoLee/Nitro.jl/issues/310) ; `src/Auth/validators.jl`
- **Recorded**: 2026-09-24
- **Severity**: **breaking (auth).** The fix fails closed. An app that relied on the old default
  key now gets a `401` for every session until it names the key. This was an authentication
  bypass.

### What changed

`Auth.session_user_validator(store)` turns a session into an authenticated user for
`CookieAuthMiddleware`. When the session had no `user_key` entry, it returned the **whole session
dict** instead of `nothing`. `SessionMiddleware` gives every visitor a session, so an anonymous
visitor with a cart authenticated as `Dict("cart" => [...])`. `login_required` admits any
non-empty user, so the visitor passed it too. An empty session authenticated on a route guarded
by the session `CookieAuthMiddleware` alone.

It now returns `nothing`, which is a `401`, when:

- the session has no `user_key` entry,
- the entry's value is `nothing`, or
- the session does not exist or is not a dict.

The default `user_key` also moved from `"user"` to **`"user_id"`**. That is the key
`login_required(session_key = ...)` and `SessionMiddleware(auth_key = ...)` already read, and the one
every Nitro doc sets at login. Under the old default, a session shaped like the docs never matched
the key. It reached the fallthrough every time, which is how the bypass was usually hit.

`getuser(req)` is the value stored under the key. With `session["user_id"] = 42` it is `42`. A plain
id is not a claims source, so `claim_required`/`role_required` deny it. Store a dict under the key
if those guards should read the session.

### How to find the calls to migrate

```bash
grep -rn 'session_user_validator(' --include=*.jl .
```

For each call without `user_key =`, check which key your login handler writes:

```bash
grep -rnE '\["user"\]|\[:user\]|\["user_id"\]|\[:user_id\]' --include=*.jl .
```

Then check what the protected routes read from the user. **This is the common case, and the
first grep alone will not flag it.** The docs log in with `session["user_id"] = id` and never
passed `user_key`, so such an app never matched the old default `"user"`. It reached the
fallthrough on every request, and `getuser(req)` was the **whole session dict**. Now it is the
bare id. Code that indexed into it now raises a `MethodError`, which is a `500`. Claim guards
that read the session's `"role"` through it now answer `403`:

```bash
grep -rnE 'getuser\(req\)\[|role_required|claim_required|permission_required' --include=*.jl .
```

### Migrate your app

The login stored `session["user"]`, and the default key found it:

```julia
# ✗ before
getsession(req)["user"] = Dict("id" => user.id, "role" => user.role)
session_auth = CookieAuthMiddleware(Auth.session_user_validator(store); cookie_name = "nitro_session")

# ✓ after — name the key you store under
session_auth = CookieAuthMiddleware(Auth.session_user_validator(store; user_key = "user");
                                    cookie_name = "nitro_session")
```

The login stored `session["user_id"]`, and routes read more than the id through `getuser`:

```julia
# ✗ before — `getuser(req)` was the whole session, by accident
getsession(req)["user_id"]  = user.id
getsession(req)["role"]     = user.role
getsession(req)["username"] = user.name
path("/admin", admin; middleware = [session_auth, GuardMiddleware(role_required("admin"))])
admin(req) = "hello $(getuser(req)["username"])"

# ✓ after — keep the user dict under its own key, and point the validator at it
getsession(req)["user_id"] = user.id          # still the marker login_required and rotation read
getsession(req)["user"]    = Dict("id" => user.id, "role" => user.role, "username" => user.name)
session_auth = CookieAuthMiddleware(Auth.session_user_validator(store; user_key = "user");
                                    cookie_name = "nitro_session")
admin(req) = "hello $(getuser(req)["username"])"
```

To keep `session["user_id"]` a plain id instead, read the other fields from `getsession(req)` in
the handler. A claim guard then denies, because a plain id is not a claims source.

**The same call as `SessionMiddleware(validator = ...)` fails silently, not with a `401`.** Take
an app that passes `Auth.session_user_validator(store)` without `user_key` as the session
middleware's fixation validator, and whose login writes `session["user"]`. It rotated the session
id at login only by accident, and it no longer does. The validator now returns `nothing` before
and after login, so the pre-login id survives into the logged-in session. Pass
`user_key = "user"`, or log in under `"user_id"`, which `SessionMiddleware(auth_key = ...)` reads
directly.

An app that already stores `session["user_id"]` and passes `user_key = "user_id"` needs no edit.
If an anonymous visitor could reach a page because the fallthrough authenticated them, that page
now answers `401`. Log the visitor in, or take the route out from behind the session auth.
