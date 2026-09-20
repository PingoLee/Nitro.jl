## `staticfiles`, `spafiles` and `dynamicfiles` return `route => filepath` pairs (#102)

- **Version**: 0.3.0
- **Nitro ref**: #102; `src/utilities/fileutil.jl`, `src/core.jl`, `src/methods.jl`
- **Recorded**: 2026-09-07
- **Severity**: **breaking (return type)** — affects apps that use the value a mount returns.
  A mount whose return value is discarded needs no edit.

### What changed

The three mount functions, and the internal `Nitro.Core.Util.mountfolder` behind them, returned a
`Vector{String}` of the routes they registered. They now return `Vector{Pair{String,String}}` —
`route => filepath`, in registration order.

The route half alone is **ambiguous by construction**. An `index.html` claims two routes naming the
same file — its own and the bare directory route — so `/<prefix>/index.html` is the direct route of
`<folder>/index.html` and equally the bare route of `<folder>/index.html/index.html`. `spafiles`
gated its history-mode fallback on a route *name* being present and then re-derived the file with
`joinpath` alongside it; for a directory named `index.html` the two disagreed, the fallback was
registered against a directory, and every unmatched request 500'd on `read(::dir)` (#94). That was
closed by adding an `isfile` conjunct — a `stat` that follows symlinks, reaching back past the
enumeration rules the mount owns, and correct only while nobody simplified it away.

`spafiles` now looks its index up by **file** in what the mount registered. A directory is never a
`mountable_files` result, so the ambiguity is unrepresentable rather than outvoted, and the extra
`stat` is gone. Behavior is unchanged in every case — this is a pure shape change.

The fallback route (`/<prefix>/**`) is registered but is **not** in the returned vector, as before:
it is a catch-all, not a mounted file, and has no filepath to pair with.

One thing to look at even if you never bind the result: the value now carries **filesystem paths**,
so `@info staticfiles(...)` or any log line that dumps it starts emitting local paths where it used
to emit URL routes. These are your own `folder` spelling plus a relative path — not a resolved
symlink target — but check any mount whose return value reaches a log.

### How to find the calls to migrate

```bash
# Mounts whose return value is bound or used -- these are the calls that need an edit
rg -n '=\s*(static|spa|dynamic)files\(' <app>/src <app>/test

# Anything treating a mount result as strings
rg -n '(static|spa|dynamic)files\([^)]*\)\s*(\.|\[|∈|in\b)' <app>/src <app>/test

# Direct users of the internal helper
rg -n 'mountfolder' <app>/src <app>/test
```

A missed call fails loudly at the use site — `occursin`/`startswith` on a `Pair` is a `MethodError`.
The one quiet exception is a **membership test**: a `String` is never `isequal` to a `Pair`, so
`"/static/app.js" in routes` silently becomes `false` rather than erroring. Grep for `in`/`∈` against
a mount result specifically.

### Migrate your app

```julia
# ✗ before — a Vector{String} of routes
routes = staticfiles("dist", "assets")
"/assets/app.js" in routes
for r in routes; println(r); end

# ✓ after — unwrap for the routes alone
routes = first.(staticfiles("dist", "assets"))
"/assets/app.js" in routes
for r in routes; println(r); end

# ✓ or use the half that is new: which file backs which route
for (route, filepath) in staticfiles("dist", "assets")
    println(route, " -> ", filepath)
end
```
