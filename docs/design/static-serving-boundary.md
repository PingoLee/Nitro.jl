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

It could not close the race it targeted: the check resolves the path, and `file()` then re-opens the
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
registers a literal route per file at mount time (§1), so the per-request resolution those two rely
on is not available here — canonical segments are the form that fits.

Note this changes no URL that a *reachable* mount already served. HTTP.jl's `register!` and its
request path both split on `/` with `keepempty=false`, so every slash-only spelling —
`/static//app.js` versus `/static/app.js`, `""` versus `"/"` — was already the same router node.

Three things do change, and none of them forces an app edit, which is why there is no
`UPGRADING.md` entry.

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

## 9. See also

- [`docs/src/tutorial/reverse_proxy.md`](../src/tutorial/reverse_proxy.md) — the user-facing guide,
  including client-IP trust configuration and worked nginx/Caddy configs
- [`UPGRADING.md`](../../UPGRADING.md) — the #20 entry and its migration notes
- [`docs/design/agent-security.md`](agent-security.md) — the analogous "trust is decided at the
  boundary" reasoning for agent tooling
