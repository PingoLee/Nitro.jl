---
description: Nitro.jl documentation conventions — tutorial style, routing examples, generic models, PormG idioms
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
main.jl                # the program: `(@main)` calls MyApp.main() (see bigger_applications.md)
src/
├── MyApp.jl           # the module: `const app = App(mod = @__MODULE__)`, main() registers and serves
├── Routes.jl          # all path() declarations
└── Handlers/
    └── DomainHandlers.jl
```

This is the layout `Nitro.newapp` writes; show it, not a variant.

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

When showing how to wire PormG into an app, `include` the models in the module body and load and
bind them in `main()`, as `Nitro.newapp` writes it:

```julia
# src/MyApp.jl — module body: defines code, connects nothing
include("../db/models.jl")   # defines the `models` module, bound to nothing yet
const appM = models          # handlers import this alias

function main(; root::AbstractString = pkgdir(@__MODULE__), kwargs...)
    env = something(sync_pormg_env!(), current_env())
    PormG.Configuration.load_many(["db"]; root, env)        # reads db/connection.yml at runtime
    PormG.Models.set_models(models, joinpath(root, "db"))   # binds the models to it
    # … worker_startup, urlpatterns(app, …), serve(app; …)
end
```

- **Never call `load_many`/`load` in a module body.** A package's module body runs at precompile
  time and never again, so the connection would not exist at runtime, and a JuliaC image would
  carry `connection.yml`'s password. It goes in `main()` — the boot in `bigger_applications.md` is
  the generated file, pinned by a test.
- **Never show `@import_models` in a package's module body.** It registers the models as it
  includes them, PormG 0.9 refuses that before their folder is loaded, and a precompile is never a
  REPL: the package does not precompile.
- **Name the environment at the `load`** (`env = something(sync_pormg_env!(), current_env())`):
  outside a REPL PormG refuses a `load` with none.
- **`db/` is found from `main`'s `root`.** `main.jl` passes `APP_ROOT`, else the working
  directory, because a JuliaC executable's `pkgdir` names the folder it was built from.
- The `db/` directory lives **outside** `src/` alongside the project root.
- `include` creates a plain Julia module; the `const appM = ...` alias is what handlers use.
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

- **Examples use the explicit `App` form.** Build the handle once and pass it first to
  `urlpatterns`, `serve`/`terminate`, `staticfiles`/`spafiles`/`dynamicfiles`, `worker_startup`,
  `url`, `configcookies` and `set_cookie!`/`get_cookie`. `path()` and `include_routes()` build
  values and take no app. The argument-less global layer is a convenience CONTRIBUTING asks new
  code to avoid, so the docs do not teach it, and a page never mixes the two forms.
- **`serve(app; …)` takes the app as its only positional argument** — never a port, and *not* the
  routes. Everything else is a keyword. Route registration is a separate, earlier step:

```julia
const app = App(mod = @__MODULE__)
urlpatterns(app, "", routes)   # register (app first, then the prefix; "" is root)
serve(app)                     # then start — add host=/port=/middleware=/context= as needed
```

- Never write `serve(urlpatterns)` or `serve(routes)`; there is no such method and the example will
  not run.
