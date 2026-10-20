"""
    HostApp

A host application that mounts the reusable [`CatalogApp`](@ref) package. The host decides
everything the package left open: the prefix it lives under, the catalog it serves, and the
key that guards writes.
"""
module HostApp

using HTTP
using Nitro
using CatalogApp

# The module body holds only `using`s, definitions and the App const. Nothing here reads the
# environment, registers a route or starts a server: a module body runs at precompile time and
# never again.
const app = App(mod = @__MODULE__)

health(req::HTTP.Request) = Res.json(Dict("status" => "ok"))

"""
    urls(; api_key::SecretString, catalog = Catalog()) -> Vector{RouteDefinition}

The host's whole URL table: its own `/health`, plus the catalog package under `/api/products`
with its writes behind `api_key`. A function rather than a constant, so a test can mount the
same table on an `App` of its own.
"""
function urls(; api_key::SecretString, catalog::Catalog = Catalog())
    return vcat(
        [path("/health", health; method = "GET", name = "health")],
        include_routes("/api", routes(catalog; prefix = "/products",
                                      write_middleware = [RequireApiKey(key = api_key)])),
    )
end

"""
    main(; kwargs...)

Register the routes and serve. Reads `PORT` (default 8000) and `CATALOG_API_KEY`; keyword
arguments go to `serve` (tests pass `async = true`).
"""
function main(; kwargs...)
    urlpatterns(app, "", urls(api_key = SecretString(ENV["CATALOG_API_KEY"])))
    serve(app; port = parse(Int, get(ENV, "PORT", "8000")), kwargs...)
end

end # module
