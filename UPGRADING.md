# Upgrading Nitro — consumer-app rollout log

Tracks **breaking / behavior changes in Nitro** that require source-code changes in the applications
that depend on it. Nitro is pre-publish (single maintainer, no external users), so breaking changes
are intentional and cheap on the *Nitro* side — but each one still has to be rolled out by hand in
every consuming app. This file is that rollout checklist.

> 🚀 **Upgrading an app? Don't read this file top to bottom.** Run
> `Nitro.upgrade_guide(from = v"<your pinned version>")` — it renders only the entries newer than
> your pin, newest-first. The full how-to (versioning model, the apply recipe, driving it with an AI
> agent) lives in the docs: **[Upgrading Nitro](https://pingolee.github.io/Nitro.jl/dev/upgrading/)**.
> This file is the change log those tools read; the sections below are the rules for *writing* an
> entry.

## Writing an entry

- One `##` entry per breaking change, **newest first**. New entries land in **`## Unreleased`** with
  `- **Version**: Unreleased` and **no `Project.toml` bump**; the maintainer stamps them with a
  release number when cutting a train (`nitro-cut-release`).
- Each entry records: the Nitro **version** it shipped in, what changed, why, a *"How to find the
  calls to migrate"* grep, and the concrete **before → after** code edit.
- **Not for additive features.** This log is only what **forces** an app edit. A new opt-in
  capability (middleware, extractor, kwarg, function) requires no change to keep an app working →
  document it in `docs/`, not here.
- **No per-entry rollout tables.** An app's own Nitro dependency pin *is* its rollout state, and
  `upgrade_guide(from = <that pin>)` derives what it still needs — so there is nothing to maintain
  per app.
- **Keep the prose version-neutral.** Write *"part of the `0.1.x` pre-publish wave"*, never *"part of
  the current `## Unreleased` wave"* — stamping rewrites the `- **Version**:` bullet, not the body,
  so self-referential prose ships stale.
- Entries are version-stamped from **`0.1.0`** onward. `0.1.0` is the baseline of the release-train
  policy: earlier `Project.toml` numbers (`0.2.0`–`0.4.0`) and their tags predate it and were
  reclaimed, so nothing below `0.1.0` exists to port from.

---

## Unreleased — next `0.2.0`

_Changes merged but not yet cut into a release. A consumer dev'ing Nitro at HEAD is running these,
and `Nitro.upgrade_guide` surfaces them by default. When the maintainer next rolls changes into a
consuming app, `nitro-cut-release` stamps every entry below with `0.2.0`, dates them, and tags it._

## Global middleware now runs on unmatched (404) and method-mismatched (405) requests (#71)

- **Version**: Unreleased

Global middleware — the `middleware=[...]` vector passed to `serve` — now runs on **every**
request, including ones that match no route (404) and ones whose path matches but whose method
does not (405).

Previously this depended on something unrelated: `compose` was only installed when the app had
registered at least one route with per-route `middleware=`, and `compose`'s unmatched branch
called the inner handler directly, skipping the global chain. So an app **with** per-route
middleware silently exempted 404s and 405s from all global middleware, while an app **without**
any ran it on them. The two are now consistent, matching what the routing docs already described.

**Who this affects.** Only apps that use per-route middleware *and* global middleware. If your
global middleware assumed it only ever saw matched routes, it now also sees unmatched ones:

- an auth middleware that rejects unauthenticated requests will return **401 instead of 404** for
  unknown paths;
- a session middleware will create a session and emit `Set-Cookie` on 404 responses;
- a rate limiter will now count unmatched requests — this is usually the point, since it closes a
  bypass where 404 probes were never limited.

**How to find the calls to migrate**

```bash
rg -n 'serve\(' --glob '*.jl' -A5 | rg 'middleware\s*='
```

For each global middleware in those vectors, ask whether it is correct for a request that matches
no route. Nitro's own middleware needs no change.

**Before → after** — a global auth middleware that should not turn unknown paths into 401s.
Scope it to the subtree it actually guards:

```julia
# before — fine only while unmatched requests never reached it
auth = handler -> function (req)
    isauthenticated(req) || return json(Dict("error" => "unauthorized"); status = 401)
    return handler(req)
end

# after — guard the paths it owns; everything else falls through to the router
auth = handler -> function (req)
    if startswith(req.target, "/api/") && !isauthenticated(req)
        return json(Dict("error" => "unauthorized"); status = 401)
    end
    return handler(req)
end
```

Alternatively, move it off the global list and attach it per route with
`path(...; middleware = [GuardMiddleware(login_required())])`, which never sees unmatched
requests at all.

## Scalar path & query params reject bad input with 400; `Nullable{T}` params bind their value (#18)

- **Version**: Unreleased
- **Nitro ref**: #18; `src/utilities/misc.jl`, `src/core.jl`, `src/extractors.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior (status codes + optional-param binding)** — bug fix.

### What changed

Nitro had two binding paths that disagreed about whose fault a bad request is. Extractors
(`Json{T}`, `Query{T}`, `Path{T}`, …) routed every failure through a guard that produced a clean
`400`. Plain scalar parameters — `function get_user(req, id::Int)` — called `parseparam` unguarded,
so client input errors escaped as **`500 Internal Server Error`** with a full stack trace logged per
request. Both halves are fixed:

- **Malformed scalar path or query values are now `400`.** `/users/abc` against `<int:id>`, an
  out-of-range `@enum`, an empty `Char` segment, an `Int` that overflows — all `400`, not `500`. The
  converter remains a *binding* declaration rather than a routing filter, so this is a `400` and not
  a `404`; a route-level pattern could not reject the overflow case anyway.
- **A required query parameter that was not sent is now `400`.** It was a `KeyError` → `500`. A
  parameter *with* a declared default is unaffected: absence still falls back to the default.
- **`parseparam(::Union, …)` throws instead of returning the raw string.** When no member type
  parsed, it returned the unparsed `String` — a value outside the declared type, which reached the
  handler and typically became a `MethodError` → `500`. It is now a `400`.
- **`Nullable{T}` scalar params bind the client's value.** `Base.uniontypes` puts `Nothing` first and
  `JSON.parse(str, Nothing)` succeeds for *any* valid JSON, so `Union{Nothing, Int}` matched
  `Nothing` before it ever tried `Int`: **`?cursor=5` bound `nothing`.** `Nothing` is no longer a
  parse target, and neither is `Missing`, which had the identical defect.
- **`JsonFragment{T}` returns `400` for a body it cannot read.** The fragment key lookup sat outside
  the extractor guard, so a body missing the key (`KeyError`) or one that is not a JSON object at
  all (`MethodError`) escaped as a `500` while every sibling extractor returned a `400`.
- **Rejected requests are no longer logged with a backtrace.** `handlerequest` logs a
  `ValidationError` at `@debug` and genuine faults still log at `@error` with the full trace. This
  also removes the per-request stack trace that extractor `400`s were emitting, which made a spray
  of malformed URLs a log-flood vector. The `@debug` line deliberately does **not** include the
  `ValidationError` message: `try_validate` embeds a preview of the deserialized payload in it, so
  logging it would put a submitted password in the log.

The `400` response body is unchanged: the generic `{"message": "400: Bad Request"}`.

### How to find the calls to migrate

```bash
# Handlers with optional scalar path/query params — the silent half
rg -n 'Nullable\{|Union\{[^}]*Nothing' <app>/src

# Your own tests, and any client retry policy, asserting 5xx on bad input
rg -n '== 500|status.*500' <app>/test
```

The `Nullable{T}` change is the one that needs eyes. Nothing breaks at load time and nothing throws:
a handler that branched on `isnothing(cursor)` simply starts taking the other branch, because it now
receives the value the client actually sent. Read each hit and confirm the "absent" branch is still
what you want for a *present* value.

**One `Nullable{T}` case flips from `200` to `400`: a literal `?cursor=null`.** It used to be
absorbed by the `Nothing` member and bound `nothing`; now no member type accepts it. A JavaScript
client building `` `?cursor=${cursor}` `` with a null value emits exactly that string — omit the
parameter instead of sending `null`. (`?cursor=` with an empty value was already broken: it bound
the raw `""` and then `MethodError`'d into a `500`. It is now a clean `400`.)

### Migrate your app

```julia
# ✗ before — `?cursor=5` bound `nothing`, so this always took the first-page branch
function list_items(req, cursor::Nullable{Int} = nothing)
    return isnothing(cursor) ? first_page() : after(cursor)   # `after` was unreachable
end

# ✓ after — `?cursor=5` binds 5; absent still binds nothing; `?cursor=abc` is a 400
#   No source change is required, but verify the branch is correct now that both are reachable.

# ✗ before — a required query param that was not sent produced a 500
function search(req, q::String, limit::Int) ... end
# GET /search?q=chair   ->  500

# ✓ after
# GET /search?q=chair   ->  400   ... or give `limit` a default to make it genuinely optional:
function search(req, q::String, limit::Int = 20) ... end
```

If an app depends on the old status codes — an integration test asserting `500`, or an HTTP client
whose retry policy fires on 5xx and not 4xx — update it. Bad input now reports as bad input.

## `ExtractIP` trust model rebuilt; `trust_forwarded` removed (#16)

- **Version**: Unreleased
- **Nitro ref**: #16; `src/middleware/extract_ip.jl`, `src/middleware/rate_limiter.jl`, `src/core.jl`
- **Recorded**: 2026-08-03
- **Severity**: **breaking (removed kwarg + changed resolution)** — security fix.

### What changed

Under `trusted_proxies`, the configuration the old docstring called "the recommended, safe option",
the resolved client IP was attacker-controllable. Two defects: `X-Forwarded-For` was read
**leftmost-first** — the client-controlled end of the chain, so a client that prepended
`X-Forwarded-For: 9.9.9.9` before nginx appended the real address won outright — and
`CF-Connecting-IP`/`True-Client-IP` were honored *above* `X-Forwarded-For` unconditionally, which
no ordinary nginx config strips. Either header could be rotated to mint an unlimited number of
rate-limit buckets, forge access-log entries, and slip past IP allow/deny lists.

The trust model is now declarative. `ExtractIP` reads **exactly one** header, named by the
operator, and only when the socket peer is a listed proxy:

- `forwarded_header::Symbol` — `:none` (default), `:x_forwarded_for`, `:x_real_ip`,
  `:cf_connecting_ip`, `:true_client_ip`. It and `trusted_proxies` are strictly
  mutually-required; setting either alone is an `ArgumentError` at construction.
- `trusted_proxies` now accepts **CIDR strings** (`"10.244.0.0/16"`, `"2400:cb00::/32"`) mixed
  with `IPAddr` values, so k8s ingress pods and published CDN ranges are expressible. A catch-all
  range is rejected.
- `X-Forwarded-For` is walked **right-to-left**, peeling hops that match `trusted_proxies`; the
  first address that is not one of yours is the client. Unreadable chains, all-proxy chains and
  absent headers fall back to the socket peer.
- A header sent on **several lines** is treated as one value, joined in order per RFC 9110 §5.3,
  so a client-supplied line cannot shadow the one a proxy appended. This matters for proxies that
  append a new header line rather than rewriting (HAProxy's `option forwardfor`).
- Addresses resolved out of a header are returned in canonical form, so `::ffff:203.0.113.7` and
  `203.0.113.7` no longer key two different rate-limit buckets.
- `trust_forwarded` is **removed**. It trusted headers from any peer and guessed which header to
  read; passing it now throws with a message naming the replacement — on `RateLimiter` as well as
  on `ExtractIP`.
- On `RateLimiter`, `auto_extract_ip = false` is now **incompatible** with `forwarded_header` /
  `trusted_proxies` and throws. That combination built no `ExtractIP` at all, so both keywords
  were accepted, never validated, and had no effect: every client stayed in the proxy's single
  bucket while the configuration read as active. Set the IP yourself in your own middleware, or
  keep `auto_extract_ip = true` and let the limiter apply them.
- `RateLimiter` also validates the pair **itself** now, rather than deferring to the `ExtractIP`
  it composes — a bad trust configuration fails at `RateLimiter(...)`, not later at `serve()`.
- `extract_ip` returns `Union{IPAddr, Nothing}` — it previously declared `::IPAddr` while being
  able to return `nothing` for a request that never went through the server.
- New: `getpeerip(req)` returns the socket peer, preserved by `ExtractIP` before it overwrites
  `getip(req)`. No forwarding header can change it.

`ExtractIP()` with no arguments is unchanged and still the safe default: the socket peer is used
and no forwarding header is read.

### How to find the calls to migrate

```bash
rg -n 'trust_forwarded|trusted_proxies|extract_ip' <app>     # not just <app>/src — proxy trust
                                                             # is often set in config/ or env wiring
```

Every `ExtractIP`/`RateLimiter` hit needs a `forwarded_header` alongside it, and a configuration
missing one will not start — the `ArgumentError` names the absent keyword — so those call sites
cannot fail silently.

**`extract_ip` is the exception, and it is why the grep includes it.** It is now a public export
and its return type widened from `IPAddr` to `Union{IPAddr, Nothing}`. A direct call such as
`ip::IPAddr = extract_ip(req)` or `string(extract_ip(req))` breaks at runtime, and a bare
`extract_ip(req)` with no trust configured keeps returning the peer exactly as before — so this
one *does* have a silent path. Check every direct call for a `nothing` it did not previously have
to handle.

### Migrate your app

```julia
# ✗ before — the header was guessed from a fixed priority list
ExtractIP(trusted_proxies = [ip"127.0.0.1"])

# ✓ after — declare the one header your proxy writes
ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = [ip"127.0.0.1"])

# ✗ before — trusted forwarding headers from ANY peer
ExtractIP(trust_forwarded = true)

# ✓ after — name the proxies instead; CIDR covers dynamic addresses
ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = ["10.244.0.0/16"])

# ✗ before — same two kwargs on the rate limiter
RateLimiter(rate_limit = 100, trusted_proxies = [ip"127.0.0.1"])

# ✓ after
RateLimiter(rate_limit = 100,
            forwarded_header = :x_forwarded_for,
            trusted_proxies  = [ip"127.0.0.1"])
```

Two operational notes. Your proxy must **set** the header it writes, not forward a client-supplied
value — `proxy_set_header X-Real-IP $remote_addr`, not a pass-through — because single-valued
headers are believed as written. And if you were relying on a vendor header while declaring
`X-Forwarded-For`, that now resolves differently: only the declared header is read, which is the
point of the fix.

---

## 0.1.0 — 2026-07-31

## `jwt_validator` returns a `Principal`, not the raw claims object (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46, #4; `src/Auth/`, `src/middleware/`, `docs/src/tutorial/authentication.md`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (return type)** — part of the `0.1.x` claim-based identity wave.

### What changed

`jwt_validator` used without a `user_validator` set `req.user` to the decoded claims object, so apps
reached into it with property sugar (`req.user.sub`) and sometimes mutated it. It now yields a
`Principal`: an immutable, dict-like wrapper over the *verified* claims with typed fields `id`
(normalized identity), `kid` (keyset-verified key id) and `source` (`:claim` / `:kid`).

Dict-style **reads** are unchanged — `user["sub"]`, `get`, `haskey`, iteration, `==`, and the JSON
serialization (which is exactly the claims object) all behave as before. Only property access and
mutation break.

### How to find the calls to migrate

```bash
rg -n 'user\.[a-z_]+' <app>/src        # property sugar on req.user
rg -n 'req\.user\[[^]]+\]\s*='  <app>/src   # mutation of req.user
```

`.id`, `.claims`, `.kid` and `.source` are the only valid properties; every other `req.user.<name>`
is a claim read that must become an index.

### Migrate your app

```julia
# ✗ before — property sugar over the claims object
subject = req.user.sub
email   = req.user.email

# ✓ after — index the Principal
subject = req.user["sub"]
email   = req.user["email"]
# or use the normalized identity field
subject = req.user.id

# ✗ before — mutating the claims in place
req.user["tenant"] = tenant_id

# ✓ after — the Principal is immutable; build your own user object in a
# user_validator, or copy out of it
u = Dict(req.user)
u["tenant"] = tenant_id
```

---

## `user_validator` receives the `Principal`; the tuple contract is `(user, principal)` (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46; `src/Auth/`, `src/middleware/`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (callback argument + context key)** — part of the `0.1.x` claim-based
  identity wave.

### What changed

A `user_validator` used to be handed the raw claims dict, and a validator returning a tuple returned
`(user, claims)`. It now receives the `Principal` — a dict-compatible superset of the old argument —
and the tuple contract is `(user, principal)`. Consequently `req.context[:auth_claims]` now holds
the `Principal` rather than a raw claims dict.

Because `Principal` supports the same dict reads, a validator that only *indexes* its argument keeps
working untouched. What breaks is a validator that treats the argument as a mutable `Dict`, calls
`Dict`-only methods on it, or annotates the parameter with `::Dict`.

### How to find the calls to migrate

```bash
rg -n 'user_validator' <app>/src
rg -n 'auth_claims' <app>/src
```

Then check each validator body for `::Dict` annotations, `setindex!`/`push!`/`delete!` on the
argument, and any downstream code that reads `req.context[:auth_claims]` expecting a plain dict.

### Migrate your app

```julia
# ✗ before — annotated and mutated as a Dict
function load_user(claims::Dict)
    claims["seen_at"] = now()
    return (fetch_user(claims["sub"]), claims)
end

# ✓ after — accept the Principal, copy before mutating, return (user, principal)
function load_user(principal)
    user = fetch_user(principal["sub"])   # or principal.id
    return (user, principal)
end

# ✗ before — downstream consumer assumed a dict
claims = req.context[:auth_claims]
claims["extra"] = 1

# ✓ after — it is a Principal; copy out if you need a mutable dict
principal = req.context[:auth_claims]
claims = Dict(principal)
claims["extra"] = 1
```

---

## `jwt_validator(...; with_kid=...)` is now a construction-time `ArgumentError` (#46)

- **Version**: 0.1.0
- **Nitro ref**: #46; `src/Auth/`
- **Recorded**: 2026-07-31
- **Severity**: **breaking (removed kwarg)** — part of the `0.1.x` claim-based identity wave.

### What changed

`with_kid` existed to opt into surfacing the token's key id. The kid now always flows through the
`Principal` (`req.user.kid`, populated only when the key id was *verified* against a keyset), so the
kwarg is redundant and is rejected at construction time rather than silently ignored. Passing it
throws an `ArgumentError` when the validator is built — at bootstrap, not per-request.

Note the tightened trust rule that comes with it: only a keyset-verified kid is exposed. A `kid`
header on a single-secret token is never trusted and leaves `req.user.kid` unset.

### How to find the calls to migrate

```bash
rg -n 'with_kid' <app>/src
```

### Migrate your app

```julia
# ✗ before
validator = jwt_validator(keyset = ks, with_kid = true)

# ✓ after — drop the kwarg; read the verified kid off the Principal
validator = jwt_validator(keyset = ks)

# in a handler or guard:
signing_key = req.user.kid          # nothing unless keyset-verified

# to authorize on it, prefer the declarative guard over a manual check
path("/admin", admin_handler, middleware = [kid_required(["ops-2026"])])
```

---

## Template for new entries

<!--
Copy the block below into the `## Unreleased` section at the top of the log for each new
breaking/behavior change. Do NOT bump `Project.toml` — the version moves once, at cut time
(the `nitro-cut-release` skill rewrites `Version: Unreleased` → the release number).

## `<api>` — <one-line summary of the change>

- **Version**: Unreleased
- **Nitro ref**: <issue / PR / commit> ; <src file>
- **Recorded**: <YYYY-MM-DD>
- **Severity**: breaking | behavior change | deprecation

### What changed
<what the old API did vs. the new contract>

### How to find the calls to migrate
<error message to grep for, or the call pattern>

### Migrate your app
```julia
# ✗ before
...
# ✓ after
...
```

-->
