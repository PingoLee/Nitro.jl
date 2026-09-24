## `Query{T}` / `Form{T}` / `Header{T}` / `Path{T}` / `JsonFragment{T}` — binding follows the struct's fields, and StructTypes is no longer consulted

- **Version**: Unreleased
- **Nitro ref**: [#306](https://github.com/PingoLee/Nitro.jl/issues/306) ; `src/reflection.jl`,
  `src/utilities/bodyparsers.jl`, `src/utilities/misc.jl`, `src/extractors.jl`, `Project.toml`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — a struct that customized its binding through StructTypes.jl is
  bound by its field names instead, and a custom StructUtils method written for JSON.jl's default
  style no longer applies to request JSON.

### What changed

The struct binder behind these extractors began with `Dict(Symbol(k) => v for (k, v) in params)`
over **everything the client sent**, so every key — including keys the struct does not have — was
interned as a `Symbol` before binding ran. Julia never frees an interned `Symbol`: a million unique
junk keys on a public login form grew the process by ~47 MB, permanently, with no credentials
needed. The binder now walks the struct's fields and looks each one up by name as a string, so a
key that is not a field is never touched.

| | Before | After |
|---|---|---|
| Keys read from the client map | all of them, each interned | only `T`'s field names, as strings |
| A plain (non-`@kwdef`) struct | `StructTypes.constructfrom`: honored `StructTypes.names` (renamed keys), `StructTypes.defaults` and a custom `StructType` | built positionally from its fields; an absent field binds `nothing`/`missing` if its type admits one, else 400. StructTypes is no longer a dependency of Nitro, and nothing of it is consulted |
| `Nullable{T}`, `UUID`, `Date` field of a `@kwdef` struct | 400 | binds exactly like a scalar query parameter of that type |
| Enum field | plain struct: by name, interning the string whether valid or not; `@kwdef` struct: always 400 | by integer value **or** by name, for both, never interned |
| Enum or `Symbol` field in typed JSON (`Json{T}`, `json(req, T)`, `JsonFragment{T}`) | JSON.jl's default style, which interns the string | Nitro's read style: an enum matches by name without interning; a `Symbol` field is refused |

A struct that uses StructUtils' own field tags or defaults (`@tags`, `@defaults`, `StructUtils.@kwarg`)
is unaffected: typed JSON still hands it to JSON.jl whole.

Typed request JSON is now parsed with a Nitro style rather than JSON.jl's `DefaultStyle`. A
StructUtils method your app defines for the **abstract** `StructStyle`, or the style-less
`StructUtils.lift(::Type{MyType}, x)` form, still applies. One written specifically for
`StructUtils.DefaultStyle` or `JSON.JSONStyle` no longer runs for request bodies.

### How to find the calls to migrate

```bash
# Binding customized through StructTypes -- no longer read.
rg -n 'StructTypes\.' <app>/src

# StructUtils customizations pinned to JSON.jl's default style.
rg -n 'StructUtils\.(lift|liftkey|make)\(\s*::\s*(StructUtils\.DefaultStyle|JSON\.JSONStyle)' <app>/src

# The extractors whose binding changed, to review their structs.
rg -n 'Query\{|Form\{|Header\{|Path\{|JsonFragment\{' <app>/src
```

### Migrate your app

```julia
# ✗ before — a query key renamed through StructTypes
struct Search
    q::String
end
StructTypes.names(::Type{Search}) = ((:q, :query),)   # ?query=lamp bound `q`

# ✓ after — name the field after the key the client sends
struct Search
    query::String
end

# ✗ before — a custom conversion only JSON.jl's default style dispatched to
StructUtils.lift(::StructUtils.DefaultStyle, ::Type{Money}, x::AbstractString) = (parse_money(x), nothing)

# ✓ after — the style-less form, which every style reaches
StructUtils.lift(::Type{Money}, x::AbstractString) = parse_money(x)
```
