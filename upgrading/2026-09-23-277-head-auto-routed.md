## `path(...; method="GET")` — every `GET` route now also answers `HEAD`

- **Version**: Unreleased
- **Nitro ref**: [#277](https://github.com/PingoLee/Nitro.jl/issues/277) ; `src/core/registration.jl`, `src/routerhof.jl`, `src/types.jl`
- **Recorded**: 2026-09-23
- **Severity**: behavior change. A `HEAD` request to a `GET`-only route used to get a `405`, and now
  runs the `GET` handler and gets its status and headers with no body. A route with an explicit
  `HEAD` keeps it. One edge case moves: a `method="*"` route or a static mount registered at
  the same path *after* a `GET` route used to receive that path's `HEAD`, and the `GET` route
  now does.

### What changed

`HEAD` was not routed at all unless a route declared it, so `curl -I`, uptime checkers and link
previewers got a `405` from ordinary `GET` routes. Under a root `spafiles(dir, "")` it was worse:
the `HEAD` fell through to the mount and got the app shell's headers while its `GET` returned JSON.

Now registering a `GET` route also registers `HEAD` for it, the way Django, Express and Go's
`net/http` do (RFC 9110 §9.3.2):

| Request | Before | After |
|---|---|---|
| `HEAD` to a `GET`-only route | `405` (or the SPA shell under a root `spafiles`) | the `GET` handler runs; its status and headers, no body |
| `HEAD` where an explicit `HEAD` route exists | the explicit handler | unchanged; it wins in either registration order |
| `path(...; methods=["GET", "HEAD"])` | one handler for both | unchanged |
| `HEAD` to a `GET` route with `middleware=[...]` | `405` | the `GET` route's middleware and guards run, then its handler |
| `HEAD` to a `STREAM` or `WEBSOCKET` route | `405` | unchanged |
| `HEAD` where a `method="*"` route or mount was registered after the `GET` at the same path | the `"*"` handler | the `GET` handler |

The handler receives the `HEAD` request as-is (`req.method == "HEAD"`), and the server drops the
body on the way out. A streamed body is closed without being read.

**What can need an edit:** a `GET` handler whose work is not safe to repeat for `HEAD`. Examples
are a view counter, a "mark as read", a paid external call, or a report built on every request.
RFC 9110 already requires `GET` to be safe, so a handler like that was already wrong for crawlers
and prefetchers. Clients that send `HEAD` (monitors, link unfurlers, `curl -I`) now reach it too.

### How to find the calls to migrate

```bash
# Every route that now answers HEAD: explicit `method="GET"`, and `path(...)` with no method at all.
grep -rnE 'path\(' --include=*.jl . | grep -vE 'method(s)? *='
grep -rnE 'method *= *"GET"' --include=*.jl .
# Of those, review the handlers that write or count something.
```

Most routes need nothing. Only a handler with a side effect or an expensive body needs a look.

### Migrate your app

Either let the handler skip the work on `HEAD`:

```julia
# ✗ before — every HEAD from a link unfurler now counts as a view
function show_article(req, id::Int)
    record_view!(id)
    return Res.json(load_article(id))
end

# ✓ after — HEAD gets the same headers without the side effect
function show_article(req, id::Int)
    req.method == "HEAD" || record_view!(id)
    return Res.json(load_article(id))
end
```

or declare a cheaper `HEAD` route, which wins over the automatic one:

```julia
path("/api/articles/<int:id>", ArticleHandlers.show_article)
path("/api/articles/<int:id>", ArticleHandlers.article_exists; method="HEAD")
```

An app that relied on the `405` to refuse `HEAD` can restore it per route with an explicit `HEAD`
route returning `Res.status(405)`.
