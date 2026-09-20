## Static mounts answer conditional GETs and byte ranges (#40)

- **Version**: Unreleased
- **Nitro ref**: #40; `src/response.jl`, `src/core/staticfiles.jl`, `src/methods.jl`,
  `docs/design/static-serving-boundary.md`, `docs/src/tutorial/reverse_proxy.md`
- **Recorded**: 2026-09-20
- **Severity**: **behavior.** Nothing in an app's source has to change. What changes is the status
  code a *client* sees when it revalidates or asks for a range — which is the point — and that is
  visible to tests asserting `200`.

### What changed

`staticfiles`, `spafiles` and `dynamicfiles` now emit `ETag`, `Last-Modified` and `Accept-Ranges`,
and answer:

| Request carries | Was | Now |
|---|---|---|
| `If-None-Match` matching the served file | `200` + full body | **`304`**, no body |
| `If-Modified-Since` not older than the file | `200` + full body | **`304`**, no body |
| `Range: bytes=0-99` | `200` + full body | **`206`** + `Content-Range` |
| `Range` that cannot be satisfied | `200` + full body | **`416`** |
| `If-Match` / `If-Unmodified-Since` that fails | `200` + full body | **`412`** |

The same is available to handlers through a new **`Res.file(req, path)`** method. The existing
`Res.file(path)` is **unchanged** — it is a pure builder with no request to inspect, so it emits no
validators and can never short-circuit. Reach for the `req` form when you want conditional GET:

```julia
path("/reports/<int:id>.csv", function (req::HTTP.Request, id::Int)
    Res.file(req, report_path(id); disposition = "attachment")
end)
```

The protocol work is `HTTP.servecontent`, which is HTTP.jl **public** API (declared through Julia's
`public` mechanism). Nitro does not hand-roll the precondition table — weak-versus-strong tag
comparison, the order the four preconditions are evaluated in, and which headers a `304` may carry
are each places a plausible implementation is subtly wrong.

#### New keyword arguments

`staticfiles`, `spafiles`, `dynamicfiles` and `Res.file(req, path)` all take:

| Kwarg | Default | Meaning |
|---|---|---|
| `etag` | `:weak_stat` | `W/"<size>-<mtime>"`. Also `:strong` (sha256 of the body), a `String`, or `nothing` |
| `cache_control` | `nothing` | emitted verbatim when given; **no default is invented** |

`Res.file(req, path)` additionally takes `allow_ranges = true`.

**`Cache-Control` has no default on purpose.** Hashed build output wants a year and an unhashed
`index.html` wants zero, and guessing high pins clients to a stale asset with no way to recover.
State it per mount:

```julia
staticfiles("dist/assets", "assets"; cache_control = "public, immutable, max-age=31536000")
spafiles("dist", ""; cache_control = "no-cache")
```

**`:weak_stat` is the default** because a strong tag means hashing every byte — once per file at
mount, which is free for a small `dist/` and a visible startup pause for a folder of media. A weak
tag is exactly as good for `If-None-Match`, which compares weakly. Use `:strong` when `If-Range` or
`If-Match` has to be exact.

#### What this does *not* add

**Compression.** `docs/design/static-serving-boundary.md` §7 still lists it as a non-goal and §1
still gives it to the proxy. Cache validation and ranges moved off that list only because HTTP.jl
ships them; a content-negotiated compressor would be a codec, a negotiation and a cache to own.

Also unchanged: validators are computed **at mount time**, not per request. A mount serves a
snapshot (§6, §7), so re-`stat`ing per request to notice a changed file would be exactly the
per-request filesystem work that was removed on purpose. A `dynamicfiles` mount still re-reads
*content* per request; its validators still describe the mount-time snapshot.

### How to find the calls to migrate

```bash
# 1. Tests that assert 200 for a static asset AND send a validator or Range header. These are
#    the ones whose expected status changes.
rg -n 'If-None-Match|If-Modified-Since|If-Match|If-Unmodified-Since|"Range"' <app>/test

# 2. Clients or proxies in front of Nitro that were adding their own ETag. Two layers emitting
#    one is not an error, but the inner one now wins and yours may differ.
rg -n -i 'etag|add_header\s+Cache-Control' <app>/deploy <app>/nginx* 2>/dev/null

# 3. Anywhere a mount result or Res.file response is compared header-for-header, or counted.
rg -n 'length\(\w+\.headers\)' <app>/test
```

### Migrate your app

```julia
# Unchanged — the mount call itself needs no edit, and the default behaviour for a client that
# sends no validators is byte-for-byte what it was.
staticfiles("dist", "static")

# ✓ opt into a cache policy now that one is honoured
staticfiles("dist/assets", "assets"; cache_control = "public, immutable, max-age=31536000")
```

```julia
# ✗ before — a handler serving a download could not revalidate
path("/export.csv", req -> Res.file(export_path()))

# ✓ after — the request-aware form adds ETag/Last-Modified/Range handling
path("/export.csv", req -> Res.file(req, export_path(); disposition = "attachment"))
```

```julia
# ✗ before — a test that revalidates and expects the body back
@test internalrequest(HTTP.Request("GET", "/static/app.js",
                                   ["If-None-Match" => etag])).status == 200

# ✓ after — that is the whole feature
@test internalrequest(HTTP.Request("GET", "/static/app.js",
                                   ["If-None-Match" => etag])).status == 304
```
