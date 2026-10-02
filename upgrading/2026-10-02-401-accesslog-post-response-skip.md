## `AccessLog` — `skip` runs after the handler as `skip(req, resp)`, records gain `matched` and bounded fields (#401)

- **Version**: Unreleased
- **Nitro ref**: [#401](https://github.com/PingoLee/Nitro.jl/issues/401) ;
  `src/middleware/access_log.jl`, `src/core/framework_middleware.jl`, `src/core/staticfiles.jl`
- **Recorded**: 2026-10-02
- **Severity**: **breaking** for every `AccessLog(sink; skip = …)` call, and for code that builds
  an `AccessRecord` positionally. **Behavior change** for sinks: long fields are now cut, and
  under a probe flood unmatched records are the ones dropped.

### What changed

The structured `AccessLog` could not keep scanner traffic out of the audit trail. `skip` was
`req -> Bool` and ran *before* the handler, so it could not see the status or tell whether any
route matched. On one production consumer about 88% of requests were 404 probes. Four changes
follow:

| | before | after |
|---|---|---|
| `skip` | `req -> Bool`, before the handler | `(req, resp) -> Bool`, after it. `resp` is `nothing` when the handler threw |
| `AccessRecord` | 9 fields | a 10th, `matched::Bool`, after `status`: `false` only when the router found no route |
| `method`, `path`, `query`, `user_agent` | the full client-sent value (up to 64 KiB each) | cut to `max_field_bytes` (default 2048), marker included, ending in `"…[truncated]"` |
| buffer full | the newest record dropped, matched or not | unmatched records may hold at most `unmatched_capacity` (default `capacity ÷ 10`) slots, so a probe flood cannot evict matched records |

`matched` is `!route_missed(req)`. The new exported predicate `route_missed` is `true` only where
Nitro answered "no route here": the router's 404/405, a static mount's miss, the 404 outside
`serve(prefix = …)`, and the 400 for a request-target no route could match (`/../x`, `//x`). A route that returns 404 itself is matched, and so is a request a guard or
middleware refused on a real route. A denied login is therefore never budgeted or filtered as a
probe.

A one-argument `skip` is now an `ArgumentError` when `AccessLog` is constructed, rather than a
`MethodError` warned about on every request.

There is also something new, with nothing to migrate: `serve(...; access_log_skip = (req, resp) -> Bool)`
gives the console access log the same hook. It had none.

### How to find the calls to migrate

```bash
grep -rn 'AccessLog(' --include=*.jl .          # then check each for `skip`
grep -rn 'AccessRecord(' --include=*.jl .       # positional constructors (test fixtures, fakes)
```

### Migrate your app

Add the response argument to `skip`. A hook that only looked at the request ignores it:

```julia
# ✗ before
AccessLog(sink; skip = req -> startswith(req.target, "/static/"))
# ✓ after
AccessLog(sink; skip = (req, resp) -> startswith(req.target, "/static/"))
```

To keep scanner probes out of the sink, which is what the change is for:

```julia
# ✓ drop requests the router found no route for
AccessLog(sink; skip = (req, resp) -> route_missed(req))
```

`route_missed` can only report a lookup that happened. A probe that a global middleware listed
after `AccessLog` refuses *before* the router runs, such as an app-wide `BearerAuth`, counts as
matched. So does every GET under an SPA history-mode fallback (`spafiles`), which answers with
the app shell. Filter those on `resp.status` or the path.

A positional `AccessRecord(...)` takes `matched` after `status`:

```julia
# ✗ before
AccessRecord(ts, "GET", "/x", nothing, 200, 3, ip, ua, ctx)
# ✓ after
AccessRecord(ts, "GET", "/x", nothing, 200, true, 3, ip, ua, ctx)
```

A sink whose columns are narrower than 2048 bytes can now rely on the cut. Pass a smaller
`max_field_bytes` to match the column instead of truncating in the sink. A sink that stored full
paths for forensics should raise it, since the default is a deliberate bound and not a limit
HTTP imposes.
