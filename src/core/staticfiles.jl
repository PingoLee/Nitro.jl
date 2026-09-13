# ── Static, SPA and dynamic file mounts ─────────────────────────────────────────
# `staticfiles`, `spafiles`, `dynamicfiles`.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

function staticfiles(
    ctx::ServerContext,
    router::HTTP.Router,
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
)
    function addroute(currentroute, filepath)
        resp = Res.file(filepath; loadfile=loadfile, headers=headers)
        register_internal(ctx, router, GET, currentroute, () -> resp)
    end
    # The bytes are captured now, so the file this route serves cannot change on disk afterwards.
    mountfolder(folder, mountdir, addroute; include_hidden, allow_symlink_escape)
end

function spafiles(
    ctx::ServerContext,
    router::HTTP.Router,
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
)

    function addroute(currentroute, filepath)
        resp = Res.file(filepath; loadfile=loadfile, headers=headers)
        register_internal(ctx, router, GET, currentroute, () -> resp)
    end
    mounted = mountfolder(folder, mountdir, addroute; include_hidden, allow_symlink_escape)

    # Ask the mount what it registered rather than probing the filesystem again. The old form
    # (`isfile(joinpath(folder, "index.html"))`, which follows symlinks) reached straight past the
    # enumeration rules: a refused `index.html` was still served here on *every* unmatched path
    # under the mount, which is a strictly larger hole than the single route it was denied.
    #
    # Ask it by FILE, not by route name. A route name does not identify what produced it: an
    # `index.html` contributes both its own route and the bare directory route, so
    # `/<prefix>/index.html` is the direct route of `<folder>/index.html` and equally the *bare*
    # route of `<folder>/index.html/index.html`. Matching the name picks up the second shape and
    # points the fallback at a nested file the mount root never meant to serve — which is how this
    # gate previously needed an `isfile` conjunct bolted on to stay correct (#94). Matching the
    # filepath makes it correct by construction, because a *directory* is never a `mountable_files`
    # result, and it drops a `stat` that followed symlinks straight back past the enumeration rules
    # this gate exists to respect (#102).
    #
    # `mountable_files` returns `joinpath(root, rel)` verbatim — contractual, see its docstring — so
    # this comparison is exact and needs no filesystem call of its own.
    segments   = Util.mount_segments(mountdir)
    index_file = joinpath(folder, "index.html")
    index_idx  = findfirst(pair -> last(pair) == index_file, mounted)

    if index_idx === nothing
        @warn "spafiles: no servable 'index.html' in $folder. History mode fallback will not work."
    else
        # Bind outside the closure. `last(mounted[index_idx])` is `index_file` by construction, and
        # spelling it this way is what makes "serve exactly the file the mount kept" visible to the
        # next reader — but the closure must capture the String, not `mounted` and a
        # `Union{Nothing,Int}` index, or every fallback request pays a dynamic dispatch and the whole
        # route table stays alive for the process lifetime.
        index_path     = last(mounted[index_idx])
        fallback_route = Util.mount_route(vcat(segments, "**"))
        register_internal(ctx, router, GET, fallback_route, (req::HTTP.Request) ->
            Res.file(index_path; loadfile=loadfile, headers=headers))
    end

    # NOTE: the fallback route is deliberately NOT appended to `mounted` — it is a catch-all, not a
    # mounted file, and it has no filepath of its own to pair with.
    return mounted
end

function dynamicfiles(
    ctx::ServerContext,
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
    function addroute(currentroute, filepath)
        register_internal(ctx, router, GET, currentroute, () ->
            Res.file(filepath; loadfile=loadfile, headers=headers))
    end
    mountfolder(folder, mountdir, addroute; include_hidden, allow_symlink_escape)
end
