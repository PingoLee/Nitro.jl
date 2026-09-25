## `Body{T}` — a struct or container `T` is refused at registration; use `Json{T}`

- **Version**: Unreleased
- **Nitro ref**: [#345](https://github.com/PingoLee/Nitro.jl/issues/345) ; `src/core/registration.jl`,
  `src/utilities/bodyparsers.jl`
- **Recorded**: 2026-09-24
- **Severity**: breaking — a route declaring `Body{T}` for a struct, `Vector`, `Dict`, `Tuple` or
  `NamedTuple` `T` now throws an `ArgumentError` when `urlpatterns`/`path` registers it.

### What changed

`Body{T}` binds the raw body text through `parseparam`, whose fallback for a type with no
`Base.parse` method is a JSON parse. So `Body{Transfer}` bound a JSON body **whatever its
`Content-Type`**, including `text/plain` or no type at all. Those are what a cross-site page can
send without a CORS preflight, the path `Json{T}` closed with a `415` in #327.

`Body{T}` is now limited to what a body's text parses to on its own: `String`, `Any` (the text),
`Char`, `Regex`, an `@enum`, any concrete type with a `Base.parse(::Type{T}, ::String)` method
(numbers, `Bool`, `Date`, `UUID`, or an app type once it defines one), and a `Union` of those with
`Nothing`/`Missing`. An abstract numeric type (`Body{Integer}`, `Body{Real}`) is refused too:
declare a concrete one such as `Body{Int}` or `Body{Float64}`. Anything else is refused when the route is declared, so the failure shows up
at startup, not on the first request. Those scalar forms behave as before and still ignore the
`Content-Type`.

`Json{T}` binds the same value and requires the request to declare `application/json` or an
`application/*+json` type, or it answers `415`.

### How to find the calls to migrate

The error names the parameter and route:

```
Parameter 'transfer' of route /transfers is a Body{Transfer}, but Body{T} binds only the raw body text
```

To find them before starting the app:

```bash
rg -n 'Body\{' <app>/src
```

Every hit whose type parameter is not a string, number, `Bool`, enum, date or other parseable scalar
needs changing. Clients of those routes must send `Content-Type: application/json`.

### Migrate your app

```julia
# ✗ before — bound JSON from a text/plain body too
path("/transfers", (req, t::Body{Transfer}) -> create(t.payload); method = "POST")

# ✓ after — requires a JSON Content-Type; otherwise 415
path("/transfers", (req, t::Json{Transfer}) -> create(t.payload); method = "POST")

# unchanged — raw scalars still bind from the text
path("/note",  (req, n::Body{String})  -> save(n.payload);  method = "POST")
path("/price", (req, p::Body{Float64}) -> price(p.payload); method = "POST")
```
