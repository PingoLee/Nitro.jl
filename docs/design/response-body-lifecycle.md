# Response body lifecycle: HTTP.jl behavior, framework norms, and Nitro.jl patterns

Design reference for how Nitro.jl constructs, shares, and reuses HTTP responses.
Grounded in three things: HTTP.jl 2.x body semantics, how mainstream frameworks
handle the same problem, and **what Nitro's own server write path actually does** —
which changes the rules (see §1.5).

> **TL;DR for Nitro contributors:** Reusing or sharing a `Response` object across
> requests — including a module-level `const` with a `String` body — is **safe in
> Nitro**. Nitro's `_write_response_body!` writes the body non-destructively, so the
> upstream "a `BytesBody` is single-use" footgun (which also hit `String` bodies on HTTP
> ≤ 2.6) does not apply inside Nitro's serve path. The shared `const` error responses in `src/middleware/auth_middleware.jl`
> are correct and endorsed. The one rule: don't reintroduce HTTP's consuming writer
> (see §3, Guardrails).

## 1. The raw HTTP.jl behavior

This section is about HTTP.jl *by itself* — e.g. `HTTP.serve!` / `HTTP.listen!`.
§1.5 covers what changes once a response goes through Nitro.

> **Updated for HTTP 2.7+.** HTTP.jl #1364 (2.7.0) stopped wrapping a `String` body in a
> `BytesBody`: a `String` is now stored as-is and is reusable, exactly like `Vector{UInt8}`. The
> single-use cursor survives for an **explicit `BytesBody`** — which `HTTP.servecontent`, behind
> every `staticfiles` / `spafiles` / `dynamicfiles` / `Res.file` response, returns — and since 2.7
> the pre-send check `_check_response_body_unsent` answers its 2nd send with a **500** instead of
> a truncated body. Verified against 2.8.0 under raw `HTTP.serve!`. The `String` walkthrough below
> is the ≤ 2.6 history that motivated §1.5; the guardrail is unchanged, because `BytesBody` still
> reaches Nitro.

`HTTP.Response` stores its body differently depending on how you build it:

| Constructed with | Stored body type | Reusable across requests (raw HTTP.jl)? |
|---|---|---|
| a `String` (`Response(503, "msg")`) | `String` since 2.7; a `BytesBody` cursor on ≤ 2.6 | ✅ since 2.7 (❌ on ≤ 2.6: breaks after 1st send) |
| a `Vector{UInt8}` (`Response(503, bytes)`) | `Vector{UInt8}` (inert data) | ✅ written non-destructively |
| an explicit `HTTP.BytesBody` (incl. `HTTP.servecontent`) | `BytesBody` (single-use **cursor**) | ❌ 2nd send is a 500 (2.7+) |
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
body directly from `BytesBody.data` (`src/core/transport.jl`, `_write_response_body!`):

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
- It is coupled to the `HTTP.BytesBody.data` field — documented since HTTP 2.8 as public
  and safe to borrow without advancing the cursor, but on a type HTTP does not declare
  `public` — canaried in
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
- It depends on `HTTP.BytesBody.data` (documented since HTTP 2.8; its type is not declared
  `public`), canaried in
  `test/http_internals_contract_tests.jl`. Keep that canary and the behavioral coverage
  in `test/middleware/authmiddleware_tests.jl` green across HTTP.jl bumps.
- **Header-adding middleware must not mutate the inner response in place.** Build a new
  response (`add_response_headers`) or own the headers first (`own_response_headers`);
  never `append!`/`setheader`/`set_cookie!` on a response returned by an inner layer. It
  may be a shared `const` read concurrently by other request threads — mutating it leaks
  per-request headers (an echoed `Origin`, a session `Set-Cookie`) across requests and
  races. Regression: `test/middleware/shared_response_mutation_tests.jl`.

### What P2 costs, and why it is a rule rather than an accumulator (#447)

P2 means every header-adding layer rebuilds the response. Phoenix's `Plug.Conn` gets the same
guarantee by *shape*: one connection value threads through the pipeline, and headers accumulate
in it, so the response is built once. Nitro could do the same by rule, with a per-request
"pending headers" list on `req.context` that the serializer applies once. #447 measured whether
that is worth it. It is not.

The rebuild was expensive because of how it called HTTP.jl, not because it happened. HTTP 2.8's
keyword `Response` constructor runs `copy(mkheaders(...))` on both `headers` and `trailers`, and
`add_response_headers` fed it a `vcat`'d vector, so one layer built four collections. Since
#446/#447 the rebuild uses HTTP's field constructor around a single sized `Headers`, with the
field order pinned in `test/http_internals_contract_tests.jl`.

Measured in process: pipeline built once, Julia 1.12.7, HTTP 2.8.0, `GET /plaintext` returning
`Res.send`, behind `Cors`, `SessionMiddleware`, `CSRFMiddleware`, `RateLimiter` and
`SecurityHeaders`. Three of those rebuild on an anonymous GET: CORS, `SecurityHeaders` and the
rate limiter. Session and CSRF write nothing until they have something to set.

| | allocations / request | bytes / request |
|---|---|---|
| no middleware, before → after | 16 → 12 | 544 → 448 |
| five layers, before → after | 195 → 169 | 10,768 → 8,544 |
| one rebuild now, 12-header response | 6–8 | 416–544 |

The three rebuilds left are about 20 of those 169 allocations. An accumulator still has to build
the final response once, so the most it could save is roughly two rebuilds, ~14 allocations and
~1 KB a request, about 8%. The rest of the layers' cost is their own work (origin checks, cookie
parsing, rate-limit bookkeeping, header values). That saving does not buy a second mechanism every
header-adding middleware must remember to use. P2 stays a rule, enforced by
`shared_response_mutation_tests.jl`. Reopen this only if a layer's rebuild count grows, or a
profile shows `_rebuild_with_headers` near the top again.

### What `Res.json` costs, and where JSON.jl spends it (#474)

#465 left `Res.json(Dict)` at 12 allocations / 976 B and attributed the rest to JSON.jl. #474
asked which of three candidates in JSON.jl's writer was material: key-sorting of every `Dict`,
`Dict{String,Any}` versus a `NamedTuple` or struct, and the writer's own fixed costs. Measured in
process with `Profile.Allocs` at `sample_rate = 1`: Julia 1.12.7, one thread, JSON.jl 1.10.0,
HTTP 2.8.0, per call after warm-up. Flat payloads alternate `Int` and `String` values.

| | 2 keys | 10 keys | 50 keys |
|---|---|---|---|
| `JSON.json(Dict{String,Any})`, default sort | 8 | 8 | 10 |
| `JSON.json(Dict{String,Any})`, `sort_keys = false` | 6 | 6 | 6 |
| `JSON.json(NamedTuple)` | 9 | 17 | 57 |
| `Res.json(Dict{String,Any})` | 12 | 12 | 14 |
| `Res.json(NamedTuple)` | 13 | 21 | 61 |

Allocations per call. A two-field struct costs what a two-field `NamedTuple` costs (9).

**The `Dict` beats the `NamedTuple`, and the gap grows with the key count.** That inverts #474's
item 2. A `Dict{String}` key passes through `StructUtils.lowerkey` unchanged; a `Symbol` key —
every `NamedTuple` or struct field — goes through `lowerkey(::JSONStyle, sym::Symbol) =
String(sym)`, one `String` per field per object. For a 250-row `Vector{NamedTuple}` with three
fields that is 750 of the 762 allocations. It is the one upstream candidate the measurement
supports: a `Symbol` is interned, so the writer could copy its bytes into the buffer without a
`String`. Until that lands, **the docs' `Res.json(Dict(...))` examples are the cheaper form**, and
the guidance stays as it is.

**Key-sorting is 2 to 4 allocations per `Dict`** (`collect(keys(x))` plus `sort!`), flat in the key
count. Nothing at the root; on a payload of 250 nested `Dict`s it is ~500 of ~5,000, about 10%.
Not worth giving up deterministic key order for by itself; decide it with the next nested-payload
case, not this one.

**What is left in `Res.json(Dict)` at 2 keys is fixed cost**: the output buffer, its `Memory`, the
final `String`, the ancestor stack `Any[root]` and its `Memory` (circular-reference tracking), one
`Memory{Any}` behind the `WriteClosure`, and the two sort allocations — 8 — plus 4 for the response
and its headers. `sizeguess(::Any) = 512` sets bytes, not count.

**The bench's JSON echo is dominated by the parse, not the write.** `bench/suite/json.jl`'s
`echo_10kb_served` (250 rows through `getjson` → `Res.json`, pipeline built once) is 5,047
allocations / 236 KB; `JSON.parse` into `Dict{String,Any}` is 2,510 of them, about ten per row for
the `Dict`, its two `Memory`s, the boxed values and the key strings. That is inherent to an untyped
parse. The typed extractor `Json{T}` is the lever on that side; #475 below measures it, and corrects
one premise of this paragraph: `getjson` returns a `JSON.Object{String,Any}`, not a `Dict`.

**JSON.jl below 1.9 is a different story.** The `[compat]` floor moved to `^1.9` in #306 for the
read style, which happened to exclude two writer costs this measurement found in 1.8.0: every
array element paid two allocations (`StructUtils.applyeach(::AbstractArray)` stringified the
*index* through `lowerkey(::Real) = string(i)` though arrays never write a key — `JSON.json` of a
250-element `Vector{Int}` was 507 allocations against 7 on 1.10), and every `Dict{String,Any}` key
boxed the `WriteClosure` on the dynamic call (60 against 10 at 50 keys). A stale local
`Manifest.toml` still resolving 1.8.0 reproduces both; `Manifest.toml` is gitignored, so
`Pkg.update()` is the fix, not a commit.

### What `Json{T}` costs against `getjson` (#475)

The same echo through the typed extractor: `bench/suite/json.jl`'s `typed_*` rows bind the body
as a plain struct (`BenchItem` for the 3-field body, `BenchRows` holding a `Vector{BenchRow}` for
the 250-row one) and `kwdef_*` as its `@kwdef` twin, then return `Res.json` of what they parsed.
`parse_*` and `write_*` measure each half on its own, because a struct and a parsed object
serialize differently. Measured with BenchmarkTools, minimum per call, Julia 1.12.7, one thread,
JSON.jl 1.10.0, HTTP 2.8.0, reproduced across two runs. Attribution from `Profile.Allocs` at
`sample_rate = 1`.

| allocations / time | `getjson` | `Json{T}`, plain struct | `Json{T}`, `@kwdef` |
|---|---|---|---|
| parse, 3 fields | 14 / 0.36 µs | 12 / 1.46 µs | 57 / 6.2 µs |
| write, 3 fields | 22 / 0.58 µs | 17 / 0.48 µs | (same as plain) |
| echo served, 3 fields | 49 / 1.9 µs | 45 / 3.0 µs | 92 / 8.4 µs |
| parse, 250 rows | 2,510 / 65–75 µs | 1,264 / 65 µs | 1,295 / 108 µs |
| write, 250 rows | 2,524 / 104 µs | 773 / 44 µs | (same as plain) |
| echo served, 250 rows | 5,047 / 181 µs | 2,053 / 114 µs | 2,085 / 159 µs |

The `echo_*_served` rows are the parse plus the write, plus about 15 allocations of pipeline.

**On a real payload `Json{T}` wins outright: 60% fewer allocations and 37% less time at 250 rows.**
The parse halves its allocations, because one immutable `BenchRow` stored inline in the
`Vector{BenchRow}` replaces a per-row object of boxed values. The write gains even more.

**Half of `getjson`'s win comes from the write, because `getjson` returns a
`JSON.Object{String,Any}`, not a `Dict`.** JSON.jl 1.x parses objects into its own ordered `Object`
type, and the writer iterates it through a dynamic `applyeach` that heap-allocates every
`Pair{String,Any}` and its iteration tuple: about seven allocations per object, 2,524 for the 250
rows. Writing the same data as a Base `Dict{String,Any}` takes 773 allocations and 77 µs. A struct
writes in 773 too, almost all of it the 750 field-name `String`s described in the `Res.json`
section above. That section's "`Dict` beats `NamedTuple`" therefore holds for a `Dict` the handler
builds itself, not for an echoed `getjson` value. Parsing into a Base `Dict` instead
(`dicttype = Dict{String,Any}`) costs 3,495 allocations and 101 µs, so swapping the type inside
`getjson` would roughly break even. The upstream candidate is the writer's `Object` iteration.

**On a 3-field body `Json{T}` allocates less but takes 1 µs longer, and that microsecond is
reflection, not parsing.** The typed parse itself is 0.33 µs. `json_bind`'s `binds_by_keyword(T)`
adds 0.9 µs on every request, through `hasmethod` with keyword names, although its answer depends
only on `T`. Filed as #493.

**The `@kwdef` path makes a large body parse slower than `getjson` does, at half the
allocations.** For a `@kwdef` type, `json_bind` first parses the whole body into
`Dict{String, JSON.JSONText}` (#294): that pass validates the body and copies its text, 38.6 µs at
10 KB for 6 allocations. Only then does it parse each field. At 250 rows that is 108 µs against 65
for the plain struct. On a small body the extra cost is one `binds_by_keyword` per field plus
`kw_construct`'s dynamic keyword call (1.2 µs, 12 allocations), so 6.2 µs against 1.5. The
`@kwdef` echo still beats `getjson` end to end (159 against 181 µs) only because the struct write
is cheap. Also #493.

**Both are fixed (#493), and `Json{T}` is no longer slower than `getjson` at any size measured.** The
keyword-constructor check is memoized per type (8–10 ns a hit, 9–15 ns with four threads reading
it at once; keyed on the world counter so a later method definition is still seen), and a `@kwdef` body
is one `JSON.parse` through a `make` hook on a Nitro-owned type, so it costs what a plain struct
costs. Same method and versions as above:

| allocations / time | before | after |
|---|---|---|
| parse, plain struct, 3 fields | 12 / 1.46 µs | 9 / 0.48 µs |
| parse, `@kwdef`, 3 fields | 57 / 6.2 µs | 27 / 2.0 µs |
| parse, `@kwdef`, 250 rows | 1,295 / 108 µs | 1,278 / 66 µs |
| echo served, plain struct, 3 fields | 45 / 3.0 µs | 42 / 1.9 µs |
| echo served, `@kwdef`, 3 fields | 92 / 8.4 µs | 60 / 3.5 µs |
| echo served, `@kwdef`, 250 rows | 2,085 / 159 µs | 2,067 / 114 µs |

The plain-struct echo now ties `getjson`'s 1.9 µs on the 3-field body, with fewer allocations. What
`@kwdef` still pays over a plain struct on a small body is `kw_construct`'s dynamic keyword call,
about 1.2 µs. A positional shortcut when every field is present would remove it, but would also
bypass a hand-written keyword constructor that transforms its arguments, so it is not taken.

One edge now behaves like JSON.jl's plain-struct path instead of like the `Dict` the walk replaced:
a repeated key binds its last value as before, but every occurrence is parsed, so an invalid
earlier occurrence (`{"a":"bad","a":5}`) refuses the body where the `Dict` kept only the last text.

## 4. Reference facts

- Up to 2.6, a `String` body was wrapped in a `BytesBody`, and HTTP.jl #1272 declared that
  single-use behavior intentional. HTTP.jl #1364 (2.7.0) reversed it: `String` bodies are now
  stored as-is and are reusable.
- Byte-vector responses are reusable by design (HTTP.jl #1254).
- An explicit `BytesBody` is still consumed and closed on write, by design; since 2.7
  `_check_response_body_unsent` turns a resend into a 500.
- Client response bodies (`HTTP.get(...).body`) are always materialized `Vector{UInt8}`
  — unaffected. The footgun is only **server responses whose body is a `BytesBody`
  (e.g. from `HTTP.servecontent`) and that are reused**, and Nitro neutralizes even
  that (§1.5).
- Nitro specifics: `_write_response_body!` in `src/core/transport.jl`; the non-mutating header
  helpers `own_response_headers` / `add_response_headers` in `src/utilities/misc.jl`
  (used by the CORS / session / CSRF / rate-limiter middleware); shared consts in
  `src/middleware/auth_middleware.jl`; guards in `test/http_internals_contract_tests.jl`,
  `test/middleware/authmiddleware_tests.jl`, and
  `test/middleware/shared_response_mutation_tests.jl`.
