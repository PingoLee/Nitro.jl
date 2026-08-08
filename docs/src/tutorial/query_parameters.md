# Query Parameters

Query parameters are everything after the `?` in a URL. They are often used for
filtering, pagination, and sorting in data-heavy applications.

Nitro.jl offers two ways to work with them.

## Low-level: `queryparams(req)`

The `queryparams` function returns a `Dict{String, String}`. Useful when parameters are
truly dynamic or when you need to inspect the raw strings first.

```julia
# src/Handlers/ProductHandlers.jl
function list_products(req)
    params = queryparams(req)

    limit = parse(Int, get(params, "limit", "20"))
    name  = get(params, "name", nothing)

    # PormG pipe idiom — chain filters conditionally
    query = appM.Product.objects
    !isnothing(name) && query.filter("name__@icontains" => name)

    return Res.json(list(query.page(1, limit)))
end
```

---

## Typed Scalar Parameters

Any handler argument that is neither a path parameter nor an extractor is bound from the query
string, converted to its declared type:

```julia
# GET /products?q=chair&limit=50
function search_products(req, q::String, limit::Int)
    return Res.json(Dict("q" => q, "limit" => limit))
end
```

### Missing And Invalid Values

- **With a default** — an absent parameter falls back to the default. `limit::Int = 20` binds `20`
  for `GET /products`.
- **Without a default** — an absent parameter is a **`400 Bad Request`**. `GET /products?q=chair`
  against the handler above is rejected, because `limit` was declared required.
- **Present but unparseable** — always a **`400`**, default or not. `?limit=abc` cannot become an
  `Int`.

```
GET /products?q=chair&limit=50   ->  200
GET /products?q=chair            ->  400   (limit is required)
GET /products?q=chair&limit=abc  ->  400   (limit is not an Int)
```

Rejections are logged at `@debug` level with no stack trace — they are client input, not server
faults. If you want the parameter to be genuinely optional, give it a default; declaring it
`Nullable{Int}` alone does not make an unparseable value acceptable (see
[Path Parameters](path_parameters.md)).

---

## Recommended: The `Query{T}` Extractor

For structured handlers, declare a `@kwdef` struct and use `Query{T}`. Nitro automatically
parsed the query string into typed fields. Combined with `PormG`'s pipe idiom, this
creates clean, readable handlers.

```julia
@kwdef struct ProductFilters
    name     :: String = ""  # optional
    category :: String = ""  # optional
    limit    :: Int    = 20  # optional
    skip     :: Int    = 0   # optional
end

# src/Handlers/ProductHandlers.jl
function list_products(req, filters::Query{ProductFilters})
    f = filters.payload

    # PormG: chain filters from struct fields
    query = appM.Product.objects
    !isempty(f.name)     && query.filter("name__@icontains" => f.name)
    !isempty(f.category) && query.filter("category" => f.category)

    return Res.json(list(query.page(f.skip + 1, f.limit)))
end
```

## Validation

You can use the extractor's second argument to enforce business rules before the handler runs.

```julia
# Limit results to 200 max to avoid expensive queries
function list_products(req, f = Query(ProductFilters, q -> q.limit <= 200))
    # ... handler logic
end
```

## Combining Path and Query Parameters

Real-world endpoints often use path parameters for the "resource" and query parameters
for the "view" of it.

```julia
# Route: /api/store/<int:store_id>/products?name=chair&limit=50
function store_products(req, store_id::Int, filters::Query{ProductFilters})
    f = filters.payload

    query = appM.Product.objects.filter("store_id" => store_id)
    !isempty(f.name) && query.filter("name__@icontains" => f.name)

    return Res.json(list(query.page(1, f.limit)))
end
```

## API Reference

```@docs
queryparams
Query
```