## Request JSON and JWT decoding — nesting is capped at 512 levels, the JWT header at 1 KB, and JWT claims wait for the signature

- **Version**: Unreleased
- **Nitro ref**: [#314](https://github.com/PingoLee/Nitro.jl/issues/314) ; `src/utilities/bodyparsers.jl`, `src/utilities/misc.jl`, `src/extractors.jl`, `src/Auth/jwt.jl`
- **Recorded**: 2026-09-24
- **Severity**: **behavior change** — JSON nested 513 or more levels deep, which used to parse, is
  now rejected as malformed on every request path. A JWT whose encoded header is over 1 KB is
  refused, and `decode_jwt(...; verify=true)` reports a forged token's malformed claims as a
  signature failure.

### What changed

JSON.jl parses by recursive descent and has no depth option, so the nesting of a request's JSON
was the depth of the parser's recursion. On the stack a request runs on, it overflowed at ~3,100
levels: ~3.1 KB of unclosed `[[[[…` as a body or query string, or a **4,149-byte** bearer token,
inside nginx's and Apache's default header limits. Julia reports a stack overflow as *"program
state may be corrupted"*, and on some Windows hosts the process dies outright
([#301](https://github.com/PingoLee/Nitro.jl/issues/301)). Catching it could not be made safe,
so Nitro now stops the input from getting there:

1. **Every JSON parse of request data is depth-bounded.** A document nesting arrays and objects
   deeper than **512** levels is rejected *as malformed JSON* before the parser sees it. That
   covers `getjson`/`json(req)`, the `Json{T}`, `JsonFragment{T}` and `Body{T}` extractors, a
   path or query parameter that falls through to a JSON parse, and every JWT segment. The limit
   is fixed; there is no setting.
2. **`decode_jwt` caps the encoded header segment at 1024 bytes**, on both `verify` paths.
   Nitro's own header is under 100 bytes. `encode_jwt` refuses to mint a longer one.
3. **`decode_jwt` decodes the claims only after the signature verifies** (RFC 7519 §7.2). An
   unsigned or forged token now reaches exactly one JSON parse, of its capped header.

Each path gives a too-deep document the answer it already gave malformed JSON:

| Input | Before | Now |
|---|---|---|
| JSON nested 513 to ~3,000 levels, via `getjson(req)` / `json(req)` | parsed | `nothing` |
| … via `Json{T}`, `JsonFragment{T}`, `Body{T}`, a JSON-parsed path/query parameter | bound | `400 Bad Request` |
| … via `json(req, T)` | parsed | throws `ArgumentError` |
| … as the `CSRFMiddleware` JSON-body token | presented | not presented, so `403` unless sent in the header or a form field |
| JSON deep enough to overflow (~3,100+ levels), any path | `StackOverflowError` | the rows above, with no overflow |
| JWT with an encoded header segment over 1024 bytes | decoded | `AuthError("Invalid JWT header: longer than 1024 bytes")`; `401` through `BearerAuth`/`CookieAuthMiddleware` |
| `decode_jwt(t, key)` (`verify=true`), forged token with a malformed claims segment | `AuthError("Invalid JWT claims")` or `("Invalid JWT encoding")` | the header or signature check that fails first — `AuthError("Invalid JWT signature")` for a single key, `("No key in the JWT keyset verified this token")` for a kid-less token against several |
| `json(res::HTTP.Response)` / `json(res, T)` on a body nested past 512 levels | parsed | `nothing` / throws `ArgumentError`, like the request parsers |
| `encode_jwt` with a keyset `kid` of ~730+ characters | minted | `ArgumentError` |

Through `BearerAuth`/`CookieAuthMiddleware`, the header cap is the JWT row that changes an
answer: a validly signed token whose encoded header is over 1 KB used to authenticate and is now
a `401` (so is one whose claims nest past 512 levels, which no real issuer produces). The
forged-claims row was a `401` there before and still is; only a direct `decode_jwt` caller sees
its message change. The [#254](https://github.com/PingoLee/Nitro.jl/issues/254)
entry describes deep JSON reaching a `500`; with this change it never does.

### How to find the calls to migrate

```bash
# 1. Routes that accept JSON. Does any client send documents nested more than 512 levels deep?
#    Real payloads rarely pass 20; recursive trees (comment threads, ASTs, org charts) are the
#    ones to check.
rg -n 'getjson|json\(req|Json\{|JsonFragment\{|Body\{' <app>/src

# 2. Code or tests matching decode_jwt's messages. A forged-token fixture that expected
#    "Invalid JWT claims" or "Invalid JWT encoding" now gets the signature (or key) failure.
rg -n 'Invalid JWT (encoding|claims)' <app>/src <app>/test

# 3. Offline inspection of foreign tokens -- the likeliest way to meet the 1 KB header cap,
#    since another issuer's header can carry a certificate chain (`x5c`) or a key (`jwk`).
rg -n 'verify\s*=\s*false' <app>/src

# 4. Keysets whose kid could push the header past 1 KB.
rg -n 'JWTKeyset\(' <app>/src
```

### Migrate your app

A test that checks claims handling needs a token that verifies, or an offline decode:

```julia
# ✗ before -- a forged token, expecting the claims check to fire
@test_throws "Invalid JWT claims" decode_jwt(forged_token, secret)

# ✓ after -- the signature is checked first; decode offline to reach the claims check
@test_throws "Invalid JWT claims" decode_jwt(forged_token, secret; verify = false)
```

A payload that legitimately nests past 512 levels has to be sent flatter, because the limit
cannot be raised:

```julia
# ✗ before -- a tree sent as nested children, any depth
body = Dict("id" => 1, "children" => [Dict("id" => 2, "children" => [#= … =#])])

# ✓ after -- a flat list with parent links, rebuilt by the handler
body = [Dict("id" => 1, "parent" => nothing), Dict("id" => 2, "parent" => 1) #= , … =#]
```
