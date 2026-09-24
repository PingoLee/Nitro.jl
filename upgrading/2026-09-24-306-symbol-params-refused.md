## `path()` / `urlpatterns()` — a parameter that would build a `Symbol` from the request is refused when the route is declared

- **Version**: Unreleased
- **Nitro ref**: [#306](https://github.com/PingoLee/Nitro.jl/issues/306) ; `src/core/registration.jl`,
  `src/utilities/bodyparsers.jl`, `src/utilities/misc.jl`
- **Recorded**: 2026-09-24
- **Severity**: breaking — a route whose handler binds a `Symbol` from the request no longer
  registers; `urlpatterns` throws an `ArgumentError` at startup.

### What changed

Julia never frees an interned `Symbol`. A parameter declared `::Symbol` was bound with
`Symbol(str)`, so every distinct value a client sent stayed in memory until the process restarted —
an unauthenticated way to grow it without limit, one request at a time. `parseparam(::Type{Symbol})`
is gone, and route registration now refuses any parameter that would bind a `Symbol` from request
input:

- a scalar path or query parameter of type `Symbol`, or a `Union` containing it
  (`Nullable{Symbol}`);
- `Body{Symbol}` and `Cookie{Symbol}`;
- a `Path`/`Query`/`Header`/`Form`/`Json`/`JsonFragment`/`MultipartForm` struct with a `Symbol`
  anywhere a value is read into: a field, an element type (`Vector{Symbol}`), a dictionary key or
  value (`Dict{Symbol,Int}`), a tuple slot;
- a dictionary **keyed by an enum** in any of those (`Dict{Status,Int}`): JSON.jl converts
  dictionary keys with its own `lift`, which interns an enum name before looking it up.

The error names the parameter and the route. `json(req, T)` applies the same rule to its `T` and
throws an `ArgumentError` rather than parsing.

`Session{T}`, `Files{T}` and `Context{T}` are not checked (they are not bound from client strings
by Nitro), nor is a third-party extractor such as `ProtoBuffer{T}`, which decodes with its own
code. An enum *value* is fine everywhere: it binds by integer or by name without interning.

### How to find the calls to migrate

```bash
# Handler parameters and bound struct fields typed as Symbol.
rg -n '::\s*(Nullable\{)?Symbol\b|\{Symbol\}|Vector\{Symbol\}|Dict\{Symbol' <app>/src

# Dictionaries keyed by an enum inside request-bound structs.
rg -n 'Dict\{[A-Z][A-Za-z]*\s*,' <app>/src
```

The refusal itself is the reliable signal: register the app's routes (start it, or run its test
suite) and every offending parameter is named in the `ArgumentError`.

### Migrate your app

```julia
# ✗ before — every distinct ?sort=… value interned for good
path("/items", (req, sort::Symbol = :newest) -> list_items(sort))

# ✓ after — a closed set: an @enum binds by name or integer, without interning
@enum SortKey newest cheapest popular
path("/items", (req, sort::SortKey = newest) -> list_items(sort))

# ✓ or — an open String checked against an allow-list
const SORT_KEYS = Set(["name", "price", "created"])
path("/items", function (req, sort::String = "name")
    sort in SORT_KEYS || return Res.status(400)
    list_items(sort)
end)
```
