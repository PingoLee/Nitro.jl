## A token or user validator written with a `where` clause is called, instead of answering 401 (#627)

- **Version**: 0.7.0
- **Nitro ref**: [#627](https://github.com/PingoLee/Nitro.jl/issues/627) ; `src/utilities/misc.jl`
- **Recorded**: 2026-10-19
- **Severity**: **behavior change (auth).** Requests that were refused with a `401` are now
  decided by the validator, so some of them are admitted.

### What changed

`BearerAuth`, `CookieAuthMiddleware` and `jwt_validator(...; user_validator = …)` call a validator
as `f(x)` or as `f(x, req)`, depending on the methods it has. The check that decides this read
`method.sig.parameters`. A method written with a `where` clause has a `UnionAll` signature, which
has no `parameters` field, so the check threw a `FieldError`.

For the two middlewares, that throw happened inside the `catch` that turns a failing validator into
"no identity". **Every request was answered with a `401`, the validator was never called, and
nothing was logged.** A direct call to a `jwt_validator` with no request
(`validator(token)`) threw the `FieldError` to the caller instead.

The check now unwraps the `where` clause first. A `where`-clause validator is called with the
arity it declares, the same way as any other validator, so it admits the requests it accepts.

Unaffected: validators written without a `where` clause, typed or not, including callable structs.

### How to find the calls to migrate

List the validators handed to the auth middleware and to `jwt_validator`, including calls that
span several lines:

```bash
grep -rn -A3 -E 'BearerAuth\(|CookieAuthMiddleware\(|jwt_validator\(|user_validator' --include=*.jl .
```

For each validator that is a named function or a lambda, check its definition for `where`, e.g.
`function lookup(t::T) where {T<:AbstractString}` or `((t::T) where {T}) -> …`. Each one used to
refuse every request. Read what it returns: from now on, any identity it returns admits the
request.

### Migrate your app

```julia
# A validator that USED TO refuse every request, and now admits valid tokens
lookup_user(token::T) where {T<:AbstractString} = find_user_by_token(token)
BearerAuth(lookup_user)

# ✓ if it was meant to admit, nothing to change -- it works now.

# ✓ if a route was protected only because the validator never ran, protect it on purpose
BearerAuth(lookup_user)                      # authenticates
GuardMiddleware(role_required("admin"))      # authorizes
```
