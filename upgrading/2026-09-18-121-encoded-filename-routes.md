## A filename that must be percent-encoded now mounts at its encoded route (#121)

- **Version**: 0.4.0
- **Nitro ref**: #121; `src/utilities/fileutil.jl`, `src/methods.jl`,
  `docs/design/static-serving-boundary.md`, `test/staticfiles_security_tests.jl`,
  `test/util_tests.jl`
- **Recorded**: 2026-09-18
- **Severity**: **behaviour.** Nothing forces an edit unless a mounted folder contains a filename
  with a character outside RFC 3986 `pchar` — or a literal `%`. Those files change URL. Most of the
  change is repair (URLs that answered nobody now answer everybody), but two cases take something
  away, and both are called out below.

### What changed

`staticfiles`, `spafiles` and `dynamicfiles` register one literal route per enumerated file, and the
router compares path segments **byte for byte and never percent-decodes**. A file whose name
contains a character a conforming client must encode therefore got a route that client could never
match — enumerated, registered, counted in the return value and logged as served, and a 404 in every
browser. Measured over a socket with hand-written request lines:

| File on disk | Route before | Browser sent | Before |
|---|---|---|---|
| `café.txt` | `/static/café.txt` | `/static/caf%C3%A9.txt` | **404** (200 only for a raw-byte client) |
| `my file.txt` | `/static/my file.txt` | `/static/my%20file.txt` | **404** — and the raw spelling is a **400**, so it was reachable by *nobody* |

Under `spafiles` it was worse than a 404: the `/<prefix>/**` history fallback answered the encoded
URL with `index.html` and a 200, so the asset silently resolved to the app shell.

Those files are now registered at their **encoded** route, which is the URL a conforming client
sends. `mountfolder`'s `route => filepath` pair carries the encoded route and the raw filesystem
path, so the two halves can differ — which is what #102 made expressible.

**Only characters that RFC 3986 forbids in a path segment are encoded.** The safe set is exactly
`pchar` (`unreserved / sub-delims / ":" / "@"`), *not* `HTTP.escapeuri`'s narrower one, so a filename
that already worked keeps its exact URL:

| File on disk | Route |
|---|---|
| `report(1).txt`, `a+b.txt`, `v1.2~beta.txt`, `a:b.txt`, `a@b.txt`, `file.min.js` | **unchanged** |
| `café.txt` | `/static/caf%C3%A9.txt` |
| `my file.txt` | `/static/my%20file.txt` |
| `sub dir/x.txt` | `/static/sub%20dir/x.txt` |
| `100%.txt` | `/static/100%25.txt` |
| `my%20file.txt` | `/static/my%2520file.txt` |

**Two costs, both real.**

- **A literal `%` in a filename is itself encoded, so such a file's URL moves — and that URL was
  reachable by a browser.** A file named `my%20file.txt` served at `/static/my%20file.txt` before
  and serves at `/static/my%2520file.txt` now. This is not avoidable: the file's name contains the
  three characters `%`, `2`, `0`, and leaving the triplet alone would make one URL name both that
  file *and* the encoded form of a sibling called `my file.txt`. If you have a mounted filename
  containing `%`, fix the links that point at it.
- **A non-browser client sending raw bytes loses `café.txt`.** It used to reach
  `/static/café.txt` with raw UTF-8 (curl does this by default) and now gets a 404, because `café`
  and `caf%C3%A9` are different byte strings under a byte-exact matcher. **Changing the server does
  not migrate such a client** — it has to be fixed to percent-encode. This is the same cost the #101
  entry records for `mountdir`, in the same direction.

**A mount's *reachable* surface can grow, even though its *served* surface does not.** No file
becomes servable that the mount did not already enumerate and register — the dotfile, symlink
containment, route-pattern and regular-file refusals are untouched. What changes is that files which
were registered but unreachable now answer. If an app has been relying on "no browser can fetch
this" for something like `credentials backup.txt` sitting in a mounted `public/` tree, that was
never a boundary (see `docs/design/static-serving-boundary.md` §5 — this layer is a floor for the
accidental case, not a defence against someone who can write into the served directory), and it is
gone now. The remedy is the existing one: do not mount a directory whose full contents are not meant
to be public.

`mountdir` is unchanged and still **throws** on such a segment rather than encoding it (#101). That
asymmetry is deliberate: a `mountdir` is *authored*, so `"my%20static"` is someone spelling a space
on purpose and the triplet is passed through, while a filename is *data*. The reasoning is in
`docs/design/static-serving-boundary.md` §8.

Filenames the router would read as **patterns** are still *refused*, not encoded — `*` and `**` are
legal `pchar` so encoding would not neutralize them, and `{id}.txt` stays skipped rather than
becoming servable at `%7Bid%7D.txt`.

### How to find the calls to migrate

Nitro tells you at mount time rather than silently: each affected file is logged individually
(`@info "mountfolder: serving a file at its percent-encoded route…"`) up to the **first five**,
capped because a user-writable upload directory would otherwise be a log flood. Past five, a summary
line carries the **total** — so either the individual lines are the complete list, or the summary
tells you how many more there are. Use that to decide whether the greps below found everything. The
genuinely silent case is in *your* links and clients.

```bash
# Every mount. The first argument is the folder whose filenames matter.
rg -n '(static|spa|dynamic)files\(' <app>/src

# Per mounted folder: names with a non-pchar byte, or a literal `%`. These are the files
# whose URL changed. An empty result means this entry does not apply to you.
find <folder> -type f | rg -P "[^/\-A-Za-z0-9._~!\$&'()*+,;=:@]|%"

# Then the links that point at them. Search the OLD spelling — the raw filename — in
# templates, JS, CSS and tests.
rg -nF 'café.txt' <app>          # substitute each name the find above reported
```

```bash
# Non-browser callers: anything sending a raw non-ASCII or space-bearing static path.
rg -n 'static/[^"'"'"' ]*[^\x00-\x7F]' <app>
```

### Migrate your app

```julia
# Unchanged — no action needed. The mount call itself does not change at all.
staticfiles("dist", "static")
```

```html
<!-- ✗ before — this href 404'd in every browser; the route was registered raw -->
<img src="/static/café.txt">
<!-- ✓ after — the encoded spelling is what is registered, and what the browser sends -->
<img src="/static/caf%C3%A9.txt">

<!-- ✗ before — a file literally named `my%20file.txt` was served here -->
<a href="/static/my%20file.txt">download</a>
<!-- ✓ after — that URL now names `my file.txt`; the `%`-bearing file moved -->
<a href="/static/my%2520file.txt">download</a>
```

```julia
# ✗ before — re-deriving the route from the filename. This was always fragile (an index.html
#   contributes two routes) and is now simply wrong for an encoded name.
mounted = staticfiles("dist", "static")
route   = "/static/" * basename(path)

# ✓ after — read the route off the pair the mount returned.
mounted = staticfiles("dist", "static")
idx     = findfirst(p -> last(p) == path, mounted)
route   = idx === nothing ? nothing : first(mounted[idx])
```

```bash
# ✗ before — a raw-byte client that worked
curl http://localhost:8080/static/café.txt
# ✓ after — encode the path; the server cannot answer the raw form any more
curl http://localhost:8080/static/caf%C3%A9.txt
```
