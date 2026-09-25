## Request targets — the path global middleware reads is in one canonical percent-encoding (#351)

- **Version**: Unreleased
- **Nitro ref**: [#351](https://github.com/PingoLee/Nitro.jl/issues/351) ;
  `src/core/framework_middleware.jl`, `src/utilities/fileutil.jl`, `src/core/registration.jl`
- **Recorded**: 2026-09-25
- **Severity**: **behavior change.** It affects global middleware that compares `req.target`
  against a percent-encoded string, clients that send a dot segment, and routes or prefixes
  written with lowercase or unnecessary escapes. Every app is covered.

### What changed

A static, SPA or dynamic mount, and a `{var}` path parameter, percent-decode the path **after**
global middleware has run. So a gate testing `startswith(req.target, "/files/private/")` saw one
spelling while the mount served another, and every spelling below got through to the protected
file:

| Request path | Before | After |
|---|---|---|
| `/files/%70rivate/secret.txt` | `200`, served `private/secret.txt` | gate sees `/files/private/secret.txt` |
| `/files/priv%61te/secret.txt` | `200` | gate sees `/files/private/secret.txt` |
| `/files/caf%c3%a9/s.txt`, `/files/café/s.txt` | `200`, gate on `/files/caf%C3%A9/` missed | gate sees `/files/caf%C3%A9/s.txt` |
| `/%66iles/private/secret.txt` | `404` | gate sees `/files/private/secret.txt` |
| `/%61dmin/users` | `404` | routed to `/admin/users`, so gated like it |
| `/files/./x`, `/a/../b`, `/a/%2E%2E/b` | `404` | `400`, before any middleware |
| `/files/%ZZ` | `400` from the mount | the same JSON `400`, before any middleware |
| `/a%23b` or `/a#b` in the path | `#` cut the mount's lookup | kept, as `%23`, like the router always did |

Every path segment is now put in canonical form before the prefix strip and before any of your
middleware, by the same layer that refuses `//` (#341):

- **An escape of a character that may stand unencoded in a path is decoded.** That is letters,
  digits, `-._~`, the sub-delims `!$&'()*+,;=`, and `:` and `@`.
- **Every other byte is written as an uppercase escape**, whether it arrived escaped or raw:
  `%c3%a9` and a raw `é` both become `%C3%A9`, and `%2f` becomes `%2F`. An encoded `/` stays
  encoded, so it never splits a segment.
- **A dot segment is refused with `400`**, raw or encoded. Clients resolve them before sending.
- The query string is left as the client sent it.

Decoding the canonical path gives exactly the bytes decoding the original gave, so no handler
and no mount sees a different value. Only the spelling in `req.target` changes, and every
spelling of one path now reaches middleware as the same string. The one exception is stricter,
not looser: HTTP.jl's decoder tolerated whitespace inside an escape (`%A `), and that is now a
malformed escape and a `400`. With `catch_errors = false`, a malformed escape now throws out of
the pipeline on any path, where before it threw only on a path a mount or a `{var}` route read.

Values you author are canonicalized the same way, so they keep matching:
- a route in `path()`: `path("/a%7eb", …)` registers `/a~b`;
- a `staticfiles`/`spafiles`/`dynamicfiles` prefix: `"caf%c3%a9"` becomes `"caf%C3%A9"`;
- `serve(prefix = …)`.

A route segment that could not be reached this way is now an `ArgumentError` at registration:
a malformed escape, a `.` or `..`, or an escape that decodes to one or to `*`. So is such a
mount or `serve` prefix.

### How to find the calls to migrate

A literal your own middleware compares against `req.target` is **not** rewritten. Neither are
the `Cors(paths = …)` list and the rate limiter's exempt paths. If one of them holds a lowercase
escape, or an escape of a character that needs none, it no longer matches:

```bash
# middleware reading the target
grep -rn 'req.target' --include=*.jl .
# every escape in your source: rewrite one with lowercase hex, or one of a character from
# the decoded list above (`%7E` is `~`, `%41` is `A`, `%21` is `!`)
grep -rnE '%[0-9A-Fa-f]{2}' --include=*.jl .
# clients, proxies and tests that send a dot segment
grep -rnE '"[^"]*/\.\.?(/|"|\?)' --include=*.jl .
```

The entry for #341 said to gate a mount's root rather than a directory inside it. That advice is
no longer needed: a gate on a directory inside a mount holds now.

### Migrate your app

```julia
# ✗ before: matched only clients that sent lowercase hex; now it matches nothing
denied(req) = startswith(req.target, "/files/caf%c3%a9/")
# ✓ after: write the prefix you test in canonical form -- uppercase escapes, and
#   unencoded wherever a character may stand unencoded
denied(req) = startswith(req.target, "/files/caf%C3%A9/")

# ✗ before: decoding the target yourself so an encoded spelling could not slip past
#   (still correct, but no longer needed)
denied(req) = startswith(HTTP.unescapeuri(req.target), "/files/private/")
# ✓ after: every spelling of `/files/private/` already arrives as that string
denied(req) = startswith(req.target, "/files/private/")
```
