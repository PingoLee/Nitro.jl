module Extractors

using JSON
using Base: @kwdef
using HTTP
using Dates

using ..Util: text, json, formdata, multipart, parseparam, parsebody, FormFile
using ..Util.BodyParsers: NITRO_READ_STYLE, NitroReadStyle, _parse_json_bounded, _body_view, is_json_media_type,
    is_multipart_form_media_type, is_form_media_type
using ..Util: TypeMemo, memoized, reset!
using ..Reflection: struct_builder, extract_struct_info, kw_construct, kw_constructible
using ..Util: _check_denial_factory, _deny
using ..Errors: ValidationError, UnsupportedMediaTypeError, AuthDenial, ValidatorFault, is_unrecoverable
# The Core stubs `getjson`/`getform`/`getprincipal` bind to (their bodies are in core/request.jl,
# included later).
using ...Core: getjson, getform, getprincipal
using ..Types
using ..Cookies
using ..Crypto: SecretString
# HTTP.jl v2 newly exports `Cookie` at the top level, which collides with Nitro's
# `Cookie` extractor (defined in `Types`). Import it explicitly so the unqualified
# `Cookie` references below resolve unambiguously to ours, not `HTTP.Cookie`.
using ..Types: Cookie

export extract, validate, extracttype, isextractor, isreqparam, isbodyparam,
    Path, Query, Header, Json, JsonFragment, Form, Body, Cookie, Session, Files, MultipartForm, Claims

"""
Given a classname, build a new Extractor class
"""
macro extractor(class_name)
    quote
        struct $(Symbol(class_name)){T} <: Extractor{T} 
            payload::Union{T, Nothing}
            validate::Union{Function, Nothing}
            type::Type{T}
        
            # Neither -- a default that only declares the extractor (#423)
            $(Symbol(class_name)){T}() where T = new{T}(nothing, nothing, T)

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

            # The declared type, whatever the value's runtime type. `extract` builds its result
            # with this: `X(payload)` is an `X{typeof(payload)}`, which a handler declaring
            # `X{Any}` (or any abstract `T`) could not accept -- a 500 (#327, the #293 family).
            $(Symbol(class_name)){T}(payload, validate::Union{Function, Nothing}) where T = new{T}(payload, validate, T)

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

## Principal Extractors

# The defaults of `Claims{T}`'s two denial factories (#515's contract): 401 when there is no token
# principal, 403 when there is one whose claims do not bind. A module-level `const` response is
# reuse-safe (nitro-core §4). The default `denied` is a sentinel as much as a factory: `extract`
# recognizes it and builds its 403 per request instead, naming the claim that failed (see
# `_claims_forbidden_response`).
const CLAIMS_UNAUTHORIZED = HTTP.Response(401, "Unauthorized")
_claims_unauthorized(::HTTP.Request, ::Symbol) = CLAIMS_UNAUTHORIZED
_claims_forbidden(::HTTP.Request, ::Symbol) = HTTP.Response(403, "Forbidden")

# Hand-written rather than `@extractor`: a `Claims` default also carries the two denial factories,
# which `extract` reads off `param.default`. The bound value never needs them, so the
# `(payload, validate)` constructor `extract` uses fills in the defaults without checking them;
# every constructor that takes a factory checks it, so a wrong one fails when the route is declared.
struct Claims{T} <: Extractor{T}
    payload::Nullable{T}
    validate::Union{Function, Nothing}
    type::Type{T}
    unauthorized::Function
    denied::Function

    Claims{T}(payload, validate::Union{Function, Nothing}) where {T} =
        new{T}(payload, validate, T, _claims_unauthorized, _claims_forbidden)

    function Claims{T}(payload, validate::Union{Function, Nothing}, unauthorized::Function,
                       denied::Function) where {T}
        _check_denial_factory(unauthorized, :unauthorized)
        _check_denial_factory(denied, :denied)
        return new{T}(payload, validate, T, unauthorized, denied)
    end
end

Claims{T}(; unauthorized::Function = _claims_unauthorized, denied::Function = _claims_forbidden) where {T} =
    Claims{T}(nothing, nothing, unauthorized, denied)
Claims{T}(f::Function; unauthorized::Function = _claims_unauthorized, denied::Function = _claims_forbidden) where {T} =
    Claims{T}(nothing, f, unauthorized, denied)
Claims(::Type{T}; unauthorized::Function = _claims_unauthorized, denied::Function = _claims_forbidden) where {T} =
    Claims{T}(nothing, nothing, unauthorized, denied)
Claims(::Type{T}, f::Function; unauthorized::Function = _claims_unauthorized, denied::Function = _claims_forbidden) where {T} =
    Claims{T}(nothing, f, unauthorized, denied)

# Every extractor is a thin wrapper: declare a handler parameter of the wrapped type, and the
# bound value arrives in `.payload`. They share one construction surface (from `@extractor`):
# `X(T)`, `X{T}()`, `X(T, validator)` and `X{T}(validator)` build the parameter's *default*, which
# is how an extractor-local validator is attached — `payload = Json(Search, s -> !isempty(s.q))`.
# A default is evaluated once, when the route is registered; one that cannot be (it throws, or
# refers to another parameter) is refused there rather than silently dropped (#423).
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
    Claims{T}

Extractor that binds the **verified token claims** into a struct `T`: the claims of
[`getprincipal`](@ref)`(req)`, the `Principal` that `jwt_validator` verified. It never reads
`getuser`, so an object the application built is never bound as if it were verified claims,
and with a `user_validator` the token's `Principal` at `req.context[:auth_claims]` is read, not
whatever the app put at `:user` (#517). The one way an application's own object binds is
`getprincipal`'s: a custom validator that returns a `Principal` itself, which is that validator
vouching for it.

```julia
struct ApiClaims
    sub::String
    role::String
    org_id::Int
end

report(req, claims::Claims{ApiClaims}) = Res.json(Dict("org" => claims.payload.org_id))  # an Int
```

The claims are not parsed again: the token was already decoded and validated, and `Claims{T}`
converts that `Dict` with the binder [`Json`](@ref) uses. Fields match claims by name, a claim
that is not a field is ignored, and the field's declared type is enforced: a `String` field does
not take a number, an `Int` field a string, nor a `Vector` field a single value. With a `@kwdef` struct an absent claim takes the
field's default, so optional claims are optional fields; an absent field with no default binds
`nothing` if its type admits one. The registered claims (`exp`, `iat`, `nbf`, `iss`, `aud`) may be
fields too. A `T` that would build a `Symbol` from a claim is refused when the route is declared
(#306): a verified token still carries whatever strings its holder had signed, so claims are
client-signed, not client-free.

A request it cannot bind is refused before the handler runs, through the same denial contract
as the auth middlewares and guards (#515):

| Request | Default | `reason` |
|---|---|---|
| no token principal: unauthenticated, session-only, or a custom validator's identity that is not a `Principal` | `401` | `:missing_credentials`, to `unauthorized` |
| a principal whose claims do not bind to `T` (a claim missing or of the wrong type), or fail `validate` | `403` | `:forbidden`, to `denied` |

Not binding is a `403`, not a `401`: the token is authentic, so authentication succeeded, but
it does not carry what this route requires. That is the guards' "authenticated but not
authorized", and RFC 6750's `insufficient_scope`. A `401` would tell the client to sign in again,
and the token it gets back has the same shape. The default `403` body names the claim, never its
value: `Forbidden: claim 'org_id' is missing`, or `… is not of type Int64`. A failed validator is a
`403` too, not the `400` other extractors answer, since the principal is not client input.

Pass the app's own factories through the parameter's default, as in `BearerAuth` and the guards:

```julia
report(req, claims = Claims(ApiClaims; unauthorized = UNAUTHORIZED, denied = UNAUTHORIZED)) = ...
```

Each is a `(req, reason) -> HTTP.Response`, and is told only the reason. Which claim failed is
logged at `@debug`; a factory of the app's own does not receive it.
"""
Claims

"""
    Json{T}

Extractor that parses the whole request body as JSON into `T`. This is the recommended way to
take a JSON body: typed, validated, and a malformed body is a 400 -- including one nested deeper
than 512 arrays/objects, which is rejected before parsing (#314).

```julia
@kwdef struct Search; q::String; limit::Int = 20; end
path("/search", (req, s::Json{Search}) -> Res.json(s.payload); method = "POST")
```

With a `@kwdef` struct, a field the body omits takes its declared default: `{"q":"lamp"}` binds
`limit = 20`, while a body without `q` is a 400. An omitted field with no default binds `nothing`
(or `missing`) if its type admits one. A plain struct needs every field.

Attach a validator by giving the parameter a default: `s = Json(Search, s -> s.limit <= 100)`.
The *Request Body* guide has the walkthrough; use [`JsonFragment`](@ref) to bind one top-level
key instead of the whole body.

The request must declare a JSON body: `Content-Type: application/json` or an
`application/*+json` type. Anything else, including no `Content-Type`, is a `415` (#327) — those
are the types a cross-site page can send without a CORS preflight.
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
the key, is a 400. Like [`Json`](@ref), it needs a JSON `Content-Type`, or it is a 415.
"""
JsonFragment

"""
    Form{T}

Extractor that binds an `application/x-www-form-urlencoded` body into a struct `T`, matching
fields by name and parsing them to their declared types. For `multipart/form-data`, use
[`MultipartForm`](@ref) (text fields and files) or [`Files`](@ref) (files only).

A request that declares any other `Content-Type` -- `text/plain`, JSON, XML, multipart -- is a
`415` (#345). A request with no `Content-Type` is still read as a form.
"""
Form

"""
    Body{T}

Extractor that parses the raw request body as a single value of type `T`, such as a `String`,
a number or a `Bool`, with no JSON or form decoding. `Body{String}` is the body text verbatim.

`T` must be something a body's text parses to on its own: `String`, `Any` (the text), `Char`,
`Regex`, an `@enum`, a concrete type with a `Base.parse(::Type{T}, ::String)` method -- numbers, `Bool`,
`Date`, `UUID` -- or a `Union` of those with `Nothing`/`Missing`. The `Content-Type` is not
checked, because the body is not decoded.

A struct or container `T` is refused when the route is declared (#345): binding it would mean
parsing the body as JSON whatever its type, including the `text/plain` a cross-site page can send
without a CORS preflight. Use [`Json`](@ref) for those, which requires a JSON `Content-Type`.
The check runs when the route is registered, so an app's own `Base.parse` method must be defined
before its `urlpatterns` call.
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
parameter's default (`Json(Search, f)`), runs *after* this one; both must pass. A validator that
throws anything but a `ValidationError`, or returns a non-`Bool`, is a server bug and a `500`; its
exception is dropped, because it may render the value the validator was handed (#595).
"""
validate(type::T) where {T} = true

"""
This function will try to validate an instance of a type using both global and local validators.
If both validators pass, the instance is returned. If either fails, a `ValidationError` is thrown.
"""
function try_validate(param::Param{U}, instance) :: T where {T, U <: Extractor{T}}
    # `T` comes from the extractor, never from the instance: dispatching on `instance::T` bound
    # `T` to the value's RUNTIME type, so `Session{Any}` (or `Body{Any}`, `Json{Any}`) holding a
    # `User` matched no method at all -- a `MethodError`, answered as a 500 (#327, the #293
    # family). Every caller hands over a value it bound as a `T`; the return type asserts it.

    # The message names the parameter, its type, and the validator that rejected it —
    # never the instance. For a body-bound extractor the instance *is* the client's
    # deserialized payload, so interpolating it put submitted credentials into `.msg`,
    # which is app-reachable through `showerror` and any `catch ValidationError` (#72).
    # This matches what `parseparam_checked` (src/utilities/misc.jl) already does for
    # query and path parameters.

    # Case 1: Use global validate function - returns true if one isn't defined for this type
    passed = validator_verdict(validate, instance)
    if passed !== true
        passed === nothing && throw(validator_fault(param, T, global_validate_identity(instance)))
        impl = Base.which(validate, (typeof(instance),))
        throw(ValidationError("Validation failed for parameter '$(param.name)': $T rejected by $(impl.module).validate"))
    end

    # Case 2: Use custom validate function from an Extractor (if defined).
    #
    # `hasfield` because not every extractor carries one: `Cookie{T}` did not until #293,
    # and `ProtoBuffer{T}` (src/exts.jl) still does not. Reading `.validate` off such a
    # default was a `FieldError`, which is not a `ValidationError`, so the route answered
    # 500 whenever the value was present. It folds to a constant for a concrete `U`.
    if param.hasdefault && param.default isa U && hasfield(U, :validate) && !isnothing(param.default.validate)
        passed = validator_verdict(param.default.validate, instance)
        if passed !== true
            identity = validator_identity(param.default.validate, param)
            passed === nothing && throw(validator_fault(param, T, identity))
            throw(ValidationError("Validation failed for parameter '$(param.name)': $T rejected by $identity"))
        end
    end

    return instance
end

# A validator's verdict: `true`/`false`, or `nothing` when it threw or returned a non-`Bool` (#595).
# A validator is application code handed the bound value -- a client's deserialized body, a token's
# claims -- and its most likely accidental throw is a `MethodError`, which renders its arguments.
# Reaching `handlerequest`'s `@error` that wrote the value to the log, so the exception is dropped
# here. A non-`Bool` is caught by type, not by `!` throwing: `!x` is a `MethodError` holding `x`.
#
# The fault is raised by the CALLER, after this returns, never from inside the `catch`: a throw
# from a `catch` block leaves the original on the task's exception stack (`current_exceptions()`),
# still holding the value. A `ValidationError` is the validator's own message, so it passes.
function validator_verdict(f::F, instance) :: Nullable{Bool} where {F}
    try
        ok = f(instance)
        return ok isa Bool ? ok : nothing
    catch e
        (e isa ValidationError || is_unrecoverable(e)) && rethrow()
        return nothing
    end
end

# Which `validate` method faulted. `which` itself throws when the fault WAS the lookup -- two
# `validate` methods ambiguous for the bound type are a `MethodError` too -- and the fault must
# still be raised, so the identity degrades to the bare name.
function global_validate_identity(instance) :: String
    try
        return "$(Base.which(validate, (typeof(instance),)).module).validate"
    catch e
        is_unrecoverable(e) && rethrow()
        return "validate"
    end
end

validator_fault(param::Param, ::Type{T}, identity::String) where {T} = ValidatorFault(
    "Validator for parameter '$(param.name)' failed on a $T: $identity threw or returned a non-Bool")

# Which validator rejected a value, for `ValidationError.msg`: a function and its module, never a
# source location (#327). This used to interpolate `Base.which(...)`, which renders as
# `validate(s::Login) @ Main ~/app/src/handlers.jl:12` -- and `.msg` is what an app returns to a
# client (`JSON.json(err)` is documented as safe), so every rejection published the deployment's
# directory layout. An anonymous validator has no name of its own; the parameter it guards is
# its identity.
function validator_identity(f::Function, param::Param) :: String
    name = String(nameof(f))
    startswith(name, '#') && return "the extractor-local validator of parameter '$(param.name)'"
    return "$(parentmodule(f)).$name"
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
        # issue's fix is not confined to the parsers. If this guard named only
        # `InterruptException`, a `StackOverflowError` or `OutOfMemoryError` raised while
        # binding would be caught here and laundered into a `ValidationError` -- so every
        # extractor-based route, the most idiomatic shape in the framework, would answer 400
        # for a corrupted worker while a bare `getjson` handler answered 500.
        #
        # A deeply-nested body no longer overflows on the way here: every JSON parse behind
        # `Json{T}`/`JsonFragment{T}` is depth-bounded (#314) and answers an
        # ordinary `ArgumentError`, which becomes the 400 below. This line is the backstop
        # for what the bound does not cover.
        #
        # A further wrap site must copy this line too.
        is_unrecoverable(e) && rethrow()
        if e isa ValidationError || e isa UnsupportedMediaTypeError
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

# A form body must say it is a form, or say nothing (#345). The untyped case is kept for
# hand-built requests; a body declared as anything else is not read as a form by `getform` either,
# so without this `Form{T}` would bind an empty form -- a 400, or a silent 200 when every field of a
# `@kwdef` struct has a default. The message names the parameter, never the client's Content-Type.
function require_form_media_type(param::Param, request::LazyRequest)
    is_form_media_type(HTTP.header(request.request, "Content-Type", "")) && return nothing
    throw(UnsupportedMediaTypeError(
        "parameter '$(param.name)' needs a form body: Content-Type application/x-www-form-urlencoded"))
end

# A body bound as JSON must say it is JSON (#327). `text/plain`, a urlencoded form, multipart, or
# no Content-Type at all are what a cross-site page can send without a CORS preflight, so reading
# JSON from them regardless accepts a forged request as readily as the app's own client. The
# message names the parameter, never the client's Content-Type.
function require_json_media_type(param::Param, request::LazyRequest)
    is_json_media_type(HTTP.header(request.request, "Content-Type", "")) && return nothing
    throw(UnsupportedMediaTypeError(
        "parameter '$(param.name)' needs a JSON body: Content-Type application/json or application/*+json"))
end

"""
Extracts a JSON object from a request and converts it into a custom struct
"""
function extract(param::Param{Json{T}}, request::LazyRequest) :: Json{T} where {T}
    require_json_media_type(param, request)
    instance = safe_extract(param) do
        # Straight from the body's bytes: `textbody` would copy the whole body into a `String`
        # first, only for JSON.jl to read it back as bytes (#327). The body's type is abstract
        # here, so this is a dynamic call whatever it calls; calling the binder directly keeps
        # it the only one (see `json_binder`).
        Base.inferencebarrier(json_binder(T))(_body_view(request.request.body)) :: T
    end
    valid_instance = try_validate(param, instance)
    return Json{T}(valid_instance, nothing)
end

"""
    json_bind(T, text) :: T

`JSON.parse(text, T)`, except that a `@kwdef` struct is built through its keyword constructor, so
a field the body omits takes its declared default (#294). JSON.jl 1.x knows only StructUtils-style
defaults, not `Base.@kwdef`'s, and answers a partial body with "field has no default and is absent
from the source" -- while `Query{T}`, `Form{T}` and `JsonFragment{T}` already honored the defaults
through `struct_builder`.

A `@kwdef` struct is bound in one `JSON.parse` over the body, through the `KwdefBind{T}` hook: each
present field is parsed against its own declared type, with JSON.jl's own read style, so field
values bind exactly as they do for a plain struct, and the parse rejects a malformed or
trailing-garbage body as before. It used to parse the body twice -- once into
`Dict{String, JSON.JSONText}` to learn which fields were present, then each field again -- which
made a large `@kwdef` body slower to bind than an untyped `getjson` (#493). A `@kwdef` struct
nested directly as a field is bound the same way; one inside a container or a `Union` follows
JSON.jl's own rules.

A struct that already speaks StructUtils -- field tags or defaults, as `StructUtils.@kwarg`,
`@tags` and `@defaults` declare -- is left to `JSON.parse` whole: JSON.jl honors those itself, and
the per-field path would drop the tags, so a renamed key would silently bind the field's default.

The parse goes through `_parse_json_bounded`, so a body nested deeper than 512 is an
`ArgumentError` -- a 400 via `safe_extract` -- before `JSON.parse` recurses into it (#314). And
it uses Nitro's read style, which never interns a client string as a `Symbol` (#306): JSON.jl's
default style did so for every enum field, valid name or not.
"""
function json_bind(::Type{T}, text::Union{AbstractString, AbstractVector{UInt8}}) :: T where {T}
    return Base.inferencebarrier(json_binder(T))(text) :: T
end

# `json_bind` reaches its parse through `inferencebarrier`, and that is what keeps a type's first
# request cheap (#508). Which parse a type takes is answered at run time, so the compiler, unable
# to know it, used to compile BOTH for every `T`: for a `@kwdef` type the branch it never takes is
# JSON.jl's whole plain-struct parse specialized on `T`, which cost more to compile than the
# branch it does take. And it compiled them twice: `Json{T}` hands over the body through a
# `LazyRequest`, whose abstractly typed request makes the text abstract, so each branch was
# inferred once for `AbstractVector{UInt8}` and again for the body's concrete type. Behind the
# barrier only the parse a request takes is compiled, for the text it has. The price is one
# dynamic call per bind, about 25 ns, plus a box for the result when `T` is isbits. The call is
# on an instance rather than on the `Type`, which dispatches about four times faster.
struct JsonBinder{P} end
(::JsonBinder{P})(text) where {P} = _parse_json_bounded(text, P; style = NITRO_READ_STYLE)

json_binder(::Type{T}) where {T} = binds_by_keyword(T) ? JsonBinder{KwdefBind{T}}() : JsonBinder{T}()

"""
    stored_json_bind(T, text) :: T

`json_bind` for JSON the application stored itself, such as a named job's arguments
([#514](https://github.com/PingoLee/Nitro.jl/issues/514)). It is the same bind: the same
`@kwdef` defaults, Nitro's read style, and the 512-level depth bound. The one difference is that
it applies **no field cap** (`max_fields = 0`).

The cap (#327) guards request bodies, whose keys a client chooses. Stored data is the app's own,
so every read of it parses with `max_fields = 0`, as the PormG stores do. Through `json_bind` it
would take whatever cap was in force: `serve(max_fields = …)` inside a request, and 1000 outside
one. A job's arguments are checked at submit, often inside a request, and bound when the run
starts, always on a background task outside one. So arguments under the app's raised cap would
pass the check and then fail the run.
"""
function stored_json_bind(::Type{T}, text::Union{AbstractString, AbstractVector{UInt8}}) :: T where {T}
    return Base.inferencebarrier(stored_json_binder(T))(text) :: T
end

# A separate binder type, not a keyword on `JsonBinder`, so `Json{T}`'s request path compiles and
# runs exactly as before; the barrier reasoning above applies to this one unchanged.
struct StoredJsonBinder{P} end
(::StoredJsonBinder{P})(text) where {P} =
    _parse_json_bounded(text, P; style = NITRO_READ_STYLE, max_fields = 0)

stored_json_binder(::Type{T}) where {T} =
    binds_by_keyword(T) ? StoredJsonBinder{KwdefBind{T}}() : StoredJsonBinder{T}()

# Asked once per `Json{T}` request and once per field of a keyword-bound struct, so the answer is
# memoized per type (#493): uncached, the `hasmethod` behind `kw_constructible` cost ~1 µs, three
# times the parse of a small body. StructUtils is reached through JSON, whose typed-parse API is
# built on it, so it is not a dependency of Nitro's own.
const _SU = JSON.StructUtils
const BINDS_BY_KEYWORD = TypeMemo()
__init__() = reset!(BINDS_BY_KEYWORD)
binds_by_keyword(::Type{T}) where {T} = memoized(_binds_by_keyword, BINDS_BY_KEYWORD, T)
function _binds_by_keyword(::Type{T}) :: Bool where {T}
    T isa DataType && isstructtype(T) || return false
    style = _SU.DefaultStyle()
    isempty(_SU.fieldtags(style, T)) && isempty(_SU.fielddefaults(style, T)) || return false
    return kw_constructible(T)
end

"""
    KwdefBind{T}

Parse target standing in for a keyword-bound `T` (see `json_bind`). Overloading `StructUtils.make`
for a type Nitro owns is JSON.jl's hook for custom construction, and JSON.jl hands the method its
**own** read style: every field parsed with that style binds exactly as `JSON.parse(·, FT; style)`
would, and returns the position after it, so the body is walked once. No JSON.jl internals are
named.
"""
struct KwdefBind{T} end
(::KwdefBind{T})(style, source) where {T} = _SU.make(style, KwdefBind{T}, source)

# The fields a `KwdefBind{T}` walk has seen, as keyword arguments for `kw_construct`.
struct KwdefFields{T, S}
    style::S
    kwargs::Vector{Pair{Symbol, Any}}
end

@noinline _throw_not_an_object() = throw(ArgumentError("expected a JSON object"))

function _SU.make(st::_SU.StructStyle, ::Type{KwdefBind{T}}, source) where {T}
    fields = KwdefFields{T, typeof(st)}(st, Pair{Symbol, Any}[])
    pos = _SU.applyeach(st, fields, source)
    return kw_construct(T, fields.kwargs), pos
end

# An array hands its elements over with integer keys, an object its field names. JSON.jl would bind
# a struct from an array positionally; the keyword path never has. An empty array has no element
# to refuse and binds every default -- as it did through the `Dict` this walk replaced.
#
# The key is materialized once. JSON.jl hands it over undecoded, and comparing an escaped key to a
# `String` decodes it again on every comparison: one long escaped key, matched against every field
# of a wide struct, allocated its length once per field.
function (fields::KwdefFields)(key, value)
    key isa Integer && _throw_not_an_object()
    return bind_field!(fields, String(key), value)
end

# One literal comparison per field, unrolled so each branch knows its field's type statically. A
# key matching no field returns `nothing`, and JSON.jl skips its value.
@generated function bind_field!(fields::KwdefFields{T}, key, value) where {T}
    body = Expr(:block)
    for name in fieldnames(T)
        push!(body.args, :(key == $(String(name)) &&
            return bind_field!(fields, $(QuoteNode(name)), $(fieldtype(T, name)), value)))
    end
    push!(body.args, :(return nothing))
    return body
end

# A field's type takes one of the same two parses as `json_bind`'s `T`, with the same problem. Both
# were compiled for every field type: an `Int` field compiled a keyword walk it never takes, and a
# `Vector` field's recursed into `Vector`'s own fields (#508). Only that branch is behind a
# barrier. It is the one a field rarely takes -- a `@kwdef` struct nested directly as a field --
# so a plain field keeps its static call and only a nested `@kwdef` field pays the dynamic one.
function bind_field!(fields::KwdefFields, name::Symbol, ::Type{FT}, value) where {FT}
    bound, pos = binds_by_keyword(FT) ?
        Base.inferencebarrier(KwdefBind{FT}())(fields.style, value) :: Tuple{FT, Int} :
        _SU.make(fields.style, FT, value)
    # A repeated key replaces the earlier value, so the last one binds. Every occurrence is parsed,
    # though, so an invalid one refuses the body even when a later one is valid -- as JSON.jl's
    # plain-struct path does. The `Dict` this walk replaced kept only the last text and parsed that.
    i = findfirst(p -> p.first === name, fields.kwargs)
    i === nothing ? push!(fields.kwargs, name => bound) : (fields.kwargs[i] = name => bound)
    return pos
end

"""
Extracts a part of a json object from the body of a request and converts it into a custom struct
"""
function extract(param::Param{JsonFragment{T}}, request::LazyRequest) :: JsonFragment{T} where {T}
    require_json_media_type(param, request)
    instance = safe_extract(param) do
        # The fragment lookup belongs INSIDE the guard: a body that is not a JSON object
        # (`MethodError` on `getindex(::Nothing, ::String)`) or one missing this fragment's
        # key (`KeyError`) is client input, and used to escape as a 500 with a backtrace
        # while every sibling extractor returned a 400.
        #
        # Through the cached `getjson`, so several fragments of one body parse it once.
        struct_builder(T, getjson(request.request)[string(param.name)])
    end
    valid_instance = try_validate(param, instance)
    return JsonFragment{T}(valid_instance, nothing)
end

"""
Extracts the body from a request and convert it into a custom type
"""
function extract(param::Param{Body{T}}, request::LazyRequest) :: Body{T} where {T}
    instance = safe_extract(param) do
        # Never `parseparam`: its JSON fall-through would bind a struct from any body (#345).
        parsebody(T, textbody(request))
    end
    valid_instance = try_validate(param, instance)
    return Body{T}(valid_instance, nothing)
end

"""
Extracts a Form from a request and converts it into a custom struct
"""
function extract(param::Param{Form{T}}, request::LazyRequest) :: Form{T} where {T}
    require_form_media_type(param, request)
    # The cached `getform`, so a handler that also reads `getform`/`payload` -- or CSRFMiddleware,
    # which reads the form for its token -- does not parse the body again (#327).
    form = getform(request.request)::Dict{String,String}   # the cache is untyped; keep `Any` off the hot path
    instance = safe_extract(param) do 
        struct_builder(T, form) 
    end
    valid_instance = try_validate(param, instance)
    return Form{T}(valid_instance, nothing)
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
    return Path{T}(valid_instance, nothing)
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
    return Query{T}(valid_instance, nothing)
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
    return Header{T}(valid_instance, nothing)
end

"""
Binds the verified token claims of `getprincipal(req)` into a custom struct (#527).
"""
function extract(param::Param{Claims{T}}, request::LazyRequest) :: Claims{T} where {T}
    req = request.request
    unauthorized, denied = claims_factories(param)
    principal = getprincipal(req)
    principal === nothing && throw(AuthDenial(_deny(unauthorized, req, :missing_credentials)))
    claims = getfield(principal, :claims)
    instance = try
        claims_bind(T, claims)
    catch e
        is_unrecoverable(e) && rethrow()
        # `e` is dropped on purpose: a `MethodError` from the conversion holds the claim's value,
        # and claims carry identities, so nothing of it is kept or logged. The diagnosis is only a
        # better message, so a failure inside it costs the message, never the 403.
        why = try
            claims_mismatch(T, claims)
        catch d
            is_unrecoverable(d) && rethrow()
            "the claims do not bind to $T"
        end
        @debug "Claims{T} refused: the token's claims do not bind" parameter = param.name type = T why
        throw(AuthDenial(_claims_forbidden_response(denied, req, why)))
    end
    valid_instance = try
        try_validate(param, instance)
    catch e
        e isa ValidationError || rethrow()
        @debug "Claims{T} refused: a validator rejected the claims" message = e.msg
        throw(AuthDenial(_claims_forbidden_response(denied, req, "a validator rejected the claims")))
    end
    return Claims{T}(valid_instance, nothing)
end

# The factories the parameter's default declared, else the defaults. Folds to a constant for a
# parameter with no default.
function claims_factories(param::Param{Claims{T}}) where {T}
    default = param.default
    (param.hasdefault && default isa Claims{T}) || return (_claims_unauthorized, _claims_forbidden)
    return (default.unauthorized, default.denied)
end

# The default `denied` names the claim that failed; an app's factory is told only the reason.
function _claims_forbidden_response(denied::Function, req::HTTP.Request, why::String) :: HTTP.Response
    denied === _claims_forbidden && return HTTP.Response(403, "Forbidden: " * why)
    return _deny(denied, req, :forbidden)
end

"""
    claims_bind(T, claims::Dict{String, Any}) :: T

The verified claims converted to `T` with `json_bind`'s binder, which walks a `Dict` exactly as it
walks a JSON body: StructUtils' `make` with Nitro's read style, through `KwdefBind{T}` for a
`@kwdef` struct. There is no JSON parse and no re-serialization: the token was decoded and
validated by `jwt_validator` already (#449 refused binding a JWT straight from its text). The call
goes through `inferencebarrier` for the reason `json_bind`'s does (#508): only the branch a type
takes is compiled.
"""
claims_bind(::Type{T}, claims::Dict{String, Any}) where {T} =
    Base.inferencebarrier(claims_binder(T))(claims) :: T

struct ClaimsBinder{P} end
(::ClaimsBinder{P})(claims) where {P} = first(_SU.make(NITRO_READ_STYLE, P, claims))

# A collection field takes only a collection. StructUtils walks whatever source it is handed, so a
# scalar claim bound to an array, set or dict field made an EMPTY one -- `"aud" => "api"` bound
# `aud::Vector{String}` as `String[]`, and a deny-list check on it admitted everything -- where
# `Json{T}` refuses the same `{"aud":"api"}`. These are the scalars a decoded claim can be. A JSON
# body never reaches this method: JSON.jl hands `make` its own lazy values, not Julia scalars.
@noinline _throw_scalar_for_collection() = throw(ArgumentError("expected a JSON array or object"))
_SU.make(::NitroReadStyle, ::Type{T}, ::Union{AbstractString, Number, Nothing}) where
    {T <: Union{AbstractArray, AbstractSet, AbstractDict}} = _throw_scalar_for_collection()

claims_binder(::Type{T}) where {T} = binds_by_keyword(T) ? ClaimsBinder{KwdefBind{T}}() : ClaimsBinder{T}()

# Which claim made `claims_bind` fail, for the refusal: the first field whose claim does not bind
# as the field's type, else the first required field with no claim. Runs on the refusal path only,
# and names fields of `T` and their declared types, never a value. The error the bind raised is
# no help: a conversion's `MethodError` names neither the field nor anything safe to repeat.
function claims_mismatch(::Type{T}, claims::Dict{String, Any}) :: String where {T}
    # Only a record's fields are claims. A `Tuple` or a collection has fields of its own that are
    # not claim names, and a StructUtils-tagged field may bind a claim under another name.
    generic = "the claims do not bind to $T"
    (T isa DataType && isstructtype(T)) || return generic
    T <: Union{Tuple, NamedTuple, AbstractArray, AbstractSet, AbstractDict} && return generic
    isempty(_SU.fieldtags(_SU.DefaultStyle(), T)) || return generic
    keyword = binds_by_keyword(T)
    defaults = keyword ? (;) : _SU.fielddefaults(_SU.DefaultStyle(), T)
    kwargs = Pair{Symbol, Any}[]
    for name in fieldnames(T)
        key = String(name)
        FT = fieldtype(T, name)
        if haskey(claims, key)
            bound = try
                claims_field_bind(FT, claims[key])
            catch e
                is_unrecoverable(e) && rethrow()
                return "claim '$key' is not of type $(Base.nonnothingtype(FT))"
            end
            push!(kwargs, name => bound)
        elseif Nothing <: FT || Missing <: FT
            push!(kwargs, name => (Nothing <: FT ? nothing : missing))
        elseif !keyword && !haskey(defaults, name)
            return "claim '$key' is missing"
        end
    end
    # A `@kwdef` struct knows its own defaults: whichever keyword it still needs had no claim.
    if keyword
        try
            T(; kwargs...)
        catch e
            is_unrecoverable(e) && rethrow()
            e isa UndefKeywordError && e.var in fieldnames(T) && return "claim '$(e.var)' is missing"
        end
    end
    return "the claims do not bind to $T"
end

claims_field_bind(::Type{FT}, value) where {FT} =
    first(_SU.make(NITRO_READ_STYLE, binds_by_keyword(FT) ? KwdefBind{FT} : FT, value))

"""
Extracts a cookie from a request and converts it into a custom type.
This is a helper used by the cookie strategy in Core.
"""
function extract(param::Param{Cookie{T}}, request::LazyRequest, secret_key::Union{AbstractString, SecretString, Nothing}) :: Cookie{T} where {T}
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
    # From the REQUEST, not `headers(request)`: that is a lowercased Dict keeping only the last
    # `cookie` header, so repeated headers would resolve differently here than in
    # `get_cookie(req)` / `parse_cookies(req)` (#329).
    val = Cookies.get_cookie(request.req, cookie_name; encrypted=!isnothing(secret_key), secret_key=secret_key)
    
    if isnothing(val)
        return Cookie(cookie_name, T)
    end

    instance = safe_extract(param) do 
        parseparam(T, val) 
    end
    
    valid_instance = try_validate(param, instance)
    return Cookie{T}(cookie_name, valid_instance)
end

"""
Extracts a session from a request using the application context as a store.
"""
function extract(param::Param{Session{T}}, request::LazyRequest, secret_key::Union{AbstractString, SecretString, Nothing}, app_context::Any) :: Session{T} where {T}
    # 1. Get the session cookie name
    session_cookie_name = if param.hasdefault && !isnothing(param.default.name) && !isempty(param.default.name)
        param.default.name
    else
        "session" # default session cookie name
    end

    # 2. Extract the session ID from cookies
    val = Cookies.get_cookie(request.req, session_cookie_name; encrypted=!isnothing(secret_key), secret_key=secret_key)
    
    if isnothing(val) || isempty(val)
        return Session(session_cookie_name, T)
    end

    # 3. Lookup in App Context
    if ismissing(app_context)
        return Session(session_cookie_name, T)
    end

    # app_context is expected to be a Context object
    store = app_context.payload

    # Only a session store is read (#327). Any other context used to be indexed directly by the
    # cookie's value -- meant for a `Dict` of sessions, but a context that was the app's
    # CONFIGURATION let `Cookie: session=admin_defaults` bind that config entry as the session,
    # and without a `secret_key` the client picks the cookie value freely.
    if !(store isa AbstractSessionStore{String})
        @warn "Session{T} reads only an AbstractSessionStore{String} app context; this one is not a store, so no Session{T} parameter will ever bind a session" context_type = typeof(store) maxlog = 1
        return Session(session_cookie_name, T)
    end

    instance = try
        get_session(store, val)
    catch e
        # The store is application code, so "it threw" means "no session for this id" and the
        # extractor falls back. The three in `is_unrecoverable` are not that (#254).
        is_unrecoverable(e) && rethrow()
        nothing
    end

    # A stored value of another type is not this parameter's session. It used to reach
    # `try_validate` with the wrong type and fail there as a 500 (the #293 family).
    if isnothing(instance) || !(instance isa T)
        return Session(session_cookie_name, T)
    end

    valid_instance = try_validate(param, instance)
    return Session{T}(session_cookie_name, valid_instance)
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
| `T <: Number`, `Bool`       | single text field, parsed; a float must be finite |
| `Vector{String}`            | all text fields under that name                   |
| `FormFile`                  | single uploaded file (by field name)              |
| `Vector{FormFile}`          | all uploaded files under that name                |
| `Union{X, Nothing}`         | optional — `nothing` when the field is absent     |

For a `@kwdef struct`, a field absent from the body falls back to its declared default;
an absent `Union{X, Nothing}` field always binds to `nothing` (taking precedence over a
default). A required field (no default, no `Nothing` in its type) that is absent is an error.

A request whose `Content-Type` is not `multipart/form-data` is an `UnsupportedMediaTypeError`
(→ 415). Throws a `ValidationError` (→ 400) when a required field is missing, a value cannot be
parsed, or `validate(::T)` / an extractor-local validator fails.

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
    if !is_multipart_form_media_type(content_type)
        # 415, like a JSON extractor given the wrong type (#327). It was a 400.
        throw(UnsupportedMediaTypeError("parameter '$(param.name)' needs a multipart/form-data body"))
    end

    parsed = multipartbody(request)
    instance = safe_extract(param) do
        multipart_struct_builder(T, parsed)
    end
    valid_instance = try_validate(param, instance)
    return MultipartForm{T}(valid_instance, nothing)
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
    if kw_constructible(T)
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
    # A union of number types is `<: Number` too, and wins dispatch over the `Union` method below;
    # `tryparse` on a union recurses until the stack overflows. Try the members one by one instead.
    N isa Union && return invoke(multipart_bind, Tuple{String, Union, AbstractDict}, field, N, parsed)
    raw = strip(multipart_text_value(field, parsed))
    result = tryparse(N, raw)
    isnothing(result) && throw(ValidationError("Field '$field' could not be parsed as $N"))
    # `tryparse(Float64, "nan")` and `"1e999"` (→ Inf) succeed (#327).
    result isa AbstractFloat && !isfinite(result) &&
        throw(ValidationError("Field '$field' must be a finite number"))
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