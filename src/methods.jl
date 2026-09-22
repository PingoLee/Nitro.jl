# This is where methods are coupled to a global state

"""
    resetstate()

Reset all the internal state variables
"""
function resetstate()
    # prevent context reset when created at compile-time
    if (@__MODULE__) == Nitro
        CONTEXT[] = Nitro.Core.App()
        Nitro.Workers.reset_runtime!()
    end
end

function serve(; kwargs...)
    async = Base.get(kwargs, :async, false)
    # Whether the server this `finally` would tear down is OURS to tear down. Decided from
    # the context *before* the call, not from a flag set after it: if something is already
    # serving, `Core.serve` rejects this call and that server belongs to somebody else —
    # terminating it here would do the very thing the rejection message asks the caller to do
    # deliberately, making a refused `serve()` lethal to a healthy one. Reading the context up
    # front also still cleans up when a throw lands *after* the handle was installed, which a
    # post-hoc `started = true` would miss.
    ours = !isopen(CONTEXT[].service)
    try
        # Returns the running `HTTP.Server` when async; `nothing` in blocking mode (the
        # server is already down by then, so the handle would be useless). Either way the
        # handle is safe to display — `Nitro.Core.NitroStreamHandler` gives it a `show`
        # that prints only the address, never the secrets captured in handler closures.
        return Nitro.Core.serve(CONTEXT[]; kwargs...)
    finally
        # close server on exit if we aren't running asynchronously
        if !async && ours
            try
                terminate()
            catch e
                # This path's contract is already "Ctrl-C is the quiet exit". `terminate` now
                # rethrows an interrupt raised inside a shutdown hook or the drain (#185), but it
                # does so only AFTER completing the teardown, so there is nothing left to clean
                # up — and printing a stacktrace over a clean shutdown would be noise. Anything
                # else is a real teardown failure and stays loud.
                e isa InterruptException || rethrow()
            finally
                # only reset state on exit if we aren't running asynchronously & are running it interactively
                isinteractive() && resetstate()
            end
        end
    end
end


"""
    serveparallel(; middleware::Vector=[], handler=stream_handler, host="127.0.0.1", port=8080, serialize=true, async=false, catch_errors=true, docs=true, metrics=true, kwargs...)

"""
function serveparallel(; kwargs...)
    @warn "serveparallel() is deprecated. serve() now runs in parallel by default using Threads.@spawn. Please use serve() instead."
    serve(; kwargs...)
end


"""
    worker_startup(; kwargs...)

Create a lifecycle middleware that starts `Nitro.Workers` when `serve()` starts and
shuts the worker runtime down when the server terminates.
"""
worker_startup(; kwargs...) = Nitro.Workers.startup(CONTEXT[]; kwargs...)


### Core Routing Functions (Internal plumbing for path() and urlpatterns()) ###

function route(methods::Vector{String}, path::Union{String,HOFRouter}, func::Function)
    for method in methods
        Nitro.Core.register(CONTEXT[], method, path, func)
    end
end

# This variation supports the do..block syntax
route(func::Function, methods::Vector{String}, path::Union{String,HOFRouter}) = route(methods, path, func)


"""
    staticfiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing,
                include_hidden::Bool=false, allow_symlink_escape::Bool=false,
                etag=:weak_stat, cache_control=nothing, cache=:eager,
                stream_threshold=8*1024*1024, cache_max_bytes=64*1024*1024)

Mount the servable files inside `folder` under `mountdir`, reading each one **once at startup** —
fast to serve, but a change on disk needs a restart. Use [`dynamicfiles`](@ref) to re-read per
request, or [`spafiles`](@ref) for a single-page app.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

It is also **validated**, and throws `ArgumentError` at mount time rather than registering a mount
that cannot work. A segment is refused when it would register as a router pattern (`*`, `**`, or one
containing `{`/`}`) — the rule that has always applied to filenames, so a mount cannot claim URLs a
file may not — or when it is not a legal URL path segment (outside RFC 3986 `pchar`). The router
compares path segments byte for byte and never percent-decodes, so `"my static"` and `"café"` are
refused while `"my%20static"` and `"caf%C3%A9"` mount and serve: the encoded spelling is the one a
conforming client sends. A relative dot-segment (`.`, `..`) is refused too, because clients strip it
before sending.

Note `"café"`, `"a#b"`, `"a|b"` and `"100%"` *were* reachable by a client that sends raw bytes instead
of encoding them (curl does), so refusing them takes a working mount away from those callers, and the
encoded spelling is a different byte string that will not answer them. Only a space, a `?` and
control characters were strictly unmatchable.

Returns `Vector{Pair{String,String}}` — `route => filepath` for everything it registered, in
registration order. An `index.html` contributes two pairs naming the *same* file: its own route and
the bare directory route (`/docs/index.html` also registers `/docs`, and a top-level one registers
`/`). Use `first.(result)` for the routes alone.

Not every file in `folder` is served. These are refused:

- **Hidden entries** — any path component starting with `.` *relative to `folder`*, so `.env` and
  everything under `.git/`. A symlink is judged by what it resolves to as well as by its own name.
- **Symlinks resolving outside `folder`**, so `data.csv -> /etc/passwd` is not served.
- **Filenames the router reads as patterns** — `*` and `**` are wildcards that would shadow sibling
  URLs, and a name containing `{` or `}` is parsed as a path parameter and throws at registration,
  which would stop the server booting.
- **Anything that is not a regular file** — symlinked directories, FIFOs, devices.

A filename that needs percent-encoding is **not** refused — it is served at its **encoded route**.
`café.txt` mounts at `/static/caf%C3%A9.txt` and `my file.txt` at `/static/my%20file.txt`, which are
the URLs a conforming client sends; the router compares path segments byte for byte and never
decodes, so **no conforming client** could reach the unencoded spellings. The returned pair carries
the encoded route and the raw filesystem path, so **do not re-derive one from the other** — read the
route from `first(pair)` rather than rebuilding it from the filename.

Only characters that RFC 3986 forbids in a path segment are encoded, so a name that already works
keeps its exact URL: `report(1).txt`, `a+b.txt`, `v1.2~beta.txt`, `a:b.txt` and `a@b.txt` are all
unchanged. The two costs, both real: a **literal `%`** in a filename is itself encoded, so
`my%20file.txt` moves to `/static/my%2520file.txt` (it has to — otherwise one URL would name both
that file and the encoded form of `my file.txt`); and a non-browser client that was sending raw
UTF-8 bytes to reach `café.txt` gets a 404, because `café` and `caf%C3%A9` are different byte
strings under a byte-exact matcher.

`include_hidden=true` serves dotfiles and `allow_symlink_escape=true` serves escaping symlinks; both
widen what is publicly reachable, so set them deliberately. Note they interact: with
`allow_symlink_escape=true`, a link pointing at a dotfile *outside* the folder is served regardless
of `include_hidden`, because the hidden rule is only meaningful relative to the mount.

These rules are evaluated once, at mount time. A directory whose contents untrusted users can change
belongs behind a reverse proxy — see `docs/design/static-serving-boundary.md`.

To serve a directory that is itself dotted, mount it as its own root — the rule tests components
*below* `folder`, never `folder`'s own name:

```julia
staticfiles("public/.well-known", ".well-known")
```

Note this registers only the files present at startup; anything written later (an ACME
`acme-challenge` token, say) needs its own route.

# Caching, validators and memory

| Keyword | Default | Effect |
|---|---|---|
| `etag` | `:weak_stat` | `W/"<size>-<mtime>"`. Also `:strong` (sha256 of the body served), a `String` used verbatim, or `nothing` for no `ETag` |
| `cache_control` | `nothing` | emitted verbatim when given. **No default is invented** — hashed build output wants a year and an unhashed `index.html` wants zero, and guessing high pins a client to a stale asset |
| `cache` | ``:eager`` | `:eager` reads at mount and holds; `:lazy` reads on first request into a byte-bounded LRU; `:none` re-reads per request |
| `stream_threshold` | 8 MiB | a file larger than this is streamed in chunks rather than buffered, so peak memory is a buffer and not the file. `0` disables streaming |
| `cache_max_bytes` | 64 MiB | the `:lazy` budget, in bytes across the whole mount |

The mount answers conditional GETs (`If-None-Match` / `If-Modified-Since` → `304`) and byte ranges
(`Range` → `206`, an unsatisfiable one → `416`). [`Res.file`](@ref) gives a handler the same thing.

**Validators describe the bytes actually sent.** Under `:eager` and `:lazy` those are a snapshot,
so a change on disk is not picked up and the `ETag` does not move either; under `:none` both track
the file. A mount never re-`stat`s to *detect* a change — which files exist is decided once, at
mount time.

**`etag = :strong` costs what it measures.** It hashes the body it is about to send, so under
`:eager` that is once per file at mount, but under `:none` — and for an entry too large for the
`:lazy` budget — it is a full hash **on every request**. `dynamicfiles(dir; etag = :strong)` over a
100 MB file hashes 100 MB per request. `:weak_stat` is the default for this reason.

**A non-GET request under the mount prefix is a `405`, not a `404`**, because the mount's
catch-all matches the path and carries `GET` only.

"""
staticfiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:eager,
    stream_threshold::Integer=Nitro.Core.MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=Nitro.Core.MOUNT_CACHE_MAX_BYTES
) = Nitro.Core.staticfiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape, etag, cache_control, cache, stream_threshold, cache_max_bytes)


"""
    spafiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing,
             include_hidden::Bool=false, allow_symlink_escape::Bool=false)

Mount `folder` for a Single Page Application. In addition to registering its servable files, this
registers a catch-all route under `mountdir` that serves `index.html` for any unmatched request,
enabling SPA History Mode routing.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

It is also **validated**, and throws `ArgumentError` at mount time rather than registering a mount
that cannot work. A segment is refused when it would register as a router pattern (`*`, `**`, or one
containing `{`/`}`) — the rule that has always applied to filenames, so a mount cannot claim URLs a
file may not — or when it is not a legal URL path segment (outside RFC 3986 `pchar`). The router
compares path segments byte for byte and never percent-decodes, so `"my static"` and `"café"` are
refused while `"my%20static"` and `"caf%C3%A9"` mount and serve: the encoded spelling is the one a
conforming client sends. A relative dot-segment (`.`, `..`) is refused too, because clients strip it
before sending.

Note `"café"`, `"a#b"`, `"a|b"` and `"100%"` *were* reachable by a client that sends raw bytes instead
of encoding them (curl does), so refusing them takes a working mount away from those callers, and the
encoded spelling is a different byte string that will not answer them. Only a space, a `?` and
control characters were strictly unmatchable.

Returns `Vector{Pair{String,String}}` — `route => filepath` for everything it registered, in
registration order. An `index.html` contributes two pairs naming the *same* file: its own route and
the bare directory route (`/docs/index.html` also registers `/docs`, and a top-level one registers
`/`). Use `first.(result)` for the routes alone.

Which files are servable — and the `include_hidden` / `allow_symlink_escape` opt-outs — is described
in [`staticfiles`](@ref); the same rules apply here. Three SPA-specific consequences:

- The history-mode fallback is registered **only if `index.html` itself is servable.** If it is
  refused (an escaping symlink, say), the fallback is skipped and a warning is logged, rather than
  serving through the mount rules on every unmatched path. Servability is decided by looking the
  file up in what the mount registered, so the fallback serves exactly the bytes the mount chose.
- The fallback route (`/<prefix>/**`) is **not** in the returned vector. It is a catch-all rather
  than a mounted file, and it has no filepath of its own to pair with.
- Because the fallback answers any unmatched path under the mount, a file that *was* refused reads
  as `index.html` with a 200 rather than a 404. That is not a leak, but it can be confusing in logs.
  A filename needing percent-encoding is no longer in that class: it is mounted at its encoded
  route, so `/<prefix>/caf%C3%A9.txt` serves the asset rather than silently resolving to the app
  shell ([#121](https://github.com/PingoLee/Nitro.jl/issues/121)).

# Caching, validators and memory

| Keyword | Default | Effect |
|---|---|---|
| `etag` | `:weak_stat` | `W/"<size>-<mtime>"`. Also `:strong` (sha256 of the body served), a `String` used verbatim, or `nothing` for no `ETag` |
| `cache_control` | `nothing` | emitted verbatim when given. **No default is invented** — hashed build output wants a year and an unhashed `index.html` wants zero, and guessing high pins a client to a stale asset |
| `cache` | ``:eager`` | `:eager` reads at mount and holds; `:lazy` reads on first request into a byte-bounded LRU; `:none` re-reads per request |
| `stream_threshold` | 8 MiB | a file larger than this is streamed in chunks rather than buffered, so peak memory is a buffer and not the file. `0` disables streaming |
| `cache_max_bytes` | 64 MiB | the `:lazy` budget, in bytes across the whole mount |

The mount answers conditional GETs (`If-None-Match` / `If-Modified-Since` → `304`) and byte ranges
(`Range` → `206`, an unsatisfiable one → `416`). [`Res.file`](@ref) gives a handler the same thing.

**Validators describe the bytes actually sent.** Under `:eager` and `:lazy` those are a snapshot,
so a change on disk is not picked up and the `ETag` does not move either; under `:none` both track
the file. A mount never re-`stat`s to *detect* a change — which files exist is decided once, at
mount time.

**`etag = :strong` costs what it measures.** It hashes the body it is about to send, so under
`:eager` that is once per file at mount, but under `:none` — and for an entry too large for the
`:lazy` budget — it is a full hash **on every request**. `dynamicfiles(dir; etag = :strong)` over a
100 MB file hashes 100 MB per request. `:weak_stat` is the default for this reason.

**A non-GET request under the mount prefix is a `405`, not a `404`**, because the mount's
catch-all matches the path and carries `GET` only.

"""
spafiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:eager,
    stream_threshold::Integer=Nitro.Core.MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=Nitro.Core.MOUNT_CACHE_MAX_BYTES
) = Nitro.Core.spafiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape, etag, cache_control, cache, stream_threshold, cache_max_bytes)


"""
    dynamicfiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing,
                 include_hidden::Bool=false, allow_symlink_escape::Bool=false,
                 etag=:weak_stat, cache_control=nothing, cache=:none,
                 stream_threshold=8*1024*1024, cache_max_bytes=64*1024*1024)

Mount the servable files inside `folder` under `mountdir`, re-reading each one **on every request**
so changes on disk are picked up without a restart. Use [`staticfiles`](@ref) to snapshot at startup
instead.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

It is also **validated**, and throws `ArgumentError` at mount time rather than registering a mount
that cannot work. A segment is refused when it would register as a router pattern (`*`, `**`, or one
containing `{`/`}`) — the rule that has always applied to filenames, so a mount cannot claim URLs a
file may not — or when it is not a legal URL path segment (outside RFC 3986 `pchar`). The router
compares path segments byte for byte and never percent-decodes, so `"my static"` and `"café"` are
refused while `"my%20static"` and `"caf%C3%A9"` mount and serve: the encoded spelling is the one a
conforming client sends. A relative dot-segment (`.`, `..`) is refused too, because clients strip it
before sending.

Note `"café"`, `"a#b"`, `"a|b"` and `"100%"` *were* reachable by a client that sends raw bytes instead
of encoding them (curl does), so refusing them takes a working mount away from those callers, and the
encoded spelling is a different byte string that will not answer them. Only a space, a `?` and
control characters were strictly unmatchable.

Returns `Vector{Pair{String,String}}` — `route => filepath` for everything it registered, in
registration order. An `index.html` contributes two pairs naming the *same* file: its own route and
the bare directory route (`/docs/index.html` also registers `/docs`, and a top-level one registers
`/`). Use `first.(result)` for the routes alone.

Which files are servable — and the `include_hidden` / `allow_symlink_escape` opt-outs — is described
in [`staticfiles`](@ref); the same rules apply here. They are evaluated **once, at mount time**: this
re-reads file *contents* per request, not the directory listing or the rules. Only files present at
startup get a route, so a directory that gains files at runtime needs a handler, not a mount.

That makes this the wrong tool for a directory untrusted users can write to — a file swapped for a
symlink after startup is not re-checked. Put a reverse proxy in front of such a directory; see
`docs/design/static-serving-boundary.md`.

# Caching, validators and memory

| Keyword | Default | Effect |
|---|---|---|
| `etag` | `:weak_stat` | `W/"<size>-<mtime>"`. Also `:strong` (sha256 of the body served), a `String` used verbatim, or `nothing` for no `ETag` |
| `cache_control` | `nothing` | emitted verbatim when given. **No default is invented** — hashed build output wants a year and an unhashed `index.html` wants zero, and guessing high pins a client to a stale asset |
| `cache` | ``:none`` | `:eager` reads at mount and holds; `:lazy` reads on first request into a byte-bounded LRU; `:none` re-reads per request |
| `stream_threshold` | 8 MiB | a file larger than this is streamed in chunks rather than buffered, so peak memory is a buffer and not the file. `0` disables streaming |
| `cache_max_bytes` | 64 MiB | the `:lazy` budget, in bytes across the whole mount |

The mount answers conditional GETs (`If-None-Match` / `If-Modified-Since` → `304`) and byte ranges
(`Range` → `206`, an unsatisfiable one → `416`). [`Res.file`](@ref) gives a handler the same thing.

**Validators describe the bytes actually sent.** Under `:eager` and `:lazy` those are a snapshot,
so a change on disk is not picked up and the `ETag` does not move either; under `:none` both track
the file. A mount never re-`stat`s to *detect* a change — which files exist is decided once, at
mount time.

**`etag = :strong` costs what it measures.** It hashes the body it is about to send, so under
`:eager` that is once per file at mount, but under `:none` — and for an entry too large for the
`:lazy` budget — it is a full hash **on every request**. `dynamicfiles(dir; etag = :strong)` over a
100 MB file hashes 100 MB per request. `:weak_stat` is the default for this reason.

**A non-GET request under the mount prefix is a `405`, not a `404`**, because the mount's
catch-all matches the path and carries `GET` only.

"""
dynamicfiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:none,
    stream_threshold::Integer=Nitro.Core.MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=Nitro.Core.MOUNT_CACHE_MAX_BYTES
) = Nitro.Core.dynamicfiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape, etag, cache_control, cache, stream_threshold, cache_max_bytes)

"""
    getexternalurl()

Return the external URL of the service
"""
function getexternalurl() :: String
    external_url = CONTEXT[].service.external_url[]
    if isnothing(external_url)
        error("getexternalurl() is only available when the service is running")
    end
    return external_url
end

"""
    url(name; kwargs...)

Build a URL path for a named route registered through `path(..., name="...")`.
Keyword arguments fill the route parameters.
"""
function url(name::String; kwargs...)
    return Nitro.Core.Routing.url(CONTEXT[], name; kwargs...)
end

"""
    internalrequest(req::Nitro.Request; middleware::Vector=[], serialize::Bool=true, catch_errors=true, context=missing)

Sends an internal request to the server, allowing for communication between different parts of the application.

Errors go through the same error handling `serve` uses. With `catch_errors=true` (the default), an
exception thrown by a handler **or by middleware** is logged with its backtrace and comes back as
the generic `500` response, instead of being raised. A `ValidationError` comes back as a `400`,
recorded at `@debug` only. An `InterruptException` from middleware is still raised. Pass `catch_errors=false` to have the exception raised to the caller,
which is usually what a test asserting on it wants.

!!! warning "A streamed response body is yours to close"
    This runs the whole pipeline **minus the socket layer**, so it never reaches the write path
    that drains and closes a streaming body. A handler using `Res.file(req, path; stream = true)`,
    or a mounted file above `stream_threshold`, therefore hands back a response whose body is an
    **open cursor**. Drain it with `HTTP.body_read!` until it returns `0`, or call
    `HTTP.body_close!` — otherwise the file handle stays open, which on Windows also blocks
    deleting the file. Over a real socket this never applies: the write path always closes.
"""
internalrequest(req::Nitro.Request; middleware::Vector=[], serialize::Bool=true, catch_errors=true, context=missing) = 
    Nitro.Core.internalrequest(CONTEXT[], req; middleware, serialize, catch_errors, context)

"""
    router(prefix::String = ""; 
                tags::Vector{String} = Vector{String}(), 
                middleware::Nullable{Vector} = nothing)

Create a new router instance.

# Arguments
- `prefix::String`: A string to be prefixed to all routes in this router.
- `tags::Vector{String}`: A vector of strings to tag the router for documentation and management purposes.
- `middleware::Nullable{Vector}`: Optional middleware to be applied to all routes in the router.

# Returns
A router instance that can be used to define and manage a set of related routes.
"""
function router(prefix::String = ""; 
                tags::Vector{String} = Vector{String}(), 
                middleware::Nullable{Vector} = nothing)

    return Nitro.Core.router(CONTEXT[], prefix; tags, middleware)
end

"""
    urlpatterns(prefix, routes...)

Register routes under a common prefix. Automatically uses the global context.
See `Nitro.Core.Routing.urlpatterns` for details.
"""
urlpatterns(prefix::String, routes::Nitro.Core.Routing.RouteDefinition...) = 
    Nitro.Core.Routing.urlpatterns(CONTEXT[], prefix, routes...)

urlpatterns(prefix::String, routes::Vector{Nitro.Core.Routing.RouteDefinition}) =
    Nitro.Core.Routing.urlpatterns(CONTEXT[], prefix, routes)




### Cookie functions ###

"""
    configcookies(defaults::Dict)
    configcookies(; kwargs...)

Configure global cookie defaults for the application.
"""
function configcookies(defaults::Dict)
    CONTEXT[].service.cookies[] = Nitro.Core.load_cookie_settings!(defaults)
end

function configcookies(; kwargs...)
    configcookies(Dict(string(k) => v for (k, v) in kwargs))
end

"""
    get_cookie(req::Nitro.Request, name::String, default::Any=nothing; kwargs...)

Get a cookie value from an Nitro request. Automatically handles decryption if a secret key is configured.
"""
function get_cookie(req::Nitro.Request, name::String, default::Any=nothing; kwargs...)
    secret_key = CONTEXT[].service.cookies[].secret_key
    # If encrypted is not explicitly passed, we default to whatever the global config says (based on secret_key presence)
    encrypted = Base.get(kwargs, :encrypted, !isnothing(secret_key))
    return Nitro.Core.get_cookie(req, name, default; secret_key=secret_key, encrypted=encrypted, kwargs...)
end

"""
    set_cookie!(res::Nitro.Response, name::String, value::Any; kwargs...)

Set a cookie on an Nitro response using the global cookie configuration.
"""
function set_cookie!(res::Nitro.Response, name::String, value::Any; kwargs...)
    return Nitro.Core.set_cookie!(res, name, value; config=CONTEXT[].service.cookies[], kwargs...)
end



### Terminate Function ###

# No docstring here on purpose: the loop below reassigns `@doc(Nitro.Core.terminate)` onto this
# binding, so anything written here is silently discarded (it is why `terminate` rendered with an
# empty body in `docs/src/api.md`). The canonical docstring lives on `Nitro.Core.terminate`.
terminate(context::App; timeout::Nullable{Real} = nothing) =
    Nitro.Core.terminate(context; timeout)
terminate(; timeout::Nullable{Real} = nothing) = terminate(CONTEXT[]; timeout)


### Setup Docs Strings ###


# `staticfiles`/`dynamicfiles`/`spafiles` are deliberately absent: they carry their own docstrings
# above, and `Nitro.Core` has none for them, so propagating would replace real docs with a stub.
for method in [:serve, :terminate, :internalrequest]
    eval(quote
        @doc (@doc(Nitro.Core.$method)) $method
    end)
end





# ── The explicit `App` surface (#31) ────────────────────────────────────────────────────
#
# Everything above this line is the SINGLETON convenience layer: one-argument-shorter forms
# that read and write the process-wide `CONTEXT[]`. Every one of them is defined HERE, in
# `Nitro`, which means it SHADOWS the same-named function `using .Core` brought in from
# `Nitro.Core` — so before this block, `Nitro.urlpatterns` had only the `CONTEXT[]` methods
# and `Core`'s `(ctx, …)` methods were unreachable through `using Nitro`. Exporting `App`
# without these forwards would have produced a public type with no public API taking it.
#
# Each forward is deliberately thin: it adds the `App` method to the `Nitro`-level function
# and hands straight to the implementation, which already took an app-shaped first argument.
# No behavior is defined here.
#
# `route` is absent on purpose -- it is plumbing for `path`/`urlpatterns`, not public API
# (nitro-core §3). `resetstate` is absent because it is singleton-shaped by definition: the
# `App` equivalent is constructing a new `App`.

"""
    serve(app::App; kwargs...)

Serve `app`. Same keywords as [`serve()`](@ref); see [`App`](@ref) for the handle.

Unlike the singleton form this never calls `resetstate()` on exit — that resets the global
context, which has nothing to do with `app`. A blocking call still terminates the listener
it started.
"""
function serve(app::App; kwargs...)
    async = Base.get(kwargs, :async, false)
    # Same reasoning as the singleton form above: decide ownership BEFORE the call, so a
    # rejected `serve` never tears down the healthy server that caused the rejection.
    ours = !isopen(app.service)
    try
        return Nitro.Core.serve(app; kwargs...)
    finally
        if !async && ours
            try
                terminate(app)
            catch e
                # Same guard as the singleton form above, and for a sharper reason: an exception
                # out of a `finally` REPLACES whatever was propagating. Unguarded, a second Ctrl-C
                # landing in this teardown would overwrite the interrupt `startserver` is already
                # carrying — or print a stacktrace over a clean shutdown. `terminate` completes
                # its sequence before rethrowing (#185), so there is nothing left to do here.
                e isa InterruptException || rethrow()
            end
        end
    end
end

worker_startup(app::App; kwargs...) = Nitro.Workers.startup(app; kwargs...)

"""
    getexternalurl(app::App) -> String

The URL `app` is serving on. Throws if it is not running.
"""
function getexternalurl(app::App) :: String
    external_url = app.service.external_url[]
    isnothing(external_url) && error("getexternalurl is only available while the app is serving")
    return external_url
end

url(app::App, name::String; kwargs...) = Nitro.Core.Routing.url(app, name; kwargs...)

internalrequest(app::App, req::Nitro.Request; middleware::Vector=[], serialize::Bool=true,
                catch_errors=true, context=missing) =
    Nitro.Core.internalrequest(app, req; middleware, serialize, catch_errors, context)

router(app::App, prefix::String = "";
       tags::Vector{String} = Vector{String}(),
       middleware::Nullable{Vector} = nothing) =
    Nitro.Core.router(app, prefix; tags, middleware)

urlpatterns(app::App, prefix::String, routes::Nitro.Core.Routing.RouteDefinition...) =
    Nitro.Core.Routing.urlpatterns(app, prefix, routes...)

urlpatterns(app::App, prefix::String, routes::Vector{Nitro.Core.Routing.RouteDefinition}) =
    Nitro.Core.Routing.urlpatterns(app, prefix, routes)

staticfiles(app::App, folder::String, mountdir::String="static"; kwargs...) =
    Nitro.Core.staticfiles(app, app.service.router, folder, mountdir; kwargs...)

spafiles(app::App, folder::String, mountdir::String="static"; kwargs...) =
    Nitro.Core.spafiles(app, app.service.router, folder, mountdir; kwargs...)

dynamicfiles(app::App, folder::String, mountdir::String="static"; kwargs...) =
    Nitro.Core.dynamicfiles(app, app.service.router, folder, mountdir; kwargs...)

"""
    configcookies(app::App, defaults::Dict)
    configcookies(app::App; kwargs...)

Set `app`'s cookie defaults. The only one of these forms that MUTATES the app.
"""
configcookies(app::App, defaults::Dict) =
    (app.service.cookies[] = Nitro.Core.load_cookie_settings!(defaults))

configcookies(app::App; kwargs...) =
    configcookies(app, Dict(string(k) => v for (k, v) in kwargs))

function get_cookie(app::App, req::Nitro.Request, name::String, default::Any=nothing; kwargs...)
    secret_key = app.service.cookies[].secret_key
    # Mirrors the singleton form: `encrypted` defaults to whatever the app's config implies.
    encrypted = Base.get(kwargs, :encrypted, !isnothing(secret_key))
    return Nitro.Core.get_cookie(req, name, default; secret_key=secret_key, encrypted=encrypted, kwargs...)
end

set_cookie!(app::App, res::Nitro.Response, name::String, value::Any; kwargs...) =
    Nitro.Core.set_cookie!(res, name, value; config=app.service.cookies[], kwargs...)
