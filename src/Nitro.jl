module Nitro

Base.@kwdef struct ReviseHooks
    revise::Function
    has_pending_revisions::Function
    wait_for_revision_event::Function
end

const REVISE_HOOKS :: Ref{Union{Nothing, ReviseHooks}} = Ref{Union{Nothing, ReviseHooks}}(nothing)

function register_revise_hooks!(; revise::Function, has_pending_revisions::Function, wait_for_revision_event::Function)
    REVISE_HOOKS[] = ReviseHooks(; revise, has_pending_revisions, wait_for_revision_event)
    return REVISE_HOOKS[]
end

function clear_revise_hooks!()
    REVISE_HOOKS[] = nothing
    return nothing
end

revise_hooks() = REVISE_HOOKS[]
has_revise_hooks() = !isnothing(REVISE_HOOKS[])

include("core.jl"); using .Core
include("Auth.jl"); using .Auth
include("instances.jl"); using .Instances
include("Workers.jl"); using .Workers

import HTTP: Request, Response, Stream, WebSocket, queryparams
using .Core: ServerContext, Nullable, HOFRouter
using .Core: GET, POST, PUT, DELETE, PATCH

const CONTEXT :: Ref{ServerContext} = Ref(ServerContext())

include("exts.jl")
include("methods.jl")

macro oxidize()
    quote
        import Nitro
        import Nitro: PACKAGE_DIR, ServerContext, Nullable, HOFRouter
        import Nitro: GET, POST, PUT, DELETE, PATCH, STREAM, WEBSOCKET

        const CONTEXT :: Ref{ServerContext}  = Ref(ServerContext(; mod=$(__module__)))
        include(joinpath(PACKAGE_DIR, "methods.jl"))
        
        nothing; # to hide last definition
    end |> esc
end

export  @oxidize,
        # Server lifecycle
        serve, terminate, internalrequest,
        worker_startup,
        resetstate, instance, router,
        register_revise_hooks!, clear_revise_hooks!,
        # File serving
        staticfiles, dynamicfiles, spafiles,
        # Util
        getparams, getquery, getsession, setsession!, getip, setip!, payload,
        redirect, formdata, multipart, format_sse_message,
        html, text, json, file, xml, js, css, binary,
        # Extractors
        Path, Query, Header, Json, JsonFragment, Form, Body, Cookie, Session, Files, FormFile, extract, validate,
        # Cookies & Security
        configcookies, get_cookie, set_cookie!, Cookies, Errors,
        # Middleware
        BearerAuth, CookieAuthMiddleware, Cors, RateLimiter, ExtractIP,
        SessionMiddleware, GuardMiddleware, login_required, role_required, permission_required, CSRFMiddleware,
        # Optional app extensions
        Workers,
        # Auth module
        Auth,
        # Common HTTP Types
        Request, Response, Stream, WebSocket, queryparams,
        # Context Types and methods
        Context, context,
        # Django-style Routing (THE routing API)
        path, urlpatterns, include_routes, RouteDefinition,
        # Response Abstractions
        Res
end
