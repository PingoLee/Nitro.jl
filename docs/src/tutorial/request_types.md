# Request Types

Every HTTP request has a **method** that communicates the *intent* of the operation.
When designing an API, choosing the right method makes your endpoints
predictable and consistent with production standards.

## HTTP Methods in Practice

For Nitro.jl-style applications, two methods cover virtually all real-world needs:

| Method | Purpose | When to use |
|--------|---------|-------------|
| `GET`  | Fetch / query data | Reading records, dashboards, status checks |
| `POST` | Submit data / trigger an action | Creating records, imports, syncs, complex lookups |

> `PUT`, `PATCH`, and `DELETE` are supported, but action-oriented backends (like BI data pipelines)
> naturally favor `POST` for any operation that involves a payload or a side-effect.

## Anatomy of a URL

```
http://localhost:8080/api/worker/status/abc-123?verbose=true
│        │      │    │                  │        │
scheme  host  port  path           path param  query param
```

## GET — Reading Data

Use `GET` when the handler only reads and returns data. Parameters come from the
path or query string — never from the body.

```julia
# src/Handlers/ProductHandlers.jl
module ProductHandlers

using HTTP
using Nitro
using PormG
import ..appM  # your app's model module

export list_by_category

function list_by_category(req::HTTP.Request, category::String)
    # PormG pipe idiom — Model.objects returns a chainable query builder
    query = appM.Product.objects.filter("category" => category)
    return Res.json(list(query))
end

end # module
```

```julia
# src/Routes.jl
path("/api/products/<str:category>", ProductHandlers.list_by_category, method="GET", middleware=auth_guard),
```

## POST — Submitting Data or Complex Lookups

Use `POST` when the handler receives a body payload or performs a write/side-effect. It is ALSO
preferred for lookups when the input is too large for a URL (e.g. a batch of IDs).

```julia
# src/Handlers/ProductHandlers.jl
function find_by_skus(req::HTTP.Request)
    payload = req.json
    skus = get(payload, "skus", String[])

    # PormG's __@in operator for batch lookup
    query = appM.Product.objects.filter("sku__@in" => skus)

    return Res.json(list(query))
end
```

```julia
# src/Routes.jl
path("/api/products/batch", ProductHandlers.find_by_skus, method="POST", middleware=auth_guard),
```

## Deciding Which Method to Use

Ask yourself two questions:

1. **Does the handler change state or trigger a side-effect?** → `POST`
2. **Does the client need to send a body with structured data?** → `POST`

Everything else is `GET`.

```
GET  /api/products/<str:category>  → filter by category
GET  /api/worker/status/:id        → read task status
POST /api/products/batch           → batch lookup by SKU list
POST /api/import/data              → upload files, queue a job
POST /api/sync/units               → trigger a sync with a payload
```

> The batch lookup pattern (`POST` for reads) is common when the input list is too
> large or sensitive to place in a URL.
