## `kid_required` — reads the token's kid, never one an app-built `Principal` carries (#517)

- **Version**: Unreleased
- **Nitro ref**: [#517](https://github.com/PingoLee/Nitro.jl/issues/517) ; `src/middleware/guards.jl`
- **Recorded**: 2026-10-14
- **Severity**: **behavior change (auth).** The fix fails closed: a route that was admitted on an
  unverified key id is now a `403`, or whatever your `denied` factory answers.

### What changed

When a `jwt_validator` has a `user_validator`, the auth middleware puts the application's object at
`req.context[:user]` and the token's own `Principal` at `req.context[:auth_claims]`. `kid_required`
read `:user` **first**. If the `user_validator` returned a `Principal` it built itself with a `kid`,
the guard authorized on that kid, which nothing had verified:

- with a single string secret, which never yields a verified kid, an "enriched" copy such as
  `Principal(Dict(p); id = p.id, kid = "importer")` passed `kid_required("importer")`;
- with a keyset, a `user_validator` that relabelled the kid was authorized as the label, not as
  the key that signed the token.

`kid_required` now reads the kid from `getprincipal(req)`. That function reads `:auth_claims` first,
so the guard authorizes on the same key id a handler sees. A custom validator that returns a bare
`Principal` (no `(user, claims)` tuple) still opts in through `:user`, because that one is the
token's `Principal`.

Unaffected: apps whose `user_validator` returns a non-`Principal` user (a `Dict`, a struct, an id),
or a `Principal` without a `kid`. Apps with no `user_validator` are unaffected too.

### How to find the calls to migrate

Find `user_validator`s that build a `Principal` with a `kid`:

```bash
grep -rn 'user_validator' --include=*.jl .
grep -rnE 'Principal\(.*kid *=' --include=*.jl .
```

The second grep matches a constructor call on one line. A call split across lines, with
`kid = …` on a later line, needs reading by hand from the first grep's hits.

An app is affected only where both hold on a route that `kid_required` guards. Where the token is
verified against a single string secret, that route now refuses every request. It always should
have.

### Migrate your app

```julia
# ✗ before -- single secret; the app-written kid admitted the request
validator = jwt_validator(secret; user_validator = p -> Principal(Dict(p); id = p.id, kid = "importer"))
GuardMiddleware(kid_required("importer"))

# ✓ after -- authenticate against a keyset, so the token itself carries a verified kid;
#            the user_validator need not (and cannot) supply one
validator = jwt_validator(JWTKeyset("importer" => importer_secret);
                          user_validator = p -> Principal(Dict(p); id = p.id))
GuardMiddleware(kid_required("importer"))
```

A handler that needs the key id reads `getprincipal(req).kid`, never a `kid` it wrote itself.
