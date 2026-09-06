# This is where methods are coupled to a global state

"""
    resetstate()

Reset all the internal state variables
"""
function resetstate()
    # prevent context reset when created at compile-time
    if (@__MODULE__) == Nitro
        CONTEXT[] = Nitro.Core.ServerContext()
        Nitro.Workers.reset_store!()
    end
end

function context()
    app_ctx = CONTEXT[].app_context[]
    return ismissing(app_ctx) ? missing : app_ctx.payload
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
            terminate()
            # only reset state on exit if we aren't running asynchronously & are running it interactively
            isinteractive() && resetstate()
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
                include_hidden::Bool=false, allow_symlink_escape::Bool=false)

Mount the servable files inside `folder` under `mountdir`, reading each one **once at startup** —
fast to serve, but a change on disk needs a restart. Use [`dynamicfiles`](@ref) to re-read per
request, or [`spafiles`](@ref) for a single-page app.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

Not every file in `folder` is served. These are refused:

- **Hidden entries** — any path component starting with `.` *relative to `folder`*, so `.env` and
  everything under `.git/`. A symlink is judged by what it resolves to as well as by its own name.
- **Symlinks resolving outside `folder`**, so `data.csv -> /etc/passwd` is not served.
- **Filenames the router reads as patterns** — `*` and `**` are wildcards that would shadow sibling
  URLs, and a name containing `{` or `}` is parsed as a path parameter and throws at registration,
  which would stop the server booting.
- **Anything that is not a regular file** — symlinked directories, FIFOs, devices.

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
"""
staticfiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false
) = Nitro.Core.staticfiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape)


"""
    spafiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing,
             include_hidden::Bool=false, allow_symlink_escape::Bool=false)

Mount `folder` for a Single Page Application. In addition to registering its servable files, this
registers a catch-all route under `mountdir` that serves `index.html` for any unmatched request,
enabling SPA History Mode routing.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

Which files are servable — and the `include_hidden` / `allow_symlink_escape` opt-outs — is described
in [`staticfiles`](@ref); the same rules apply here. Two SPA-specific consequences:

- The history-mode fallback is registered **only if `index.html` itself is servable.** If it is
  refused (an escaping symlink, say), the fallback is skipped and a warning is logged, rather than
  serving through the mount rules on every unmatched path.
- Because the fallback answers any unmatched path under the mount, a file that *was* refused reads
  as `index.html` with a 200 rather than a 404. That is not a leak, but it can be confusing in logs.
"""
spafiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false
) = Nitro.Core.spafiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape)


"""
    dynamicfiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing,
                 include_hidden::Bool=false, allow_symlink_escape::Bool=false)

Mount the servable files inside `folder` under `mountdir`, re-reading each one **on every request**
so changes on disk are picked up without a restart. Use [`staticfiles`](@ref) to snapshot at startup
instead.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

Which files are servable — and the `include_hidden` / `allow_symlink_escape` opt-outs — is described
in [`staticfiles`](@ref); the same rules apply here. They are evaluated **once, at mount time**: this
re-reads file *contents* per request, not the directory listing or the rules. Only files present at
startup get a route, so a directory that gains files at runtime needs a handler, not a mount.

That makes this the wrong tool for a directory untrusted users can write to — a file swapped for a
symlink after startup is not re-checked. Put a reverse proxy in front of such a directory; see
`docs/design/static-serving-boundary.md`.
"""
dynamicfiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false
) = Nitro.Core.dynamicfiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape)

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
terminate(context::ServerContext; timeout::Nullable{Real} = nothing) =
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




