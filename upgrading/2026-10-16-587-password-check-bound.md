## `check_password` / `make_password` wait for a permit: at most `nthreads(:default) - 2` hash at once (#587)

- **Version**: 0.7.0
- **Nitro ref**: [#587](https://github.com/PingoLee/Nitro.jl/issues/587) ; `src/Auth/passwords.jl`
- **Recorded**: 2026-10-16
- **Severity**: **behavior change (availability default).** Under a burst of logins, the checks
  past the bound now wait their turn instead of all hashing at once.

### What changed

A password check computes for ~0.1 s (pbkdf2_sha256) to ~0.2 s (bcrypt) at the default cost and
never yields, so as many concurrent logins as there are default threads used to stall every
other request for the length of one hash. `check_password` and `make_password` now share one
process-wide bound, `password_concurrency()`, which defaults to
`max(Threads.nthreads(:default) - 2, 1)`. A call past it waits parked, which gives its thread back,
until a running hash finishes. The answers do not change, and neither does the cost of one hash.

What an app sees is the queue. During a burst of more concurrent logins than the bound, sign-ins
per second stay at what the bound can hash, the extra sign-ins wait longer, and every other
route keeps the threads the bound leaves free. At `-t 1` and `-t 2` the bound is 1, so logins
are hashed one at a time. The unknown-user path, `check_password(pw, nothing)`, waits in the same
queue as a known user. **A caller that holds a pooled database connection or a lock across
`check_password` now holds it for the whole wait**, not just the hash; during a burst that can
starve the pool for other routes. Look the user up, release the connection, then check.

### How to find the calls to migrate

Two call patterns. An app that wraps its checks in a `Base.Semaphore` of its own, which the
Passwords guide recommended before this change, now has two bounds in a row: the smaller one
wins, so it still works, and the app's own wrapper can go. And an app that wants every check to
hash at once, as before, sets the bound to `0`.

```bash
rg -n 'Semaphore|acquire\(' <app>/src | rg -i 'password|login|check'
rg -n 'check_password|make_password' <app>/src
```

### Migrate your app

```julia
# ✗ before — the app bounded the checks itself
const PASSWORD_CHECKS = Base.Semaphore(max(Threads.nthreads(:default) - 2, 1))
checked(pw, hash) = Base.acquire(() -> check_password(pw, hash), PASSWORD_CHECKS)

# ✓ after — Nitro bounds them; call check_password directly
check_password(pw, hash)

# ✓ to size the bound yourself, once at startup, at run time: in `main` or an `__init__`,
#   not a module body (0 = unbounded, the old behavior)
Nitro.Auth.set_password_concurrency!(4)
```
