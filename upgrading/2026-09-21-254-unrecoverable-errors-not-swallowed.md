## Auth middleware and body parsers — `InterruptException`, `StackOverflowError` and `OutOfMemoryError` are no longer swallowed

- **Version**: Unreleased
- **Nitro ref**: [#254](https://github.com/PingoLee/Nitro.jl/issues/254) ; `src/errors.jl`, `src/middleware/auth_middleware.jl`, `src/utilities/bodyparsers.jl`, `src/utilities/misc.jl`, `src/middleware/csrf_middleware.jl`, `src/middleware/extract_ip.jl`, `src/extractors.jl`
- **Recorded**: 2026-09-21
- **Severity**: **behavior change** — a request that returned `401` (auth), `403` (CSRF),
  `400` (typed extractors and scalar path/query parameters) or `200` with an empty parse
  result (body parsers) can now produce a `500`. Only for the three exception types named
  below; every other failure is unchanged.

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

**It is request-reachable, and one path needs no credentials at all.** `JSON.parse` raises
`StackOverflowError` on a deeply-nested value. Measured on a `Threads.@spawn` task — the stack
a real request runs on — the threshold is nesting depth ~3100, i.e. **~6.2 KB** of `[[[[…` as a
body or query string, and **~8.3 KB** once base64url-encoded into a JWT header segment:

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

All five now propagate.

**The auth path is the narrowest of them, and worth sizing before you panic about it.** At
~8.3 KB the `Authorization` header is above nginx's default `large_client_header_buffers` (8k)
and Apache's `LimitRequestFieldSize` (8190), so a default-configured reverse proxy refuses it;
the `CookieAuthMiddleware` variant cannot be reached at all, since browsers cap a cookie at
4 KB. Nitro served directly does accept it. The **body**, **scalar parameter** and **extractor**
paths need only ~6.2 KB and nothing gates those anywhere — they are the ones that matter in a
proxied deployment.

[#45](https://github.com/PingoLee/Nitro.jl/issues/45) narrowed `decode_jwt`'s own catch so the
overflow stopped being *reported* as an encoding error; this change stops the layers above from
absorbing it.

### Where the 500 surfaces, and what it looks like

The two paths differ, and it is worth knowing which you are looking at:

- From a **handler** (which is where `getjson` runs): `handlerequest` catches it, logs
  `@error` with a backtrace, writes the access-log line, and returns the standard
  `{"message": "500: Internal Server Error"}` body.
- From **middleware** (which is where `BearerAuth` runs): middleware sits outside
  `DefaultSerializer`, so the exception reaches HTTP.jl directly and the client gets a
  **bodyless `500` with no Nitro log line**. That gap is pre-existing and is tracked
  separately; it is not introduced here.

In both cases the server keeps running and the next request is served normally.

### How to find the calls to migrate

Nothing in your app has to change for Nitro's own behavior to be correct. Look for three things:

```bash
# 1. Your own bare catches on the request path -- the same defect, in your code. A `catch`
#    with no exception variable catches StackOverflowError too.
rg -n 'catch\s*$' <app>/src

# 2. Code that treats "getjson returned nothing" as "the body was not JSON". That is still
#    true for malformed input, but a hostile body now raises instead of landing here.
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
is nothing to change: it simply stops answering `400` for this one input class and answers
`500` instead, consistently with the untyped path.

If a handler relies on `getjson(req) === nothing` to mean "no usable body", it keeps working
for every malformed body. It no longer covers a body engineered to break the parser, which now
returns a `500` instead of running the handler — which is the point.

Rejecting such a body earlier is a size question, not a parse question: cap it with
`serve(...; max_body_bytes = N)`. A 20 KB body is well inside most caps, so a cap alone does
not close this.
