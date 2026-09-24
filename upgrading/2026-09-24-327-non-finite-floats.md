## Float binding — `NaN`, `Inf` and out-of-range numbers are a `400`

- **Version**: Unreleased
- **Nitro ref**: [#327](https://github.com/PingoLee/Nitro.jl/issues/327) ; `src/utilities/misc.jl`,
  `src/utilities/bodyparsers.jl`, `src/extractors.jl`, `src/cookies.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — a request that sent a non-finite value for a float parameter,
  which used to bind, is now rejected; `json(req, T; allownan = true)` throws.

### What changed

`parse(Float64, s)` accepts `"NaN"`, `"nan"`, `"inf"` and `"-Infinity"`, and reads `"1e999"` as
`Inf`. JSON has no NaN, but it has no size limit either: JSON.jl reads `1e999`, or a 400-digit
integer, as a `BigFloat`/`BigInt`, and converting that to a `Float64` field gave `Inf`. None of
these is a number a client can mean, and `NaN` defeats comparisons silently — `NaN > balance` and
`NaN <= balance` are both `false`, so a check like "reject if amount > balance" let it through.

Every path a client float takes now requires a finite value:

| Path | A non-finite value |
|---|---|
| `<float:x>`, a typed `x::Float64` path or query parameter, `Body{Float64}`, `Cookie{Float64}` | `400` |
| a float field bound by `Query{T}`, `Form{T}`, `Header{T}`, `Path{T}`, `JsonFragment{T}` | `400` |
| a float field of `Json{T}`, including `Nullable{Float64}` and `Float32` | `400` |
| a number field of `MultipartForm{T}` | `400` |
| `get_cookie(req, name, default::AbstractFloat)` | the default, as for a value that does not parse |
| `json(req, T)` | an `ArgumentError`; and `json(req, T; allownan = true)` is itself refused |

There is no opt-out. The untyped parsers (`json(req; allownan = true)`, `getjson`) and the
`Response` forms of `json` are unchanged: they build no typed value from client input.

### How to find the calls to migrate

```bash
# Float parameters and fields that could have been bound from NaN/Inf before.
rg -n '<float:|::\s*(Float16|Float32|Float64|BigFloat|AbstractFloat)' <app>/src

# The one call that now throws.
rg -n 'allownan' <app>/src <app>/test
```

### Migrate your app

```julia
# ✗ before — the handler had to guard against NaN itself, or did not
path("/withdraw", (req, amount::Float64) -> isnan(amount) ? Res.status(400) : withdraw(amount))
# ✓ after — a non-finite amount never reaches the handler
path("/withdraw", (req, amount::Float64) -> withdraw(amount))

# ✗ before
json(req, Reading; allownan = true)
# ✓ after — read the body untyped if NaN is genuinely part of your wire format
json(req; allownan = true)
```
