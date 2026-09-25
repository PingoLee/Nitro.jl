## `AccessLog` — records carry no query string and no URL credentials by default (#320)

- **Version**: Unreleased
- **Nitro ref**: [#320](https://github.com/PingoLee/Nitro.jl/issues/320) ;
  `src/middleware/access_log.jl`, `src/utilities/misc.jl`, `src/core/framework_middleware.jl`
- **Recorded**: 2026-09-24
- **Severity**: **behavior change.** It affects every app whose `AccessLog` sink reads
  `record.query`. A sink that ignores `query` needs no edit.

### What changed

The structured `AccessLog` middleware put the raw query string in `record.query` and a
prefix-sliced target in `record.path`. An app that persists records therefore wrote
password-reset and magic-link tokens, OAuth `code`s and signed-URL signatures into its access-log
table. For an absolute-form request (`GET http://alice:pa55w0rd@host/x`), `path` also kept the
authority and its credentials. The console access log (`serve(access_log = true)`) has redacted
both by default since #39. The structured log now does the same.

| Request target | `record.path` before | after | `record.query` before | after |
|---|---|---|---|---|
| `/reset?token=S3CRET` | `/reset` | `/reset` | `"token=S3CRET"` | `nothing` |
| `http://alice:pa55w0rd@h/x?k=1` | `http://alice:pa55w0rd@h/x` | `/x` | `"k=1"` | `nothing` |
| `//bob:pw@evil/y` | `//bob:pw@evil/y` | `/y` | `nothing` | `nothing` |
| `/f#frag?k=1` | `/f#frag` | `/f` | `"k=1"` | `nothing` |

`record.query` is now `nothing` unless you pass the new `AccessLog(sink; log_query = true)`. This
mirrors `serve(...; access_log_query = true)`. With it, `query` is the raw query up to any `#`,
and `path` is still reduced, so credentials in a well-formed authority never reach the sink in
either mode. A target with no usable path (authority-form `CONNECT h:443`) records `"-"`, and
`OPTIONS *` records `"*"`, as the console log does.

The console line changed too, with nothing to migrate. Its request target is now escaped: C1
controls, invalid UTF-8 and Unicode line/bidi characters appear as `\u…`/`\x…` escapes, and `"`
and `\` are backslash-escaped (`\"`, `\\`), so a request cannot forge a log line. A log parser
that matched any of those characters raw, a backslash included, will see the escaped form.

### How to find the calls to migrate

Find every `AccessLog` constructor, then check whether its sink reads `query`:

```bash
grep -rn 'AccessLog(' --include=*.jl .
grep -rnE '\.query\b' --include=*.jl .
```

A sink that stores `r.query` keeps working, but from now on writes `NULL`/`missing` there. A
sink or report that parsed the scheme or host out of `r.path` now receives only a path, or the
placeholders `"-"` and `"*"`.

### Migrate your app

Usually the right migration is none: an empty `query` column is the point of the change. Opt back
in only after checking that no secret travels in your URLs:

```julia
# ✗ before — the query (tokens included) was recorded implicitly
serve(middleware = [AccessLog(sink)])
# ✓ after — record it explicitly, for a service whose URLs carry no secrets
serve(middleware = [AccessLog(sink; log_query = true)])
```

If you need one non-secret parameter, such as a page number, record just that from `annotate`
rather than opting into the whole query:

```julia
annotate = req -> Dict{Symbol, Any}(:page => get(getquery(req), "page", nothing))
serve(middleware = [AccessLog(sink; annotate)])
```
