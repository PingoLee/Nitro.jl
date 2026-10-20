"""
    CatalogApp

A reusable Nitro app package: a small product catalog that a host application mounts wherever
it likes. It follows the checklist in the *Extension Points* tutorial:

- [`routes`](@ref) **returns** route definitions and registers nothing; the host owns the prefix
  and the moment of registration.
- Route names are namespaced, and the namespace is a keyword, so one host can mount the package
  twice.
- [`RequireApiKey`](@ref) is a keyword-only middleware factory.
- State and configuration arrive as arguments: the host builds the [`Catalog`](@ref) and the
  key. The package keeps no global.
- Handlers are not exported.
"""
module CatalogApp

using HTTP
using Nitro

export Catalog, Product, RequireApiKey, routes

"""
    Product

One catalog entry, as the JSON endpoints return it.
"""
struct Product
    id::Int
    name::String
    price_cents::Int
end

# The body `POST` binds through `Json{NewProduct}`. A body without `name` is a 400 before the
# handler runs; `price_cents` defaults to 0.
@kwdef struct NewProduct
    name::String
    price_cents::Int = 0
end

"""
    Catalog()

The package's state, an in-memory product table. The host creates one and passes it to
[`routes`](@ref), so two mounts can hold two catalogs. Requests run on many threads at once,
which is why every access takes the lock.
"""
struct Catalog
    lock::ReentrantLock
    products::Dict{Int,Product}
    next_id::Base.RefValue{Int}
end
Catalog() = Catalog(ReentrantLock(), Dict{Int,Product}(), Ref(1))

function add!(catalog::Catalog, name::String, price_cents::Int)::Product
    return lock(catalog.lock) do
        product = Product(catalog.next_id[], name, price_cents)
        catalog.products[product.id] = product
        catalog.next_id[] += 1
        product
    end
end

lookup(catalog::Catalog, id::Int) = lock(() -> get(catalog.products, id, nothing), catalog.lock)

listing(catalog::Catalog) =
    lock(() -> sort!(collect(values(catalog.products)); by = p -> p.id), catalog.lock)

# Handlers stay internal: the host only ever needs `routes` and the middleware. Each one closes
# over the catalog it was built for instead of reading a global.
list_products(catalog::Catalog) = (req::HTTP.Request) -> Res.json(listing(catalog))

function get_product(catalog::Catalog)
    return function (req::HTTP.Request, id::Int)
        product = lookup(catalog, id)
        product === nothing && return Res.json(Dict("error" => "not found"); status = 404)
        return Res.json(product)
    end
end

function create_product(catalog::Catalog)
    return function (req::HTTP.Request, body::Json{NewProduct})
        new = body.payload
        return Res.json(add!(catalog, new.name, new.price_cents); status = 201)
    end
end

"""
    routes(catalog::Catalog; prefix = "/products", namespace = "catalog",
           write_middleware = nothing) -> Vector{RouteDefinition}

The routes this package contributes, all under `prefix`:

| Method | Path | Name |
|--------|------|------|
| `GET`  | `prefix` | `"<namespace>.list"` |
| `GET`  | `prefix/<int:id>` | `"<namespace>.detail"` |
| `POST` | `prefix` | `"<namespace>.create"`, behind `write_middleware` |

Returns a value and registers nothing: pass it to `urlpatterns(app, …)`, alone or `vcat`-ed
with other packages' routes. Route names share one table per app, so give each mount of the
package its own `namespace`.
"""
function routes(catalog::Catalog; prefix::String = "/products", namespace::String = "catalog",
                write_middleware::Union{Nothing,Vector} = nothing)
    return include_routes(prefix, [
        path("", list_products(catalog); method = "GET", name = "$namespace.list"),
        path("/<int:id>", get_product(catalog); method = "GET", name = "$namespace.detail"),
        path("", create_product(catalog); method = "POST", name = "$namespace.create",
             middleware = write_middleware),
    ])
end

"""
    RequireApiKey(; key::SecretString, header = "X-Api-Key")

Middleware that answers `401` unless the request's `header` carries `key`. It is a
keyword-only factory: list it **called**, as in `write_middleware = [RequireApiKey(key = k)]`.
Comparing a `SecretString` with `==` is constant-time, so the check does not leak the key
through response timing. An empty `key` is refused: a missing header reads as `""`, so it would
let every request through.
"""
function RequireApiKey(; key::SecretString, header::String = "X-Api-Key")
    isempty(reveal(key)) && throw(ArgumentError("RequireApiKey: `key` must not be empty"))
    return function (handler)
        return function (req::HTTP.Request)
            key == HTTP.header(req, header, "") ||
                return Res.json(Dict("error" => "unauthorized"); status = 401)
            return handler(req)
        end
    end
end

end # module
