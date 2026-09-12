module Errors
## In this module, we export commonly used exceptions across the package

import JSON

export ValidationError, CookieError, AuthorizationError

"""
    ValidationError(msg::String)
    ValidationError(msg::String, cause::Exception)

The exception Nitro raises when a request is rejected as **client input**: an extractor could not
bind the body, a scalar path or query parameter would not parse, a percent-escape was malformed, or
a `validate` method returned `false`. `handle_error` turns it into a fixed `400 Bad Request`; no
detail from this value ever reaches the response body.

`msg` names the parameter, its source, and the expected type or the rejecting validator, and
**never the submitted value** (#72). It is safe to log.

`cause` is the underlying exception, when there was one. It is **not** safe to log or serialize:
those exceptions quote their input, so a rejected JSON body puts the submitted password in there.
All three of Nitro's output paths mask it — `showerror`, `show`, and `JSON.lower` — which keeps
`@error … exception=err`, Julia's own exception display, and `Res.json(err)` value-free by
construction rather than by convention. Each renders the cause's *type* and never its message.
Reaching the cause itself is opt-in, per call:

```julia
sprint(showerror, err)                            # "Validation Error: <msg>" -- safe
sprint(io -> showerror(io, err; cause = true))    # ...plus "Caused by: <cause>"
Nitro.Errors.cause_report(err)                    # the same, as a String
```

Those two forms are for a REPL session while debugging — never a log sink, a response body, or a
bug report (#130).

!!! warning
    Redaction covers display and JSON, not reflection: `dump`, `getfield` and `err.cause` still
    reach the raw exception, and serializers other than JSON (ProtoBuf, template engines) see the
    underlying struct. This guards against *accidental* disclosure only.
"""
struct ValidationError <: Exception
    msg::String
    cause::Union{Nothing, Exception}
    ValidationError(msg::String) = new(msg, nothing)
    ValidationError(msg::String, cause::Exception) = new(msg, cause)
end

# The 2-arg form is what Base's exception display, `sprint(showerror, e)` and -- under a
# `ConsoleLogger` -- `@error … exception=e` all reach, so it is the form that has to be value-free.
# `.cause` is the wrapped underlying exception, and those quote their input: a JSON parse
# `ArgumentError` echoes the offending bytes verbatim, so rendering it here put a submitted password
# into every app that displayed the error (#130). Rendering is now per-call opt-in. There is
# deliberately no global switch and no environment variable -- Django's `DEBUG` and Express's
# `NODE_ENV` are the cautionary precedent: a process-wide flag is the thing that is on in production
# once. `current_env()` (#55) does not change this: it REPORTS the environment, for configuration
# and the startup banner, and deliberately does not gate anything here.
function Base.showerror(io::IO, e::ValidationError; cause::Bool = false)
    print(io, "Validation Error: $(e.msg)")
    # Bind the field to a local: the kwarg and the field deliberately share the name `cause`, which
    # reads well at the call site but is a typo hazard inside the body.
    c = e.cause
    if cause && !isnothing(c)
        print(io, "\nCaused by: ")
        # Propagate the opt-in down the chain -- a silently truncated chain is worse than none.
        # Nothing in `src/` nests a `ValidationError` today (every wrap site rethrows one
        # unwrapped), but an application can, and the renderer must not quietly stop.
        c isa ValidationError ? showerror(io, c; cause = true) : showerror(io, c)
    end
    return nothing
end

# The cause's TYPE is what every masked path renders in place of the cause itself -- the one
# genuinely useful bit that survives, since `ArgumentError` vs `EOFError` vs `BoundsError` already
# narrows a 400 considerably.
#
# `string(typeof(...))` rather than `nameof(...)`: it keeps type parameters and, when the type is
# not reachable from `Main`, the module qualifier, so an app's own `MyPkg.Error` is usually
# distinguishable from someone else's `Error`. "Usually" is the honest word -- `string` renders in
# `Main`'s context, so `using MyPkg: Error` collapses it back to the bare name. Every cause Nitro
# itself attaches is a Base/Core type, so Nitro's own output is stable either way.
#
# A type's NAME cannot carry submitted bytes. Its PARAMETERS could in principle -- Julia admits
# `Symbol` and isbits values as type parameters, so a hypothetical `SymErr{:hunter2}` would render
# that symbol. Nothing Nitro wraps is value-parameterized (`ArgumentError`, `EOFError`,
# `BoundsError`, `MethodError`, `UndefKeywordError`, JSON.jl's errors), and reaching it would take
# an exception type parameterized on a `Symbol` built from client input. Worth knowing before
# someone introduces one.
_cause_typename(e::ValidationError) = isnothing(e.cause) ? nothing : string(typeof(e.cause))

# `showerror` is not the only way this value renders. A logger that treats `exception=` as an
# ordinary value -- `SimpleLogger`, for one -- reaches `show` instead, and the default struct `show`
# prints every field, so `ValidationError("...", ArgumentError("<payload>"))` leaked the whole cause
# even after `showerror` stopped. Mask it the same way `SecretString` masks its own (src/crypto.jl,
# #25): keep the constructor-call shape, name the cause's type, elide what it carries.
function Base.show(io::IO, e::ValidationError)
    print(io, "ValidationError(", repr(e.msg))
    t = _cause_typename(e)
    isnothing(t) || print(io, ", ", t, "(…)")
    print(io, ")")
    return nothing
end
Base.show(io::IO, ::MIME"text/plain", e::ValidationError) = show(io, e)

# Serialization mask, parallel to the `show` mask above -- the same pairing `SecretString` uses
# (src/crypto.jl, #25), and for the same reason: `show` and JSON are INDEPENDENT output paths, and
# masking only the first left the worse one open. JSON.jl reflects struct fields, so
# `Res.json(err)`, `format_response(::Any)` for a raw struct return, and any structured log sink
# that JSON-encodes a containing struct all shipped `{"cause":{"msg":"<the submitted password>"}}`
# -- to the CLIENT, in a response body, which is a strictly worse leak than the log one #130 was
# filed for. JSON.jl routes every value through `StructUtils.lower` before writing, so this single
# method covers the value bare, as a struct field, and nested in a Dict/Vector/Tuple.
#
# `msg` stays serialized on purpose: a mask that swallowed the whole struct would satisfy every
# "does not contain the secret" assertion while breaking the app-level error envelope this exists
# to serve.
JSON.lower(e::ValidationError) =
    isnothing(e.cause) ? (; msg = e.msg) : (; msg = e.msg, cause = _cause_typename(e))

"""
    cause_report(e::ValidationError) -> String

Render `e` **together with its `.cause` chain**, for interactive diagnosis only.

!!! danger "The returned string can contain the submitted payload"
    `.cause` is the underlying exception Nitro wrapped, and those exceptions quote their input: a
    JSON parse `ArgumentError` echoes the offending bytes, so a rejected `Json{Login}` body puts the
    submitted password in this string. That is exactly why `showerror(io, ::ValidationError)` -- the
    2-arg form Base, `sprint(showerror, e)` and `@error … exception=e` all reach -- renders no cause,
    and why `show` and `JSON.lower` mask it (#130).

    Print it at a REPL while debugging. **Never** log it, never put it in a response body, never
    paste it into an issue. Nitro itself never calls this function, so a single
    `rg -n cause_report` over an application is the whole audit.

Unexported on purpose -- reach it as `Nitro.Errors.cause_report(err)`. Adding it to this module's
`export` list would push a "never log this" function into every application's top-level namespace,
because `src/core.jl` re-exports `Errors` wholesale.
"""
cause_report(e::ValidationError) = sprint(io -> showerror(io, e; cause = true))

struct CookieError <: Exception
    msg::String
end

function Base.showerror(io::IO, e::CookieError)
    print(io, "Cookie Error: $(e.msg)")
end

struct AuthorizationError <: Exception
    msg::String
end

function Base.showerror(io::IO, e::AuthorizationError)
    print(io, "Authorization Error: $(e.msg)")
end

end