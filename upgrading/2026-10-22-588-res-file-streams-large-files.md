## `Res.file(req, path)` streams a file over 8 MiB by default (#588)

- **Version**: 0.7.0
- **Nitro ref**: [#588](https://github.com/PingoLee/Nitro.jl/issues/588) ; `src/response.jl`, `src/constants.jl`
- **Recorded**: 2026-10-22
- **Severity**: behavior change (response body type)

### What changed

`Res.file(req, path)` used to read the whole file into memory unless you passed `stream = true`.
Its `stream` keyword now defaults to `nothing`, which streams any file larger than 8 MiB. That is
the same threshold the static mounts already use (`stream_threshold`). Files of 8 MiB or less are
still read whole.

The whole-file read was the one file path left that stalled a server. One `read` of a 100 MiB
file holds its thread with no safepoint. In #588's stall pass, that made every garbage collection
wait 43–66 ms for the thread at any client speed, and it allocated the whole file per request.
A streamed body sends 64 KiB at a time, gives its thread up whenever the client is slower than the
server, and holds one buffer instead of the file.

The default stays buffered where streaming cannot apply: when `loadfile` is given, or
`etag = :strong` is. An explicit `stream = true` or `stream = false` means what it did before.

What a streamed response does differently, for a file over 8 MiB with no `stream` keyword:

- **The body is a single-use cursor over the open file**, not bytes. You cannot cache the returned
  `Response` and send it again, or read its body twice. Nitro's own body readers (`text(resp)`,
  `json(resp)`, `binary(resp)`) do not accept a streamed body and throw a `MethodError`.
- **The file is read while the response is sent**, not when the handler returns.
  - A file rewritten in place during the download (a regenerated export, say) sends a body that
    no longer matches the `Content-Length` already sent, and the transfer aborts.
  - A handler that deletes the file right after returning (`try return Res.file(req, tmp)
    finally rm(tmp) end`, or `Res.file` inside `mktempdir() do`) still works on Linux and macOS,
    where an unlinked file stays readable. On Windows the open handle blocks the delete: an
    explicit `finally rm` throws and the request answers `500`, and inside `mktempdir() do` the
    cleanup fails, Julia logs an error, and the directory stays behind until a later cleanup.
- **`internalrequest` hands you an open cursor.** It never reaches the socket write that closes the
  handle, so a test that calls a handler like this through `internalrequest` must drain the body
  with `HTTP.body_read!` until it returns `0`, or call `HTTP.body_close!`. On Windows an open
  handle also blocks deleting the file.
- **`write_timeout` bounds each 64 KiB chunk** instead of the whole body, so a slow client is cut
  only when it stalls on one chunk.
- **Unchanged on the wire:** the bytes, `Content-Length`, `ETag` (the default `:weak_stat`), and
  the `304` and `206` answers.

### How to find the calls to migrate

```bash
grep -rn -E 'Res\.file\(\s*[A-Za-z_][A-Za-z0-9_.]*\s*,' --include=*.jl .
```

That finds the request-aware form whatever the request variable is called. It also matches
`Res.file(path, kw = …)` with keywords; skip those, since `Res.file(path)` has no request and
did not change. Also look for calls split across lines, where `Res.file(` ends the line.

For each hit with no `stream =` keyword that can serve a file larger than 8 MiB, pass
`stream = false` if the code does any of these:

- keeps or reuses the returned `Response`;
- reads the body itself (`resp.body`, `text(resp)`, `json(resp)`), including through
  `internalrequest` in a test;
- deletes or rewrites the file after returning, and must run on Windows or tolerate a rewrite.

Calls that only return the response from a handler need no change.

### Migrate your app

```julia
# ✗ before: a memoised response was reusable because its body was always bytes
resp = get!(() -> Res.file(req, path), RESPONSES, path)

# ✓ after: ask for the buffered read explicitly when you keep the response
resp = get!(() -> Res.file(req, path; stream = false), RESPONSES, path)
```

```julia
# ✗ before: a test read a large file's body straight off internalrequest
resp = internalrequest(HTTP.Request("GET", "/export"))
@test length(resp.body) == filesize(path)

# ✓ after: drain the streamed body, which also closes the file
resp = internalrequest(HTTP.Request("GET", "/export"))
buf = Vector{UInt8}(undef, 64 * 1024); n = 0
while (k = HTTP.body_read!(resp.body, buf)) > 0; n += k; end
@test n == filesize(path)
```
