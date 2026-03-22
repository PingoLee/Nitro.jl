---
applyTo: "**/*.md"
description: "Nitro.jl documentation conventions — tutorial style, routing examples, generic models, PormG idioms"
---

# Nitro.jl Documentation Conventions

When writing or editing documentation (tutorials, guides, API references) for **Nitro.jl**,
follow these rules so every example is consistent and immediately usable.

## 1. Routing: Django-Style Always

- **Never** use `@get`, `@post`, `router()`, or any other macro/HOF routing API in examples.
  Those APIs are deleted. Using them in docs will mislead readers.
- **Always** use `path()` + `urlpatterns` for route declarations.
- **Always** use Django path converters (`<int:id>`, `<str:slug>`, `<float:n>`, `<uuid:key>`).

```julia
# ✅ correct
path("/api/products/<int:id>", ProductHandlers.get_product, method="GET")

# ❌ wrong — deleted API
@get "/api/products/{id}" function(req, id::Int) ... end
```

## 2. Project Structure: Handlers / Routes Separation

Every multi-file example must use the Django-style separation:

```
src/
├── main.jl            # entry-point: loads routes, calls serve()
├── Routes.jl          # all path() declarations
└── Handlers/
    └── DomainHandlers.jl
```

- Handler logic belongs in `src/Handlers/<Domain>Handlers.jl` modules.
- Route declarations belong exclusively in `src/Routes.jl` (or sub-files under `src/Routes/`).
- `include_routes(prefix, routes)` is used to compose and prefix route groups.

## 3. Generic Examples — No Domain-Specific Models

Tutorial examples must use **generic, universally understandable** models and fields.
Do not reference domain-specific databases, identifiers, or terminology
(e.g. CPF/CNS numbers, BPA records, IBGE codes, patient records, or any model tied to a
specific production project).

| Use this | Not this |
|---|---|
| `appM.Product` | `biM.Bas_populacao` |
| `ProductHandlers` | `PatientHandlers` |
| `ProductFilters` | `PatientFilters` |
| `name`, `category`, `store_id`, `sku` | `no_paciente`, `nu_cpf`, `ibge_id` |
| `/api/products/...` | `/api/bpa/...`, `/api/city/.../patients` |

Good generic domains: Products, Orders, Users, Drivers, Stores, Items.

## 4. PormG Model Setup

When showing how to wire PormG into an app, use the `@import_models` + alias pattern from `BI.jl`:

```julia
# src/App.jl
PormG.Configuration.load_many(["db"])
PormG.@import_models "../db/automatic_models.jl" automatic_models
const appM = automatic_models   # handlers import this alias
```

- The `db/` directory lives **outside** `src/` alongside the project root.
- `@import_models` creates a plain Julia module; the `const appM = ...` alias is what handlers use.
- Handlers include `import ..appM` and query with `appM.Product |> object`.
- Never import `PormG` in `src/` of the Nitro core itself — only in application code and `ext/NitroPormGExt/`.

## 5. PormG Query Idiom

When showing ORM queries with PormG, use the **pipe + chained filter** idiom.
Never use `.objects.` (it does not exist) or the one-liner `(Model |> object).filter(...)`.

```julia
# ✅ correct — two-line idiom
query = appM.Product |> object
query.filter("category" => category)

# ✅ also correct — conditional chaining
query = appM.Product |> object
!isempty(f.name) && query.filter("name__@icontains" => f.name)
!isnothing(f.category) && query.filter("category" => f.category)

# ❌ wrong — .objects. doesn't exist
appM.Product.objects.filter("category" => category)

# ❌ wrong — one-liner makes chaining unreadable
(appM.Product |> object).filter("category" => category)
```

Common PormG operators to demonstrate: `__@icontains`, `__@in`, `.page(n, limit)`, `list(query)`.

## 5. Response Construction

Always use `Res` module functions. Never return raw dicts or strings from handlers.

```julia
# ✅ correct
return Res.json(list(query))
return Res.status(201, product)
return Res.status(400, "invalid payload")

# ❌ wrong
return Dict("data" => rows)
return "ok"
```

## 6. Handler Signatures

Always type the `req` parameter as `HTTP.Request` and path parameters with their concrete type.

```julia
# ✅ correct
function get_product(req::HTTP.Request, id::Int)

# ❌ avoid — untyped parameters hurt readability and type stability
function get_product(req, id)
```

## 7. `serve()` and Entry-Point

- Use `serve(urlpatterns)` — no positional port argument unless specifically demonstrating port configuration.
- Never use `serveparallel()` — it is deleted.

```julia
# src/main.jl
include("Handlers/ProductHandlers.jl")
include("Routes.jl")
serve(urlpatterns)
```
