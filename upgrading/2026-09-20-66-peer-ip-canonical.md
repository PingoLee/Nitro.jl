## `getip`/`getpeerip` report one canonical address per host (#66)

- **Version**: Unreleased
- **Nitro ref**: #66; `src/core/transport.jl`, `src/core/request.jl`,
  `src/middleware/extract_ip.jl`, `docs/src/tutorial/reverse_proxy.md`
- **Recorded**: 2026-09-20
- **Severity**: **behavior change** — the *value* `getip`/`getpeerip` return for a direct IPv4
  client on a dual-stack listener changes type and spelling. No API signature moves.

### What changed

On a dual-stack (AF_INET6) listener the OS reports an IPv4 client's address as an IPv4-mapped
IPv6 address, sixteen bytes in the `::ffff:0:0/96` block. Nitro used to hand that straight through:

```julia
getip(req)       # was: IPv6("::ffff:203.0.113.7")   → now: IPv4("203.0.113.7")
getpeerip(req)   # was: IPv6("::ffff:203.0.113.7")   → now: IPv4("203.0.113.7")
```

The same host arriving through a trusted proxy was already returned as `IPv4("203.0.113.7")`,
because `ExtractIP` canonicalizes an address it resolves out of a forwarding header. One host
therefore had two spellings depending on which path it took into the server. `serve` now demotes
the mapped form where it reads the socket (`_ipaddr_from_bytes`, `src/core/transport.jl`), so
both paths agree.

**Watch the rendering, not just the type.** Julia does not print a mapped address in dotted-quad
form — `string(IPv6("::ffff:203.0.113.7"))` is `"::ffff:cb00:7107"`, with the last four bytes in
hex. An access log written before this change therefore holds rows that do not contain the client's
address in any searchable form. That is the practical half of the fix, and it is also why grepping
old logs for the *old* spelling will not find them.

**Three things are deliberately unchanged:**

- **Rate-limit buckets.** `RateLimiter` already folded the mapped form itself, in `_bucket_key`
  via `_norm`, so no client's quota moves and no bucket splits or merges.
- **`ExtractIP` still never rewrites the peer.** It did not before and does not now; the
  canonicalization happens one layer below it, at the transport boundary. `ExtractIP()` with no
  trust configured remains a value pass-through, and `getip(req) == getpeerip(req)` still holds
  whenever no forwarding header was read.
- **The deprecated IPv4-*compatible* form** (`::a.b.c.d`, without the `ffff`) is **not** demoted.
  It is not a reliable indicator of an IPv4 peer, which is the same position `_norm` has always
  taken for trusted-proxy matching.

Applications that never ran on a dual-stack listener, or that already normalized the value
themselves, see no difference.

### How to find the calls to migrate

```bash
# Every place the app reads a client address. Anything that stores, compares, or keys off
# one of these may be holding the old spelling somewhere.
rg -n 'getip\(|getpeerip\(' <app>/src

# Code that assumes a concrete address TYPE — this is what breaks loudly rather than quietly.
rg -n 'IPv6|IPv4|::IPAddr|isa IPv[46]' <app>/src

# Hard-coded mapped literals. Search the whole app, not just src/: the hex rendering Julia
# actually emits (`::ffff:cb00:7107`) is what landed in stored logs and fixtures.
rg -n '::ffff:' <app>
```

Two places hold state that the grep cannot reach, and both are migrations rather than code edits:

- **Stored access-log rows and any IP column** written before this change keep the old spelling.
  Joining old rows to new ones on the address will not match for affected clients.
- **IP allow/deny lists** persisted with a mapped literal stop matching the peer. Rewrite the
  entry in plain IPv4 form; note that `trusted_proxies` itself was never affected, since
  `_is_trusted` has always matched across the two spellings.

### Migrate your app

```julia
# ✗ before — a type assertion that held only because the listener was dual-stack
peer::IPv6 = getpeerip(req)

# ✓ after — the address family follows the client. Note `getpeerip` is declared
#   Union{IPAddr, Nothing}, so an annotation still has to admit the `nothing`.
peer::Union{IPAddr, Nothing} = getpeerip(req)

# ✗ before — comparing against the spelling the OS happened to report
getip(req) == IPv6("::ffff:203.0.113.7")

# ✓ after — one spelling per host, whichever path it took into the server
getip(req) == IPv4("203.0.113.7")
```

If you were normalizing the value yourself on the way into a log or a bucket key, that code is now
redundant but harmless — demoting an already-demoted address is a no-op.
