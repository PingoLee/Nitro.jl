# Reusable app package

Two projects that show how a feature ships as its **own package** and a host application mounts
it. This is the contract described in the
[Extension Points](https://pingolee.github.io/Nitro.jl/dev/tutorial/extension_points/) tutorial,
built out and tested.

| Project | Role |
|---------|------|
| [`CatalogApp/`](CatalogApp/) | The reusable package: a small product catalog with list, detail and create endpoints, and an API-key middleware |
| [`HostApp/`](HostApp/) | An application that mounts `CatalogApp` under `/api/products`, next to a route of its own |

## What the package does, and what it leaves to the host

| `CatalogApp` | The host |
|--------------|----------|
| `routes(catalog; prefix, namespace, write_middleware)` **returns** a `Vector{RouteDefinition}` built with `include_routes`. It never calls `urlpatterns` | Picks the outer prefix and calls `urlpatterns(app, …)` once, at boot |
| Namespaces its route names (`"catalog.detail"`), with the namespace as a keyword | Reverses them with `url(app, "catalog.detail"; id = 1)`, and passes a different `namespace` to mount the package twice |
| Takes its state (`Catalog()`) and its secret (`SecretString`) as arguments | Owns both, and reads the key from the environment in `main()` |
| Ships `RequireApiKey(; key, header)` as a keyword-only middleware factory | Decides which routes it guards (here only the write, through `write_middleware`) |
| Keeps its handlers unexported | Never imports a handler |

`HostApp` uses an explicit `App` (`const app = App(mod = @__MODULE__)`) rather than the
argument-less convenience layer, and its module body only defines things. Routes are
registered and the server starts in `main()`, because a module body runs at precompile time
and never again.

## Run it

From this directory, with Julia 1.12 or newer:

```bash
julia --project=CatalogApp -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia --project=HostApp    -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

CATALOG_API_KEY=change-me julia --project=HostApp -e 'using HostApp; HostApp.main()'
```

Then, in another shell:

```bash
curl -X POST localhost:8000/api/products -H 'Content-Type: application/json' \
     -H 'X-Api-Key: change-me' -d '{"name": "lamp", "price_cents": 1500}'
curl localhost:8000/api/products/1
```

The tests use `internalrequest(app, …)` on a fresh `App`, so they bind no port and never touch
the `HostApp.app` that `main()` serves.

## Copying it out of this repository

Both `Project.toml` files point `[sources]` at this checkout (`Nitro = {path = "../../.."}`), so
the example always runs against the code next to it. Nitro's own test suite instantiates and
tests both projects (`test/examples_tests.jl`), which is what keeps this example from going
stale.

In a project of your own, install Nitro from its repository instead, pinned to a commit:

```toml
[sources]
Nitro = {url = "https://github.com/PingoLee/Nitro.jl", rev = "<40-character commit SHA>"}
```

and point the host's `CatalogApp` entry at wherever the package lives: a `path`, or its own
`url` and `rev`.
