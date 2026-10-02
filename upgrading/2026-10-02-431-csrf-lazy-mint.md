## `CSRFMiddleware` — a new visitor gets a token only when a handler asks for it with `csrf_token!` (#431)

- **Version**: Unreleased
- **Nitro ref**: [#431](https://github.com/PingoLee/Nitro.jl/issues/431) ;
  `src/middleware/csrf_middleware.jl`
- **Recorded**: 2026-10-02
- **Severity**: **behavior change.** No call stops compiling. A first visit that nothing else
  gives a session no longer receives a CSRF cookie, so a page or SPA that relied on that cookie
  appearing by itself gets `403` on its first mutation until it asks for the token.

### What changed

`CSRFMiddleware` used to issue a token on **every** safe response, and to keep the session that
token is bound to. Behind a global `CSRFMiddleware`, every cookieless `GET` (health checks,
bearer-token API clients, uptime probes, scanners) therefore stored a session and got a
`Set-Cookie`. That undid #317, and with a database session store it meant one INSERT per request
and unbounded table growth.

A token is now issued only when the client will use it:

| Request | Before | After |
|---|---|---|
| Cookieless `GET`, handler never asks for the token | CSRF cookie + session cookie, session stored | nothing: no cookie, no session |
| Handler calls `csrf_token!(req)` (new) | — | token returned to the handler, cookie set, session stored |
| Visitor already has a session, no valid CSRF cookie | token issued | token issued (unchanged) |
| New visitor whose session the request writes to or rotates | token issued | token issued (unchanged) |
| Refused unsafe request from a client echoing its own stale token | fresh token with the `403` | unchanged |

`csrf_token!(req)` is new and exported from `Nitro`. It returns the raw token (the value the
client echoes in `X-CSRF-Token` or `_csrf`), and the middleware sets the matching cookie on the
response. A client that already holds a valid token gets that one back, with its cookie re-sent
so its `ttl` starts again. A handler that rotates the session must call it **after**
`regenerate_session!`: rotation retires the client's earlier token, as it always did. Because it runs inside
the handler, a server-rendered form can now embed the token on the **first** visit. Before, the
token was minted only after the handler had returned, so `req.context[:csrf_token]` was `nothing`
on that visit.

`req.context[:csrf_token]` is still set before the handler: the client's verified token, or
`nothing`. It is now also set on an unsafe request that passed the check.

### How to find the calls to migrate

```bash
# apps that use CSRF at all
grep -rn 'CSRFMiddleware(' --include=*.jl .
# handlers that read the token from the context -- on a first visit this stays `nothing`
grep -rn ':csrf_token' --include=*.jl .
# front-end code that waits for the cookie to appear by itself
grep -rn 'csrf_token' --include=*.js --include=*.ts --include=*.vue --include=*.jsx --include=*.tsx .
# tests that expect a token from a plain GET
grep -rn 'csrf_token=' --include=*.jl test/
```

A page that renders a form, and every SPA, has to ask for the token. Anything that only reads or
writes data with a token it already holds needs no change.

### Migrate your app

A server-rendered form: call `csrf_token!` where the form is built.

```julia
# ✗ before: the token was minted after this handler ran, so on a first visit it was `nothing`
#           and the form relied on the cookie alone
login_form(req::HTTP.Request) = Res.html("""
    <form method="post"><input type="hidden" name="_csrf" value="$(something(req.context[:csrf_token], ""))">…</form>""")

# ✓ after: the token exists as soon as the handler asks for it
login_form(req::HTTP.Request) = Res.html("""
    <form method="post"><input type="hidden" name="_csrf" value="$(csrf_token!(req))">…</form>""")
```

A single-page app: its shell is served by `spafiles` or the proxy, where no handler runs, so add
an endpoint. Fetch it at startup, again after a login or logout, and on a `403` from a mutation
(then retry once): the cookie expires `ttl` seconds after the last fetch.

```julia
# ✗ before: nothing; the app read the cookie the shell's GET happened to receive

# ✓ after
csrf(req::HTTP.Request) = Res.json(Dict("token" => csrf_token!(req)))
urlpatterns("", path("/api/csrf", csrf, method="GET"))
```

```javascript
// ✓ after: once at boot, then send it on every mutation
const { token } = await (await fetch("/api/csrf", { credentials: "same-origin" })).json();
fetch("/api/products", { method: "POST", credentials: "same-origin",
                         headers: { "X-CSRF-Token": token }, body: "…" });
```

Tests that took a token from a plain `GET` response now point that `GET` at a handler calling
`csrf_token!(req)`.

See *When a token is issued* in `docs/src/tutorial/sessions_and_auth.md`.
