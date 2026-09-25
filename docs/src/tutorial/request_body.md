# Request Body

A request body is data sent by the client to your API — usually JSON or a form.
Used when inputs are too complex or large for a URL.

Nitro.jl offers two layers of body access:
1. **Low-level** — `getjson(req)` / `getform(req)` on `HTTP.Request` (simple, flexible)
2. **Extractors** — `Json{T}`, `Form{T}`, `JsonFragment{T}`, `Body{T}` (typed, validated, recommended)

---

## Low-level: `getjson(req)` and `getform(req)`

Nitro provides exported body accessors that take the request. This is the simplest approach
when you need to inspect the raw payload before deciding what to do.

```julia
# src/Handlers/ProductHandlers.jl
module ProductHandlers

using HTTP
using Nitro
using PormG
import ..appM  # your app's model module

export get_product

function get_product(req::HTTP.Request)
    payload = getjson(req)  # Dict{String, Any}, or nothing (no JSON Content-Type, empty, malformed)
    if !(payload isa AbstractDict)
        return Res.json(Dict("error" => "Invalid JSON payload"), status=400)
    end

    sku = get(payload, "sku", nothing)
    isnothing(sku) && return Res.json(Dict("error" => "sku is required"), status=400)

    # PormG lookup using the pipe idiom
    product = appM.Product.objects.filter("sku" => sku)

    return Res.json(first(list(product)))
end

end # module
```

---

## Recommended: The `Json{T}` Extractor

For typed handlers, declare a `@kwdef` struct and use `Json{T}`. Nitro automatically
constructs the struct with the JSON payload. A field the body leaves out takes its declared
default, so `{"name": "lamp"}` binds `category = ""` and `limit = 20`. A field with no default is
required, and a body without it is a `400`, unless its type admits `nothing`
(`Union{String, Nothing}`), in which case it binds `nothing`. This is ideal when combined with `PormG` filters.

The request must say it carries JSON: `Content-Type: application/json`, or an `application/*+json`
type. Anything else — `text/plain`, a form type, or no `Content-Type` at all — is a
`415 Unsupported Media Type`, and `getjson(req)` returns `nothing` for such a body. Those are the
types a cross-site page can send without a CORS preflight, so reading JSON from them regardless
would accept a forged request as readily as your own client's. `fetch` with a JSON body, axios and
most HTTP clients send the header already; hand-built test requests are the usual place it is
missing.

```julia
using Nitro
using PormG

@kwdef struct ProductSearch
    name     :: String           = ""
    category :: String           = ""
    limit    :: Int              = 20
end

function search_products(req, payload::Json{ProductSearch})
    q = payload.payload

    # PormG: build a query with the pipe idiom, chain filters dynamically
    query = appM.Product.objects

    !isempty(q.name)     && query.filter("name__@icontains" => q.name)
    !isempty(q.category) && query.filter("category" => q.category)

    return Res.json(list(query.page(1, q.limit)))
end
```

### Inline Validation

Attach a validator that returns a `Bool`. A `false` result automatically produces a `400 Bad Request`.

```julia
# At least one search field must be provided
function search_products(req, payload = Json(ProductSearch, q -> !isempty(q.name) || !isempty(q.category)))
    # ... handler logic
end
```

---

## The `Form{T}` Extractor

For `application/x-www-form-urlencoded` bodies, use `Form{T}` the same way:

```julia
@kwdef struct LoginForm
    username :: String
    password :: String
end

function login(req, form::Form{LoginForm})
    f = form.payload
    return authenticate(f.username, f.password)
end
```

The request must be `application/x-www-form-urlencoded`, or carry no `Content-Type` at all. A body
that declares any other type — `text/plain`, XML, JSON, multipart — is a `415`, and `getform(req)`
returns an empty `Dict` for it, so its `key=value` pieces never reach `getform` or `payload(req)`
either. The untyped case stays readable for hand-built `HTTP.Request`s and clients that send no type.

---

## The `Body{T}` Extractor

`Body{T}` binds the raw body text as one value, with no decoding: `Body{String}` is the text
verbatim, and `Body{Int}`, `Body{Float64}`, `Body{Bool}`, an `@enum` or a `Date` are parsed from it.
Any concrete type with a `Base.parse(::Type{T}, ::String)` method qualifies. The `Content-Type` is not
checked, because nothing is decoded.

A struct or container — `Body{Transfer}`, `Body{Vector{Int}}`, `Body{Dict{String,Any}}` — is refused
when the route is declared. It could only be bound by parsing the body as JSON whatever its
`Content-Type`, which would accept a cross-site `text/plain` request exactly as it accepts your own
client. Declare it `Json{T}` instead.

---

## The `JsonFragment{T}` Extractor

When your JSON body contains multiple top-level keys and you want to split them into
separate typed structs, use `JsonFragment{T}`.

```julia
# POST body: {"origin": {"lat": -1.0, "lon": -2.0}, "destination": {"lat": 3.0, "lon": 4.0}}

@kwdef struct Coords
    lat :: Float64
    lon :: Float64
end

function route_trip(req, origin::JsonFragment{Coords}, destination::JsonFragment{Coords})
    o, d = origin.payload, destination.payload
    return Res.json(Dict("from" => (o.lat, o.lon), "to" => (d.lat, d.lon)))
end
```

---

## When Binding Fails

A body Nitro cannot bind is **client input**, not a server fault: it becomes a `400 Bad Request`
with a fixed body, never a `500` and never a logged backtrace. A body of the wrong media type — JSON
for a `Json{T}` parameter sent without a JSON `Content-Type`, a non-form type sent to a `Form{T}`,
or a non-multipart request to a `MultipartForm{T}` — is a `415 Unsupported Media Type` instead, raised as an
`UnsupportedMediaTypeError` and treated the same way.

The `ValidationError` behind it names the parameter and its type and **never the submitted value**,
so it is safe to log. When a validator rejected the value, the message names that validator by
function and module (`MyApp.validate`, `MyApp.check_limit`), or as "the extractor-local validator
of parameter `x`" for an anonymous one — never by the file it is defined in, so returning `.msg` to
a client does not publish the server's directory layout. The exception that actually failed — a JSON parse error, say — is kept on
`.cause`, and that one *does* quote the payload. Every path Nitro renders it through masks it down
to the cause's *type*:

```julia
sprint(showerror, err)                             # parameter and type only — safe
repr(err)                                          # the cause's type, not its value — safe
JSON.json(err)                                     # {"msg":"…","cause":"ArgumentError"} — safe
sprint(io -> showerror(io, err; cause = true))     # ...plus the cause — a REPL, not a log
```

So `@error "rejected" exception = err` stays value-free whatever logger you use, and returning the
error from a handler — `Res.json(Dict("error" => err))` — cannot put the submitted body back on the
wire. If you reach for the opt-in while debugging, treat what comes back as the request body
itself: do not log it, do not put it in a response, do not paste it into a bug report.

!!! warning
    The masking covers display and JSON, not reflection. `err.cause`, `dump`, and serializers other
    than JSON still reach the wrapped exception.

### Nesting depth

JSON nested deeper than **512** arrays or objects is treated as malformed JSON, and rejected
before it is parsed. The parser recurses once per level, so without that bound a few kilobytes of
`[[[[…` would exhaust the stack of the task serving the request. The limit is fixed, and real
payloads sit far below it.

Every path gives a too-deep document the same answer it gives any other malformed one:

| Path | Too-deep JSON |
|---|---|
| `getjson(req)`, `json(req)` | `nothing` |
| `json(req, T)` | throws `ArgumentError` |
| `Json{T}`, `JsonFragment{T}` | `400 Bad Request` |
| a path or query parameter parsed as JSON | `400 Bad Request` |
| a JWT segment in `BearerAuth` / `CookieAuthMiddleware` | `401` |

---

## API Reference

[`Json`](@ref), [`Form`](@ref), [`JsonFragment`](@ref), [`Body`](@ref), [`validate`](@ref) and
[`ValidationError`](@ref) are documented with the other extractors in
[Requests And Extractors](@ref).
