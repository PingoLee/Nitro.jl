---
description: Nitro.jl documentation conventions — tutorial style, routing examples, generic models, PormG idioms
applyTo: "docs/**/*.md"
---

# Nitro.jl Documentation Conventions

When writing or editing documentation (tutorials, guides, API references) for **Nitro.jl**,
follow these rules so every example is consistent and immediately usable.

## 1. Routing: Django-Style Always

- **Never** use `@get`, `@post`, `router()`, or any other macro/HOF routing API in examples.
  Those APIs are deleted. Using them in docs will mislead readers.
- **Always** use `path()` + `urlpatterns` for route declarations.
- **Always** use Django path converters. The registry defines exactly five — `<int:id>`, `<str:slug>`, `<float:n>`, `<bool:flag>`, `<uuid:key>`. Do not invent others in examples; an unknown converter throws at `path()` time.

```julia
path("/api/products/<int:id>", ProductHandlers.get_product, method="GET")
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
Do not reference domain-specific databases, identifiers, or terminology tied to a specific production project.

| Use this | Not this |
|---|---|
| `appM.Product` | production-specific model names |
| `ProductHandlers` | domain-specific handler module names |
| `name`, `category`, `store_id`, `sku` | project-specific field names |

Good generic domains: Products, Orders, Users, Drivers, Stores, Items.

## 4. PormG Model Setup

When showing how to wire PormG into an app, use the `@import_models` + alias pattern:

```julia
# src/App.jl
PormG.Configuration.load_many(["db"])
PormG.@import_models "../db/automatic_models.jl" automatic_models
const appM = automatic_models   # handlers import this alias
```

- The `db/` directory lives **outside** `src/` alongside the project root.
- `@import_models` creates a plain Julia module; the `const appM = ...` alias is what handlers use.
- Handlers include `import ..appM` and query with `appM.Product |> object`.
- Never import `PormG` in `src/` of the Nitro **core** itself — only in application code and `ext/NitroPormGExt.jl`.

## 5. PormG Query Idiom

When showing ORM queries with PormG, use the **dot-chained** idiom via `.objects.`:

```julia
M.Product.objects.filter("category" => category).list()
```

Terminal methods: `.list()`, `.first()`, `.count()`, `.exists()`, `.delete()`.

## 6. Response Construction

Always use `Res` module functions in examples, so status and content type are explicit and readers learn the intended form. (Raw dict/string returns are safe and auto-formatted per nitro-core §4 — this is a teaching convention, not a safety rule.)

## 7. Handler Signatures

Always type the `req` parameter as `HTTP.Request` and path parameters with their concrete type.

## 8. `serve()` and Entry-Point

- **`serve()` is keyword-only.** It takes no positional argument — not a port, and *not* the routes.
  Route registration is a separate, earlier step:

```julia
urlpatterns("", routes)   # register (prefix first; "" is root)
serve()                   # then start — add host=/port=/middleware=/context= as needed
```

- Never write `serve(urlpatterns)` or `serve(routes)`; there is no such method and the example will
  not run.
