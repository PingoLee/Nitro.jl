module Nitro

const WAS_LOADED_AFTER_REVISE :: Ref{Bool} = Ref(false)

function __init__()
    if isdefined(Main, :Revise)
        WAS_LOADED_AFTER_REVISE[] = true
    end
end

include("core.jl"); using .Core
include("instances.jl"); using .Instances

import HTTP: Request, Response, Stream, WebSocket, queryparams
using .Core: ServerContext, Server, Nullable, HOFRouter
using .Core: GET, POST, PUT, DELETE, PATCH

const CONTEXT :: Ref{ServerContext} = Ref(ServerContext())

include("exts.jl")
include("methods.jl")
include("deprecated.jl")

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

export  @oxidize, @oxidise,
        # Server lifecycle
        serve, terminate, internalrequest,
        resetstate, instance, router, route,
        # File serving
        staticfiles, dynamicfiles, spafiles,
        # Util
        redirect, formdata, format_sse_message,
        html, text, json, file, xml, js, css, binary,
        # Extractors
        Path, Query, Header, Json, JsonFragment, Form, Body, Cookie, Session, extract, validate,
        # Cookies & Security
        configcookies, get_cookie, set_cookie!, Cookies, Errors,
        # Middleware
        BearerAuth, Cors, RateLimiter, ExtractIP,
        SessionMiddleware, GuardMiddleware, login_required, role_required,
        # Common HTTP Types
        Request, Response, Stream, WebSocket, queryparams,
        # Context Types and methods
        Context, context,
        # Django-style Routing (THE routing API)
        path, urlpatterns, include_routes, RouteDefinition,
        # Response Abstractions
        Res
end
