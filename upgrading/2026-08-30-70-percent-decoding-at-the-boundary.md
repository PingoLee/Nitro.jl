## Percent-decoding now happens once, at the boundary — query, `Path{T}`, and cookie values change (#70)

- **Version**: 0.3.0
- **Nitro ref**: #70; `src/types.jl`, `src/core.jl`, `src/utilities/misc.jl`, `src/extractors.jl`,
  `ext/TimeZonesExt.jl`
- **Recorded**: 2026-08-30
- **Severity**: **behavior (parameter values reaching handlers)** — bug fix. Three separate value
  changes; an app that compensated for any of them by hand will now double-correct.

### What changed

Percent-decoding is now performed **exactly once**, in the `Types.*` accessor that turns the raw
request into a map. `parseparam`, `parsetype`, and `struct_builder` are pure type conversion and
never unescape. Previously the `parseparam` family carried an `escape=true` keyword — the
*converter* decided — and that one default was correct for path params and wrong for query params.

Three defects followed from it, all fixed together:

- **Query values were decoded twice.** `HTTP.queryparams` decodes, then `parseparam` decoded again.
  `?q=100%25%20off` reached the handler mangled instead of as `100% off`; `%252B` collapsed to a
  literal `+`. Silent — no error, just a wrong string.
- **`Path{T}` was never decoded at all.** It binds through `struct_builder`/`parsetype`, which do
  not unescape, so `GET /files/a%2Fb` reached the struct field as the literal `a%2Fb` while the
  scalar form of the same parameter correctly yielded `a/b`. The two binding paths disagreed.
- **`Cookie{T}` values were decoded on read but never encoded on write.** `set_cookie!` validates
  octets (`_validate_cookie_value`) rather than percent-encoding, and `%` is a legal cookie octet,
  so a cookie written as `a%2Bb` was read back as `a+b`.

Scalar path parameters are **unchanged** — they were already decoded exactly once; the decode
simply moved from `parseparam` up to `Types.pathparams`.

Two further changes to **malformed** input, one a fix and one a genuinely new restriction:

- **A malformed escape is now a clean `400` (fix).** `HTTP.unescapeuri` throws on `%ZZ` or a
  trailing `%`, and `HTTP.queryparams` throws the same way. `?q=%ZZ` previously returned `500`
  with a logged backtrace — that path was unguarded before this change too — and moving the path
  decode to the accessor would have put it outside the guard as well. Both accessors now raise
  `ValidationError`, so both are a `400` and neither logs a stack trace per request.
- **A value decoding to invalid UTF-8 is now rejected with `400` (new restriction).**
  `unescapeuri("%80")` does not throw; it returns an invalid `String`. Nothing downstream
  rejected it either, so `GET /f/caf%E9` and `?q=%FF` **used to return `200`** — with the bad
  byte reaching your handler and, through `Res.json`, the response body. Nitro now refuses the
  request instead of emitting an invalid-UTF-8 body. If you accept Latin-1 or other non-UTF-8
  encoded parameters, percent-encode them as UTF-8 client-side, or read the raw value from
  `req.target` yourself.

Also: `HTTP.queryparams(::HTTP.Request)` — which Nitro re-exports — now raises `ValidationError`
for a malformed query string where it previously raised `ArgumentError`/`EOFError`. A `catch`
block matching on those specific types needs updating.

The `escape` keyword is **removed**, not re-defaulted, so no call site can opt back into a second
decode. `parseparam` is not part of Nitro's public export surface (it is exported from the internal
`Util` module only), so this signature change is source-visible only to code reaching into
`Nitro.Core.Util` — or defining its own `parseparam` method, as `ext/TimeZonesExt.jl` does.

### How to find the calls to migrate

```bash
# 1. Any method or call passing the removed keyword — including in your own extensions.
grep -rn "parseparam" --include=*.jl . | grep "escape"

# 2. Hand-rolled workarounds for the old double decode: a re-encode before reading a query
#    value, or a decode/encode wrapped around a cookie read. These now over-correct.
grep -rnE "escapeuri|unescapeuri" --include=*.jl .

# 3. Handlers reading `Path{T}` fields that compensated for the missing decode.
grep -rn "Path{" --include=*.jl .
```

### Before → after

```julia
# 1. A custom `parseparam` method (e.g. in your own package extension)
# before
function parseparam(::Type{MyType}, str::String; escape=true)
    return parse(MyType, escape ? HTTP.unescapeuri(str) : str)
end
# after — the value arrives already decoded
function parseparam(::Type{MyType}, str::String)
    return parse(MyType, str)
end

# 2. A handler that re-encoded to undo the double decode
# before
handler(req, q::String) = search(HTTP.escapeuri(q))
# after — `q` is now exactly what the client sent
handler(req, q::String) = search(q)

# 3. A handler that decoded a `Path{T}` field by hand
# before
handler(req, p::Path{Ref}) = lookup(HTTP.unescapeuri(p.payload.name))
# after — already decoded
handler(req, p::Path{Ref}) = lookup(p.payload.name)
```

### ⚠️ Security: check anything that builds a filesystem path or URL from a path parameter

`Path{T}` fields and `req.params` values were previously **not** decoded, and are now. Encoded
traversal sequences that used to arrive inert now arrive live:

```
GET /files/..%2F..%2Fetc%2Fpasswd

  before →  p.payload.name == "..%2F..%2Fetc%2Fpasswd"   (usually a harmless ENOENT)
  after  →  p.payload.name == "../../etc/passwd"
```

An app that joined such a value straight into a path was already wrong — the scalar form of the
same parameter (`handler(req, name::String)`) has always been decoded and was always exploitable
— but this change makes the `Path{T}` and `req.params` spellings behave like the scalar one, so
code that looked safe by accident no longer is. **Audit every handler that reaches a filesystem,
an outbound URL, or a shell from a path parameter, and reduce the value to a bare basename or
validate it against an allowlist:**

```julia
# unsafe — traversal reachable
handler(req, p::Path{FileRef}) = readfile(joinpath(UPLOAD_DIR, p.payload.name))

# safe — strip any directory component before joining
handler(req, p::Path{FileRef}) = readfile(joinpath(UPLOAD_DIR, basename(p.payload.name)))
```

**Nitro's own static/SPA mounts are not affected.** `staticfiles`/`spafiles`/`dynamicfiles`
enumerate the tree at mount time and register one literal route per file, so no path parameter
ever reaches a path join inside the framework. This exposure is entirely in application code.

### `req.params` stopped being a live handle — then became one again (superseded by #38)

> ⚠️ **This subsection is superseded.** #70 made `req.params` a fresh `Dict` per access, so
> mutating it became a no-op. #38 — *"`req.query`, `req.params` and `headers(req)` are cached per
> request, so they are live handles"*, above — caches the decode and makes it a live handle again.
> Both changes are in this same unreleased wave, so **no released version ever exposed the
> snapshot behavior** and there is nothing to migrate *from* it. Follow the #38 entry.

The advice that survives both changes is unchanged, and is the only thing an app needs to act on:
do not use `req.params` to carry a value down a request — under #70 the write vanished, under #38
it persists and is visible to `req.input` and to bindings that have not run yet. Either way:

```julia
# don't — the meaning of this write has changed twice
req.params["tenant"] = resolve_tenant(req)

# do — the request context is what exists for this
req.context[:tenant] = resolve_tenant(req)
```

Reading is unaffected by both.

Apps that never put a `%` in a query value, never used `Path{T}` or `req.params`, never sent a
non-UTF-8 percent-encoded parameter, and never stored a `%` in a cookie are unaffected and need
no edit.
