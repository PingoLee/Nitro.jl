## `GuardMiddleware` — a guard result other than `nothing` or a response is a 500, not an admission (#519)

- **Version**: 0.6.0
- **Nitro ref**: [#519](https://github.com/PingoLee/Nitro.jl/issues/519) ; `src/middleware/guards.jl`
- **Recorded**: 2026-10-14
- **Severity**: **behavior change (auth).** The fix fails closed: a request that a malformed guard
  admitted is now a `500`, and its handler does not run.

### What changed

A guard is a `req -> Union{Nothing, HTTP.Response}`: `nothing` admits the request, a response
denies it. `GuardMiddleware` used to act only on the second half of that contract. It returned the
result when it was an `HTTP.Response` and ran the handler for **everything else**, so every one of
these "denials" admitted the request:

- `false`, from a predicate written as `req -> is_admin(req)`;
- a `Dict` meant to be serialized as the JSON error body;
- a status code `Int`, a message `String`, a `Symbol`, `missing`.

`GuardMiddleware` now refuses any result that is neither `nothing` nor an `HTTP.Response`. It throws
an `ArgumentError` naming the guard (its position and function name) and the result's **type**, never
its value. The server's error boundary answers that with a `500` and logs it. This is the rule
`_deny` already applied to the `denied` / `unauthorized` factories (#515), now applied to every
guard.

`true` is refused too. A guard reports a *denial*, not whether the caller is allowed, so a `Bool`
is malformed whichever way it points.

Unaffected:

- The shipped guards — `login_required`, `claim_required`, `role_required`,
  `permission_required`, `kid_required`. They already return `nothing` or a response.
- Custom guards that return `nothing` to admit and an `HTTP.Response` (including `Res.json(...)`,
  `Res.status(...)`) to deny.

### How to find the calls to migrate

List every `GuardMiddleware` call, including calls that span several lines:

```bash
grep -rn -A3 'GuardMiddleware(' --include=*.jl .
```

Every argument that is not a shipped guard (`login_required`, `claim_required`, `role_required`,
`permission_required`, `kid_required`) is a custom guard, wherever it sits in the list.
`GuardMiddleware(login_required(), only_admins)` has one. Read each custom guard and check every
return path, including the implicit last value of a function or lambda. Anything that is not
`nothing` or an `HTTP.Response` must change.

At run time, the error-log line to search for is below. It is logged only while the server logs
handler errors; with `serve(...; show_errors = false)` the client still gets the `500`, but
nothing is written.

```
GuardMiddleware: guard #
```

### Migrate your app

```julia
# ✗ before -- a predicate: `false` for a non-admin, and the request was ADMITTED
only_admins = req -> getuser(req)["role"] == "admin"

# ✗ before -- a Dict "denial": also ADMITTED
only_admins = req -> getuser(req)["role"] == "admin" ? nothing : Dict("error" => "forbidden")

# ✓ after -- `nothing` to admit, a response to deny
only_admins = req -> getuser(req)["role"] == "admin" ? nothing :
                     Res.json(Dict("error" => "forbidden"); status = 403)

# ✓ or the shipped guard, which also handles where the claims are read from
GuardMiddleware(role_required("admin"))
```
