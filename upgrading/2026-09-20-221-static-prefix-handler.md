## Static mounts register one prefix handler instead of a route per file (#221)

- **Version**: Unreleased
- **Nitro ref**: #221; `src/core/staticfiles.jl`, `src/utilities/fileutil.jl`,
  `docs/design/static-serving-boundary.md`, `test/staticfiles_security_tests.jl`,
  `test/util_tests.jl`, `test/spa_tests.jl`
- **Recorded**: 2026-09-20
- **Severity**: **behavior.** Most of this is repair — URLs that answered nobody now answer
  everybody — but four things change for an app that was relying on the old shape, and they are
  called out below.

### What changed

`staticfiles`, `spafiles` and `dynamicfiles` used to enumerate a folder at boot and register **one
literal route per file**. They now register **two** routes per mount — `/<prefix>/**` and the bare
`/<prefix>` — and resolve the **percent-decoded** request against a table built from the same
enumeration.

That is what every comparable framework already does: Go's `net/http.FileServer`, Express's
`serve-static`/`send`, Phoenix's `Plug.Static`, Django's `static.serve` and nginx all mount one
prefix handler and resolve the decoded path per request. None of them registers a route per
enumerated file, which is why none of them has the class of defect #101, #94 and #121 each fixed one
instance of: under byte-exact route matching, the route a mount *registers* and the request a
conforming client *sends* are two independent strings that have to be made to agree.

**Enumeration is unchanged.** `mountable_files` still decides which files are exposed, at mount
time, with the same refusals — dotfiles, symlink containment, route-pattern names, non-regular
files — and `include_hidden` / `allow_symlink_escape` still opt out of the first two. **The lookup
resolves against that enumerated set, never against the filesystem**, so `%2e%2e%2f` decodes to
`../`, is not a key, and 404s without a single `stat`. This is deliberately stronger than the
`safe_join` / `UP_PATH_REGEXP` defences the frameworks above need precisely *because* they resolve
against the filesystem. (It is also why `HTTP.fileserver`, which is now available and does resolve
against the filesystem, is **not** used: it applies none of those refusals and would serve `.env`
and escaping symlinks again.)

**The mount's return value is unchanged** — still `Vector{Pair{String,String}}` of *encoded*
`route => filepath` (#102, #121). Neither registered route appears in it, exactly as the SPA
fallback never did.

#### Repairs — nothing to do

| Request | Before | After |
|---|---|---|
| `GET /static/caf%C3%A9.txt` (browser) | 200 | 200 |
| `GET /static/café.txt` (raw bytes, e.g. `curl` default) | **404** | **200** |
| `GET /static/my%20file.txt` → `my file.txt` | 200 | 200 |
| `GET /static/my%2520file.txt` → `my%20file.txt` | 200 | 200 |

The second row reverses a cost recorded in **both** the #101 and #121 entries — *"A non-browser
client sending raw bytes loses `café.txt` … Changing the server does not migrate such a client."*
It no longer has to be migrated: both spellings decode to one key and both are served. If you
changed a client to percent-encode because of the #121 entry, that change is still correct and
still works; it simply is no longer required.

#### Four things that do change

**1. An application route now always beats a mount at the same path.** HTTP.jl matches
`exact → conditional → wildcard → doublestar`, so a literal app route under a mount prefix wins
over the mount's catch-all. Previously both were literal routes and the **later registration won**,
with HTTP.jl warning `replacing existing registered route`. If your app declares a route under a
mount prefix *and* registers the mount afterwards, the mount used to shadow it and no longer does.

**2. A collision between two mounted files is now a Nitro warning, not an HTTP.jl one.** An
`index.html` contributes two keys — its own and its parent directory's — so a directory literally
named `index.html` collides with the file beside it. Last write still wins, as it did at
registration; the announcement moved:

```
┌ Warning: mountfolder: two enumerated files claim the same mount key; the later one wins
│   key = "index.html"
```

**3. A malformed request target under a mount is a `400`, not a `404`.** `GET /static/%ZZ.txt` and
`GET /static/%80.txt` previously matched no route and fell through to the not-found handler. The
mount now decodes the remainder, and a malformed escape or a value that is not valid UTF-8 raises
`ValidationError` — the same boundary rule #70 established for query and path parameters, and the
same answer Express's `send` gives. A test asserting `404` for such a target needs to assert `400`.

**4. The route a mount reports in logs and `req.context[:route]` is now the pattern.** Access-log
lines and anything reading `req.context[:route]` see `/static/**` rather than the individual file
route, and an unmatched path under a mount now *matches* a route rather than falling through. The
served response for a miss is unchanged: the mount defers to the router's own not-found handler, so
a custom one supplied through `Service(router = Router(my404))` keeps working.

#### Internal API: `mountfolder`'s callback takes a third argument

`Nitro.Core.Util.mountfolder(folder, mountdir, addroute)` now calls
`addroute(route, filepath, key)`. `route` is the percent-**encoded** URL to emit, `filepath` is the
raw filesystem path, and `key` is the raw, `/`-separated, mount-relative path the mount table is
keyed by. A two-argument callback fails loudly with a `MethodError`.

### How to find the calls to migrate

```bash
# 1. Direct users of the internal enumerator's callback -- these break with a MethodError.
rg -n 'mountfolder' <app>/src <app>/test

# 2. Application routes declared UNDER a mount prefix. These now win where the mount may have
#    shadowed them. Substitute your own mountdir for "static".
rg -n 'path\(\s*"/static/' <app>/src

# 3. Tests asserting a 404 for a malformed target under a mount -- they want 400 now.
rg -n '%[0-9A-Za-z]{0,2}[^0-9A-Fa-f].*404|404.*%ZZ' <app>/test

# 4. Anything asserting on the NUMBER of registered routes, or reading req.context[:route]
#    for a static request.
rg -n 'context\[:route\]' <app>/src <app>/test
```

Nitro also tells you about collision case 2 at mount time — grep your startup log for
`two enumerated files claim the same mount key`.

### Migrate your app

```julia
# Unchanged — the mount call itself does not change at all, and neither does its return value.
routes = staticfiles("dist", "static")      # still Vector{Pair{String,String}}, encoded routes
```

```julia
# ✗ before — a two-argument mountfolder callback
Nitro.Core.Util.mountfolder(dir, "static", (route, filepath) -> register!(route, filepath))

# ✓ after — the third argument is the mount-table key (raw, not encoded)
Nitro.Core.Util.mountfolder(dir, "static", (route, filepath, key) -> register!(route, filepath))
```

```julia
# ✗ before — the mount was registered after the app route, so the mount shadowed it
urlpatterns("", [path("/static/api/ping", ping)])
staticfiles("dist", "static")      # this used to win, with a `replacing existing route` warning

# ✓ after — the literal app route wins regardless of registration order. If you WANTED the
#   mount to serve that path, remove the app route; if you wanted the app route, nothing to do.
```

```bash
# ✗ before — a raw-byte client had to be changed to reach an accented filename
curl http://localhost:8080/static/caf%C3%A9.txt
# ✓ after — either spelling works; the encoded one is still what a browser sends
curl http://localhost:8080/static/café.txt
```
