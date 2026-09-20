## Static mounts no longer serve dotfiles, escaping symlinks, or route-pattern filenames (#20)

- **Version**: 0.2.0
- **Nitro ref**: #20; `src/utilities/fileutil.jl`, `src/core.jl`, `src/methods.jl`
- **Recorded**: 2026-08-09
- **Severity**: **behavior (files that were served now 404)** — security fix.

### What changed

`staticfiles`, `spafiles` and `dynamicfiles` used to register a route for **every** regular file
under the mounted folder. Pointing a mount at a directory that also held `.git/`, `.env`, or a
symlink to a file outside it served those to any unauthenticated client — something nginx, Express
and Caddy all deny by default.

Four classes of entry are now refused at mount time:

- **Hidden entries** — any path component starting with `.`, *relative to the mounted folder*. That
  covers `.env` and everything under `.git/`. The folder's own name is never tested, so mounting a
  dotted directory directly still works. Interior dots (`file.min.js`) are unaffected. The rule
  applies to what a symlink **resolves to** as well as to its own name, so an innocuously-named link
  pointing at an in-mount dotfile is refused too.
- **Symlinks resolving outside the mount** — resolved with `realpath` and required to stay under the
  resolved root, so a link *inside* the mount still works while `data.csv -> /etc/passwd` does not.
  Windows directory junctions count as symlinks here.
- **Filenames the router reads as patterns.** Two different failures. A file named `*` or `**` is an
  HTTP.jl wildcard and shadows its siblings — a request for any unmatched path under the mount was
  answered with that file's body. A file whose name contains `{` or `}` is read as a path parameter
  by Nitro's own route parser, which then threw `ArgumentError` because a mount's handler takes no
  such parameter, so **a single such file made `serve()` fail to boot** — an unauthenticated
  startup denial of service against exactly the user-writable directory `dynamicfiles` is meant for.
  Both are always refused; there is no opt-out. No working app can have been serving one, so this
  half needs no migration.
- **Anything that is not a regular file** — symlinked directories, FIFOs, sockets, devices.

Two related fixes ride along. `spafiles`' history-mode fallback used to locate `index.html` by
probing the filesystem, which reached straight past the mount rules: a refused `index.html` was
still served on *every* unmatched path under the mount. It now registers only if `index.html` is
actually servable, and logs a warning otherwise.

**These checks run at mount time only.** Which files exist is decided once, when the mount runs;
`dynamicfiles` still re-reads *content* per request, but it does not re-evaluate the rules. Serving a
directory whose contents an attacker can change between startup and a request is explicitly out of
scope for this layer — put a reverse proxy in front of it, or do not serve that directory. The
reasoning is in [`docs/design/static-serving-boundary.md`](docs/design/static-serving-boundary.md).

`include_hidden=true` and `allow_symlink_escape=true` restore the old behavior per mount. The
enumerator `Nitro.Core.Util.getfiles` has been replaced by `Nitro.Core.Util.mountable_files`, and
`mountfolder` now returns the `Vector{String}` of routes it registered.

### How to find the calls to migrate

```bash
# Every mount — check each one against the folder it actually points at
rg -n 'staticfiles|spafiles|dynamicfiles' <app>/src

# Mounts pointed at a project or build root are the ones most likely to lose files
rg -n '(static|spa|dynamic)files\(\s*"\.?/?"' <app>/src

# Direct users of the removed enumerator
rg -n 'getfiles' <app>/src <app>/test
```

Then list what a mount now refuses, without starting a server. Walk the tree yourself for the
left-hand side — `readdir` would compare only the top level, and against directories rather than
files, so it reports every ordinary subdirectory as "refused" while hiding every nested refusal:

```julia
julia> all_files = [joinpath(d, f) for (d, _, fs) in walkdir("public") for f in fs];

julia> setdiff(all_files, Nitro.Core.Util.mountable_files("public"))
```

### Migrate your app

```julia
# ✗ before — served .env, .git/config and any escaping symlink under "public"
staticfiles("public", "static")

# ✓ after — same call, but those entries are now refused. Nothing to change unless you
#   were relying on one of them; the mount logs what it skipped at startup.
staticfiles("public", "static")

# ✗ before — a dotted directory was served because nothing was filtered
staticfiles("public", "static")     # relied on public/.well-known/* being reachable

# ✓ after — mount it as its own root; the rule tests components *below* the folder,
#   never the folder's own name
staticfiles("public", "static")
staticfiles("public/.well-known", ".well-known")

# ✓ last resort — reinstate the old behavior for one mount, deliberately
staticfiles("public", "static"; include_hidden=true, allow_symlink_escape=true)
```

**`.well-known` will not make ACME work**, and it did not before either: every Nitro mount registers
only the files that exist when it runs, and `http-01` writes `acme-challenge/<token>` at renewal
time, long after boot. Serve that with a handler, not a mount.

One `spafiles`-specific wrinkle: because the history-mode fallback answers any unmatched path under
the mount, a refused file reads as `index.html` with a `200` rather than a `404`. Nothing leaks, but
it is confusing in logs — check the startup message for what was skipped rather than probing URLs.
