# Request Body

A request body is data sent by the client to your API — usually JSON or a form.
Used when inputs are too complex or large for a URL.

Nitro.jl offers two layers of body access:
1. **Low-level** — `req.json` / `req.form` on `HTTP.Request` (simple, flexible)
2. **Extractors** — `Json{T}`, `Form{T}`, `JsonFragment{T}` (typed, validated, recommended)

---

## Low-level: `req.json` and `req.form`

Nitro extends `HTTP.Request` with body accessors. This is the simplest approach
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
    payload = req.json  # Dict{String, Any} or nothing
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
constructs the struct with the JSON payload. This is ideal when combined with `PormG` filters.

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

## API Reference

```@docs
Json
Form
JsonFragment
```
