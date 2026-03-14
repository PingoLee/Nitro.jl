module AppContext
import Base: @kwdef, wait, close, isopen
import Base.Threads: ReentrantLock
using HTTP
using HTTP: Server, Router
using ..Types

export ServerContext, EagerReviseService, Service, wait, close, isopen
export set_extension!, get_extension, delete_extension!, has_extension



@kwdef struct EagerReviseService
    task::Task
    done::Ref{Bool}
end

function Base.close(revise_service::EagerReviseService)
    revise_service.done[] = true
end

@kwdef struct Service
    server              :: Ref{Nullable{Server}}    = Ref{Nullable{Server}}(nothing)
    router              :: Router                   = Router()
    custommiddleware    :: Dict{String, Tuple}      = Dict{String, Tuple}()
    middleware_cache    :: Dict{String, Function}   = Dict{String, Function}()
    external_url        :: Ref{Nullable{String}}    = Ref{Nullable{String}}(nothing)
    prefix              :: Ref{Nullable{String}}    = Ref{Nullable{String}}(nothing)
    eager_revise        :: Ref{Nullable{EagerReviseService}} = Ref{Nullable{EagerReviseService}}(nothing)
    middleware_cache_lock :: ReentrantLock          = ReentrantLock()
    lifecycle_middleware  :: Set{LifecycleMiddleware} = Set{LifecycleMiddleware}()
    cookies               :: Ref{CookieConfig}      = Ref{CookieConfig}(CookieConfig())
    extensions            :: Dict{Symbol, Any}      = Dict{Symbol, Any}()
    extensions_lock       :: ReentrantLock          = ReentrantLock()
end

@kwdef struct ServerContext
    service :: Service          = Service()    
    mod     :: Nullable{Module} = nothing
    app_context :: Ref{Any}     = Ref{Any}(missing) # This stores a reference to an Context{T} object
end

Base.isopen(service::Service)   = !isnothing(service.server[]) && isopen(service.server[])
Base.wait(service::Service)     = !isnothing(service.server[]) && wait(service.server[])
function Base.close(service::Service)
    !isnothing(service.server[]) && close(service.server[])
    !isnothing(service.eager_revise[]) && close(service.eager_revise[])
end

function set_extension!(ctx::ServerContext, key::Symbol, value)
    lock(ctx.service.extensions_lock) do
        ctx.service.extensions[key] = value
    end
    return value
end

function get_extension(ctx::ServerContext, key::Symbol, default=nothing)
    lock(ctx.service.extensions_lock) do
        return Base.get(ctx.service.extensions, key, default)
    end
end

function delete_extension!(ctx::ServerContext, key::Symbol)
    lock(ctx.service.extensions_lock) do
        if haskey(ctx.service.extensions, key)
            delete!(ctx.service.extensions, key)
        end
    end
    return nothing
end

function has_extension(ctx::ServerContext, key::Symbol)
    lock(ctx.service.extensions_lock) do
        return haskey(ctx.service.extensions, key)
    end
end


# @eval begin
#     """
#         ServerContext(ctx::ServerContext; kwargs...)

#     Create a new `ServerContext` object by copying an existing one and optionally overriding some of its fields with keyword arguments.
#     """
#     function ServerContext(ctx::ServerContext; $([Expr(:kw ,k, :(ctx.$k)) for k in fieldnames(ServerContext)]...))
#         return ServerContext($(fieldnames(ServerContext)...))
#     end
# end

end
