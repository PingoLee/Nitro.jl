module Errors
## In this module, we export commonly used exceptions across the package

import JSON

export ValidationError, CookieError, AuthorizationError, StoreInterfaceError, UnsupportedMediaTypeError

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

"""
    UnsupportedMediaTypeError(msg::String)

The exception Nitro raises when a request's body has the wrong `Content-Type` for the extractor
that binds it (#327): a `Json{T}`/`JsonFragment{T}` parameter needs `application/json` or an
`application/*+json` type, a `MultipartForm{T}` needs `multipart/form-data`, and a `Form{T}` needs
`application/x-www-form-urlencoded` (#345). A missing `Content-Type` is the wrong type too, except
for `Form{T}`, which still reads an untyped body as a form. `handle_error` answers it with a fixed
`415 Unsupported Media Type`, and it is logged at `@debug` only, like a `ValidationError`.

Why a JSON body sent as `text/plain` is refused rather than parsed: `text/plain`,
`application/x-www-form-urlencoded` and `multipart/form-data` are the CORS "simple" types, so a
cross-site page can send any of them — or no type at all — without a preflight. An API that
reads JSON regardless of the type accepts a forged cross-site request exactly as it accepts its
own client's. Express's `json()` and Spring's `@RequestBody` refuse it the same way.

`msg` names the parameter and the type it needs, never the `Content-Type` the client sent.
"""
struct UnsupportedMediaTypeError <: Exception
    msg::String
end

function Base.showerror(io::IO, e::UnsupportedMediaTypeError)
    print(io, "Unsupported Media Type: $(e.msg)")
end


"""
    StoreInterfaceError(f::Function, store_type::Type)

The exception a pluggable store backend raises when it is handed a call it never implemented.

Nitro has two store contracts — `AbstractWorkerStore` for the worker queue and
`AbstractSessionStore` for sessions — and both are open for third-party backends. Each
required method carries a fallback defined on the *abstract* type; reaching that fallback means the
concrete store did not define the method, so this is thrown instead of letting the call fail far
downstream with a bare `MethodError` that names neither the contract nor the missing piece.

The message names the method, the offending store type, and where the contract is documented.

# Not a substitute for `MethodError`

The fallbacks are typed at the contract's *documented* argument types, never `args...`. A call whose
positional arguments do not match the contract at all therefore still raises an ordinary
`MethodError` — a caller-side mistake keeps reporting as one, rather than being mislabelled as a
missing backend method.
"""
struct StoreInterfaceError <: Exception
    f::Function
    store_type::Type
end

"""
    implements_contract_method(f, S::Type, abstract_store_type::Type, store_index::Int) -> Bool

Whether `S` itself contributed a method of `f` — that is, a method whose store-position parameter
is something narrower than `abstract_store_type` and that `S` satisfies.

This is what both store contracts use to answer "did this backend implement the method", and it
deliberately asks about *presence*, not about signature compatibility. Checking the exact call
signature instead sounds stricter and is worse: a contract method is written
`(::MyStore{K,V}, ::K, ::V)` as often as `(::MyStore, ::String, ::Any)`, and a probe pinned to
either shape reports the other as missing.

`store_index` is 1-based over the *arguments*, so it is 2 for a callback-first method such as
`lock_tasks(callback, store)`.

It errs toward **over**-reporting, never under-reporting, which is the safe direction for a
conformance check: a method typed on a union that reaches outside the contract's hierarchy —
`f(::Union{MyStore, Nothing}, …)` — satisfies dispatch but is not counted here, so such a backend
sees a spurious name in `missing_store_methods`. Narrowing the search to the contract's own
hierarchy is what makes the opposite mistake impossible, and a false "you are conforming" is the
one that turns the check into theater.
"""
function implements_contract_method(f::Function, S::Type, abstract_store_type::Type, store_index::Int)
    for m in methods(f)
        params = Base.unwrap_unionall(m.sig).parameters
        length(params) >= store_index + 1 || continue
        # Re-apply the method's `where` clause before testing. A method written
        # `(::MemoryStore{K,V}, ::K, ::V) where {K,V}` has FREE type variables in its unwrapped
        # store parameter, and `MemoryStore{String,Dict} <: MemoryStore{K,V}` is not true of a
        # free `K`/`V` -- so an unwrapped test reports every parametric backend as missing.
        P = Base.rewrap_unionall(params[store_index + 1], m.sig)
        P isa Type || continue
        P === abstract_store_type && continue
        # `P` must sit INSIDE the contract's own hierarchy. Without this, any method of `f` that
        # happens to accept `S` counts -- which is harmless for the functions Nitro owns, but
        # `Base.get` is part of the session contract and belongs to Base. One unrelated package
        # defining a `Base.get` broad enough to accept a store would make every store report as
        # conforming: a false NEGATIVE, which is the failure mode that turns a conformance check
        # into theater.
        P <: abstract_store_type || continue
        S <: P && return true
    end
    return false
end

"""
    store_contract_error(f, abstract_store_type, store_index, args...)

Decide, at the moment a contract fallback is reached, whether this is a missing backend method or
a caller-side mistake — and raise the honest one.

A fallback is defined on the abstract store type with every other parameter left at `Any`. That
width is required: a fallback pinned to the contract's exact argument types is *ambiguous* with a
backend that types one of its own parameters more loosely (`::AbstractString` where the contract
says `::String` — which is how Nitro's own public API is written), and Julia may then resolve the
call to the fallback instead of to the store's method. Ambiguity is a far worse failure than an
imprecise error message.

The cost of that width is that the fallback also catches a caller who passed the wrong positional
type to a perfectly conforming store. Hence this check: if the store's type contributed a method
of its own, the arguments are what did not match, so an ordinary `MethodError` carrying the real
arguments is raised. Only a store that implemented nothing gets `StoreInterfaceError`.
"""
@noinline function store_contract_error(f::Function, abstract_store_type::Type, store_index::Int, args...)
    store = args[store_index]
    if implements_contract_method(f, typeof(store), abstract_store_type, store_index)
        throw(MethodError(f, args))
    end
    throw(StoreInterfaceError(f, typeof(store)))
end

function Base.showerror(io::IO, e::StoreInterfaceError)
    name = nameof(e.f)
    println(io, "StoreInterfaceError: `", e.store_type, "` does not implement `", name,
                "`, which its store contract requires.")
    print(io, "Define a method `", name, "(::", e.store_type, ", ...)`. ",
              "The full contract is in the docstring of the abstract store type ",
              "(`?AbstractWorkerStore` or `?AbstractSessionStore`); ",
              "`missing_store_methods` / `missing_session_methods` list everything a type is ",
              "still missing.")
end


"""
    is_unrecoverable(e) -> Bool

True for the exceptions that are **not failures of the guarded operation** — the conditions the
runtime raises about *itself*. A `try`/`catch` on a request path exists to turn a failure into a
response; these three are not failures, so swallowing one reports a broken process as a routine
outcome and keeps serving:

- `StackOverflowError` — Julia's own report is *"program state may be corrupted, so further
  execution might be unreliable"*, and on some Windows hosts the process does not survive it
  at all (#301). `JSON.parse` raises it on a deeply-nested value: measured on a
  `Threads.@spawn` task, which is the stack every Nitro request runs on, at nesting depth
  ~3100 — ~3.1 KB of unclosed `[[[…`, which is a **4.1 KB** bearer token once base64url
  encoded, inside nginx's and Apache's default header limits. Request input no longer gets
  there: every request-data parse goes through `BodyParsers._parse_json_bounded`, which
  rejects nesting past `MAX_JSON_DEPTH` (512) as malformed JSON before the parser recurses
  (#314). Catching the overflow is not the defence; bounding the input is.
- `OutOfMemoryError` — same class, one resource over.
- `InterruptException` — a catch that eats it makes Ctrl-C a no-op. Rethrowing *it* was already
  the house rule (`src/middleware/janitor.jl` #190, `src/core/transport.jl`); #254 is where the
  other two joined it on the request path.

### Which sites use this, and which deliberately do not

The criterion is **"a request can make this block raise one of the three"**. In practice that
means the guarded expression reaches `JSON.parse`, which is the only recursive parser on
Nitro's request path. Since #314 its depth is bounded, so request input alone should no longer
overflow it — the rethrows below stay as the backstop for what the bound does not cover: a
regression in the bound, an `OutOfMemoryError`, an interrupt, and the application code several
of these sites call (a user's `validate_token`, a user's session store):

| site | guarded expression |
|---|---|
| `src/middleware/auth_middleware.jl` ×2 | the user's `validate_token` (reaches `decode_jwt` → `JSON.parse`) |
| `src/utilities/bodyparsers.jl` ×6 | `_parse_json_bounded` — plus `HTTP.queryparams`/`HTTP.parse_multipart_body`, which do NOT recurse and ride along so the parsers in one file cannot drift apart; the sixth is `json(req, T)`'s wrap into a `ValidationError` (#326) |
| `src/utilities/misc.jl` ×4 | `parseparam`'s `_parse_json_bounded(str, T)` fall-through — reached by **any** scalar path/query parameter, since `parse(Int, str)` fails first and lands there — plus `parsebody_union`'s member loop, the same shape for `Body{T}` (#345) |
| `src/extractors.jl` ×2 | `safe_extract`'s `f()` (the extractor body, i.e. the parsers above) and the app's session store |
| `src/middleware/csrf_middleware.jl` ×2 | `getform`/`getjson` |

`src/extractors.jl`'s `safe_extract` is the load-bearing one: without it the parser fix is a
no-op for `Json{T}`/`JsonFragment{T}` routes, because the rethrow would be caught one
frame later and relabelled a `ValidationError` → 400.

The sites that keep the narrower `e isa InterruptException && rethrow()` do so for **three
different reasons**, and conflating them is how this list rots:

1. **Nothing recursive is reachable.** `src/types.jl:1024,1055` (`unescapeuri`, `queryparams`),
   `src/utilities/fileutil.jl:609`, `src/core/framework_middleware.jl:43` (`HTTP.URI`), and
   `src/core/transport.jl` `_swallow_request_body!` (`readbytes!`). All scan-based; no request
   input makes them overflow, so widening them would be churn.
2. **Not a request path — a background task, where the caught failure has no request to fail.**
   `src/middleware/janitor.jl:76` and `src/Workers/api.jl:915` are supervisor loops: both call
   application-supplied store code, so by the argument below they would otherwise qualify. They
   stay narrow because the #190 janitor discipline is that one bad tick must not kill the janitor,
   and a dead sweeper is worse than a swallowed tick. `src/response.jl`'s `_run_sse_producer`
   (#160) is the same discipline one level down: the producer task nothing waits on, where the
   expected failure is the client disconnecting. Do not "fix" these to match the table above.
3. **The error boundary itself — the place the other two are MEANT to arrive.**
   `ErrorBoundary` in `src/core/framework_middleware.jl` (#256) wraps the whole middleware chain
   so that what this predicate lets through gets logged and answered with a 500. Widening it would
   send `StackOverflowError`/`OutOfMemoryError` straight back to HTTP.jl as the bodyless, unlogged
   500 it exists to replace. Only the interrupt goes past it.

`src/middleware/extract_ip.jl` uses the predicate despite belonging to group 1, for consistency
within a file this change already touched.

Those three groups plus the sites in the table are every `e isa InterruptException && rethrow()`
in `src/`; `grep -rn 'isa InterruptException && rethrow()' src/` is the audit, and a hit it
returns that no group names is a site that owes this list a line. (Sites are named by function
rather than line where the file churns; the grep is the source of truth for where they are.)

Use it as a **predicate with a lexical `rethrow()`**, never wrapped in a helper that rethrows for
you — the no-argument `rethrow()` preserves the original backtrace, which is what
`handlerequest`'s `exception=(error, catch_backtrace())` ends up logging:

```julia
catch e
    is_unrecoverable(e) && rethrow()
    nothing
end
```

### Why a deny-list, when `decode_jwt` argues for an allow-list

`src/Auth/jwt.jl` catches `ArgumentError` and rethrows the rest, and says why: *"Naming the
exceptions to rethrow means keeping that list correct forever; naming the one to catch cannot
rot."* That is right **there** and does not generalize. The expression `decode_jwt` guards is
Nitro's own code — a closed set, so an allow-list is expressible. The call sites here guard
**arbitrary application code** (a user's `validate_token`, a user's session store) or a parser
whose full error surface is a dependency's business. There is no closed set to name, so an
allow-list would turn every ordinary failure into a 500 — a far bigger break of the contract than
the one this closes. The deny-list is not the weaker choice at these sites; it is the only
representable one.

Deliberately **not exported**: this is internal vocabulary, imported explicitly per call site.
"""
@inline is_unrecoverable(e) =
    e isa InterruptException || e isa StackOverflowError || e isa OutOfMemoryError

end
