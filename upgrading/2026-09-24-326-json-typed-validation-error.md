## `json(req, T)` — a body that does not bind raises a `ValidationError`

- **Version**: Unreleased
- **Nitro ref**: [#326](https://github.com/PingoLee/Nitro.jl/issues/326) ; `src/utilities/bodyparsers.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — code that caught the parser's own exception from
  `json(req, T)` (`ArgumentError`, `TypeError`, …) no longer catches it.

### What changed

`json(req::HTTP.Request, T)` let the parser's exception escape as it was. In a handler that was a
**500** with a logged backtrace, and the log line quoted the body: a JSON parse `ArgumentError`
echoes the bytes around the error, so `{"password":"hunter2" oops}` put the password in the error
log. The `Json{T}` extractor answered the same body with a silent `400`.

It now raises a `ValidationError` — `400 Bad Request` from a handler, logged at `@debug` only —
whose message names the target type and never the body. The parser's exception is kept as `.cause`,
which none of Nitro's output paths render.

Still `ArgumentError`, because they are programming errors rather than client input: passing
`style` or `allownan = true`, or a `T` that would bind a `Symbol`. `json(res::HTTP.Response, T)` is
unchanged: a response is not client input, and its failure is still the parser's exception.

### How to find the calls to migrate

```bash
# Typed request parses...
rg -n 'json\(req[^)]*,\s*[A-Z]' <app>/src
# ...wrapped in a catch that names the parser's exception.
rg -n 'catch.*(ArgumentError|TypeError)|isa (ArgumentError|TypeError)' <app>/src
```

### Migrate your app

```julia
# ✗ before
try
    order = json(req, Order)
catch e
    e isa ArgumentError || rethrow()
    return Res.status(400)
end

# ✓ after — or drop the try entirely: an uncaught ValidationError already answers 400
try
    order = json(req, Order)
catch e
    e isa ValidationError || rethrow()
    return Res.status(400)
end
```
