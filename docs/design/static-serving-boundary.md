# Static serving: where the boundary between Nitro and a reverse proxy falls

Design record for what Nitro's file-mounting layer is responsible for, what it deliberately is not,
and why static assets, TLS, and transport-level limits belong to nginx/Caddy rather than to
application code.

> **TL;DR for Nitro contributors:** `staticfiles`, `spafiles` and `dynamicfiles` are a **development
> convenience with a safe floor**, not a production asset pipeline. They must stay safe by default —
> the API is exported, and dev machines have no proxy — but they will not grow filesystem-semantics
> features to chase edge cases a real web server already solved. Concretely: mount-time checks are
> in scope; per-request re-validation, symlinked-directory traversal, byte-range serving,
> compression, and cache negotiation are not. Production serves assets from the proxy.

## 1. The decision

| Concern | Owner | Rationale |
|---|---|---|
| TLS termination, certificate lifecycle | **Proxy** | Nitro has no TLS story and should not acquire one. Caddy does ACME automatically |
| Static assets in production | **Proxy** | `sendfile`, cache headers, compression, byte ranges, conditional GETs — none of which Nitro implements |
| SPA history-mode fallback in production | **Proxy** | `try_files $uri /index.html` is one directive |
| Request body size caps | **Proxy first**, app second | Rejecting before the request reaches Julia is strictly better; the app still needs its own (see [#41](https://github.com/PingoLee/Nitro.jl/issues/41), [#17](https://github.com/PingoLee/Nitro.jl/issues/17)) |
| Slow-client / connection timeouts | **Proxy** | See §4 — this one is load-bearing for Nitro's concurrency model |
| Coarse per-IP rate limiting | **Proxy** | Cheaper, and upstream of the Julia process |
| Per-user / per-key rate limiting | **App** | Needs identity, which the proxy does not have |
| Real client IP | **Both** | Proxy sets the header, app trusts it *only* from declared proxies — see [`docs/src/tutorial/reverse_proxy.md`](../src/tutorial/reverse_proxy.md) |
| **Authentication and authorization** | **App, always** | §3 |
| CSRF, sessions | **App, always** | Requires server-side state |
| Static serving in development | **App** | There is no proxy on a laptop, and this is the case the safe floor exists for |

## 2. Why: the evidence from issue #20

[#20](https://github.com/PingoLee/Nitro.jl/issues/20) reported that mounts served `.git/`, `.env`,
and symlinks pointing outside the mounted folder. Fixing it properly required, in one change:

- dotfile refusal by path component *relative to the mount root* (an absolute test breaks any project
  living under a dot-directory)
- symlink confinement by `realpath`, compared **component-wise** — a string prefix makes `/srv/app`
  appear to contain `/srv/app-secrets`
- a special case for Windows UNC share roots, which `splitpath` spells two different ways depending
  on whether the root stands alone
- rejecting `relpath`-based containment outright, because on Windows `relpath("D:/x", "C:/y")` has no
  `..` component and the check fails **open** across drives
- resolving both sides through `realpath`, because macOS `mktempdir()` returns `/var/folders/…` while
  `/var` is a symlink to `/private/var`
- treating Windows directory junctions as links (`walkdir` classifies every link as a *file*, so a
  symlinked directory would otherwise register a route whose target is a directory and crash the
  mount at startup)
- refusing FIFOs, sockets and devices for the same reason
- refusing filenames the router reads as patterns — `*`/`**` shadow sibling URLs, and a `{`/`}` name
  is parsed as a path parameter and throws at registration, taking `serve()` down with it
- applying the dotfile rule to a symlink's **target** as well as its name, or `innocent.txt -> .env`
  walks straight through it

Two independent review passes were needed. The first found the UNC failure; the second found the
`innocent.txt -> .env` bypass — in code that already had tests and had been read carefully. That bug
density is the argument. nginx expresses most of this as `location ~ /\. { deny all; }` and
`disable_symlinks on;`, backed by two decades of adversarial exposure.

**This is on-lineage, not a departure.** [`nitro-general.instructions.md`](../../.github/instructions/nitro-general.instructions.md)
names Django as the tradition for routing, sessions and project layout — and Django settled this
question years ago. `django.views.static.serve` is documented as not hardened for production, and the
`static()` URL helper returns no patterns when `DEBUG=False`. Nitro borrowed the *name* `staticfiles`
from `django.contrib.staticfiles`, whose entire purpose is collecting assets to hand to a real web
server.

## 3. What cannot move to the proxy

A reverse proxy sees a URL, headers, and a peer address. It does not know whether the authenticated
caller owns the row being requested. So these stay in application code permanently, and no proxy
configuration substitutes for them:

- `login_required`, `role_required`, `permission_required`, `claim_required`, `kid_required`
- **object-level authorization** — the IDOR class. A handler that loads a record by client-supplied
  id must verify ownership; a proxy cannot
- CSRF token validation, session issuance and rotation
- Worker task authorization (`user_id` on submit/status/cancel)

"Offload security boundaries to the proxy" is correct for *transport* boundaries and wrong for
*authorization* ones. Path-based proxy rules (`location /admin/ { allow 10.0.0.0/8; }`) are a useful
second layer and a dangerous only layer — they are ordered, prefix-matched, and silently bypassed the
moment the app port is reachable directly.

## 4. Why this matters more for Nitro than for a typical framework

Nitro is Go-shaped: every request runs on `Threads.@spawn`, with no event loop. A slow client
therefore occupies a **thread**, not a cheap continuation. nginx buffers request and response bodies
by default (`proxy_request_buffering on`), so Nitro sees only complete requests and hands off
complete responses — the proxy absorbs the slow-client cost that would otherwise sit in Nitro's
thread pool.

Two consequences worth stating:

- Slowloris-style exhaustion is a *concurrency-model* problem here, not just a bandwidth one. The
  proxy is the correct mitigation.
- `staticfiles` reads every mounted file into memory at startup and holds it for process lifetime.
  For a real SPA `dist/` that is resident RAM with no `sendfile`, no ranges, and no conditional GETs.
  This is acceptable for development and wasteful in production.

## 5. What the app layer keeps, and why there is a floor at all

The tempting conclusion — "the proxy handles it, so the app needs nothing" — is wrong for three
reasons:

1. **The API is exported and documented.** Someone will call `staticfiles("public")` in production
   whatever the docs recommend. A shipped API is safe by default or it is a footgun.
2. **Development has no proxy**, and a project root during development is exactly where `.env` and
   `.git/` live. This is the reported case in #20.
3. **Proxy config is a separate artifact that drifts.** A `location` block edited wrong should not be
   the only thing between the internet and a credentials file.

So the floor is kept, chosen by **cost and completeness** — cheap, total checks stay; expensive,
partial ones do not:

| Check | Cost | Complete | Status |
|---|---|---|---|
| Dotfile refusal, by name | pure string | yes | **kept** |
| Dotfile refusal, by resolved target | `realpath` + `splitpath`, links only | **symlinks yes, hard links no** | **kept** — see the caveat below |
| Regular-file-only | one `stat` | yes | **kept** — also prevents a startup crash |
| Router-pattern filenames | pure string | yes | **kept** — also prevents a startup crash |
| Symlink containment (`_is_within`) | `realpath` on links only | **symlinks yes, hard links no** | **kept** |
| Per-request re-validation | `realpath` + `stat` + allocation **per request** | **no** | **removed** — see §6 |

**The hard-link caveat is not hypothetical.** A hard link inside the mount pointing at a dotfile is
served, contents and all: `islink` is false, so the resolved-target check never runs, and `realpath`
reports the in-mount path because that genuinely is where the inode lives. Nothing at this layer can
detect it. Note the asymmetry — on unprivileged Windows, where `symlink()` is unavailable and the
link-dependent tests go dark, `mklink /H` needs no privilege at all. So the *cheapest* bypass works
precisely where the *coverage* is thinnest.

This is a floor for the accidental case — a `.env` sitting in a project root that someone mounted —
not a boundary against an adversary who can write into the served directory. For that, see §6.

## 6. Removed on purpose: the per-request re-check

An earlier revision of the #20 fix re-validated on every `dynamicfiles` request and on every SPA
fallback request, to catch a file swapped for a symlink after startup. It was removed before landing.

It could not close the race it targeted: the check resolves the path, and `Res.file()` then re-opens the
**unresolved** path, so a swap landing between the two is still followed. A hard link to an outside
file is undetectable regardless, because the resolved path genuinely is inside the mount. Meanwhile
it cost a `realpath`, a `stat`, and a `splitpath` allocation on every request to a `dynamicfiles`
route or the SPA fallback — `staticfiles` and `spafiles`' enumerated routes never had it, since their
bytes are captured at mount.

The threat it addressed — *an attacker can write to the directory you are serving* — is real, and a
partial in-app mitigation is the wrong response to it. The right responses are: serve that directory
from the proxy, or do not serve it. Anything else invites treating a hardened-but-unsealed path as
safe.

**Consequence to accept:** a file deleted after startup now produces a `500` from the failed read
rather than a `404`. That is the pre-#20 behavior, not a regression introduced here. A bare `isfile`
guard would fix it for one `stat` and no allocation — a reasonable follow-up, but it is an
error-handling improvement, not a security control, and should be argued on those terms.

## 7. Non-goals

Not planned, and a PR adding one should cite this section or change it:

- Byte-range requests, ETag/`If-None-Match`, `Last-Modified` negotiation, on-the-fly compression
- Traversing symlinked directories inside a mount (needs a custom walk with cycle detection)
- Serving files created after startup — mounts register a snapshot; use a handler
- ACME `http-01` support. `.well-known/acme-challenge/<token>` is written at renewal time, long after
  boot, so no mount can serve it. Caddy handles ACME internally; nginx needs a webroot location
- Any per-request filesystem re-validation (§6)

## 8. Mount paths are segments, not strings

`mountdir` is canonicalized once, by `Nitro.Core.Util.mount_segments`, into a `Vector{String}` of
path segments; routes are rebuilt from it with `mount_route` by **joining**, never by interpolating a
prefix into `"/$prefix/$path"`. `staticfiles`, `spafiles` and `dynamicfiles` normalize nothing
themselves.

This replaced three separate string manipulations that produced two defects with one shared cause:

- Each mount function stripped a single leading `/` with `first(mountdir)`, which threw a
  `BoundsError` on `""` — a value everything downstream already understood as "mount at the root"
  ([#93](https://github.com/PingoLee/Nitro.jl/issues/93)).
- The bare directory route of an `index.html` was derived by stripping a `"/index.html"` suffix off
  the mount path, matching the **first** occurrence of that substring. Any directory whose name
  *starts with* `index.html`, at any depth, therefore hijacked the route above it — including a
  plausible `index.html.bak/`: `/assets/index.html.bak/index.html` yielded `/assets`, so
  `GET /assets` served a file from inside the backup directory
  ([#94](https://github.com/PingoLee/Nitro.jl/issues/94)).

Both are unrepresentable in segment form. The prefix is `["static"]` however many slashes or spaces
were typed, and the bare route is `segments[1:end-1]`, which cannot mismatch. That is also why the
root bare route is now spelled `"/"` rather than `""` — HTTP.jl's router splits with
`keepempty=false` and treats the two alike, so the empty string worked only by accident.

**The prior art is Phoenix's `Plug.Static`**, which canonicalizes its `at:` option into a segment
list in `init/1` and never rejoins by interpolation. Go's `net/http` and Express's `serve-static`
take a different route to the same place: they resolve the index per request from the directory and
redirect to one canonical URL, so neither ever derives a directory URL from a file URL. Nitro
registered a literal route per file at mount time, so the per-request resolution those two rely on
was not available here — canonical segments are the form that fits. Since §9 the per-request
resolution *is* available, but segments stayed: they are what `mount_remainder` counts to know how
much of the request path the prefix occupies, and a mount is still one canonicalized value rather
than a string that each function re-derives.

Note this changes no URL that a *reachable* mount already served. HTTP.jl's `register!` and its
request path both split on `/` with `keepempty=false`, so every slash-only spelling —
`/static//app.js` versus `/static/app.js`, `""` versus `"/"` — was already the same router node.

Three things changed **in #93/#94**, and none of them forced an app edit, which is why that pair
carried no upgrade-log entry. (The later validation rule below does force one — see
*Segments are validated, not only canonicalized*.)

1. **The strings `mountfolder` and the three mount functions return.** A root mount's bare route is
   now `"/"` rather than `""`, and no returned route carries a doubled separator.
2. **A whitespace-bearing `mountdir` (`" assets "`) now serves.** It used to register a segment no
   request could match — the router does not percent-decode, so a literal space is unreachable —
   making the mount dead on arrival. A dead mount coming alive can collide with an
   application-declared route at the same path, where HTTP.jl warns `replacing existing registered
   route` and the later registration wins. That is a latent misconfiguration surfacing rather than a
   regression, but it is a spelling whose *served* URLs differ.
3. **The hijacked route stops being served.** This is the point of the second bullet above: where a
   directory named `index.html*` existed, `GET /assets` served a file from inside it and now returns
   404, while that file becomes reachable at its own path. A URL on a reachable mount does change —
   but only one that was serving the wrong file, which is a shape no app can have intended, and the
   file it was serving is still available at the route it should always have had.

### Segments are validated, not only canonicalized

Canonicalization alone left `mountdir` exempt from the rule `mountable_files` has always applied to
filenames — *a mount may not claim URLs other than its own*. `staticfiles(dir, "*")` registered
`/*/<file>` and a bare `/*`, so `GET /anything` was answered by the mount. `**` and `{id}` threw at
registration; `*` came up clean, which is what made it worth closing
([#101](https://github.com/PingoLee/Nitro.jl/issues/101)). `mount_segments` now refuses a segment on
three grounds, in this order:

1. **It would register as a router pattern** — `*`, `**`, or a segment containing `{`/`}`. Checked
   first because `*` is a perfectly legal `pchar`, so the encoding test below would wave it through
   and, for a brace, would report the wrong cause.
2. **It is a relative dot-segment** — `.` or `..`. `.` is `unreserved`, so the encoding test also
   passes it, and RFC 3986 §5.2.4 dot-segment removal happens *in the client*: nothing that would
   match `/../x` is ever sent.
3. **It could not appear in a URL path unencoded** — anything outside RFC 3986 `pchar`
   (`unreserved / pct-encoded / sub-delims / ":" / "@"`).

Rule 3 is the one that changes the accepted behavior recorded in item 2 above. That item stands for
*surrounding* whitespace, which is stripped and was never part of the segment; an **interior** one
(`"my static"`) was accepted, unreachable, and silent — the mount registered, reported its routes,
and served nothing.

**Rule 3's cost is not uniform, and the honest version matters.** Driving HTTP.jl 2.4 over a socket
with hand-written request lines splits the refused set in two:

| Registered segment | Raw request | Result |
|---|---|---|
| `my static` | `/my static/x.txt` | 400 — a space cannot appear in a request line |
| `a?b` | `/a?b/x.txt` | 404 — the query is split off before matching |
| `café`, `a#b`, `a\|b`, `a[b]`, `a^b` | raw bytes | **200 — these were working mounts** |

So only space, `?` and control characters were *strictly* dead. The rest were reachable by any client
that sends raw bytes rather than percent-encoding — `curl` by default — and refusing them genuinely
takes that away. Nor is the encoded spelling a transparent migration: `caf%C3%A9` and raw `café` are
different byte strings, and matching is a byte comparison (the same fact the no-re-encoding rule above
depends on), so the encoded route does not answer the raw client.

The trade is still worth making — `mountdir` is judged by the same rule as a filename, and a prefix no
browser can reach is a footgun whatever a hand-rolled client can do with it — but it is a capability
change, not just a dead-mount cleanup, and the #101 upgrade-log entry says so.

**Validated, never re-encoded.** A percent triplet is checked for well-formedness and passed through
byte for byte. HTTP.jl matches path segments with a byte comparison rather than an RFC 3986
equivalence test, so case-normalizing `"%2f"` to `"%2F"`, or decoding unreserved triplets, would stop
matching the client that sends the other spelling.

`mountdir` is app-authored — a single value with an obvious correction — so it throws. Filenames are
not refused at all; they are **encoded**, which is the next sub-section.

### A filename is data; a mountdir is authored

#101 left the filename side of the encoding defect open on purpose, and
[#121](https://github.com/PingoLee/Nitro.jl/issues/121) closed it the other way round: a `mountdir`
segment that is not a legal URL path segment **throws**, while a *filename* that is not one is
**percent-encoded and served at the encoded route**. `café.txt` mounts at `/static/caf%C3%A9.txt`,
`my file.txt` at `/static/my%20file.txt`, and a directory named `sub dir/` is encoded the same way.

The four options were: leave it; warn; skip the file; or encode the route. Encoding is the only one
that *fixes* the case rather than reporting it, and it was only expressible after
[#102](https://github.com/PingoLee/Nitro.jl/issues/102) made `mountfolder` return `route => filepath`
pairs — before that the route and the filesystem name were the same string. Skipping was the
consistent-with-#101 option and was rejected: refusals at that layer *skip*, so a mount would boot
serving strictly less than before with no error, trading a route nobody can reach for a file nobody
can reach.

**The asymmetry is about the kind of input, not about strictness.** A `mountdir` is *authored*:
`"my%20static"` is someone spelling a space deliberately, so the triplet is validated and passed
through. A filename is *data*: a file named `my%20file.txt` contains the three characters `%`, `2`,
`0`, and the URL that names it is `my%2520file.txt`. Passing a triplet through on that side would
make one URL mean two different files — the literal `my%20file.txt` and the encoded form of
`my file.txt`. One rule cannot serve both inputs without losing information, so `%` is encoded on
the filename side and preserved on the `mountdir` side. This is the only case where a route a
*browser* could already reach moves, and the #121 upgrade-log entry says so.

**The safe set is `_is_pchar` exactly, and that choice is what bounds the blast radius.**
`HTTP.escapeuri` would have been the obvious tool and is the wrong one: `URIs.issafe` keeps only
`A-Za-z0-9-._`, so it also encodes `~` and every sub-delim plus `:` and `@` — all legal `pchar` that
browsers send raw. Measured over a socket with hand-written request lines, before and after:

| File on disk | Route before | Route after | Browser before → after |
|---|---|---|---|
| `report(1).txt`, `a+b.txt`, `v1.2~beta.txt`, `a:b.txt`, `a@b.txt` | literal | **unchanged** | 200 → 200 |
| `café.txt` | `/static/café.txt` | `/static/caf%C3%A9.txt` | **404 → 200** |
| `my file.txt` | `/static/my file.txt` | `/static/my%20file.txt` | **404 → 200** (raw spelling was a 400, so it was reachable by nobody) |
| `100%.txt` | `/static/100%.txt` | `/static/100%25.txt` | **404 → 200** |
| `my%20file.txt` | `/static/my%20file.txt` | `/static/my%2520file.txt` | 200 → **moved** |

So encoding with `escapeuri` would have broken five working shapes to fix three. With `_is_pchar`,
every pchar-clean name keeps its route byte for byte. The cost that remains is the `%` row above,
plus the #101 cost in the other direction: a client sending raw UTF-8 to reach `café.txt` now gets a
404, and cannot be migrated by changing the server alone.

**The route-pattern refusal survives, and has to.** `*` and `**` are legal `pchar`, so the encoder
leaves them alone — nothing else stops a file named `*` from shadowing its siblings. `{` and `}`
*would* be encoded, but the refusal runs first, so `{id}.txt` stays skipped rather than becoming
servable at `%7Bid%7D.txt`. Encoding braces would change *what* a mount serves rather than only
where, which is a separate decision.

**This was the emit side of a problem no other framework has to solve.** A survey done for #121:
Go's `net/http.FileServer`, Express's `serve-static`/`send`, Phoenix's `Plug.Static`, Django's
`static.serve` and nginx all mount **one prefix handler** and resolve the **percent-decoded** request
path per request — Go stores `URL.Path` decoded and matches `ServeMux` on it; `send` runs
`decodeURIComponent` and 400s on malformed input; `Plug.Static` decodes each segment after
subtracting `:at` and *then* validates. None of them registers a literal route per enumerated file,
so none of them can register an unreachable one. Nitro did, so the decoding side was not available
to it — but the *emitting* side was, and there the same frameworks agree: Go's `dirList` writes
hrefs through `url.URL.String()` and Django's `static` tag through `quote`. Encoding at registration
is that step, moved to mount time because that is when Nitro emits its URLs.

**Nitro has since adopted the prefix-handler shape too
([#221](https://github.com/PingoLee/Nitro.jl/issues/221)), which makes the whole class
unrepresentable rather than handled** — see §9. `_route_encode` survives and is still correct,
but its job narrowed: it decides the URL a mount **emits**, not the route it registers. The
encoded and raw spellings of a name now both resolve, so the choice #101 and #121 each had to make
between a browser and a raw-byte client is gone.

### A route name does not identify what produced it

`mountfolder` returns `route => filepath` pairs, and the three mount functions return them through.
The reason is that the route half is *ambiguous by construction*: an `index.html` contributes two
routes naming the same file — its own and the bare directory route — so `/<prefix>/index.html` is
the direct route of `<folder>/index.html` and equally the bare route of
`<folder>/index.html/index.html`.

`spafiles` used to gate its history-mode fallback on `index_route in mounted`, then re-derive the
file with `joinpath(folder, "index.html")`. The two halves could disagree, and for a directory named
`index.html` they did: the name matched while the path was a directory, so the fallback was
registered against it and every unmatched request 500'd on `read(::dir)`
([#94](https://github.com/PingoLee/Nitro.jl/issues/94)). That was closed by adding `isfile` as a
second conjunct — a filesystem check that follows symlinks, reaching back past the enumeration rules
this layer exists to own, and correct only for as long as nobody simplified it.

Identifying the index by **file** removes the ambiguity instead of outvoting it
([#102](https://github.com/PingoLee/Nitro.jl/issues/102)). A directory is never a `mountable_files`
result, so no pair can name one; the `isfile` conjunct and its `stat` are gone. The escaping-symlink
case is the clearest illustration: there `isfile(joinpath(folder, "index.html"))` is *true* — it
resolves to a real file outside the mount — so only the route-name conjunct kept the catch-all from
serving it on every unmatched path. Under the file lookup the enumerator already refused it, so no
pair carries that path and the fallback simply cannot be registered.

This makes `mountable_files`' un-normalized return an actual contract: it yields `joinpath(dir, name)`
verbatim, never `realpath`/`abspath`/`normpath`, so `joinpath(root, rel)` is a valid key into it.
Normalizing there would silently drop every SPA fallback. Both the contract and the aliasing are
pinned in `test/staticfiles_security_tests.jl`.

The fallback route (`/<prefix>/**`) is registered but is **not** in the returned vector — it is a
catch-all, not a mounted file, and has no filepath to pair with. Since §9 that is true of both
routes a mount registers.

## 9. One prefix handler, resolved against the enumeration

[#221](https://github.com/PingoLee/Nitro.jl/issues/221). A mount registers **two** routes —
`/<prefix>/**` and the bare `/<prefix>` — and resolves the **percent-decoded** remainder against a
`Dict` built from `mountable_files`. It no longer registers a route per enumerated file.

**Why the change was worth making.** #101, #94, #121 and part of #95 are four instances of one
cause: the router compares path segments byte for byte and never percent-decodes, so the route a
mount registered and the request a conforming client sent were two independent strings that had to
be made to agree. Each was fixed correctly and locally, and the cluster kept reopening, because the
cause is a *representation* rather than a branch. §8 already recorded that every comparable
framework resolves the decoded request instead, and that Nitro could not because of the shape. This
changes the shape.

**The load-bearing choice is resolving against the ENUMERATED SET, not the filesystem.** Go,
Express, Plug, Django and nginx all decode and then join onto a document root, which is why each
needs a containment defence — `safe_join`, `UP_PATH_REGEXP`, `invalid_path?`, `disable_symlinks`.
Nitro decodes and then looks the result up in the table `mountable_files` produced. `%2e%2e%2f`
decodes to `../`, which is simply not a key: the request 404s without a `stat`, and nothing outside
the enumeration can be named *at all*. That is strictly stronger than a join defence, and it is why
the mount rules in §2 and §5 did not have to move.

**This is also why `HTTP.fileserver` is not used.** HTTP.jl 2.6 ships `fileserver`, `servefile` and
`servecontent` as public API, and `servecontent` is genuinely worth adopting (§7). `fileserver` is
not: it resolves against the filesystem and implements none of §2's refusals — its
`_is_unsafe_request_path_segment` rejects `.`, `..`, separators, colons and absolute paths, but
**not** a leading-dot name, and it has no `realpath` containment at all (`_join_request_path` uses
`normpath`, which is lexical). Adopting it would serve `.env` and escaping symlinks again, which is
#20 reopened. Nitro keeps the enumeration and delegates only response construction.

**Decoding here is not a new rule.** It is the boundary discipline
[#70](https://github.com/PingoLee/Nitro.jl/issues/70) established — *percent-decoding happens
exactly once, where the raw request becomes a value* — applied to the one path that never got it.
`mount_remainder` raises `ValidationError` (a 400) on a malformed escape or on bytes that are not
valid UTF-8, exactly as `Types.pathparams` does for `{var}` routes, and exactly as Express's `send`
does. A segment that cannot name one path component — `.`, `..`, or one containing a decoded
separator or NUL — is a **404**: it is a miss, and reporting it as a client error would tell an
unauthenticated caller which spellings are structurally interesting.

**This is not the per-request re-validation §6 removed.** §6 is about re-checking the *filesystem*
— `realpath`, `stat`, containment — to catch a file swapped after startup. That remains removed and
remains a non-goal: the lookup consults a `Dict` and touches no filesystem at all. Which files exist
is still decided once, at mount time.

**What it costs.** Two things, both recorded in the #221 upgrade entry rather than fixed:

- **Route-count visibility.** A mount no longer collides *loudly* with an application route at a
  file path. HTTP.jl's `replacing existing registered route` warning was doing real work there.
  Exact routes beat `**`, so an app route now wins regardless of registration order — a better
  default, but a silent change of winner where the mount registered last. The intra-mount case (an
  `index.html` directory colliding with the file beside it) is warned about explicitly instead.
- **Per-request work returns.** A decode and a `Dict` lookup, where registration-time resolution
  had neither. It is small and it is bounded, but it is not zero, and §6's removal of per-request
  cost was deliberate. The difference is that §6's check was *incomplete* as well as costly — it
  could not close the race it targeted — whereas this one is the resolution itself.

The bare `/<prefix>` route is a separate registration because HTTP.jl's `**` matches **one or more**
trailing segments: `match` advances the cursor straight to `length(segments) + 1` on the doublestar
branch, so it can never match zero. It is registered only when the mount can actually answer it —
i.e. when a mount-root `index.html` was enumerated — so a mount never claims `/<prefix>` with
nothing to serve there.

## 10. See also

- [`docs/src/tutorial/reverse_proxy.md`](../src/tutorial/reverse_proxy.md) — the user-facing guide,
  including client-IP trust configuration and worked nginx/Caddy configs
- [`upgrading/`](../../upgrading/) — the #20 entry and its migration notes
- [`docs/design/agent-security.md`](agent-security.md) — the analogous "trust is decided at the
  boundary" reasoning for agent tooling
