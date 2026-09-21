## A validator returning `(nothing, claims)` is now a 401, not an authenticated request (#24)

- **Version**: 0.4.0
- **Nitro ref**: #24; `src/middleware/auth_middleware.jl`, `src/middleware/guards.jl`,
  `docs/src/tutorial/authentication.md`, `test/middleware/authmiddleware_tests.jl`,
  `test/middleware/guards_tests.jl`, `test/auth_tests.jl`
- **Recorded**: 2026-09-19
- **Severity**: **behaviour (auth).** The forcing change fails closed: nothing needs an edit
  unless you wrote a custom validator returning a `(user, claims)` tuple whose user half can be
  `nothing`. Two non-forcing reorderings ride along and are described below — one of them can
  *grant* where the old code denied, but only for apps that write `req.context[:auth_claims]`
  themselves.

### What changed

`BearerAuth` and `CookieAuthMiddleware` hand a validator's return value to the shared
`_handle_validated` dispatch: `nothing`/`missing` is a 401, a `(user, claims)` 2-tuple populates
`req.context[:user]` + `req.context[:auth_claims]`, anything else populates `:user` alone.

The tuple branch never checked the user half. A validator returning `(nothing, claims)` therefore
**authenticated** the request with `req.context[:user]` set to `nothing` — `getuser(req)` returned
`nothing` on a request that had passed authentication, and any unguarded route served it. That
contradicted `jwt_validator`, which has always mapped a `user_validator` returning `nothing` to a
plain `nothing`, i.e. to the 401. A nil user is now the 401 in both paths.

The same release makes the claim guards (`claim_required` and its `role_required` /
`permission_required` aliases) read `req.context[:auth_claims]` when `req.context[:user]` is not
dict-like — so a `user_validator` returning a struct no longer gets a 403 on a correctly
authenticated request. That half is a repair and forces no edit.

It does reorder two sources for application code that sets `:auth_claims` **without** a
`:user`: a dict-like `:auth_claims` now outranks the session dict in *both* directions. One
that lacks the required claim denies instead of falling through to a matching session; one
that carries it grants where a non-matching session previously denied. Framework wiring never
produces that state — `_handle_validated` is the only writer of `:auth_claims` in `src/`, and
it always writes `:user` alongside — so this reaches you only if your own middleware sets the
slot directly.

Relatedly, an auth middleware now keeps the two slots describing the *same* principal: its
validator's claims always replace whatever was on the request, and a validator returning a plain
user object (no `(user, claims)` tuple) **clears** `:auth_claims` outright. That matters if you
stack two auth middlewares — previously the inner layer's user could be authorized against the
outer layer's token claims, which described a different identity — and equally if your own
middleware seeds `:auth_claims` upstream of an auth layer, since the auth layer now wins. If you
were using that slot to pass claims *into* the guards, set a dict-like `req.context[:user]`
instead, or place your middleware after the auth layer.

**Worth knowing if your `user_validator` returns a struct**: the guards then authorize off the
**token's** claims, not off your lookup's result. Those claims are verified but were issued in
the past, so a user demoted mid-token keeps what the token says until it expires. A dict-like
user object does not behave this way — it is authoritative, and an absent claim denies. If
revocation must take effect within the token TTL, return a dict that merges your fresh state.
This is a property of the repair, not a regression: before it, the struct case returned 403 for
everyone, revoked or not.

### How to find the calls to migrate

Custom validators passed to `BearerAuth`/`CookieAuthMiddleware` that can return a tuple:

The failing shape is rarely a literal `(nothing, …)` — it is `(user, claims)` where `user` is
`nothing` at *runtime*. So find the validators, then read their rejection paths:

```bash
# every validator wired into an auth middleware, and every user_validator
rg -n 'BearerAuth\(|CookieAuthMiddleware\(|user_validator\s*=' <app>/src

# tuple returns, including Julia's implicit final-expression form
rg -n -U '(return\s*)?\([^()]+,\s*(claims|principal|p)\s*\)\s*$' <app>/src
```

For each hit, ask whether the user half can be `nothing` — typically a `find_user` /
`load_user` lookup that misses.

### Migrate your app

Return `nothing` to reject, and reserve the tuple for a real user:

```julia
# before — "no user, but here are the claims" authenticated the request
function validate(token)
    claims = decode_jwt(token, SECRET)
    user = lookup_user(claims["sub"])      # may be `nothing`
    return (user, claims)
end

# after — reject explicitly; the tuple means "authenticated as this user"
function validate(token)
    claims = decode_jwt(token, SECRET)
    user = lookup_user(claims["sub"])
    user === nothing && return nothing     # 401
    return (user, claims)
end
```

If you relied on the old behaviour to serve anonymous-but-token-bearing requests, that is a
capability token: return the `Principal` (or claims dict) alone rather than a tuple, and authorize
it with `claim_required`.
