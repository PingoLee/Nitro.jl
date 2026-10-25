# Reusable auth package

Two projects that show how authentication ships as its **own package**: login, logout and "who
am I" endpoints, plus the middleware a host puts in front of routes of its own. It builds on
[`reusable_package/`](../reusable_package/), which sets the shape: a `routes(...)` function that
returns route definitions, namespaced route names, keyword-only middleware factories, and state
and secrets passed in by the host.

| Project | Role |
|---------|------|
| [`AuthKit/`](AuthKit/) | The reusable package: issues bearer JWTs at `POST /login`, revokes them at `POST /logout`, answers `GET /me`, and ships `TokenAuth`, the middleware that accepts them |
| [`AuthHost/`](AuthHost/) | An application that mounts `AuthKit` under `/auth` and guards its own `/admin/report` with `TokenAuth` plus `role_required("admin")` |

## What the package does, and what it leaves to the host

| `AuthKit` | The host |
|-----------|----------|
| `routes(config; prefix, namespace)` **returns** the three auth routes. It never calls `urlpatterns` | Picks the prefix and registers them once, at boot |
| Takes the user lookup and the signing key in an `AuthConfig` | Owns the user table and reads the key from the environment in `main()` |
| Checks passwords with `Auth.check_password`, signs tokens with `Auth.encode_jwt` | Stores password hashes from `Auth.make_password`; AuthKit never sees a stored plain password |
| Ships `TokenAuth(; config)` as a keyword-only middleware factory | Decides which of its routes need a token, and which role, by stacking `GuardMiddleware(role_required(...))` after it |
| Keeps its handlers unexported | Never imports a handler |

Things the package gets right that are easy to get wrong:

- **An unknown username costs as much as a wrong password.** `check_password(password, nothing)`
  still hashes, so response timing does not reveal which accounts exist.
- **The role comes from the user table, not the token.** `TokenAuth` looks the account up on
  every request and puts its current claims at `getuser(req)`, a dict, so `role_required` reads
  the role as it is now. Demoting or deleting a user takes effect on their next request, not when
  their token expires. The token carries only `iss`, `sub`, `jti`, `iat` and `exp`.
- **Logout means something.** Each token has an id (`jti`), and logout revokes that id until the
  token would have expired. `Revocations()` keeps that list in memory, which is right for one
  process. Several processes behind a load balancer need it in a shared store.
- **The tokens name their issuer.** AuthKit stamps `iss` and requires it back, so a token some
  other component signed with the same key is refused. Still give AuthKit a key of its own.
- **The token response is `Cache-Control: no-store`**, so no cache keeps a copy of a credential.
- **Login is not rate-limited by the package.** A login checks a password hash, and hashing is
  bounded process-wide, so a flood of guesses also queues real logins. Put a `RateLimiter` in front
  of the login route, or in the host's global middleware list.
- **The config never prints its key.** `AuthConfig` has its own `show`, so a config that reaches
  a log line or an error page does not leak the signing key.

### Handing the host what the package resolved

A guard only authorizes. It answers "may this request continue?" and throws away what it looked
up on the way. So the host handler reads what the middleware resolved for itself:

```julia
function report(req::HTTP.Request, token::Claims{TokenClaims})
    user = getuser(req)                 # the account, as the user table holds it now
    return Res.json(Dict("requested_by" => user["username"], "token_subject" => token.payload.sub))
end
```

Half of that is already injected. `Claims{TokenClaims}` binds the **verified token** into a
struct before the handler runs, and answers `401`/`403` itself when it cannot. The **resolved
account** is not: `getuser(req)` is untyped, and nothing ties the handler to the middleware that
set it. A handler that reads only `getuser(req)`, on a route that forgot `TokenAuth`, gets
`nothing` at request time rather than an error at registration.

That gap is [#24](https://github.com/PingoLee/Nitro.jl/issues/24). With FastAPI-style
`Depends`, the package would export the dependency itself, and the handler would declare
`user::CurrentUser` the way it declares `token::Claims{TokenClaims}` today, with no separate
middleware to remember.

### The cookie variant

This package uses bearer tokens because an API or SPA client can attach a header itself, and a
browser never attaches one on a cross-site request's behalf, so the routes need no CSRF
protection. A server-rendered app
would carry the token in a cookie instead: `CookieAuthMiddleware` in place of `BearerAuth`,
`Auth.set_auth_cookie!`/`clear_auth_cookie!` in login and logout, and then CSRF protection
(`CSRFMiddleware` or `CrossOriginProtection`) on every state-changing route, because the browser
attaches cookies to cross-site requests too.

## Run it

From this directory, with Julia 1.13 or newer:

```bash
julia --project=AuthKit  -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia --project=AuthHost -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

AUTH_JWT_SECRET=$(openssl rand -hex 32) ADMIN_PASSWORD=change-me MEMBER_PASSWORD=change-me-too \
    julia --project=AuthHost -e 'using AuthHost; AuthHost.main()'
```

Then, in another shell:

```bash
TOKEN=$(curl -s -X POST localhost:8000/auth/login -H 'Content-Type: application/json' \
             -d '{"username": "alice", "password": "change-me"}' | jq -r .token)
curl localhost:8000/admin/report -H "Authorization: Bearer $TOKEN"
curl -X POST localhost:8000/auth/logout -H "Authorization: Bearer $TOKEN"
curl -i localhost:8000/admin/report -H "Authorization: Bearer $TOKEN"    # 401 now
```

`bob`, with `MEMBER_PASSWORD`, can sign in but gets `403` from `/admin/report`.

The tests use `internalrequest(app, …)` on a fresh `App`, so they bind no port and never touch
the `AuthHost.app` that `main()` serves. They hash with a low iteration count to stay fast; the
demo accounts use `make_password`'s default cost.

## Copying it out of this repository

Both `Project.toml` files point `[sources]` at this checkout (`Nitro = {path = "../../.."}`), so
the example always runs against the code next to it, and Nitro's own test suite instantiates and
tests both projects (`test/examples_tests.jl`). In a project of your own, install Nitro from its
repository pinned to a commit, as [`reusable_package/`](../reusable_package/README.md) shows.
