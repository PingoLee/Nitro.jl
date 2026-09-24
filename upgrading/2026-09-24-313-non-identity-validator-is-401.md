## An auth validator returning `false`, `true`, `""` or an empty dict is now a 401 (#313)

- **Version**: Unreleased
- **Nitro ref**: [#313](https://github.com/PingoLee/Nitro.jl/issues/313) ; `src/types.jl`,
  `src/middleware/auth_middleware.jl`, `src/middleware/guards.jl`, `src/Auth/validators.jl`
- **Recorded**: 2026-09-24
- **Severity**: **behaviour (auth).** The change fails closed. Only a validator that answers
  yes/no instead of naming the caller needs an edit, and it now rejects every request. This was an
  authentication bypass.

### What changed

`BearerAuth` and `CookieAuthMiddleware` rejected a validator result only when it was
`nothing`/`missing`. Anything else was stored as `getuser(req)` and the handler ran. A predicate
validator such as `BearerAuth(t -> t == API_KEY)` returns `false` for a wrong key, so it
**authenticated** that request with `getuser(req) == false`. `login_required` then admitted it,
because it admitted any `req.context[:user]` except an empty dict.

One rule now decides what an identity is. The auth middleware, `jwt_validator` and
`login_required` all apply it. These values are **not** identities:

| Returned by the validator | Before | After |
|---|---|---|
| `nothing`, `missing` | 401 | 401 |
| `false` | 200, `getuser(req) == false` | **401** |
| `true` | 200, `getuser(req) == true` | **401** |
| `""` | 200 | **401** |
| an empty dict, including `Principal(Dict())` | 200 at the middleware; `login_required` redirected | **401** |
| a `(user, claims)` tuple whose `user` is any of the above | 200 (only `nothing` was a 401, #24) | **401** |

Everything else is still an identity. That includes `0`, a string id, a struct, a non-empty
`Principal` whose `id` is `nothing` (a service token), and a claim-less `Principal` that does
carry an `id` (a keyset-verified signer).

`jwt_validator(...; user_validator = f)` returns `nothing` when `f` returns any of these. Before, it
did so only for `nothing`.

`login_required` refuses the same values when they sit at `req.context[:user]`. It also refuses
them as the value of the session's login marker (`session_key`, default `"user_id"`). A logout that
does `session["user_id"] = nothing` instead of deleting the key no longer counts as logged in.
That is a fix and forces no edit. **One shape does need an edit.** A login flag stored as a
`Bool` — `login_required(session_key = "logged_in")` with `session["logged_in"] = true` — now
redirects every logged-in user. The same holds for `session_user_validator(store; user_key =
"logged_in")`, which now answers `401`. A `Bool` says that someone logged in, not who did.

### How to find the calls to migrate

Find every validator wired into an auth middleware, and every `user_validator`:

```bash
grep -rnE 'BearerAuth\(|CookieAuthMiddleware\(|user_validator *=' --include=*.jl .
```

For each one, check whether it returns a comparison or a `Bool`. Look for `==`, `in`,
`isvalid`, `haskey`, or `return true` as the last expression.

Then find a login marker stored as a `Bool`. Check each custom `session_key`/`user_key`, and
every session value set to `true`:

```bash
grep -rnE 'session_key *=|user_key *=' --include=*.jl .
grep -rnE '\] *= *(true|false)\b' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — `false` for a wrong key authenticated the request; `true` "worked" for the right one
BearerAuth(t -> t == API_KEY)

# ✓ after — return who is calling, or `nothing` to reject
BearerAuth(t -> t == API_KEY ? "api-client" : nothing)
```

```julia
# ✗ before — a predicate user_validator
jwt_validator(secret; user_validator = p -> is_active(p.id))

# ✓ after — return the user, or `nothing`
jwt_validator(secret; user_validator = p -> is_active(p.id) ? load_user(p.id) : nothing)
```

```julia
# ✗ before — a Bool login flag
getsession(req)["logged_in"] = true
GuardMiddleware(login_required(session_key = "logged_in"))

# ✓ after — store who logged in (the default key needs no `session_key`)
getsession(req)["user_id"] = user.id
GuardMiddleware(login_required())
```

If a client relied on the predicate's `true` to reach a route, give that route a named identity
as above. Do not remove the auth layer.
