# ── Static, SPA and dynamic file mounts ─────────────────────────────────────────
# `staticfiles`, `spafiles`, `dynamicfiles`.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.
#
# ── Why one prefix handler and not a route per file (#221) ──────────────────────
#
# A mount registers exactly TWO routes — `/<prefix>/**` and the bare `/<prefix>` — and resolves
# the request against a table built at mount time. It used to register one literal route per
# enumerated file, which is what every one of #101, #94, #121 and part of #95 came out of: the
# router compares path segments byte for byte and never percent-decodes, so the registered route
# and the request a conforming client sends were two independent strings that had to be made to
# agree. They no longer are.
#
# Every comparable framework already does it this way — Go `net/http.FileServer`, Express
# `serve-static`/`send`, Phoenix `Plug.Static`, Django `static.serve`, nginx. All of them mount one
# prefix handler and resolve the **percent-decoded** request path per request. None registers a
# literal route per enumerated file, so none of them can register an unreachable one.
#
# **Where Nitro deliberately differs from all five: the lookup resolves against the ENUMERATED SET,
# never against the filesystem.** `%2e%2e%2f` decodes to `../`, which is simply not a key, so the
# request 404s without a single `stat`. That is strictly stronger than the `safe_join` /
# `UP_PATH_REGEXP` checks those frameworks need precisely because they *do* touch the filesystem —
# and it is why `HTTP.fileserver`, which resolves against the filesystem and applies none of
# `mountable_files`' refusals, is not used here. Adopting it would serve `.env` and escaping
# symlinks again (#20).
#
# `mountable_files` is untouched by all of this. Which files are exposed is still decided once, at
# mount time, by the same refusals — dotfiles, symlink containment, route-pattern names,
# non-regular files. See docs/design/static-serving-boundary.md.

# `**` matches ONE OR MORE trailing segments: `HTTP.Handlers.match` advances the cursor straight to
# `length(segments) + 1` when it takes the doublestar branch, so it can never match zero. The bare
# mount route is therefore a SEPARATE registration — without it `GET /static` 404s while
# `GET /static/index.html` works, which is the #93/#94 bare-route behaviour regressing.
#
# Both routes share one handler; `mount_remainder` returns `""` for the bare one, which is the key
# `mountfolder` gives a mount-root `index.html`.
#
# `bare` stays CONDITIONAL on the mount actually being able to answer it — i.e. on a mount-root
# `index.html` having been enumerated. Registering it unconditionally would have a mount claim
# `/static` even when it has nothing to serve there, replacing an application route at that exact
# path (HTTP.jl's `register!` warns and the later registration wins). Under per-file registration
# the bare route appeared only when `mountfolder` emitted one, and that is preserved here.
function _register_mount(ctx::App, router::HTTP.Router, segments::Vector{String}, handler::F;
                         bare::Bool) where {F}
    register_internal(ctx, router, GET, Util.mount_route(vcat(segments, "**")), handler)
    bare && register_internal(ctx, router, GET, Util.mount_route(segments), handler)
    return nothing
end

# Fill the mount table, warning when two enumerated files claim one key.
#
# An `index.html` contributes TWO keys naming the same file — its own and its parent directory —
# so a directory literally named `index.html` collides with the file beside it (#94's shape, moved
# from the route space into the key space). Under per-file registration HTTP.jl announced this
# itself with `replacing existing registered route`; one catch-all silences that, so say it here.
# Last write wins either way, which is the behaviour that registration had.
function _table_insert!(files::Dict{String,String}, key::String, filepath::String)
    prior = get(files, key, nothing)
    if prior !== nothing && prior != filepath
        @warn "mountfolder: two enumerated files claim the same mount key; the later one wins" key=key previous=prior now=filepath
    end
    files[key] = filepath
    return nothing
end

# Resolve a request against a mount table.
#
# Returns the filesystem path, or `nothing` for a miss. `mount_remainder` throws `ValidationError`
# (a 400) on a malformed escape or invalid UTF-8; that propagates, deliberately — it is the same
# boundary rule `Types.pathparams` applies to `{var}` routes (#70).
function _lookup_mount(files::Dict{String,String}, target::AbstractString, n_prefix::Int)
    key = Util.mount_remainder(target, n_prefix)
    key === nothing && return nothing
    return get(files, key, nothing)
end

function staticfiles(
    ctx::App,
    router::HTTP.Router,
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
)
    files     = Dict{String,String}()
    responses = Dict{String,HTTP.Response}()

    # The bytes are captured now, so the file this mount serves cannot change on disk afterwards.
    # One `Response` per file, reused for every request to it — safe because Nitro's write path
    # (`src/core/transport.jl::_write_response_body!`) does not consume a body.
    function addroute(_route, filepath, key)
        _table_insert!(files, key, filepath)
        responses[key] = Res.file(filepath; loadfile=loadfile, headers=headers)
        return nothing
    end
    mounted = mountfolder(folder, mountdir, addroute; include_hidden, allow_symlink_escape)

    segments = Util.mount_segments(mountdir)
    nprefix  = length(segments)
    # Capture the router's OWN 404 rather than hardcoding one. The `**` route now *matches* every
    # unmatched path under the prefix, so a miss never reaches the router's not-found handler on
    # its own — and an app that supplied a custom one through `Service(router = Router(my404))`
    # would have had it silently disabled under the mount.
    notfound = router._404

    handler = function (req::HTTP.Request)
        key = Util.mount_remainder(req.target, nprefix)
        key === nothing && return notfound(req)
        resp = get(responses, key, nothing)
        return resp === nothing ? notfound(req) : resp
    end
    _register_mount(ctx, router, segments, handler; bare = haskey(files, ""))

    return mounted
end

function spafiles(
    ctx::App,
    router::HTTP.Router,
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
)
    files     = Dict{String,String}()
    responses = Dict{String,HTTP.Response}()

    function addroute(_route, filepath, key)
        _table_insert!(files, key, filepath)
        responses[key] = Res.file(filepath; loadfile=loadfile, headers=headers)
        return nothing
    end
    mounted = mountfolder(folder, mountdir, addroute; include_hidden, allow_symlink_escape)

    # Ask the mount what it enumerated rather than probing the filesystem again. The old form
    # (`isfile(joinpath(folder, "index.html"))`, which follows symlinks) reached straight past the
    # enumeration rules: a refused `index.html` was still served here on *every* unmatched path
    # under the mount, which is a strictly larger hole than the single route it was denied.
    #
    # Ask it by FILE, not by key. A key does not identify what produced it: an `index.html`
    # contributes both its own key and its parent directory's, so `"index.html"` is the key of
    # `<folder>/index.html` and equally the *bare* key of `<folder>/index.html/index.html`. Matching
    # the name picks up the second shape and points the fallback at a nested file the mount root
    # never meant to serve — which is how this gate previously needed an `isfile` conjunct bolted on
    # to stay correct (#94). Matching the filepath makes it correct by construction, because a
    # *directory* is never a `mountable_files` result, and it drops a `stat` that followed symlinks
    # straight back past the enumeration rules this gate exists to respect (#102).
    #
    # `mountable_files` returns `joinpath(root, rel)` verbatim — contractual, see its docstring — so
    # this comparison is exact and needs no filesystem call of its own.
    segments   = Util.mount_segments(mountdir)
    nprefix    = length(segments)
    notfound   = router._404
    index_file = joinpath(folder, "index.html")
    index_idx  = findfirst(pair -> last(pair) == index_file, mounted)

    handler = if index_idx === nothing
        @warn "spafiles: no servable 'index.html' in $folder. History mode fallback will not work."
        # No fallback: behave exactly like `staticfiles`. Registering a catch-all that 404s is not
        # the same as not registering one — but it is here, because the handler defers to the
        # router's own not-found rather than inventing a response.
        function (req::HTTP.Request)
            key = Util.mount_remainder(req.target, nprefix)
            key === nothing && return notfound(req)
            resp = get(responses, key, nothing)
            return resp === nothing ? notfound(req) : resp
        end
    else
        # Bind outside the closure, and build the fallback response ONCE. The history fallback is
        # an SPA server's hottest path — every deep link and client-route refresh lands on it — and
        # it used to re-`read` index.html from disk and allocate a fresh `Response` per request
        # while the directly-mounted `/index.html` was served from a cached object (#40). Caching it
        # is safe for the same reason the mounted responses are: the write path does not consume a
        # body.
        index_path  = last(mounted[index_idx])
        index_resp  = Res.file(index_path; loadfile=loadfile, headers=headers)
        function (req::HTTP.Request)
            key = Util.mount_remainder(req.target, nprefix)
            # An unnameable path (`..`, an encoded separator) is a client asking for something no
            # mounted file can be called. Under history mode that is still a client route, so it
            # gets the shell — matching `try_files $uri /index.html`, which does not inspect the
            # path either.
            key === nothing && return index_resp
            resp = get(responses, key, nothing)
            return resp === nothing ? index_resp : resp
        end
    end
    _register_mount(ctx, router, segments, handler; bare = haskey(files, ""))

    # NOTE: neither registered route is appended to `mounted` — they are catch-alls, not mounted
    # files, and have no filepath of their own to pair with.
    return mounted
end

function dynamicfiles(
    ctx::App,
    router::Router,
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
)
    # Which files exist here is decided once, at mount time. Serving a directory whose contents an
    # attacker can change is out of scope for this layer — see docs/design/static-serving-boundary.md.
    files = Dict{String,String}()
    function addroute(_route, filepath, key)
        _table_insert!(files, key, filepath)
        return nothing
    end
    mounted = mountfolder(folder, mountdir, addroute; include_hidden, allow_symlink_escape)

    segments = Util.mount_segments(mountdir)
    nprefix  = length(segments)
    notfound = router._404

    handler = function (req::HTTP.Request)
        filepath = _lookup_mount(files, req.target, nprefix)
        filepath === nothing && return notfound(req)
        return Res.file(filepath; loadfile=loadfile, headers=headers)
    end
    _register_mount(ctx, router, segments, handler; bare = haskey(files, ""))

    return mounted
end
