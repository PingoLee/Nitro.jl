## `SessionMiddleware` — a new session is saved only when something uses it, and `MemoryStore` is bounded (#317)

- **Version**: Unreleased
- **Nitro ref**: [#317](https://github.com/PingoLee/Nitro.jl/issues/317) ;
  `src/middleware/session_middleware.jl`, `src/middleware/csrf_middleware.jl`, `src/types.jl`
- **Recorded**: 2026-09-25
- **Severity**: **behavior change.** It affects apps that expect a session cookie on a visitor's
  first response, code that binds its own data to `req.context[:session_id]`, and deployments
  holding more than 100 000 live sessions in one `MemoryStore`.

### What changed

A request without a valid session cookie used to get a fresh session **saved for `max_age`
(24 h by default) and a `Set-Cookie`, whether or not anything touched it.** `MemoryStore` was an
unbounded `Dict`. So a loop of cookieless `GET /health` calls grew memory without limit, about
16 GiB a day at 1k req/s. With `PormGSessionStore` it cost a SELECT and an INSERT per request, and
each row lived 24 h. The cookie also rode on cacheable responses: a static file served
`public, max-age=31536000, immutable` carried `Set-Cookie: nitro_session=<fresh id>` with no
`private` and no `Vary: Cookie`. A shared cache that stored it handed one anonymous session, and
its CSRF binding, to every visitor.

Three changes:

1. **A new session is saved lazily.** This is Django's `modified` flag, and express-session's
   `saveUninitialized: false`. A new session is saved, and its cookie set, only when one of these
   holds at the end of the request:
   - the handler left data in `getsession(req)`;
   - its id was rotated (`regenerate_session!`);
   - `req.context[:session_modified]` is `true`.

   `CSRFMiddleware` sets that flag whenever it issues a token bound to the session, so a visitor
   who is not logged in keeps a working CSRF token. Otherwise nothing is stored and no cookie is
   sent. `req.context[:session_id]` is still populated for the length of the request. The flag
   also forces an existing session to be written back, which refreshes its expiry. Existing
   sessions are otherwise unchanged: written back only when their data changed.

2. **`MemoryStore` is an LRU capped at `max_sessions = 100_000`.** At capacity it evicts the least
   recently used session and logs one warning per store. `MemoryStore(; max_sessions = N)` sets
   the cap. It is still a development or single-process store; use `pormg_nitro_session()` in
   production.

3. **A response that sets the session cookie is marked private.** `Vary: Cookie` is added, and
   `Cache-Control` gains `private`. A `public` directive is replaced, and every other directive is
   kept. A response already `private` or `no-store` is left alone.

A route behind a **global** `CSRFMiddleware` still saves one session per visitor without a cookie,
because CSRF issues every such visitor a token bound to one. Scope `CSRFMiddleware` to the routes
that serve forms or the SPA, rather than to health checks and static files. The `MemoryStore` cap
is the backstop.

### How to find the calls to migrate

Code that binds its own state to the session id, rather than to session data:

```bash
# `:session_id` catches `req.context[:session_id]` and `get(req.context, :session_id, …)` alike
grep -rnE ':session_id|issue_csrf_token!' --include=*.jl .
```

Tests that expect a session cookie on a first response whose handler never writes to the session.
Header names are matched case-insensitively, because tests spell them every way:

```bash
grep -rniE 'set-cookie' --include=*.jl test/
```

`MemoryStore`s that may hold more than 100 000 live sessions:

```bash
# `.*` rather than `[^}]*`: `MemoryStore{String, Dict{String,Any}}()` nests braces
grep -rnE 'MemoryStore(\{.*\})?\(' --include=*.jl .
```

### Migrate your app

Code that hands a client something bound to `req.context[:session_id]` must make sure the session
is kept. `CSRFMiddleware` already does this for the tokens it issues, and for a CSRF cookie a
handler sets under its `cookie_name`. The case left is a token minted by hand with no
`CSRFMiddleware` in the chain, or any other value bound to the id.

```julia
# ✗ before — a token minted by hand for a brand-new visitor; the session was saved anyway
function form(req)
    res = Res.json(Dict("ok" => true))
    issue_csrf_token!(res, SECRET; binding = req.context[:session_id])
    return res
end

# ✓ after — mark the session modified so it is saved and its cookie set
function form(req)
    res = Res.json(Dict("ok" => true))
    issue_csrf_token!(res, SECRET; binding = req.context[:session_id])
    req.context[:session_modified] = true
    return res
end
```

A test that asserted a session cookie on a read-only first request should write to the session, or
assert that no cookie is set:

```julia
# ✗ before
res = mw(req -> HTTP.Response(200, "ok"))(HTTP.Request("GET", "/"))
@test occursin("nitro_session=", HTTP.header(res, "Set-Cookie"))

# ✓ after
res = mw(req -> HTTP.Response(200, "ok"))(HTTP.Request("GET", "/"))
@test !HTTP.hasheader(res, "Set-Cookie")
```

A `MemoryStore` that must hold more live sessions:

```julia
# ✗ before
store = MemoryStore()

# ✓ after
store = MemoryStore(max_sessions = 500_000)
```
