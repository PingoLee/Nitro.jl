## Auth middleware and body parsers — `InterruptException`, `StackOverflowError` and `OutOfMemoryError` are no longer swallowed

- **Version**: Unreleased
- **Nitro ref**: [#254](https://github.com/PingoLee/Nitro.jl/issues/254) ; `src/errors.jl`, `src/middleware/auth_middleware.jl`, `src/utilities/bodyparsers.jl`, `src/utilities/misc.jl`, `src/middleware/csrf_middleware.jl`, `src/middleware/extract_ip.jl`, `src/extractors.jl`
- **Recorded**: 2026-09-21
- **Severity**: **behavior change** — a request that returned `401` (auth), `403` (CSRF),
  `400` (typed extractors and scalar path/query parameters) or `200` with an empty parse
  result (body parsers) can now produce a `500`. Only for the three exception types named
  below; every other failure is unchanged. Request input no longer raises one: the
  deeply-nested JSON that did is rejected as malformed before it is parsed since
  [#314](https://github.com/PingoLee/Nitro.jl/issues/314), which has its own entry.

### What changed

Several `try`/`catch` blocks on the request path used a **bare** `catch`, which in Julia
catches everything. That is right for the failures those blocks exist to absorb — a bad token,
a body that is not JSON, a session store that is down — and wrong for the conditions the
runtime raises about *itself*:

| exception | before | after |
|---|---|---|
| `StackOverflowError` | absorbed; request served normally | propagates |
| `OutOfMemoryError` | absorbed; request served normally | propagates |
| `InterruptException` | absorbed, so Ctrl-C mid-request was a no-op | propagates |
| everything else (`AuthError`, `ArgumentError`, a store error, …) | absorbed | **absorbed — unchanged** |

Julia reports a stack overflow as *"program state may be corrupted, so further execution might
be unreliable"*. Reporting that as a routine authentication failure, and then continuing to
serve from the same worker, is the defect.

**It was request-reachable, and one path needed no credentials at all.** `JSON.parse` raises
`StackOverflowError` on a deeply-nested value. Measured on a `Threads.@spawn` task — the stack
a real request runs on — the threshold is nesting depth ~3100, i.e. **~3.1 KB** of unclosed
`[[[[…` as a body or query string (~6.2 KB closed), and a **4,149-byte** `Authorization` header
once base64url-encoded into a JWT header segment:

- Through **auth**: a bearer token whose header segment is base64url of that nesting reaches it
  inside `decode_jwt`. `BearerAuth`/`CookieAuthMiddleware` answered `401`.
- Through the **body parsers**: the same bytes as an ordinary POST body reach it inside
  `json(req)`/`getjson(req)`, on any route, with no token. `getjson` answered `nothing` and the
  handler went on to serve a normal `200`.
- Through a **typed extractor**: a handler taking `body::Json{T}` resolves through the same
  parser, but `safe_extract` relabelled the failure a `ValidationError`, so the route answered
  `400 Bad Request`. Same body, same worker, a different verdict from the plain-`getjson`
  handler next to it.
- Through **any scalar path or query parameter**: `parseparam` tries `parse(T, str)` first and
  falls through to `JSON.parse(str, T)`, so `GET /items?count=[[[[…` overflows the stack on an
  `Int` parameter. That was also reported as `400`.
- Through **CSRF**: `CSRFMiddleware` looks for a token in the parsed body, so a protected POST
  with such a body answered `403`.

This change made all five propagate. [#314](https://github.com/PingoLee/Nitro.jl/issues/314)
then removed the input class itself: JSON nested deeper than 512 levels is rejected as malformed
before `JSON.parse` sees it, and `decode_jwt` caps the header segment at 1 KB and decodes the
claims only after the signature verifies. Each path above now gives such a request its ordinary
malformed-input answer, with no overflow; see that entry.

**An earlier version of this entry sized the auth path wrongly.** It said the token needed
~8.3 KB, so nginx's default `large_client_header_buffers` (8k) and Apache's
`LimitRequestFieldSize` (8190) refused it, and that browsers' 4 KB cookie cap put the
`CookieAuthMiddleware` variant out of reach. An *unclosed* `[[[[…` overflows in half the bytes
— 4,149 bytes of header, inside both proxies' defaults — and a hand-built request is not bound
by what a browser will store. Neither a proxy nor the cookie path stopped it.

[#45](https://github.com/PingoLee/Nitro.jl/issues/45) narrowed `decode_jwt`'s own catch so the
overflow stopped being *reported* as an encoding error; this change stops the layers above from
absorbing it.

### Where the 500 surfaces, and what it looks like

A `StackOverflowError` or `OutOfMemoryError` is handled the same way whether it is raised in
a **handler** (where `getjson` runs) or in **middleware** (where `BearerAuth` runs):
`handlerequest` catches it, logs `@error` with a backtrace, writes the access-log line, and
returns the standard `{"message": "500: Internal Server Error"}` body. The server keeps running
and the next request is served normally.

An `InterruptException` raised in middleware is not converted: it propagates out of the pipeline.
One raised in a handler still becomes an unlogged `500`, as it did before this change.

The middleware half depends on [#256](https://github.com/PingoLee/Nitro.jl/issues/256), which
ships in the same release. Before it, an exception escaping middleware skipped Nitro's error
handling entirely: HTTP.jl answered with a **bodyless `500` and no Nitro log line**. See that
entry for what else it changes.

### How to find the calls to migrate

Nothing in your app has to change for Nitro's own behavior to be correct. Look for three things:

```bash
# 1. Your own bare catches on the request path -- the same defect, in your code. A `catch`
#    with no exception variable catches StackOverflowError too.
rg -n 'catch\s*$' <app>/src

# 2. Code that treats "getjson returned nothing" as "the body was not JSON". That is still
#    true for malformed input -- and since #314 a too-deeply-nested body is malformed input.
rg -n 'getjson|json\(req' <app>/src

# 3. Custom validators handed to BearerAuth / CookieAuthMiddleware, if they wrap work in a
#    broad try of their own -- the narrowing only helps if yours is narrow too.
rg -n 'BearerAuth|CookieAuthMiddleware' <app>/src
```

### Migrate your app

```julia
# ✗ before -- a bare catch also absorbs a corrupted-state condition, and the request is
#             served as though the lookup had simply failed
user = try
    lookup_user(token)
catch
    nothing
end

# ✓ after -- name the failures you are handling; let the rest through
user = try
    lookup_user(token)
catch e
    e isa MyDBError || rethrow()
    nothing
end
```

If a route takes a typed extractor (`Json{T}`, `Body{T}`, a scalar `<int:…>` converter), there
is nothing to change. A body engineered to break the parser is, since #314, simply malformed
input there: a `400`, the same answer the route gives any other bad body.

If a handler relies on `getjson(req) === nothing` to mean "no usable body", it keeps working
for every malformed body, and since #314 that includes one nested deep enough to break an
unbounded parser.

A body-size cap (`serve(...; max_body_bytes = N)`) never closed this — 3 KB of `[[[[…` was
enough — which is why #314 bounds nesting depth instead of size.
