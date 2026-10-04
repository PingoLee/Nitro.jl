# Cross-origin protection: tokenless CSRF from Fetch Metadata

Design record for `CrossOriginProtection` (#437): why it exists alongside `CSRFMiddleware`, why it
copies Go 1.25's `net/http.CrossOriginProtection` instead of inventing its own rules, and the four
decisions the issue left open.

> **TL;DR:** a separate middleware, not a mode of `CSRFMiddleware`. It checks `Sec-Fetch-Site`,
> falls back to `Origin` against `Host`, lets through requests that carry neither header, and
> takes `trusted_origins` and `exempt_paths`. It reads the `Host` header, never
> `X-Forwarded-Host`, and it ignores the scheme. Each of those is Go's choice, kept on purpose.

## 1. Why a tokenless check

A CSRF token has to be bound to something, and in Nitro that is the session (#23). So handing a
visitor a token means storing a session for them. Lazy minting (#431) limits that cost to the
visitors who need a token, but the coupling stays. Every single-page app needs a bootstrap
endpoint, a refetch after login and logout, and a `403`-and-retry for when its session rotates
under it (#441). The token also has to be masked so a compressed response cannot leak it (#436).

Browsers have since added something better. `Sec-Fetch-Site` is sent on every request to a
potentially trustworthy URL (HTTPS, or localhost) by every current engine (Chromium since 76,
Firefox since 90, Safari since 16.4). Over plain HTTP to any host but localhost no browser sends it, so there the `Origin`
fallback in §2 is the whole check. Its name starts with `Sec-`, which is a
forbidden header name, so no page can set, change or remove it. It states exactly what CSRF
defence needs to know: did this request come from the server's own origin? A server that refuses
unsafe requests marked `cross-site` has CSRF protection with no token, no cookie and no session.

## 2. The decision: Go's semantics, check for check

| Step | Request | Outcome |
|---|---|---|
| 0 | Safe method (`GET`, `HEAD`, `OPTIONS`, `TRACE`) | pass |
| 1 | `Sec-Fetch-Site: same-origin` or `none` | pass |
| 1 | `Sec-Fetch-Site`, any other non-empty value | refuse, unless step 4 exempts it |
| 2 | No `Sec-Fetch-Site`; `Origin` host:port equals `Host` | pass |
| 2 | No `Sec-Fetch-Site`; `Origin` differs from `Host`, or does not parse | refuse, unless step 4 exempts it |
| 3 | Neither header | pass |
| 4 | `Origin` in `trusted_origins`, or the path in `exempt_paths` | pass |

Go is Nitro's concurrency lineage, and its `CrossOriginProtection` has shipped in the standard
library since 1.25. Matching it step for step
means there is one reference implementation to compare against, rather than a Nitro-specific
variant whose edge cases nobody else has reviewed. The one change is the safe-method set: Nitro
reuses `CSRFMiddleware`'s, which also counts `TRACE` as safe, so the two layers agree on what an
"unsafe request" is.

## 3. Separate middleware, not a mode of `CSRFMiddleware`

A mode (`CSRFMiddleware(secret; mode = :fetch_metadata)`) would let an app drop tokens with a
single keyword. It was rejected for three reasons:

- **The two checks share nothing.** One verifies an HMAC bound to a session; the other compares
  two request headers. A mode would put both behind one constructor, with keywords (`secret`,
  `cookie_name`, `ttl`) that mean nothing to one of them.
- **They compose.** Running both is defence in depth: the header check stops the request before
  the token check runs. As one layer, that combination would need a third mode.
- **No session dependency.** `CrossOriginProtection` needs no `SessionMiddleware`, so it can sit
  anywhere in the pipeline, including outside it. `CSRFMiddleware` cannot.

## 4. Old browsers: let them through

A browser that sends neither `Sec-Fetch-Site` nor `Origin` on an unsafe request is older than
anything still maintained. Go lets such requests through: refusing them would also refuse every
non-browser client (`curl`, a mobile app, a server-to-server call), and those carry no cookie a
browser attached on its own, which is the only thing CSRF borrows. Nitro keeps that.

The trade is real but small: a user on a browser old enough to send neither header gets no CSRF
protection from this layer. An app that must cover them keeps `CSRFMiddleware` next to it.

## 5. Trusted origins share the WebSocket parser

`trusted_origins` uses the strict serialized-origin parser that `WebSocketOrigins` uses
(`Types._parse_origin`, #382). Entries are canonicalized at construction (scheme and host
lowercased, port always explicit, IPv6 normalized) and matched by exact string equality. They are
never matched by prefix, suffix or pattern. `*`, `null`, a path, a trailing `/`, `ws(s)://` and a
non-ASCII host are each an `ArgumentError`, for the same reasons.

The lists themselves are not shared. `Cors.allowed_origins` decides which pages may *read*
responses, and `WebSocketOrigins` decides which may open a socket. Neither implies the other may
*mutate*, so the three stay separate, and an app writes the same origin in each when it means all
three.

Building this middleware exposed a defect in the shared parser: it case-folded the input for its
`null` check before refusing non-ASCII, so a malformed-UTF-8 `Origin` raised `InvalidCharError`
where the contract is a fail-closed "no". That is the #383 class, and it reached the WebSocket
handshake too. The `isascii` check now runs first.

## 6. Proxies: `Host` only, scheme ignored

The `Origin` fallback compares host and port with the **`Host` header**, never `X-Forwarded-Host`.
Nitro reads no forwarded host anywhere: `ExtractIP` trusts forwarded *addresses* and *schemes*
from listed proxies, and the WebSocket Origin check also reads `Host`. A proxy that rewrites
`Host` breaks both, and the fix is the same one-line proxy setting (`proxy_set_header Host
$host`), documented in `docs/src/tutorial/reverse_proxy.md`.

The scheme is not compared, as in Go: `Host` carries no scheme, and comparing it would need
`ExtractIP(forwarded_proto = …)` behind every TLS-terminating proxy for a check that only matters
on browsers too old to send `Sec-Fetch-Site`. A current browser never marks an `http://` page
posting to an `https://` server `same-origin`, so step 1 refuses it whatever the fallback ignores.

## 7. What is deliberately out of scope

- **Pattern-matched trusted origins** (`https://*.example.com`). Exact entries only, as for
  `WebSocketOrigins`. A wildcard over subdomains is the `same-site` hole this layer refuses.
- **Per-route opt-out other than `exempt_paths`.** With route-group middleware (#439), an app
  that wants the check on some routes only puts it on a group instead.
- **Reading `Referer`.** Go does not, and `Origin` supersedes it for every browser this fallback
  serves.
