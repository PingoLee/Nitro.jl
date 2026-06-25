# Response body lifecycle: HTTP.jl behavior, framework norms, and Nitro.jl patterns

Design reference for how Nitro.jl constructs, shares, and reuses HTTP responses.
Grounded in three things: HTTP.jl 2.x body semantics, how mainstream frameworks
handle the same problem, and **what Nitro's own server write path actually does** —
which changes the rules (see §1.5).

> **TL;DR for Nitro contributors:** Reusing or sharing a `Response` object across
> requests — including a module-level `const` with a `String` body — is **safe in
> Nitro**. Nitro's `_write_response_body!` writes the body non-destructively, so the
> upstream "string bodies empty out on reuse" footgun does not apply inside Nitro's
> serve path. The shared `const` error responses in `src/middleware/auth_middleware.jl`
> are correct and endorsed. The one rule: don't reintroduce HTTP's consuming writer
> (see §3, Guardrails).

## 1. The raw HTTP.jl behavior

This section is about HTTP.jl *by itself* — e.g. `HTTP.serve!` / `HTTP.listen!`.
§1.5 covers what changes once a response goes through Nitro.

`HTTP.Response` stores its body differently depending on how you build it:

| Constructed with | Stored body type | Reusable across requests (raw HTTP.jl)? |
|---|---|---|
| a `String` (`Response(503, "msg")`) | `BytesBody` (single-use **cursor**) | ❌ breaks after 1st send |
| a `Vector{UInt8}` (`Response(503, bytes)`) | `Vector{UInt8}` (inert data) | ✅ written non-destructively |
| `EmptyBody` / an `AbstractBody` stream | as given | streams are 1-shot |

The string path wraps the bytes in a `BytesBody` — a consuming read cursor that the
server **reads to completion and closes** on write. Reusing that same `Response`
object across requests breaks on the 2nd+ send:

```julia
# Raw HTTP.jl (HTTP.serve!), NOT through Nitro — contrast with §1.5.
const ERR = HTTP.Response(503, "service unavailable")   # body is a BytesBody cursor
# request 1 → "service unavailable"
# request 2 → broken. Either a silently empty body, or — on the pinned HTTP.jl 2.4
#             with a fixed-length response — a hard client-side error:
#             `truncated fixed-length HTTP/1 body`. (Send #1 fixed Content-Length on
#             the shared object; send #2 writes 0 bytes, so the length no longer matches.)
```

The exact failure (silent empty vs. truncated error) depends on transfer encoding and
HTTP.jl version; either way the response is corrupted. This single-use behavior is
**intentional** in HTTP.jl — it lets a handler partially read a body and stream the
remainder — not a bug awaiting a fix (HTTP.jl #1272).

## 1.5. In Nitro, this footgun is neutralized in core

Nitro does **not** use HTTP's consuming writer. Its custom stream adapter writes the
body directly from `BytesBody.data` (`src/core.jl`, `_write_response_body!`):

```julia
function _write_response_body!(stream::HTTP.Stream, body::HTTP.BytesBody)
    isempty(body.data) || write(stream, body.data)   # reads .data; never advances the cursor
    return nothing
end
```

Because it reads the underlying `.data` rather than draining the cursor, a shared
`Response` — `String` body included — can be emitted any number of times. Verified:
returning a module-level `const` `String`-bodied `Response` through Nitro serves the
body on every request, where the same object under raw `HTTP.serve!` breaks on
request 2.

**Consequence:** sharing/caching a response object across requests is a supported,
endorsed Nitro pattern. The module-level `const` error responses in
`src/middleware/auth_middleware.jl` (`INVALID_HEADER`, `EXPIRED_TOKEN`,
`MISSING_COOKIE`) are correct by design — they are Nitro's equivalent of a Spring
immutable `ResponseEntity` constant (§2).

A shared response is **body + headers**, and both must be safe. Body reuse is handled by
the non-consuming write above. **Header** safety is handled separately: Nitro's
header-adding middleware (CORS, session, CSRF, rate limiter) never mutate a returned
response in place — they build a fresh one via `own_response_headers` /
`add_response_headers` (`src/utilities/misc.jl`). Mutating a shared response's `headers`
in place would otherwise **accumulate** headers across requests and **leak** per-request
headers — an echoed `Origin`, or worse, a session `Set-Cookie` minted for one visitor —
onto the shared object, and would race other request threads. See §3 (P2, Guardrails).

This safety is load-bearing and depends on two things, both guarded by tests:

- `_write_response_body!` must keep writing `.data` directly — never route bodies back
  through HTTP's consuming `_write_response_body_to_stream!`.
- It is coupled to the `HTTP.BytesBody.data` internal field, canaried in
  `test/http_internals_contract_tests.jl`; the reuse-safety is covered behaviorally in
  `test/middleware/authmiddleware_tests.jl`.

## 2. How other frameworks handle response bodies

Most frameworks expose **two layers**, and which one you touch determines the model.
This isn't a "majority vs. minority of frameworks" split — the *same* framework
usually offers both.

### Layer A — stream / write-once (the low-level layer)

No persistent body object; you write bytes to the socket per request.

- **Node.js** (`http`, Express `res.send`): `http.ServerResponse` is a per-request
  Writable stream. `Buffer` is mutable, JS strings immutable; no held reusable body.
- **Go `net/http`**: the server handler is `w.Write([]byte)` (pure stream). On the
  *client* side, `http.Response.Body` is an `io.ReadCloser` — a single-use stream you
  must `Close`.
- **Spring servlet / ASP.NET Core**: `HttpServletResponse` / `HttpResponse.Body` are
  write-oriented streams.

### Layer B — held body object (the high-level layer)

- **Django** `HttpResponse`: the primary API — body via `.content`, mutable but
  rewritten by **reassignment** (`response.content = new`), e.g. `GZipMiddleware` —
  never in-place byte poking.
- **Spring `ResponseEntity`**: **immutable** (builder, `final` body). Returned from
  controllers; the common high-level abstraction is immutable by design.
- **Rails / Rack**: `[status, headers, body]`, body an enumerable; reassigned wholesale.

### Where HTTP.jl's `BytesBody` sits relative to these

HTTP.jl is mixed. On the **server** side, a `String`-constructed body is a single-use
cursor (`BytesBody`) — the same *shape* as Go's client `io.ReadCloser`, but on the
opposite side of the wire. On the **client** side, HTTP.jl materializes the body to a
`Vector{UInt8}` (not single-use) — the inverse of Go. So the "single-use stream"
hazard in HTTP.jl lives specifically on **server responses you construct from a
`String`**, which is exactly the surface §1.5 addresses.

### The actual cross-cutting truth

The hazard is never "sharing a response object" — it's sharing one that carries
**consume-once state** (a cursor/stream). Sharing an **immutable / inert** response
*is* idiomatic and safe:

- Spring `ResponseEntity` constants are commonly cached and returned across requests
  precisely because they're immutable:
  ```java
  private static final ResponseEntity<Void> NO_CONTENT = ResponseEntity.noContent().build();
  ```
- That is the same pattern as Nitro's `const` error responses — and the same as a
  `Vector{UInt8}`-bodied `HTTP.Response` under raw HTTP.jl.

So: per-request construction is the dominant idiom across frameworks, **and** sharing
an immutable/inert response object is a recognized, safe exception. Nitro supports
both — its non-consuming write (§1.5) turns even a `String`-bodied shared response
into the safe, inert kind.

## 3. Design patterns for Nitro.jl

**P1 — Construct responses per request (recommended default).** Not because reuse is
unsafe in Nitro (it isn't — §1.5), but for clarity and portability: it's the universal
framework idiom and is cheap. Use the `Res.*` builders, which construct a fresh
response each call.

```julia
handler(req) = Res.send("service unavailable"; status=503)   # fresh each call
```

**P2 — Middleware/handlers return *new* responses; don't mutate one in place.** Matches
functional middleware (`f(::Handler) -> Handler`) and Spring's immutable
`ResponseEntity`. Nitro's own CORS / session / CSRF / rate-limiter middleware follow
this: they add headers via `add_response_headers` / `own_response_headers` rather than
`append!`/`set_cookie!`/`setheader` on the inner response (which may be a shared
`const`). A body-transforming middleware builds a fresh `Response` — and must not carry
a stale `Content-Length` over to a changed body:

```julia
# Illustrative — `compress` / `body_bytes` stand in for real helpers.
function gzip_middleware(handler)
    return function (req)
        resp       = handler(req)
        compressed = compress(body_bytes(resp))    # materialize the body to bytes first
        # Fresh object. The old Content-Length described the *uncompressed* body, so set
        # the new length explicitly (or drop the header and let it be recomputed).
        return HTTP.Response(resp.status,
            ["Content-Encoding" => "gzip",
             "Content-Length"   => string(length(compressed))],
            compressed)
    end
end
```

**P3 — Caching/sharing a response template is fine in Nitro.** A module-level `const`
with a `String` body is safe here (§1.5), as the `auth_middleware.jl` consts show. The
one portability caveat: if you ever hand a `Response` to **raw**
`HTTP.serve!` / `HTTP.listen!` *outside* Nitro's write path, give it a `Vector{UInt8}`
body — HTTP writes those non-destructively (HTTP.jl #1254):

```julia
const ERR_503 = HTTP.Response(503, Vector{UInt8}(codeunits("service unavailable")))
```

**P4 — Treat a response body as write-once data.** Don't read it in one middleware
layer expecting a later layer to still see it; if you need the bytes, materialize them
(`Vector{UInt8}` / `String`) and rebuild the response.

### Guardrails (what keeps the above true)

- **Never** route response bodies through HTTP's consuming
  `_write_response_body_to_stream!`. Nitro's non-consuming `_write_response_body!`
  (§1.5) is load-bearing; reintroducing the consuming path silently empties every
  reused response.
- It depends on the `HTTP.BytesBody.data` internal, canaried in
  `test/http_internals_contract_tests.jl`. Keep that canary and the behavioral coverage
  in `test/middleware/authmiddleware_tests.jl` green across HTTP.jl bumps.
- **Header-adding middleware must not mutate the inner response in place.** Build a new
  response (`add_response_headers`) or own the headers first (`own_response_headers`);
  never `append!`/`setheader`/`set_cookie!` on a response returned by an inner layer. It
  may be a shared `const` read concurrently by other request threads — mutating it leaks
  per-request headers (an echoed `Origin`, a session `Set-Cookie`) across requests and
  races. Regression: `test/middleware/shared_response_mutation_tests.jl`.

## 4. Reference facts

- The `String`→`BytesBody` wrapping already aliases the string bytes zero-copy, so
  switching string storage to `Vector` / `CodeUnits` would be **performance-neutral** —
  it would buy *only* reuse-safety for a pattern no framework treats as the default.
  Hence HTTP.jl leaves it single-use.
- Byte-vector responses are reusable by design (HTTP.jl #1254).
- `BytesBody`'s consume-and-close-on-write is intentional (HTTP.jl #1272).
- Client response bodies (`HTTP.get(...).body`) are always materialized `Vector{UInt8}`
  — unaffected. The footgun is only **server responses built from a `String` and
  reused**, and Nitro neutralizes even that (§1.5).
- Nitro specifics: `_write_response_body!` in `src/core.jl`; the non-mutating header
  helpers `own_response_headers` / `add_response_headers` in `src/utilities/misc.jl`
  (used by the CORS / session / CSRF / rate-limiter middleware); shared consts in
  `src/middleware/auth_middleware.jl`; guards in `test/http_internals_contract_tests.jl`,
  `test/middleware/authmiddleware_tests.jl`, and
  `test/middleware/shared_response_mutation_tests.jl`.
