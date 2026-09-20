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
# Returns the value, or `nothing` for a miss. `mount_remainder` throws `ValidationError`
# (a 400) on a malformed escape or invalid UTF-8; that propagates, deliberately — it is the same
# boundary rule `Types.pathparams` applies to `{var}` routes (#70).
function _lookup_mount(table::Dict{String,V}, target::AbstractString, n_prefix::Int) where {V}
    key = Util.mount_remainder(target, n_prefix)
    key === nothing && return nothing
    return get(table, key, nothing)
end

# Default size above which a mounted file is STREAMED rather than held in memory (#41).
#
# `staticfiles` used to read every mounted file at startup and hold it for the process lifetime,
# with no cap: a folder holding a 500 MB video pinned 500 MB resident whether or not anything ever
# asked for it, and `Res.file` then materialised the whole body again per response, so N concurrent
# downloads cost N × filesize. 8 MiB is comfortably above any realistic SPA bundle — which is the
# case the capture exists to make fast — and far below the sizes where holding the bytes is the
# problem rather than the solution.
const MOUNT_STREAM_THRESHOLD = 8 * 1024 * 1024

# Default budget for `cache = :lazy`. Bytes, across the whole mount.
const MOUNT_CACHE_MAX_BYTES = 64 * 1024 * 1024

# How a mount decides where a file's bytes come from.
#
# `:eager`  — read at mount time and hold for the process lifetime. The historical behaviour, and
#             still the default: a dev server should serve its bundle from RAM.
# `:lazy`   — read on first request into a size-bounded LRU. Memory tracks the WORKING SET rather
#             than the folder, which is what #41 asked for: mounting a large media directory no
#             longer costs its full size at startup just in case.
# `:none`   — read per request, never held. What `dynamicfiles` has always done.
#
# Files over `stream_threshold` are streamed regardless of policy — there is no cache policy under
# which buffering a 2 GB file per concurrent request is the right answer.
struct MountPolicy
    cache::Symbol
    stream_threshold::Int
    cache_max_bytes::Int

    # INNER constructor, so it replaces the default one rather than competing with it. An outer
    # method with this signature would be *less* specific than the compiler-generated
    # `MountPolicy(::Symbol, ::Int, ::Int)` for `Int` arguments — which is exactly how it would be
    # called — so every validation below would be silently skipped.
    function MountPolicy(cache::Symbol, stream_threshold::Integer, cache_max_bytes::Integer)
        cache in (:eager, :lazy, :none) ||
            throw(ArgumentError("static mount: `cache` must be :eager, :lazy or :none — got $(repr(cache))"))
        stream_threshold >= 0 || throw(ArgumentError("static mount: `stream_threshold` must be >= 0, got $stream_threshold"))
        cache_max_bytes  >  0 || throw(ArgumentError("static mount: `cache_max_bytes` must be > 0, got $cache_max_bytes"))
        return new(cache, Int(stream_threshold), Int(cache_max_bytes))
    end
end

# The read-through cache for `:lazy`, or `nothing` for the policies that do not have one.
#
# `by = sizeof` makes the bound a BYTE budget rather than an entry count, which is the only bound
# that means anything here: 200 icons and 200 videos are not the same working set. LRUCache's own
# lock makes concurrent `get!` safe, which matters because every request runs on its own thread.
_mount_cache(policy::MountPolicy) =
    policy.cache === :lazy ?
        LRU{String,Vector{UInt8}}(maxsize = policy.cache_max_bytes, by = sizeof) : nothing

# One mounted file, with everything a response needs precomputed at mount time.
#
# The validators and content type are computed once, because a mount's answer to "what is this
# file" does not change between requests — which files exist is decided at mount time and stays
# decided (docs/design/static-serving-boundary.md §6). `bytes` is the eager snapshot; `stream` is
# fixed at mount time too, from the file's size against the policy.
struct MountedFile
    path::String
    bytes::Nullable{Vector{UInt8}}
    etag::Nullable{String}
    modtime::Nullable{DateTime}
    content_type::String
    stream::Bool
end

function MountedFile(path::String, policy::MountPolicy; etag, loadfile)
    # `loadfile` decides the body, so its result cannot be streamed from disk and its size is not
    # the file's size. Such a mount keeps the old read-it-all behaviour.
    streamed = isnothing(loadfile) && policy.stream_threshold > 0 &&
               filesize(path) > policy.stream_threshold
    body = (streamed || policy.cache !== :eager) ? nothing : _read_mount(path, loadfile)
    # A strong tag over a streamed file would mean hashing every byte at mount — exactly the whole
    # -file read the threshold exists to avoid. Fall back to the weak one and say so.
    effective_etag = (streamed && etag === :strong) ? :weak_stat : etag
    if streamed && etag === :strong
        @info "mountfolder: using a weak ETag for a streamed file; a strong tag would hash it whole" path=basename(path) size=filesize(path)
    end
    tag, modtime = Res.file_validators(path; etag = effective_etag, bytes = body)
    return MountedFile(path, body, tag, modtime, Res.file_content_type(path), streamed)
end

function _read_mount(path::String, loadfile)
    isnothing(loadfile) && return read(path)
    raw = loadfile(path)
    return raw isa Vector{UInt8} ? raw : Vector{UInt8}(codeunits(raw))
end

# Build the response for one mounted file, for THIS request.
#
# A response can no longer be prebuilt and handed out unchanged: whether it is a 200, a 304 or a
# 206 depends on the request's `If-None-Match` / `If-Modified-Since` / `Range`. `servecontent`
# decides that, and it is HTTP.jl public API precisely so callers do not re-derive the precondition
# table — weak-versus-strong tag comparison and the order the four preconditions are evaluated in
# are both easy to get plausibly wrong.
function _serve_mounted(req::HTTP.Request, mf::MountedFile, policy::MountPolicy, cache,
                        headers::Vector, loadfile, cache_control)
    extra = isnothing(cache_control) ? Pair{String,String}[] :
            Pair{String,String}["Cache-Control" => String(cache_control)]

    if mf.stream
        # Peak memory is one chunk buffer, not the file. The body is a cursor over an open handle
        # and is therefore single-use — which is why a streamed file is never cached, and why
        # `adopt_stream_io!` must hand the handle over (or close it when a 304/416 carries no body
        # at all, or the descriptor leaks on exactly the cheapest request).
        io = open(mf.path, "r")
        try
            resp = HTTP.servecontent(req, io; name = basename(mf.path), modtime = mf.modtime,
                                     content_type = mf.content_type, etag = mf.etag,
                                     headers = extra)
            Res.adopt_stream_io!(resp, io)
            return Res.apply_headers!(resp, headers)
        catch
            close(io)
            rethrow()
        end
    end

    source = if mf.bytes !== nothing
        mf.bytes
    elseif cache !== nothing
        get!(() -> _read_mount(mf.path, loadfile), cache, mf.path)
    else
        _read_mount(mf.path, loadfile)
    end
    resp = HTTP.servecontent(req, source; name = basename(mf.path), modtime = mf.modtime,
                             content_type = mf.content_type, etag = mf.etag, headers = extra)
    return Res.apply_headers!(resp, headers)
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
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:eager,
    stream_threshold::Integer=MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=MOUNT_CACHE_MAX_BYTES,
)
    files  = Dict{String,String}()
    table  = Dict{String,MountedFile}()
    policy = MountPolicy(cache, stream_threshold, cache_max_bytes)
    lru    = _mount_cache(policy)

    # The bytes are captured now, so the file this mount serves cannot change on disk afterwards.
    function addroute(_route, filepath, key)
        _table_insert!(files, key, filepath)
        table[key] = MountedFile(filepath, policy; etag = etag, loadfile = loadfile)
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
        mf = _lookup_mount(table, req.target, nprefix)
        mf === nothing && return notfound(req)
        return _serve_mounted(req, mf, policy, lru, headers, loadfile, cache_control)
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
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:eager,
    stream_threshold::Integer=MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=MOUNT_CACHE_MAX_BYTES,
)
    files  = Dict{String,String}()
    table  = Dict{String,MountedFile}()
    policy = MountPolicy(cache, stream_threshold, cache_max_bytes)
    lru    = _mount_cache(policy)

    function addroute(_route, filepath, key)
        _table_insert!(files, key, filepath)
        table[key] = MountedFile(filepath, policy; etag = etag, loadfile = loadfile)
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
            mf = _lookup_mount(table, req.target, nprefix)
            mf === nothing && return notfound(req)
            return _serve_mounted(req, mf, policy, lru, headers, loadfile, cache_control)
        end
    else
        # Bind the index's `MountedFile` outside the closure. The history fallback is an SPA
        # server's hottest path — every deep link and client-route refresh lands on it — and it used
        # to re-`read` index.html from disk per request while the directly-mounted `/index.html`
        # came from a captured snapshot (#40). It now shares the same snapshot, the same validators,
        # and therefore the same 304 behaviour as the direct route: a client that has the shell
        # cached revalidates a deep link with a 304 instead of refetching it.
        index_path = last(mounted[index_idx])
        index_mf   = MountedFile(index_path, policy; etag = etag, loadfile = loadfile)
        function (req::HTTP.Request)
            mf = _lookup_mount(table, req.target, nprefix)
            # A miss — or an unnameable path (`..`, an encoded separator) — is a client asking for
            # something no mounted file can be called. Under history mode that is still a client
            # route, so it gets the shell, matching `try_files $uri /index.html`, which does not
            # inspect the path either.
            target = mf === nothing ? index_mf : mf
            return _serve_mounted(req, target, policy, lru, headers, loadfile, cache_control)
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
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:none,
    stream_threshold::Integer=MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=MOUNT_CACHE_MAX_BYTES,
)
    # Which files exist here is decided once, at mount time. Serving a directory whose contents an
    # attacker can change is out of scope for this layer — see docs/design/static-serving-boundary.md.
    files  = Dict{String,String}()
    table  = Dict{String,MountedFile}()
    policy = MountPolicy(cache, stream_threshold, cache_max_bytes)
    lru    = _mount_cache(policy)
    function addroute(_route, filepath, key)
        _table_insert!(files, key, filepath)
        # `cache = :none` by default here: the CONTENT is re-read per request, which is the whole
        # point of this mount. The validators are still computed at mount time, as everywhere else
        # — they describe the snapshot the mount decided on, and re-`stat`ing per request is the
        # per-request filesystem work §6 removed on purpose.
        table[key] = MountedFile(filepath, policy; etag = etag, loadfile = loadfile)
        return nothing
    end
    mounted = mountfolder(folder, mountdir, addroute; include_hidden, allow_symlink_escape)

    segments = Util.mount_segments(mountdir)
    nprefix  = length(segments)
    notfound = router._404

    handler = function (req::HTTP.Request)
        mf = _lookup_mount(table, req.target, nprefix)
        mf === nothing && return notfound(req)
        return _serve_mounted(req, mf, policy, lru, headers, loadfile, cache_control)
    end
    _register_mount(ctx, router, segments, handler; bare = haskey(files, ""))

    return mounted
end
