## Large mounted files are streamed instead of held in memory (#41)

- **Version**: Unreleased
- **Nitro ref**: #41; `src/core/staticfiles.jl`, `src/core/transport.jl`, `src/response.jl`,
  `src/methods.jl`, `src/precompile.jl`, `src/core.jl`,
  `docs/design/static-serving-boundary.md`
- **Recorded**: 2026-09-20
- **Severity**: **behavior.** No app source has to change. One default moved, and it changes where
  a large mounted file's bytes live — which is the point.

### What changed

`staticfiles` read **every** mounted file into memory at startup and held it for the process
lifetime, with no cap and no eviction. Mounting a folder with a 500 MB video pinned 500 MB resident
whether or not anything ever requested it, and `Res.file` then materialised the whole body again per
response — so N concurrent downloads cost N × filesize *on top of* the mount's own copy.

Two bounds now apply.

**1. Files over `stream_threshold` are streamed, whatever the cache policy says.** The default is
**8 MiB** — comfortably above any realistic SPA bundle, which is the case the in-memory snapshot
exists to make fast, and far below the sizes where holding the bytes is the problem. A streamed
response is sent in 64 KiB chunks, so peak memory is a buffer rather than the file, for one request
and for a hundred concurrent ones.

**2. `cache` chooses where the bytes come from** for everything below the threshold:

| `cache` | Behaviour | Default for |
|---|---|---|
| `:eager` | read at mount time, held for the process lifetime | `staticfiles`, `spafiles` |
| `:lazy` | read on first request into an LRU bounded by `cache_max_bytes` (64 MiB) | — |
| `:none` | read per request, never held | `dynamicfiles` |

`:lazy` is what makes memory track the **working set** rather than the folder. The bound is a byte
budget, not an entry count, because 200 icons and 200 videos are not the same working set.

`Res.file(req, path; stream = true)` exposes the same transport to handlers, which is the
user-download case:

```julia
path("/export.csv", req -> Res.file(req, export_path(); stream = true, disposition = "attachment"))
```

#### The one default that moved

**A mounted file larger than 8 MiB is no longer served from RAM.** It is re-opened and streamed per
request instead. For most mounts nothing changes — a `dist/` is well under the threshold. If you
deliberately mount large files and want them resident, raise or disable the threshold:

```julia
staticfiles("media", "media"; stream_threshold = 512 * 1024 * 1024)   # buffer up to 512 MiB
staticfiles("media", "media"; stream_threshold = 0)                   # never stream (old behaviour)
```

A streamed response is **single-use** — the body is a cursor over an open file, not a buffer — so it
can never be cached or shared. `etag = :strong` is therefore **refused** with an `ArgumentError`
rather than silently downgraded when `stream = true` on `Res.file`, because hashing the body means
reading all of it. A *mount* that asks for both logs the downgrade and uses the weak tag, since one
oversized file should not fail a whole mount.

#### Not a change: which files exist

Enumeration is still mount-time (`docs/design/static-serving-boundary.md` §6, §7). `:none` and
`:lazy` re-read **content**, exactly as `dynamicfiles` always has; they do not re-evaluate the mount
rules, and validators still describe the mount-time snapshot.

### How to find the calls to migrate

```bash
# 1. Mounts pointed at folders that contain anything large. These are the files whose bytes
#    move from RAM to per-request streaming.
rg -n '(static|spa)files\(' <app>/src
find <mounted-folder> -type f -size +8M

# 2. Anything asserting on a static response's body TYPE rather than its content. A streamed
#    response's `.body` is an `HTTP.AbstractBody` cursor, not a `Vector{UInt8}`.
rg -n '\.body\s*isa|typeof\(\w+\.body\)' <app>/test

# 3. Code reading a large static response in-process via `internalrequest`. Over a socket
#    nothing changes; in-process you must drain the body rather than index it.
rg -n 'internalrequest' <app>/test
```

### Migrate your app

```julia
# Unchanged for a normal SPA build — every file is under the threshold.
staticfiles("dist", "static")

# ✓ a media folder: cap resident memory at the working set instead of the whole folder
staticfiles("media", "media"; cache = :lazy, cache_max_bytes = 256 * 1024 * 1024)

# ✓ or keep the old behaviour explicitly
staticfiles("media", "media"; cache = :eager, stream_threshold = 0)
```

```julia
# ✗ before — a large response body was always a byte vector in process
resp = internalrequest(HTTP.Request("GET", "/media/big.bin"))
@test String(resp.body) == expected

# ✓ after — a streamed body is a cursor; drain it, or assert over a socket instead
resp = internalrequest(HTTP.Request("GET", "/media/big.bin"))
buf, chunk = UInt8[], Vector{UInt8}(undef, 64 * 1024)
while !HTTP.body_closed(resp.body)
    n = HTTP.body_read!(resp.body, chunk)
    n == 0 && break
    append!(buf, @view(chunk[1:n]))
end
@test buf == expected
```
