module Reflection
using Base: @kwdef
using JSON
using ..Types
using ..Errors: ValidationError
using ..Util: parseparam
using ..Util.BodyParsers: NITRO_READ_STYLE

export splitdef, struct_builder, extract_struct_info

"""
Helper function to access the underlying value of any global references
"""
function getargvalue(arg)
    return isa(arg, GlobalRef) ? getfield(arg.mod, arg.name) : arg
end

"""
Return all parameter name & types and keyword argument names from a function
"""
function getsignames(f::Function; start=2)
    return getsignames(methods(f), start=start)
end

"""
Return parameter name & types and keyword argument names from a list of methods
"""
function getsignames(func_methods::Base.MethodList; start=2)
    arg_names = Vector{Symbol}()
    arg_types = Vector{Type}()
    kwarg_names = Vector{Symbol}()

    # track position & types of parameters in the function signature
    positions = Dict{Symbol, Int}()
    for m in func_methods
        argnames = Base.method_argnames(m)[start:end]
        argtypes = fieldtypes(m.sig)[start:end]
        for (i, (argname, type)) in enumerate(zip(argnames, argtypes))
            if argname ∉ arg_names
                push!(arg_names, argname)
                push!(arg_types, type)
                positions[argname] = i
            end
        end
        for kwarg in Base.kwarg_decl(m)
            if kwarg ∉ kwarg_names && kwarg != :...
                push!(kwarg_names, kwarg)
            end
        end
    end
    return arg_names, arg_types, kwarg_names
end

function walkargs(predicate::Function, expr)
    if isdefined(expr, :args)
        for arg in expr.args
            if predicate(arg)
                return true
            end
            walkargs(predicate, arg)
        end
    end
    return false
end

# The name a lowered-code node refers to, WITHOUT module qualification. Used by the
# self-reference check below; returning "" means "not a named reference".
_node_name(x::GlobalRef)     = String(x.name)
_node_name(x::Symbol)        = String(x)
_node_name(x::QuoteNode)     = x.value isa Symbol ? String(x.value) : ""
_node_name(x::Function)      = String(nameof(x))
_node_name(@nospecialize(_)) = ""

"""
    _is_self_reference(name, func_name) -> Bool

Whether `name` refers to the function currently being reconstructed. Lowered
self-references are the exact name (`myhandler`, `#36`) or a generated derivative —
the base name extended through a `#` in a gensym pattern (`#36#37`, `#myhandler#12`,
`##36#40`, `myhandler##kw`).

Matching must be on these exact token shapes, never a substring test over the
stringified node: stringification includes module qualification, so an unrelated
module or closure whose printed name merely *contains* the function's name — e.g.
module `##Extractors#360` against anonymous handler `#36` — would be mistaken for a
self-reference, silently discarding a parameter's default value and misclassifying
the parameter (a `Header(...)` extractor default degrades to a required query param).
"""
function _is_self_reference(name::AbstractString, func_name::AbstractString)::Bool
    isempty(name) && return false
    return name == func_name ||
           startswith(name, func_name * "#") ||
           startswith(name, "#" * func_name * "#")
end

# Substitutes SSA values and assigned slots back into a lowered expression, recursively.
#
# A callable struct rather than a local `rebuild!` with five methods: the local function called
# itself, so its closure captured its own binding before that binding existed, and Julia boxed it
# (#364).
struct _Rebuilder
    statements  :: Dict{Core.SSAValue, Any}
    assignments :: Dict{Core.SlotNumber, Any}
    no_values   :: Symbol
end

(r::_Rebuilder)(values::AbstractVector) = r.(values)

function (r::_Rebuilder)(expr::Expr)
    expr.args = r.(expr.args)
    return expr
end

(r::_Rebuilder)(ssa::Core.SSAValue) = r(r.statements[ssa])

function (r::_Rebuilder)(slot::Core.SlotNumber)
    value = get(r.assignments, slot, r.no_values)
    return value == r.no_values ? slot : r(value)
end

(r::_Rebuilder)(@nospecialize(value)) = value

function reconstruct(info::Core.CodeInfo, func_name::Symbol)

    # Track which index the function signature can be found on
    sig_index = nothing

    # create a dictionary of statements
    statements = Dict{Core.SSAValue, Any}()
    assignments = Dict{Core.SlotNumber, Any}()

    # create a unique flag for each call to mark missing values
    NO_VALUES = gensym()

    rebuild! = _Rebuilder(statements, assignments, NO_VALUES)

    for (index, expr) in enumerate(info.code)

        ssa_index = Core.SSAValue(index)
        statements[ssa_index] = expr 

        if expr isa Expr
            if expr.head == :(=)
                (lhs, rhs) = expr.args
                try
                    assignments[lhs] = eval(rebuild!(rhs))
                catch
                end
                
            # identify the function signature
            elseif isdefined(expr, :args) && expr.head == :call
                for arg in expr.args
                    if arg isa Core.SlotNumber && arg.id == 1
                        sig_index = ssa_index
                    end
                end
            end
        end     
    end

    # Recursively build an expression of the actual type of each argument in the function signature
    evaled_sig = rebuild!(statements[sig_index])

    default_values = []

    for arg in evaled_sig.args

        # Skip self-references (the function's own name or its generated derivatives)
        # by comparing unqualified node names on exact token shapes — see
        # `_is_self_reference` for why a stringified substring test is wrong here.
        fname = String(func_name)
        contains_func_name = walkargs(x -> _is_self_reference(_node_name(x), fname), arg)

        if contains_func_name || arg == NO_VALUES || arg isa GlobalRef && _is_self_reference(String(arg.name), fname)
            continue
        end

        if arg isa Expr
            try
                rebuilt = rebuild!(arg)
                # Skip if SlotNumbers remain after rebuilding
                walkargs(x -> isa(x, Core.SlotNumber), rebuilt) && continue
                push!(default_values, eval(rebuilt))
            catch
                continue
            end
        else
            push!(default_values, arg)
        end
    end

    return default_values
end

"""
Returns true if the CodeInfo object has a function signature

Most funtion signatures follow this general pattern
- The second to last expression is used as the function signature
- The last argument is a Return node 

Below are a couple different examples of this in pattern in action:

# Standard function signature

CodeInfo(
1 ─ %1 = (#self#)(req, a, path, qparams, 23)
└──      return %1
)

# Extractor example (as a default value)

CodeInfo(
1 ─      #22 = %new(Main.RunTests.ExtractorTests.:(var"#22#37"))
│   %2 = #22
│   %3 = Main.RunTests.ExtractorTests.Header(Main.RunTests.ExtractorTests.Sample, %2)
│   %4 = (#self#)(req, %3)
└──      return %4
)

# This kind of function signature happens when a keyword argument is defined without at default value

CodeInfo(
1 ─ %1  = "default"
│         c = %1
│   %3  = true
│         d = %3
│   %5  = Core.UndefKeywordError(:request)
│   %6  = Core.throw(%5)
│         request = %6
│   %8  = Core.getfield(#self#, Symbol("#8#9"))
│   %9  = c
│   %10 = d
│   %11 = request
│   %12 = (%8)(%9, %10, %11, #self#, a, b)
└──       return %12
)
"""
function has_sig_expr(c::Core.CodeInfo) :: Bool

    statements_length = length(c.code)

    # prevent index out of bounds
    if statements_length < 2
        return false
    end

    # check for our pattern of a function signature followed by a return statement
    last_expr = c.code[statements_length]
    second_to_last_expr = c.code[statements_length - 1]
    
    if last_expr isa Core.ReturnNode && second_to_last_expr isa Expr && second_to_last_expr.head == :call
        # recursivley search expression to see if we have a SlotNumber(1) in the args
        return walkargs(second_to_last_expr) do arg
            return isa(arg, Core.SlotNumber) && arg.id == 1
        end    
    end

    return false
end

"""
Given a list of CodeInfo objects, extract any default values assigned to parameters & keyword arguments
"""
function extract_defaults(info::Vector{Core.CodeInfo}, func_name::Symbol, param_names::Vector{Symbol}, kwarg_names::Vector{Symbol})

    # These store the mapping between parameter names and their default values
    param_defaults = Dict()
    kwarg_defaults = Dict()

    # skip parsing if no parameters or keyword arguments are found
    if isempty(param_names) && isempty(kwarg_names)
        return param_defaults, kwarg_defaults 
    end

    for c in info

        # skip code info objects that don't have a function signature
        if !has_sig_expr(c)
            continue
        end

        # rebuild the function signature with the default values included
        sig_args = reconstruct(c, func_name)

        param_values = []
        kwarg_values = []

        seen_self = false
        for arg in sig_args
            if isa(arg, Core.SlotNumber) && arg.id == 1
                seen_self = true
            else 
                if seen_self 
                    push!(param_values, arg)
                else
                    push!(kwarg_values, arg)
                end
            end
        end

        # map parameters if defaults values are available
        for (index, p_val) in enumerate(param_values)
            if !isa(p_val, Core.SlotNumber)
                p_name = param_names[index]
                param_defaults[p_name] = getargvalue(p_val)
            end
        end

        # map keyword args if defaults values are available
        for (index, k_val) in enumerate(kwarg_values)
            if !isa(k_val, Core.SlotNumber)
                k_name = kwarg_names[index]
                kwarg_defaults[k_name] = getargvalue(k_val)
            end
        end
    end 

    return param_defaults, kwarg_defaults 
end


# Return the more specific type
function select_type(t1::Type, t2::Type)
    # case 1: only t1 is any
    if t1 == Any && t2 != Any
        return t2

    # case 2: only t2 is any
    elseif t2 == Any && t1 != Any
        return t1

    # case 3: Niether / Both types are Any, chose the more specific type
    else
        if t1 <: t2
            return t1
        elseif t2 <: t1
            return t2
        else
            # if the types are the same, return the first type
            return t1
        end
    end
end

# Merge two parameter objects, defaultint to the original params value
function mergeparams(p1::Param, p2::Param) :: Param
    return Param(
        name    = p1.name,
        type    = select_type(p1.type, p2.type),
        default = coalesce(p1.default, p2.default),
        hasdefault = p1.hasdefault || p2.hasdefault
    )
end


"""
Used to extract the function signature from regular Julia functions.
"""
function splitdef(f::Function; start=1)
    method_defs = methods(f)
    func_name = first(method_defs).name
    return splitdef(Base.code_lowered(f), methods(f), func_name, start=start)
end


"""
Used to extract the function signature from regular Julia Structs.
This function merges the signature map at the end, because it's common
for structs to have multiple constructors with the same parameter names as both
keyword args and regular args.
"""
function splitdef(t::DataType; start=1)
    results = splitdef(Base.code_lowered(t), methods(t), nameof(t), start=start)
    sig_map = Dict{Symbol,Param}()
    for param in results.sig
        # merge parameters with the same name
        if haskey(sig_map, param.name)
            sig_map[param.name] = mergeparams(sig_map[param.name], param)
        # add unique parameter to the map
        else
            sig_map[param.name] = param
        end
    end
    merge!(results.sig_map, sig_map)
    return results
end


function splitdef(info::Vector{Core.CodeInfo}, method_defs::Base.MethodList, func_name::Symbol; start=1)

    # Extract parameter names and types
    param_names, param_types, kwarg_names = getsignames(method_defs)

    # Extract default values
    param_defaults, kwarg_defaults = extract_defaults(info, func_name, param_names, kwarg_names)

    # Create a list of Param objects from parameters
    params = Vector{Param}()
    for (name, type) in zip(param_names, param_types)
        if haskey(param_defaults, name)
            # inferr the type of the parameter based on the default value
            param_default = param_defaults[name]
            inferred_type = type == Any ? typeof(param_default) : type
            push!(params, Param(name=name, type=inferred_type, default=param_default, hasdefault=true))
        else
            push!(params, Param(name=name, type=type))
        end
    end

    # Create a list of Param objects from keyword arguments
    keyword_args = Vector{Param}()
    for name in kwarg_names
        # Don't infer the type of the keyword argument, since julia doesn't support types on kwargs
        if haskey(kwarg_defaults, name)
            push!(keyword_args, Param(name=name, type=Any, default=kwarg_defaults[name], hasdefault=true))
        else
            push!(keyword_args, Param(name=name, type=Any))
        end
    end

    sig_params = vcat(params, keyword_args)[start:end]

    return (
        name = func_name,
        args = params[start:end],
        kwargs = keyword_args[start:end],
        sig = sig_params,
        sig_map = Dict{Symbol,Param}(param.name => param for param in sig_params)
    )
end


# Function to extract field names, types, and default values
function extract_struct_info(T::Type)
    field_names = fieldnames(T)
    type_map = Dict(name => fieldtype(T, name) for name in field_names)
    return (names=field_names, map=type_map)
end

"""
    struct_builder(::Type{T}, source::AbstractDict) :: T

Build a `T` from a map the client supplied: the query string (`Query{T}`), a form body
(`Form{T}`), the headers (`Header{T}`), the path parameters (`Path{T}`), or one object of a JSON
body (`JsonFragment{T}`).

The walk is over **`T`'s fields, never the map's keys** (#306). Each field is looked up by its name
as a `String`, so a key the client sent that is not a field is never touched. Building
`Dict(Symbol(k) => v ...)` over the client's map, as this used to, interned every key it held,
and Julia never frees an interned `Symbol`: a login form flooded with unique junk keys grew the
process by ~47 MB per million keys, for good.

Each present value binds through `bind_value`, the same rules scalar path and query
parameters follow. A `@kwdef` struct is built by keyword, so an absent field takes its declared
default; a plain struct is built positionally, and an absent field binds `nothing` or `missing`
if its type admits one. Any other absent field is a `ValidationError` naming the field. A target
that is itself a dictionary type keeps every key and binds each value the same way.
"""
function struct_builder(::Type{T}, source::AbstractDict) :: T where {T}
    T <: AbstractDict && return dict_builder(T, source)
    if hasmethod(T, Tuple{}, fieldnames(T))
        kwargs = Pair{Symbol, Any}[]
        for name in fieldnames(T)
            key = String(name)
            haskey(source, key) || continue
            push!(kwargs, name => bind_value(fieldtype(T, name), source[key]))
        end
        return kw_construct(T, kwargs)
    end
    args = Any[]
    for name in fieldnames(T)
        key = String(name)
        ftype = fieldtype(T, name)
        if haskey(source, key)
            push!(args, bind_value(ftype, source[key]))
        elseif Nothing <: ftype
            push!(args, nothing)
        elseif Missing <: ftype
            push!(args, missing)
        else
            throw(ValidationError("Missing required field '$name'"))
        end
    end
    # A `NamedTuple` is built from a tuple of its values, not positionally (`T(args...)` has no
    # method for it); `Query{@NamedTuple{a::Int, b::String}}` bound this way before #306.
    T <: NamedTuple && return T(Tuple(args))
    return T(args...)
end

# A dictionary target keeps the client's keys, so they are only ever converted to the key type,
# never interned: `convert(Symbol, ::String)` has no method, and a `Symbol`-keyed target is
# refused at registration anyway (#306).
function dict_builder(::Type{T}, source::AbstractDict) :: T where {T <: AbstractDict}
    out = T()
    for (k, v) in source
        out[k] = bind_value(valtype(T), v)
    end
    return out
end

"""
    bind_value(::Type{FT}, value) :: FT

Bind one client-supplied value to a field of type `FT`:

- a string goes through `parseparam`, so a field binds exactly as a scalar path or query
  parameter of the same type would: `Nullable{T}`, enums (by integer or by name), `UUID`,
  `Date`, and JSON for anything `parse` does not cover. A JSON string `"24"` still binds an
  `Int` field;
- a value that already is an `FT` (a JSON number for a number field, `nothing` for a
  `Nullable` field, anything for an `Any` field) is taken as is;
- a JSON object for a struct field recurses into [`struct_builder`](@ref), so `@kwdef`
  defaults apply at every level;
- anything else is converted by `StructUtils.make` under Nitro's read style.
"""
function bind_value(::Type{FT}, value) where {FT}
    value isa FT && return value
    value isa AbstractString && return parseparam(FT, String(value))
    if value isa AbstractDict
        RT = Base.nonnothingtype(FT)
        RT isa DataType && isstructtype(RT) && return struct_builder(RT, value)
    end
    return JSON.StructUtils.make(FT, value, NITRO_READ_STYLE)
end

"""
    kw_construct(T, kwargs) :: T

Build a `@kwdef` struct from the keyword arguments of the fields that were present, the way
JSON.jl treats an absent field: the declared default, else the null the field's type admits,
else a `ValidationError`.
"""
function kw_construct(::Type{T}, kwargs::Vector{Pair{Symbol, Any}}) :: T where {T}
    # The keyword constructor applies every default itself, so a field it reports as undefined
    # has none -- fill in the null if its type takes one and try again. Each pass adds a field
    # that was not there before, so this runs at most `fieldcount(T)` times.
    while true
        try
            return T(; kwargs...)
        catch e
            e isa UndefKeywordError || rethrow()
            name = e.var
            # Only a keyword of `T`'s own constructor that we did not pass -- anything else was
            # thrown from deeper inside a default expression and is not ours to answer.
            (name in fieldnames(T) && !any(p -> p.first === name, kwargs)) || rethrow()
            ftype = fieldtype(T, name)
            if Nothing <: ftype
                push!(kwargs, name => nothing)
            elseif Missing <: ftype
                push!(kwargs, name => missing)
            else
                throw(ValidationError("Missing required field '$name'"))
            end
        end
    end
end

end