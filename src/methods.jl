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
    try
        # return the resulting HTTP.Server object
        return Nitro.Core.serve(CONTEXT[]; kwargs...)
    finally
        # close server on exit if we aren't running asynchronously
        if !async 
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


staticfiles(
    folder::String, 
    mountdir::String="static"; 
    headers::Vector=[], 
    loadfile::Nullable{Function}=nothing
) = Nitro.Core.staticfiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile)


"""
    spafiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing)

Mount all files inside the /static folder (or user defined mount point) for a Single Page Application (SPA).
In addition to registering all files, it also registers a catch-all route `/*` that serves `index.html` 
for any unmatched requests, enabling SPA History Mode routing.
"""
spafiles(
    folder::String, 
    mountdir::String="static"; 
    headers::Vector=[], 
    loadfile::Nullable{Function}=nothing
) = Nitro.Core.spafiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile)


dynamicfiles(
    folder::String, 
    mountdir::String="static"; 
    headers::Vector=[], 
    loadfile::Nullable{Function}=nothing
) = Nitro.Core.dynamicfiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile)

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

"""
    terminate(context::ServerContext)
    terminate()

Terminate the server and stop all running tasks.
"""
terminate(context::ServerContext) = Nitro.Core.terminate(context)
terminate() = terminate(CONTEXT[])


### Setup Docs Strings ###


for method in [:serve, :terminate, :staticfiles, :dynamicfiles,  :internalrequest]
    eval(quote
        @doc (@doc(Nitro.Core.$method)) $method
    end)
end




