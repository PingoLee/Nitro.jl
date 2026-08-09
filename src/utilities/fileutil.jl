using HTTP

export readfile, mountfolder, mountable_files

"""
    readfile(filepath::String)

Reads a file as a String
"""
function readfile(filepath::String)
    return read(filepath, String)
end

"""
    _is_within(root_parts::Vector{String}, path::String) -> Bool

Whether `path` sits strictly underneath the directory whose `splitpath` is `root_parts`.

**Both sides must already be resolved with `realpath` by the caller.** Comparing a resolved path
against a raw one is wrong on macOS, where `mktempdir()` returns `/var/folders/…` but `/var` is a
symlink to `/private/var`, so every resolved file would look like an escape.

The comparison is component-wise rather than a string prefix, so `/srv/app` does not appear to
contain `/srv/app-secrets`.

`relpath` is deliberately *not* used for this: on Windows `relpath("D:/x", "C:/y")` returns
`"D:\\\\x"` with no `..` component at all, so a `..`-based containment test fails **open** across
drives. Comparison is byte-exact and must stay that way — `realpath` returns the case the
filesystem stores, so both sides already agree on Windows, and case-folding would be wrong on Linux.

The one component that cannot be compared verbatim is the root itself, because `splitpath` spells it
two ways. A UNC share root standing alone keeps no trailing separator, but the same root followed by
further components does:

```
splitpath(raw"\\\\host\\share")        == ["\\\\\\\\host\\\\share"]
splitpath(raw"\\\\host\\share\\sub")   == ["\\\\\\\\host\\\\share\\\\", "sub"]
```

Comparing those verbatim makes **every** file under a UNC-mounted folder look like an escape, which
fails closed as a blanket 404. Drive roots (`"C:\\\\"`) and `/` are consistent, but are normalized the
same way so there is only one rule.
"""
function _is_within(root_parts::Vector{String}, path::String)::Bool
    parts = splitpath(path)
    # Strictly greater: a file is never the root itself.
    length(parts) > length(root_parts) || return false
    isempty(root_parts) && return false
    _same_root(parts[1], root_parts[1]) || return false
    for i in 2:length(root_parts)
        parts[i] == root_parts[i] || return false
    end
    return true
end

"""
    _same_root(a, b) -> Bool

Compare two filesystem-root components ignoring a trailing separator, which `splitpath` includes or
omits depending on whether the root stands alone. See [`_is_within`](@ref).
"""
_same_root(a::AbstractString, b::AbstractString) =
    rstrip(a, ('/', '\\')) == rstrip(b, ('/', '\\'))

"""
    _resolves_hidden(root_parts::Vector{String}, resolved::String) -> Bool

Whether `resolved` lands on a hidden entry once expressed relative to the mount root — i.e. whether
any component *below* the root starts with `.`.

This exists because the hidden rule is otherwise applied to the name of the directory entry being
walked, which says nothing about where a symlink points. A link named `innocent.txt` pointing at
`.env` in the same folder is not dot-prefixed, resolves inside the root, and is a regular file, so
containment alone would serve it — re-opening the hole the hidden rule closes.

Both arguments must be `realpath`-resolved, and `resolved` must already be known to be inside the
root (`_is_within`); for a target outside it, "relative to the mount" has no meaning.
"""
function _resolves_hidden(root_parts::Vector{String}, resolved::String)::Bool
    parts = splitpath(resolved)
    length(parts) > length(root_parts) || return false
    for i in (length(root_parts) + 1):length(parts)
        startswith(parts[i], '.') && return true
    end
    return false
end

"""
    _is_route_pattern(component::AbstractString) -> Bool

Whether a single path component would be treated as something other than a literal segment by the
routing layer. Two distinct failures, both refused:

- `*` and `**` are HTTP.jl wildcards. A file named `*` shadows its siblings — a request for any
  unmatched path under the mount is answered with that file's body.
- A component containing `{` or `}` is read as a path parameter by `parse_func_params`
  (`src/core.jl`), whose brace test is `contains(value, r"({)|(})")` — deliberately broader than
  HTTP.jl's own `isvariable`, so `{id}.txt` counts even though it is not a well-formed variable.
  Registration then throws `ArgumentError` because a mount's handler takes no such parameter, which
  means a single brace-named file made `serve()` fail to boot.
"""
_is_route_pattern(component::AbstractString) =
    component == "*" || component == "**" || occursin('{', component) || occursin('}', component)

"""
    _mount_root_parts(root::String) -> Vector{String}

The `splitpath` of `root` resolved through `realpath`, for use as the left-hand side of
[`_is_within`](@ref) and [`_resolves_hidden`](@ref).

Throws `ArgumentError` when `root` is missing or not a directory. That has to be an error rather
than an empty result: `mountable_files` logs-and-continues past unreadable *subdirectories*, so
without this a typo'd folder name would quietly mount nothing at all.
"""
function _mount_root_parts(root::String)::Vector{String}
    isdir(root) || throw(ArgumentError("mount folder does not exist or is not a directory: $root"))
    return splitpath(realpath(root))
end

# NOTE: enumeration here is deliberately mount-time only. An earlier revision also re-checked on
# every request, to catch a file swapped for a symlink after startup. That was removed on purpose:
# it could not close the race (the caller re-opens the unresolved path after the check, and a hard
# link is undetectable either way), while costing a `realpath` + stat + `splitpath` allocation on
# every `dynamicfiles` request. A partial in-app mitigation is the wrong tool for "an attacker can
# write to the directory you are serving" — put a reverse proxy in front, or do not serve that
# directory. See docs/design/static-serving-boundary.md.

"""
    mountable_files(root::String; include_hidden=false, allow_symlink_escape=false) -> Vector{String}

Return the filesystem paths under `root` that are safe to expose over HTTP, in walk order.

This is the single enumerator behind [`mountfolder`](@ref) and therefore behind `staticfiles`,
`spafiles` and `dynamicfiles`. It refuses four classes of entry by default:

- **Hidden entries** — any file whose path *relative to `root`* has a component starting with `.`.
  That covers `.env` as well as everything under `.git/`. The test is relative on purpose: an
  absolute-path test would refuse every file whenever the project itself lives under a dot-directory.
  Names with interior dots (`file.min.js`) are unaffected. Set `include_hidden=true` to serve them.

  The rule applies to a symlink's **resolved target** as well as to its own name
  ([`_resolves_hidden`](@ref)) — otherwise `innocent.txt -> .env` walks straight through a name-only
  test. It does **not** catch a *hard* link to a dotfile: `islink` is false, so nothing resolves, and
  `realpath` legitimately reports the in-mount path. That gap is inherent at this layer.
- **Symlinks escaping the mount** — resolved with `realpath` and required to stay under the resolved
  `root`, so a link to a file *inside* the mount still works while `data.csv -> /etc/passwd` does
  not. Set `allow_symlink_escape=true` to serve them anyway. Note this also disables the
  resolved-target hidden check for escaping links, since "hidden relative to the mount" stops meaning
  anything once the target is outside it.
- **Filenames that are router patterns** — see [`_is_route_pattern`](@ref). Always refused; a file
  cannot opt into claiming other URLs.
- **Anything that is not a regular file** — symlinked *directories* (`walkdir` reports every link as
  a file, so without this a route would be registered whose target is a directory and the eager read
  in `staticfiles` would throw at startup), plus FIFOs, sockets and devices, where the per-request
  read in `dynamicfiles` would block or grow without bound.

Every refusal fails closed: a `realpath` that throws — a dangling link, `ELOOP`, a permission error
— skips the entry rather than propagating. An unreadable *subdirectory* is logged and skipped too,
which is why a missing `root` throws `ArgumentError` up front instead: a mount folder that does not
exist is a programming error, and it must not be silently indistinguishable from an empty one.
"""
function mountable_files(root::String;
                         include_hidden::Bool=false,
                         allow_symlink_escape::Bool=false)::Vector{String}

    root_parts = _mount_root_parts(root)
    kept       = String[]
    examples   = String[]
    n_hidden = n_escaped = n_pattern = n_unresolvable = n_irregular = 0

    # Default is `onerror=throw`, which makes one unreadable subdirectory anywhere under the mount
    # abort `serve()`. Logging and continuing fails closed — fewer files get served, never more.
    onerror = e -> @debug "mountable_files: skipping unreadable directory" exception=e

    for (dir, _, names) in walkdir(root; follow_symlinks=false, onerror=onerror)
        reldir     = relpath(dir, root)
        hidden_dir = reldir != "." && any(startswith("."), splitpath(reldir))

        for name in names
            rel  = reldir == "." ? name : joinpath(reldir, name)
            path = joinpath(dir, name)
            # Only ever record the mount-relative path. A resolved target may name something
            # sensitive (a link to `~/.ssh/id_rsa`), and logs must not carry it.
            note!() = (length(examples) < 5 && push!(examples, rel); nothing)

            if !include_hidden && (hidden_dir || startswith(name, '.'))
                n_hidden += 1; note!(); continue
            end

            if any(_is_route_pattern, splitpath(rel))
                n_pattern += 1
                # Warn on the first few only. These names can come from a user-writable upload
                # directory, so one log line per file is an attacker-controlled log flood.
                n_pattern <= 5 && @warn "mountable_files: refusing a filename that the router would read as a pattern rather than a literal path" path=rel
                note!(); continue
            end

            # `walkdir(follow_symlinks=false)` never descends a link, so no walked path can have a
            # symlinked *intermediate* component — testing the leaf is a complete test, and an
            # ordinary tree pays no `realpath` calls at all.
            if islink(path)
                resolved = try
                    realpath(path)
                catch e
                    e isa Base.IOError || rethrow()
                    n_unresolvable += 1; note!(); continue
                end
                inside = _is_within(root_parts, resolved)
                if !allow_symlink_escape && !inside
                    n_escaped += 1; note!(); continue
                end
                # A link's *name* passing the hidden test says nothing about its target.
                # `innocent.txt -> .env` is not dot-prefixed, resolves inside the root, and is a
                # regular file — so containment alone would re-expose exactly what the hidden rule
                # exists to refuse. Only meaningful for a target inside the root; an escaping one is
                # already either refused above or explicitly opted into.
                if !include_hidden && inside && _resolves_hidden(root_parts, resolved)
                    n_hidden += 1; note!(); continue
                end
            end

            if !isfile(path)
                n_irregular += 1; note!(); continue
            end

            push!(kept, path)
        end
    end

    n_skipped = n_hidden + n_escaped + n_pattern + n_unresolvable + n_irregular
    if n_skipped > 0
        @info "mountable_files: $n_skipped entry/entries under $root will not be served" hidden=n_hidden symlink_escape=n_escaped route_pattern=n_pattern unresolvable_link=n_unresolvable not_a_regular_file=n_irregular examples=examples
    end
    isempty(kept) && @warn "mountable_files: no servable files found under $root"

    return kept
end

"""
    mount_prefix(mountdir) -> String

The URL path segment a mount contributes, or `""` when it mounts at the root.

`mountfolder` and `spafiles` must derive this the *same* way. They used to spell it separately, and
an all-whitespace `mountdir` made them disagree: the mount registered `/index.html` while `spafiles`
looked for `"/  /index.html"`, so the history-mode fallback silently vanished behind a warning
claiming no servable `index.html` existed.
"""
function mount_prefix(mountdir)::String
    (isnothing(mountdir) || isempty(mountdir) || all(isspace, mountdir) || mountdir == "/") && return ""
    return String(mountdir)
end

"""
Helper function that returns everything before a designated substring
"""
function getbefore(input::String, target) :: String
    result = findfirst(target, input)
    index = first(result) - 1
    return input[begin:index]
end

"""
    mountfolder(folder::String, mountdir::String, addroute;
                include_hidden=false, allow_symlink_escape=false) -> Vector{String}

Discover the servable files under `folder` and register them, leaving the `addroute` function to
determine *how* each one is registered. Enumeration — and therefore which files are exposed — is
owned by [`mountable_files`](@ref); see it for what is refused and how to opt out.

Returns the routes that were registered, in registration order. Callers need that set rather than
re-deriving paths from the filesystem: `spafiles` uses it to decide whether its history-mode
fallback has a servable `index.html`, which keeps the fallback from drifting away from the mount
rules and re-opening the hole they close.
"""
function mountfolder(folder::String, mountdir::String, addroute;
                     include_hidden::Bool=false,
                     allow_symlink_escape::Bool=false) :: Vector{String}

    separator = Base.Filesystem.path_separator
    prefix    = mount_prefix(mountdir)
    routes    = String[]

    for filepath in mountable_files(folder; include_hidden, allow_symlink_escape)

        # remove the first occurrence of the root folder from the filepath before "mounting"
        cleanedmountpath = relpath(filepath, folder)

        # make sure to replace any system path separator with "/"
        cleanedmountpath = replace(cleanedmountpath, separator => "/")

        # generate the path to mount the file to
        mountpath = isempty(prefix) ? "/$cleanedmountpath" : "/$prefix/$cleanedmountpath"

        push!(routes, mountpath)
        addroute(mountpath, filepath)

        # also register file to the root of each subpath if this file is an index.html
        if endswith(mountpath, "/index.html")

            # /docs/metrics and /docs/metrics/ are the same path
            # when HTTP is considered.

            # add the route without the trailing "/" character
            bare_path = getbefore(mountpath, "/index.html")
            push!(routes, bare_path)
            addroute(bare_path, filepath)
        end
    end

    return routes
end
