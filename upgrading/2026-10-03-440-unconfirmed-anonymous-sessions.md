## `SessionMiddleware` — a new anonymous session lives `unconfirmed_max_age` until its cookie comes back (#440)

- **Version**: Unreleased
- **Nitro ref**: [#440](https://github.com/PingoLee/Nitro.jl/issues/440) ;
  `src/middleware/session_middleware.jl`, `src/types.jl`, `ext/NitroPormGExt.jl`
- **Recorded**: 2026-10-03
- **Severity**: **behavior change.** No call stops compiling. A new session that ends its first
  request with no signed-in identity is now stored, and its cookie set, for `unconfirmed_max_age`
  rather than `max_age`: one hour by default, less when the full lifetime is under two hours. It
  gets the full `max_age` the first time the browser sends the cookie back.

### What changed

Any route that writes to a visitor's session before sign-in (a cart, a locale choice, a flash
message, a CSRF token from `csrf_token!`) stored a session live for the whole `max_age` (24 h)
for every cookieless request. A script calling such a route without cookies grew a database
session store faster than the pruning janitor could reclaim it.

| Session | Before | After |
|---|---|---|
| New, ends its first request **anonymous** | stored for `max_age`, cookie `Max-Age = max_age` | stored for `unconfirmed_max_age` (default 1 h), cookie to match |
| That session's first request back, with the cookie | read, no write | one write: full `max_age`, cookie re-set (the response is `Cache-Control: private`, like any response setting the session cookie) |
| New, ends its first request **signed in** (a cookieless login) | `max_age` | `max_age` (unchanged) |
| Left by a logout (emptied and rotated) | `max_age` | `max_age` (unchanged) |
| Existing, confirmed | unchanged | unchanged |

`unconfirmed_max_age` defaults to one hour. When
`min(max_age, absolute_max_age)` is under two hours, the default is half of it, and under two
minutes the feature is off. An explicit value must be positive and at most half that lifetime, or
`SessionMiddleware` throws an `ArgumentError` when it is built. `nothing` restores the old
behavior.

Two additions need no migration: `pormg_nitro_session(max_sessions = N)` bounds a database store
(off by default), and `session_store_full(store)` is a new optional `AbstractSessionStore` method
that defaults to `false`. Before turning the bound on, note what a full store costs: a visitor with
no cookie cannot sign in through a form whose CSRF token is bound to the session until the store
has room again. See *Anonymous Sessions and Floods* in `docs/src/tutorial/cookies/sessions.md`.

### How to find the calls to migrate

```bash
# every app that uses server-side sessions
grep -rn 'SessionMiddleware(' --include=*.jl .
# tests that check the first response's cookie lifetime, or a new session's stored expiry
grep -rn 'Max-Age' --include=*.jl test/
grep -rn '\.expires' --include=*.jl test/
```

Most apps need no change: a browser usually sends the cookie back within seconds, on its next page
or asset, and the session is confirmed (if the assets are served outside `SessionMiddleware`, the
next page does it). Check three cases:

- **A client that makes one session-writing request and comes back more than an hour later.** An
  API client that writes an anonymous session and polls rarely, or a page that writes the session
  and loads nothing else. It now finds a fresh session. Either keep the old behavior, or have the
  client make any request with its cookie in between.
- **Tests that assert the first response's `Max-Age`, or a new session's stored expiry,** against
  `max_age`. Those now see `unconfirmed_max_age` unless the session ends signed in.
- **A custom `AbstractSessionStore`.** An unconfirmed session is recognised by its stored lifetime,
  `expires - created`, so `Base.get` must return a `SessionPayload` whose two instants come from the
  same clock. A store returning bare data never confirms, so every anonymous session lapses at
  `unconfirmed_max_age`; `SessionMiddleware` warns once. Pass `unconfirmed_max_age = nothing` to
  such a store's middleware.

### Migrate your app

```julia
# ✗ before: implicitly, every new session lived max_age from its first write
SessionMiddleware(store = store, max_age = 86400)

# ✓ after: the default -- anonymous sessions are unconfirmed for 1 h, then max_age
SessionMiddleware(store = store, max_age = 86400)

# ✓ after: keep the old behavior
SessionMiddleware(store = store, max_age = 86400, unconfirmed_max_age = nothing)
```

A test that asserted a new anonymous session's lifetime:

```julia
# ✗ before
@test occursin("Max-Age=86400", HTTP.header(first_response, "Set-Cookie"))

# ✓ after: either assert the unconfirmed lifetime...
@test occursin("Max-Age=3600", HTTP.header(first_response, "Set-Cookie"))
# ...or build the middleware with `unconfirmed_max_age = nothing` if the test is about something else
```
