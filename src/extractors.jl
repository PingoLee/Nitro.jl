module Extractors

using JSON
using Base: @kwdef
using HTTP
using Dates

using ..Util: text, json, formdata, multipart, parseparam, FormFile
using ..Reflection: struct_builder, extract_struct_info
using ..Errors: ValidationError, is_unrecoverable
using ..Types
using ..Cookies
# HTTP.jl v2 newly exports `Cookie` at the top level, which collides with Nitro's
# `Cookie` extractor (defined in `Types`). Import it explicitly so the unqualified
# `Cookie` references below resolve unambiguously to ours, not `HTTP.Cookie`.
using ..Types: Cookie

export extract, validate, extracttype, isextractor, isreqparam, isbodyparam,
    Path, Query, Header, Json, JsonFragment, Form, Body, Cookie, Session, Files, MultipartForm

"""
Given a classname, build a new Extractor class
"""
macro extractor(class_name)
    quote
        struct $(Symbol(class_name)){T} <: Extractor{T} 
            payload::Union{T, Nothing}
            validate::Union{Function, Nothing}
            type::Type{T}
        
            # Only pass a validator
            $(Symbol(class_name)){T}(f::Function) where T = new{T}(nothing, f, T)

            # Pass Type for payload
            $(Symbol(class_name))(::Type{T}) where T = new{T}(nothing, nothing, T)

            # Pass Type for payload & validator
            $(Symbol(class_name))(::Type{T}, f::Function) where T = new{T}(nothing, f, T)

            # Pass object directly
            $(Symbol(class_name))(payload::T) where T = new{T}(payload, nothing, T)

            # Pass object directly & validator
            $(Symbol(class_name))(payload::T, f::Function) where T = new{T}(payload, f, T)
            
        end
    end |> esc
end

## RequestParts Extractors

@extractor Path
@extractor Query
@extractor Header

## RequestContent Extractors

@extractor Json
@extractor JsonFragment
@extractor Form
@extractor Body
@extractor Files
@extractor MultipartForm

# Every extractor is a thin wrapper: declare a handler parameter of the wrapped type, and the
# bound value arrives in `.payload`. They share one construction surface (from `@extractor`):
# `X(T)`, `X(T, validator)` and `X{T}(validator)` build the parameter's *default*, which is how
# an extractor-local validator is attached — `payload = Json(Search, s -> !isempty(s.q))`.
# A value that fails to bind, or fails `validate`, is a `ValidationError` → 400.

"""
    Path{T}

Extractor that binds the route's path parameters into a struct `T`, matching each field to the
converter name in the pattern.

```julia
struct ItemRef; id::Int; slug::String; end
path("/items/<int:id>/<str:slug>", (req, ref::Path{ItemRef}) -> Res.json(ref.payload))
```

For one or two parameters, plain typed arguments (`id::Int`) are simpler; `Path{T}` earns its
place when the struct also carries a [`validate`](@ref) method.
"""
Path

"""
    Query{T}

Extractor that binds the query string into a struct `T`. Fields are matched by name and parsed
to their declared type; with a `@kwdef` struct an absent parameter takes the field's default.

```julia
@kwdef struct Page; page::Int = 1; per_page::Int = 20; end
path("/items", (req, p::Query{Page}) -> Res.json(Dict("page" => p.payload.page)))
```

See `getquery` for the untyped accessor.
"""
Query

"""
    Header{T}

Extractor that binds request headers into a struct `T`. Header names are lowercased before
matching, and are matched to field names exactly: `Accept` binds a field `accept`. A hyphenated
header binds only a field spelled the same way, `var"x-api-key"`; `HTTP.header(req, "X-Api-Key")`
is usually simpler.
"""
Header

"""
    Json{T}

Extractor that parses the whole request body as JSON into `T`. This is the recommended way to
take a JSON body: typed, validated, and a malformed body is a 400.

```julia
struct Search; q::String; limit::Int; end
path("/search", (req, s::Json{Search}) -> Res.json(s.payload); method = "POST")
```

Attach a validator by giving the parameter a default: `s = Json(Search, s -> s.limit <= 100)`.
The *Request Body* guide has the walkthrough; use [`JsonFragment`](@ref) to bind one top-level
key instead of the whole body.
"""
Json

"""
    JsonFragment{T}

Extractor that binds **one top-level key** of a JSON object body, named after the parameter,
into a struct `T`. Several `JsonFragment` parameters can split one body between them:

```julia
path("/orders", function(req, customer::JsonFragment{Customer}, shipping::JsonFragment{Address})
    # body: {"customer": {...}, "shipping": {...}}
end; method = "POST")
```

The key's value must itself be a JSON object. A body that is not a JSON object, or that lacks
the key, is a 400.
"""
JsonFragment

"""
    Form{T}

Extractor that binds an `application/x-www-form-urlencoded` body into a struct `T`, matching
fields by name and parsing them to their declared types. For `multipart/form-data`, use
[`MultipartForm`](@ref) (text fields and files) or [`Files`](@ref) (files only).
"""
Form

"""
    Body{T}

Extractor that parses the raw request body as a single value of type `T`, such as a `String`,
a number or a `Bool`, with no JSON or form decoding. `Body{String}` is the body text verbatim.
"""
Body

"""
    Files{FormFile}
    Files{Vector{FormFile}}

Extractor for the file parts of a `multipart/form-data` body, as [`FormFile`](@ref)s.

- `Files{FormFile}` binds the **single** file uploaded under the parameter's name. A missing
  field, or a field that is text rather than a file, is a 400.
- `Files{Vector{FormFile}}` binds **every** file in the body, whatever its field name. The vector
  is empty when there are none.

```julia
path("/upload", (req, document::Files{FormFile}) -> Res.json(Dict("size" => length(document.payload.data)));
     method = "POST")
```

To take text fields and files together into one typed struct, use [`MultipartForm`](@ref).
"""
Files

"""
    MultipartForm{T}

Extractor that binds a `multipart/form-data` body, text fields **and** files, into one struct
`T`. Each field binds by its declared type: `String` and numbers from text parts, `FormFile` and
`Vector{FormFile}` from file parts, `Union{X, Nothing}` as optional.

The field-type table and the missing-field rules are on the `MultipartForm` method of
[`extract`](@ref); the *File Uploads* guide has the walkthrough.
"""
MultipartForm

function extracttype(::Type{U}) where {T, U <: Extractor{T}}
    return T
end

function isextractor(::Param{T}) where {T}
    return T <: Extractor
end

function isreqparam(::Param{U}) where {T, U <: Extractor{T}}
    return U <: Union{Path{T}, Query{T}, Header{T}}
end

function isbodyparam(::Param{U}) where {T, U <: Extractor{T}}
    return U <: Union{Json{T}, JsonFragment{T}, Form{T}, Body{T}, Files{T}, MultipartForm{T}}
end

"""
    validate(value::T) -> Bool

The global validation hook every extractor runs after binding. The fallback accepts everything;
add a method for your own type and every extractor that binds a `T` enforces it:

```julia
Nitro.validate(s::Search) = 1 <= s.limit <= 100
```

Returning `false` is a `ValidationError` (400). An extractor-local validator, attached through the
parameter's default (`Json(Search, f)`), runs *after* this one; both must pass.
"""
validate(type::T) where {T} = true

"""
This function will try to validate an instance of a type using both global and local validators.
If both validators pass, the instance is returned. If either fails, a `ValidationError` is thrown.
"""
function try_validate(param::Param{U}, instance::T) :: T where {T, U <: Extractor{T}}

    # The message names the parameter, its type, and the validator that rejected it —
    # never the instance. For a body-bound extractor the instance *is* the client's
    # deserialized payload, so interpolating it put submitted credentials into `.msg`,
    # which is app-reachable through `showerror` and any `catch ValidationError` (#72).
    # This matches what `parseparam_checked` (src/utilities/misc.jl) already does for
    # query and path parameters.

    # Case 1: Use global validate function - returns true if one isn't defined for this type
    if !validate(instance)
        impl = Base.which(validate, (T,))
        throw(ValidationError("Validation failed for parameter '$(param.name)': $T rejected by $impl"))
    end

    # Case 2: Use custom validate function from an Extractor (if defined)
    if param.hasdefault && param.default isa U && !isnothing(param.default.validate)
        if !param.default.validate(instance)
            impl = Base.which(param.default.validate, (T,))
            throw(ValidationError("Validation failed for parameter '$(param.name)': $T rejected by $impl"))
        end
    end

    return instance
end

"""
A helper utility function to safely extract data from a function. If the function fails, a ValidationError is thrown
which is caught and results with a 400 status code.
"""
function safe_extract(f::Function, param::Param{U}) :: T where {T, U <: Extractor{T}} 
    try 
        return f()
    catch e
        # None of these is client input, so none may become a 400. Without this line a Ctrl-C
        # landing inside a body deserialization is reported as a rejected request, and neither
        # `handlerequest` nor `serve` -- both of which special-case `InterruptException` --
        # ever sees it.
        #
        # Widened from `InterruptException` alone in #254, and this site is the reason that
        # issue's fix is not confined to the parsers. `Json{T}`/`JsonFragment{T}`/`Body{T}`
        # resolve through `Types.jsonbody` -> `BodyParsers.json`, which now rethrows a
        # `StackOverflowError` from a deeply-nested body instead of answering `nothing`. If
        # this guard still named only `InterruptException`, that rethrow would be caught one
        # frame later and laundered into a `ValidationError` -- so every extractor-based
        # route, the most idiomatic shape in the framework, would still answer 400 for a
        # corrupted worker while a bare `getjson` handler answered 500. Same input, two
        # verdicts, and the narrowing a no-op exactly where routes actually are.
        #
        # A further wrap site must copy this line too.
        is_unrecoverable(e) && rethrow()
        if e isa ValidationError
            throw(e)
        end
        # If the function fails, we throw a ValidationError with the parameter name and type.
        #
        # `e` becomes `.cause`, and it is NOT value-free: for a body-bound extractor it is the
        # deserializer's own error, and those quote their input -- a JSON parse `ArgumentError`
        # echoes the submitted bytes, so this is the highest-severity of the four sites that
        # attach a cause. Keeping it attached is safe as of #130, because none of `showerror`,
        # `show` or `JSON.lower` renders a cause by default; it is reachable only through an
        # explicit `showerror(io, err; cause=true)` or `Errors.cause_report`. Never log it.
        throw(ValidationError("Failed to serialize data for | parameter: $(param.name) | extractor: $U | type: $T", e))
    end
end

"""
Extracts a JSON object from a request and converts it into a custom struct
"""
function extract(param::Param{Json{T}}, request::LazyRequest) :: Json{T} where {T}
    instance = safe_extract(param) do
        JSON.parse(textbody(request), T) 
    end
    valid_instance = try_validate(param, instance)
    return Json(valid_instance)
end

"""
Extracts a part of a json object from the body of a request and converts it into a custom struct
"""
function extract(param::Param{JsonFragment{T}}, request::LazyRequest) :: JsonFragment{T} where {T}
    instance = safe_extract(param) do
        # The fragment lookup belongs INSIDE the guard: a body that is not a JSON object
        # (`MethodError` on `getindex(::Nothing, ::String)`) or one missing this fragment's
        # key (`KeyError`) is client input, and used to escape as a 500 with a backtrace
        # while every sibling extractor returned a 400.
        struct_builder(T, Types.jsonbody(request)[string(param.name)])
    end
    valid_instance = try_validate(param, instance)
    return JsonFragment(valid_instance)
end

"""
Extracts the body from a request and convert it into a custom type
"""
function extract(param::Param{Body{T}}, request::LazyRequest) :: Body{T} where {T}
    instance = safe_extract(param) do 
        parseparam(T, textbody(request))
    end
    valid_instance = try_validate(param, instance)
    return Body(valid_instance)
end

"""
Extracts a Form from a request and converts it into a custom struct
"""
function extract(param::Param{Form{T}}, request::LazyRequest) :: Form{T} where {T}
    form = Types.formbody(request)
    instance = safe_extract(param) do 
        struct_builder(T, form) 
    end
    valid_instance = try_validate(param, instance)
    return Form(valid_instance) 
end

"""
Extracts path parameters from a request and convert it into a custom struct
"""
function extract(param::Param{Path{T}}, request::LazyRequest) :: Path{T} where {T}
    params = Types.pathparams(request)
    instance = safe_extract(param) do 
        struct_builder(T, params) 
    end
    valid_instance = try_validate(param, instance)
    return Path(valid_instance)
end

"""
Extracts query parameters from a request and convert it into a custom struct
"""
function extract(param::Param{Query{T}}, request::LazyRequest) :: Query{T} where {T}
    params = Types.queryvars(request)
    instance = safe_extract(param) do 
        struct_builder(T, params) 
    end
    valid_instance = try_validate(param, instance)
    return Query(valid_instance)
end

"""
Extracts Headers from a request and convert it into a custom struct
"""
function extract(param::Param{Header{T}}, request::LazyRequest) :: Header{T}  where {T}
    headers = Types.headers(request)
    instance = safe_extract(param) do 
        struct_builder(T, headers) 
    end
    valid_instance = try_validate(param, instance)
    return Header(valid_instance)
end

"""
Extracts a cookie from a request and converts it into a custom type.
This is a helper used by the cookie strategy in Core.
"""
function extract(param::Param{Cookie{T}}, request::LazyRequest, secret_key::Nullable{String}) :: Cookie{T} where {T}
    # The cookie name is either explicitly set in the Cookie struct or defaults to the parameter name
    cookie_name = if param.hasdefault && !isnothing(param.default.name) && !isempty(param.default.name)
        param.default.name
    else
        string(param.name)
    end

    # Use get_cookie to handle parsing, decryption and type conversion
    # We pass T() or a representative value of type T as default to trigger type parsing if needed,
    # but here safe_extract handles parseparam(T, ...) so we just get the raw/decrypted string.
    #
    # That string is NOT percent-decoded, and must not be: `set_cookie!` does not percent-encode
    # on write — `_validate_cookie_value` rejects out-of-range octets instead, and `%` is a legal
    # cookie octet. Decoding here (which `parseparam` used to do by default) therefore mangled any
    # cookie carrying a literal `%` on the way back in — a write/read asymmetry removed with #70.
    val = Cookies.get_cookie(headers(request), cookie_name; encrypted=!isnothing(secret_key), secret_key=secret_key)
    
    if isnothing(val)
        return Cookie(cookie_name, T)
    end

    instance = safe_extract(param) do 
        parseparam(T, val) 
    end
    
    valid_instance = try_validate(param, instance)
    return Cookie(cookie_name, valid_instance)
end

"""
Extracts a session from a request using the application context as a store.
"""
function extract(param::Param{Session{T}}, request::LazyRequest, secret_key::Nullable{String}, app_context::Any) :: Session{T} where {T}
    # 1. Get the session cookie name
    session_cookie_name = if param.hasdefault && !isnothing(param.default.name) && !isempty(param.default.name)
        param.default.name
    else
        "session" # default session cookie name
    end

    # 2. Extract the session ID from cookies
    val = Cookies.get_cookie(headers(request), session_cookie_name; encrypted=!isnothing(secret_key), secret_key=secret_key)
    
    if isnothing(val) || isempty(val)
        return Session(session_cookie_name, T)
    end

    # 3. Lookup in App Context
    if ismissing(app_context)
        return Session(session_cookie_name, T)
    end

    # app_context is expected to be a Context object
    store = app_context.payload

    if store isa AbstractSessionStore
        instance = get_session(store, val)
        if isnothing(instance)
            return Session(session_cookie_name, T)
        end

        valid_instance = try_validate(param, instance)
        return Session(session_cookie_name, valid_instance)
    end
    
    # We assume the store is a Dict-like object or support get()
    instance = try
        if hasmethod(Base.get, (typeof(store), String, Any))
            Base.get(store, val, nothing)
        elseif hasmethod(Base.get, (typeof(store), Symbol, Any))
            Base.get(store, Symbol(val), nothing)
        else
            nothing
        end
    catch e
        # The store is application code, so "it threw" means "no session for this id" and the
        # extractor falls back. The three in `is_unrecoverable` are not that (#254).
        is_unrecoverable(e) && rethrow()
        nothing
    end

    if isnothing(instance)
        return Session(session_cookie_name, T)
    end

    # Handle built-in SessionPayload with expiry checking
    if instance isa SessionPayload
        if is_expired(instance)
            return Session(session_cookie_name, T)
        end
        instance = instance.data
    end
    
    valid_instance = try_validate(param, instance)
    return Session(session_cookie_name, valid_instance)
end

"""
    extract(param::Param{Files{Vector{FormFile}}}, request::LazyRequest) :: Files{Vector{FormFile}}

Extracts **all** uploaded files from a `multipart/form-data` request body.

Returns a `Files` wrapper whose `.payload` is a `Vector{FormFile}`.
If the request is not multipart or contains no files, the vector is empty.
"""
function extract(param::Param{Files{Vector{FormFile}}}, request::LazyRequest) :: Files{Vector{FormFile}}
    instance = safe_extract(param) do
        parsed = multipartbody(request)
        files = FormFile[]
        for (_, value) in parsed
            if value isa FormFile
                push!(files, value)
            elseif value isa Vector{FormFile}
                append!(files, value)
            end
        end
        files
    end
    valid_instance = try_validate(param, instance)
    return Files(valid_instance)
end

"""
    extract(param::Param{Files{FormFile}}, request::LazyRequest) :: Files{FormFile}

Extracts a **single** uploaded file from a `multipart/form-data` request body.
The file is matched by the parameter name (e.g., a handler parameter named `document`
will look for a multipart field called `"document"`).

Throws a `ValidationError` if no file is found with that field name.
"""
function extract(param::Param{Files{FormFile}}, request::LazyRequest) :: Files{FormFile}
    instance = safe_extract(param) do
        parsed = multipartbody(request)
        name = string(param.name)
        value = get(parsed, name, nothing)
        if isnothing(value)
            throw(ValidationError("No file found for field '$(name)' in multipart form data"))
        end
        if value isa FormFile
            value
        elseif value isa Vector{FormFile}
            first(value)
        else
            throw(ValidationError("Field '$(name)' is not a file upload"))
        end
    end
    valid_instance = try_validate(param, instance)
    return Files(valid_instance)
end

# ─── MultipartForm{T} — typed mixed multipart (text fields + files) ──────────

"""
    extract(param::Param{MultipartForm{T}}, request::LazyRequest) :: MultipartForm{T}

Extracts a `multipart/form-data` request body and binds **both** its text fields and
its file parts into a single typed struct `T`.

`T` must be constructible from its fields in declaration order (a plain `struct` or a
`@kwdef struct`). Each field of `T` is bound by its type:

| Field type                  | Source                                            |
|-----------------------------|---------------------------------------------------|
| `String`                    | single text field (by field name)                 |
| `T <: Number`, `Bool`       | single text field, parsed                         |
| `Vector{String}`            | all text fields under that name                   |
| `FormFile`                  | single uploaded file (by field name)              |
| `Vector{FormFile}`          | all uploaded files under that name                |
| `Union{X, Nothing}`         | optional — `nothing` when the field is absent     |

For a `@kwdef struct`, a field absent from the body falls back to its declared default;
an absent `Union{X, Nothing}` field always binds to `nothing` (taking precedence over a
default). A required field (no default, no `Nothing` in its type) that is absent is an error.

Throws a `ValidationError` (→ 400) when the body is not multipart, a required field is
missing, a value cannot be parsed, or `validate(::T)` / an extractor-local validator fails.

```julia
struct ImportUpload
    user_id  :: String
    ibge_id  :: Int
    files    :: Vector{FormFile}
end

function submit_import(req, payload::MultipartForm{ImportUpload})
    data = payload.payload
    data.files     # ::Vector{FormFile}
    data.ibge_id   # ::Int
end
```
"""
function extract(param::Param{MultipartForm{T}}, request::LazyRequest) :: MultipartForm{T} where {T}
    # Reject a genuinely non-multipart request up front. Detect this from the
    # Content-Type rather than from an empty parse result, so that a well-formed
    # (but empty or incomplete) multipart body falls through to the field binder
    # and gets a specific "Missing field 'X'" error instead of a misleading
    # "Content-Type must be multipart/form-data".
    content_type = HTTP.header(request.request, "Content-Type", "")
    if !occursin("multipart/form-data", content_type)
        throw(ValidationError("Content-Type must be multipart/form-data for parameter: $(param.name)"))
    end

    parsed = multipartbody(request)
    instance = safe_extract(param) do
        multipart_struct_builder(T, parsed)
    end
    valid_instance = try_validate(param, instance)
    return MultipartForm(valid_instance)
end

"""
Builds an instance of `T` by binding each of its fields from a parsed multipart body.

A plain `struct` is constructed positionally in declaration order. A `@kwdef struct`
is constructed by keyword so that **field defaults are honored**: a field absent from
the body falls back to its declared default. An absent `Union{Nothing, _}` field always
binds to `nothing` (the documented optional rule, which takes precedence over a default),
and an absent field with neither a default nor `Nothing` in its type raises a
`ValidationError`.
"""
function multipart_struct_builder(::Type{T}, parsed::AbstractDict) :: T where {T}
    # A `@kwdef` struct exposes a keyword constructor accepting all its fields;
    # a plain struct does not. Building the former by keyword lets us omit absent
    # fields so their declared defaults apply.
    if hasmethod(T, Tuple{}, fieldnames(T))
        return multipart_kw_build(T, parsed)
    end
    args = Any[multipart_bind(String(name), fieldtype(T, name), parsed) for name in fieldnames(T)]
    return T(args...)
end

function multipart_kw_build(::Type{T}, parsed::AbstractDict) :: T where {T}
    kwargs = Pair{Symbol, Any}[]
    for name in fieldnames(T)
        field = String(name)
        ftype = fieldtype(T, name)
        if haskey(parsed, field)
            push!(kwargs, name => multipart_bind(field, ftype, parsed))
        elseif ftype isa Union && Nothing in Base.uniontypes(ftype)
            push!(kwargs, name => nothing)   # documented optional → nothing
        end
        # else: absent and non-optional — omit so the struct's own default applies.
    end
    try
        return T(; kwargs...)
    catch e
        e isa UndefKeywordError &&
            throw(ValidationError("Missing required field '$(e.var)'"))
        rethrow()
    end
end

multipart_bind(field::String, ::Type{String}, parsed::AbstractDict) =
    multipart_text_value(field, parsed)

function multipart_bind(field::String, ::Type{N}, parsed::AbstractDict) where {N <: Number}
    raw = strip(multipart_text_value(field, parsed))
    result = tryparse(N, raw)
    isnothing(result) && throw(ValidationError("Field '$field' could not be parsed as $N"))
    return result
end

function multipart_bind(field::String, ::Type{Bool}, parsed::AbstractDict)
    raw = strip(multipart_text_value(field, parsed))
    raw in ("true", "1", "yes") && return true
    raw in ("false", "0", "no") && return false
    throw(ValidationError("Field '$field' is not a valid Bool value"))
end

multipart_bind(field::String, ::Type{Vector{String}}, parsed::AbstractDict) =
    multipart_text_values(field, parsed)

function multipart_bind(field::String, ::Type{FormFile}, parsed::AbstractDict)
    value = get(parsed, field, nothing)
    isnothing(value) && throw(ValidationError("Missing file field '$field'"))
    value isa FormFile && return value
    if value isa Vector{FormFile}
        length(value) == 1 && return first(value)
        throw(ValidationError("Field '$field' expected one file but received $(length(value))"))
    end
    throw(ValidationError("Field '$field' is not a file upload"))
end

function multipart_bind(field::String, ::Type{Vector{FormFile}}, parsed::AbstractDict)
    value = get(parsed, field, nothing)
    isnothing(value) && throw(ValidationError("Missing file field '$field'"))
    value isa FormFile && return FormFile[value]
    value isa Vector{FormFile} && return value
    throw(ValidationError("Field '$field' is not a file upload"))
end

function multipart_bind(field::String, union_type::Union, parsed::AbstractDict)
    member_types = Base.uniontypes(union_type)
    optional = Nothing in member_types
    optional && !haskey(parsed, field) && return nothing

    last_error = nothing
    for current_type in member_types
        current_type === Nothing && continue
        try
            return multipart_bind(field, current_type, parsed)
        catch e
            last_error = e
        end
    end
    last_error isa ValidationError && throw(last_error)
    throw(ValidationError("Could not bind multipart field '$field' to $union_type"))
end

multipart_bind(field::String, ::Type{T}, parsed::AbstractDict) where {T} =
    throw(ValidationError("Unsupported multipart field type $T for field '$field'"))

function multipart_text_value(field::String, parsed::AbstractDict) :: String
    value = get(parsed, field, nothing)
    isnothing(value) && throw(ValidationError("Missing text field '$field'"))
    value isa AbstractString && return String(value)
    if value isa Vector && eltype(value) <: AbstractString
        length(value) == 1 && return String(first(value))
        throw(ValidationError("Field '$field' expected one value but received $(length(value))"))
    end
    (value isa FormFile || value isa Vector{FormFile}) &&
        throw(ValidationError("Field '$field' is a file upload, expected text"))
    throw(ValidationError("Field '$field' has unsupported multipart value type $(typeof(value))"))
end

function multipart_text_values(field::String, parsed::AbstractDict) :: Vector{String}
    value = get(parsed, field, nothing)
    isnothing(value) && throw(ValidationError("Missing text field '$field'"))
    value isa AbstractString && return String[String(value)]
    value isa Vector && eltype(value) <: AbstractString && return String[String(v) for v in value]
    (value isa FormFile || value isa Vector{FormFile}) &&
        throw(ValidationError("Field '$field' is a file upload, expected text"))
    throw(ValidationError("Field '$field' has unsupported multipart value type $(typeof(value))"))
end

end