# ── Parameter binding ───────────────────────────────────────────────────────────
# The per-parameter strategy structs (#37) and `create_param_parser`.
# Included into `module Core` by src/core.jl — not a submodule; see the hub for why.

# ── Per-parameter binding strategies (#37) ────────────────────────────────────
#
# One concrete callable struct per parameter kind, built once at registration.
# These were closures over `param`, a loop variable drawn from `info.sig::Vector{Param}`.
# `Param` is a `UnionAll`, so that element type is abstract, so each closure's captured
# field was abstract too — calling one cost a dynamic dispatch, and entering its
# `where T` body cost a second. Carrying the parameter's type as the *struct's* type
# parameter makes `param`, `param.type` and `param.default` concrete fields, so both
# dispatches resolve statically and the whole strategy list can live in a concrete
# `Tuple` (see `create_param_parser`). This is the shape `axum` reaches with
# `FromRequestParts` + per-arity tuple impls; the abstract-vector-of-resolvers it
# replaces is Spring's `HandlerMethodArgumentResolver`, which only survives on JIT
# devirtualization the Julia runtime does not do. nitro-core §7.
#
# `ServerContext` is a concrete struct, so carrying it by value costs no indirection.

struct ContextStrategy
    ctx::ServerContext
end
(s::ContextStrategy)(::LazyRequest) = s.ctx.app_context[]

struct ExtractorStrategy{T}
    param::Param{T}
end
(s::ExtractorStrategy)(lr::LazyRequest) = extract(s.param, lr)

struct CookieStrategy{T}
    param::Param{T}
    ctx::ServerContext
end
(s::CookieStrategy)(lr::LazyRequest) =
    extract(s.param, lr, s.ctx.service.cookies[].secret_key)

struct SessionStrategy{T}
    param::Param{T}
    ctx::ServerContext
end
(s::SessionStrategy)(lr::LazyRequest) =
    extract(s.param, lr, s.ctx.service.cookies[].secret_key, s.ctx.app_context[])

struct PathParamStrategy{T}
    param::Param{T}
    name::String
end
function (s::PathParamStrategy)(lr::LazyRequest)
    raw_pathparams = Types.pathparams(lr)
    # The lookup is deliberately OUTSIDE any guard. A route brace always has a matching
    # handler parameter (enforced at registration, see `parse_func_params` above) and the
    # router always populates it, so a miss here is a framework bug rather than client
    # input — it must stay a 500 with a real stack trace, not be laundered into a 400.
    return parseparam_checked(s.param.type, raw_pathparams[s.name], s.name, :path)
end

# Selected only when `param.hasdefault`, so an absent key means "use the declared
# default". Returns `Union{T,Nothing}` by construction — that union is the declared
# optionality of the parameter, not an inference failure.
struct QueryParamStrategy{T}
    param::Param{T}
    name::String
end
function (s::QueryParamStrategy)(lr::LazyRequest)
    raw_queryparams = Types.queryvars(lr)
    haskey(raw_queryparams, s.name) || return s.param.default
    return parseparam_checked(s.param.type, raw_queryparams[s.name], s.name, :query)
end

struct RequiredQueryParamStrategy{T}
    param::Param{T}
    name::String
end
function (s::RequiredQueryParamStrategy)(lr::LazyRequest)
    raw_queryparams = Types.queryvars(lr)
    # A required query parameter that was not sent is a client error. This used to be a
    # bare `raw_queryparams[name]`, whose `KeyError` surfaced as a 500.
    haskey(raw_queryparams, s.name) ||
        throw(ValidationError("Missing required query parameter '$(s.name)'"))
    return parseparam_checked(s.param.type, raw_queryparams[s.name], s.name, :query)
end

# The function barrier that makes the whole thing pay off. `strats` is assembled
# dynamically above, so at the assembly site its static type is only `Tuple`. Taking it
# as an explicit type parameter forces a specialization per concrete tuple type, so the
# returned closure captures it *concretely* — and `map` over a concrete tuple is
# unrolled, statically dispatched, and returns a concrete `Tuple` with no heap vector
# and no boxing. Building the closure inline at the call site would leave the field
# abstract and undo every gain above; keep this barrier.
#
# Arity degrades gracefully rather than cliff-edging: past roughly 32 elements Julia
# stops unrolling `map` and falls back to a generic (still correct) path, so a
# pathological handler loses the optimization instead of blowing up compile time.
function _make_param_parser(strats::S) where {S<:Tuple}
    return function(req::HTTP.Request)
        lr = LazyRequest(request=req)
        return map(s -> s(lr), strats)
    end
end

function create_param_parser(ctx::ServerContext, func_details)
    info = func_details.info
    pathparams = func_details.pathnames
    queryparams = func_details.querynames

    strategies = Any[]

    for param in info.sig
        name = param.name
        str_name = String(name)
        # Order matters: `Session` and `Cookie` are both `<: Extractor`, so they must be
        # tested before the generic extractor branch.
        if param.type <: Context
            push!(strategies, ContextStrategy(ctx))
        elseif param.type <: Session
            push!(strategies, SessionStrategy(param, ctx))
        elseif param.type <: Cookie
            push!(strategies, CookieStrategy(param, ctx))
        elseif param.type <: Extractor
            push!(strategies, ExtractorStrategy(param))
        elseif name in pathparams
            push!(strategies, PathParamStrategy(param, str_name))
        elseif name in queryparams
            push!(strategies, param.hasdefault ? QueryParamStrategy(param, str_name) :
                                                 RequiredQueryParamStrategy(param, str_name))
        end
    end

    return _make_param_parser(Tuple(strategies))
end
