## `serve(prefix = …)` matches whole path segments, and a malformed prefix is refused (#315)

- **Version**: Unreleased
- **Nitro ref**: [#315](https://github.com/PingoLee/Nitro.jl/issues/315) ;
  `src/core/framework_middleware.jl`, `src/core/lifecycle.jl`
- **Recorded**: 2026-09-24
- **Severity**: **behavior change.** It affects every app that calls `serve` with a `prefix`. An
  app with no prefix is unaffected.

### What changed

The global prefix was stripped with a bare `startswith`, with no `/` boundary. With
`prefix = "/api"`, a request for `/apiadmin/users` was rewritten to `admin/users` and served by
`/admin/users`. Any control keyed on the URL rather than on the matched route was bypassed: a
global gate testing `startswith(req.target, "/admin")`, or a proxy rule that denies `/api/admin/`.
Four more defects came with it:

- A trailing-slash prefix (`"/api/"`) cut the leading `/` off every target it rewrote, so global
  middleware saw `users/42` instead of `/users/42`.
- A non-ASCII prefix was sliced by characters where bytes were meant. It never matched a client
  that percent-encodes (a `404`), and a raw UTF-8 target under it was cut mid-character (a `500`).
- Any prefix that was not a `String`, a `SubString` for instance, was dropped silently, so every
  route was served unprefixed.
- `""` and `"/"` were accepted and stripped nothing.

The prefix now covers whole path segments:

| Request, with `prefix = "/api"` | Before | After |
|---|---|---|
| `/api/users` | `/users` | `/users` |
| `/api` | `/` | `/` |
| `/api?x=1` | `?x=1` | `/?x=1` |
| `/apiadmin/users` | `admin/users`, served by `/admin/users` | `404` |

Everything outside the prefix is still a `404` before any of your middleware runs, and the target
global middleware sees always keeps its leading `/`. Trailing slashes on the prefix are dropped,
so `"/api/"` behaves as `"/api"`. Any `AbstractString` is accepted.

This closes the prefix's own route past a URL check. The other routes past one, `//admin/users`
and absolute-form targets, are closed with or without a prefix by the #341 entry.

`serve` now validates the prefix before it changes anything, and raises `ArgumentError` for a
shape that could never match a well-formed request-target:

- `""` and `"/"`: pass `nothing` for no prefix;
- no leading `/`;
- non-ASCII: write it percent-encoded, as clients send it (`"/caf%C3%A9"`). Escapes are matched
  byte for byte, so use uppercase hex, as clients do;
- `?`, `#`, whitespace (a trailing newline included), a bad `%` escape, an empty segment inside
  the path (`/a//b`), or a `.` or `..` segment;
- a value that is not a string or `nothing`.

### How to find the calls to migrate

List every `prefix =` keyword. Skip the hits that are not `serve(` calls, such as a routes
function's own `prefix` keyword:

```bash
grep -rnE '\bprefix *=' --include=*.jl .
```

A prefix of the form `"/segment"` or `"/a/b"` needs no edit. A prefix that `serve` now refuses
fails at startup with an `ArgumentError` naming the value, so nothing reaches production
half-configured.

Also check global middleware that reads `req.target` under a **trailing-slash** prefix. It used to
see the target without its leading `/`:

```bash
grep -rn 'req.target' --include=*.jl .
```

### Migrate your app

```julia
# ✗ before — accepted, and every request answered 404
serve(prefix = "api")
# ✓ after
serve(prefix = "/api")

# ✗ before — accepted, and stripped nothing
serve(prefix = "/")
# ✓ after
serve()                       # or serve(prefix = nothing)

# ✗ before — with prefix = "/api/", this saw "users/42"
gate = handle -> req -> startswith(req.target, "users") ? HTTP.Response(403) : handle(req)
# ✓ after — the rewritten target always keeps its leading '/'
gate = handle -> req -> startswith(req.target, "/users") ? HTTP.Response(403) : handle(req)
```

A `SubString` prefix used to be ignored, and now it is honored. If you passed one, your routes
move under it: check that clients already call the prefixed URLs.
