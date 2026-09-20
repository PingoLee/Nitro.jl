## HTTP compat moves to `~2.7` — an app pinning `~2.6` must move too

- **Version**: Unreleased
- **Nitro ref**: #225; `Project.toml` `[compat]`, `src/core/transport.jl`,
  `test/http_internals_contract_tests.jl`
- **Recorded**: 2026-09-20
- **Severity**: **breaking (dependency resolution)** — an app carrying its own `HTTP = "~2.6"`
  bound does not resolve against this release.

### What changed

Nitro's bound moved from `HTTP = "~2.6"` to `HTTP = "~2.7"` (resolving 2.7.1).

**The pin stays tight — `~`, not `^` — on purpose**, for the same reason as the `~2.4` → `~2.6`
move: core reaches into HTTP internals that no public API covers, notably `BytesBody.data` in
`_body_bytes` and in the non-consuming response write path (`src/utilities/bodyparsers.jl`,
`src/core/transport.jl`). A caret bound would let Pkg resolve an untested minor release, and the
failure mode is not a load error — advancing the `BytesBody` read cursor corrupts reuse of a
module-level `const` response, serving a truncated body on the *second* request and nothing on
the first.

Verified against 2.7.1 before the bound moved: `BytesBody` still carries `data`, `next_index` and
`closed`; `EmptyBody`, `AbstractBody`, `Stream`, `forceclose`, `_request_context_metadata!` and
`_buffered_stream_request` all still exist; `HTTP.Request` still exposes `proto_major`,
`proto_minor` and `context`; and the router still hands over **still-encoded** path segments, which
is what keeps `Types.pathparams` from double-decoding (#70).

**Two upstream changes are worth knowing about even though neither forces an app edit.**

- **String response bodies are reusable again — and they stay `String`s.** HTTP.jl #1272 declared
  the consume-and-close-on-write of a String→`BytesBody` body *intentional*; HTTP.jl #1364 (in
  2.7.0) reversed it, storing String bodies as-is, "exactly like `Vector{UInt8}` bodies". Nitro
  never depended on either state — it writes the bytes itself in `_write_response_body!` — so what
  is *served* is unchanged. The stale rationale in `src/core/transport.jl` that cited #1272 as
  settled has been corrected.

  **One observable consequence, if you inspect a response you built.** `resp.body` is now the
  `String` you passed rather than a byte-backed `BytesBody`, so `length(resp.body)` counts
  **characters** where it used to count bytes. Anything comparing it against `Content-Length` —
  which is defined in bytes — silently disagrees on a multibyte body:

  ```julia
  resp = Res.file(path; loadfile = p -> read(p, String))   # body: "héllo wörld!!"
  sizeof(resp.body)   # 15  ← bytes, and what Content-Length says
  length(resp.body)   # 13  ← characters, and what this used to return as 15
  ```

  Use `sizeof`. Nitro's own builders were always correct here (`Res.file` has used `sizeof`
  deliberately since #92); this only affects code that measures a body itself. Nitro's test suite
  had one such assertion and it has been corrected.
- **A new pre-send check can turn a body mistake into a 500.** 2.7.0 added
  `_check_response_body_unsent`, called from `write_response!` and the HTTP/2 streaming path before
  the response head is written. It rejects a `BytesBody` or `CallbackBody` that is already sent or
  closed, and a `BytesBody` shorter than its declared `Content-Length`; the request-handler server
  answers **500** rather than dropping the connection mid-response. HEAD, 204 and 304 are allowed to
  send no body. Nitro's shared responses are unaffected — reading `.data` advances no cursor and
  closes nothing — and that is now pinned in `test/http_internals_contract_tests.jl` rather than
  assumed.

Also in this range: HTTP/2 connection stalls fixed (2.7.1 returns flow-control credit for response
bytes never read), configurable HTTP/1 header limits with the default raised to 64 KiB, HTTP/2
informational responses (103 Early Hints), RFC-correct `Host` header ordering, and a connection pool
that respects server Keep-Alive timeouts.

**What did *not* change: the router.** No percent-decoding was added, a `**` segment is still not
captured as a path variable, and match precedence is still exact → conditional → wildcard →
doublestar. Any code that derives a `/**` handler's remainder must still do so from `req.target`.

### How to find the calls to migrate

```bash
# The app's own bound — this is what blocks resolution.
rg -n '^HTTP\s*=' <app>/Project.toml

# Does the app use HTTP directly? Then HTTP's own 2.7 changes are yours to review,
# not something Nitro mediates.
rg -n 'using HTTP|import HTTP' <app>/src

# Apps that build a response body by hand and send it more than once: the new pre-send
# check turns a spent body into a 500 instead of a silent truncation. Worth a look.
rg -n 'HTTP\.Response\(' <app>/src | rg -i 'const|global'
```

### Migrate your app

```toml
# ✗ before — will not resolve against this release
HTTP = "~2.6"

# ✓ after
HTTP = "~2.7"
```

An app that does not pin HTTP itself needs no change: it inherits the bound from Nitro.
