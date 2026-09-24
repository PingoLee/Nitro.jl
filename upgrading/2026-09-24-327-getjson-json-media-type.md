## `getjson` / `payload` — a body without a JSON `Content-Type` is not read as JSON

- **Version**: Unreleased
- **Nitro ref**: [#327](https://github.com/PingoLee/Nitro.jl/issues/327) ; `src/core/request.jl`,
  `src/utilities/bodyparsers.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — `getjson(req)` returns `nothing`, and `payload(req)` leaves out the
  body, unless the request declares `application/json` or an `application/*+json` type.

### What changed

`getjson` is the cached JSON accessor behind `payload`, and behind `CSRFMiddleware`'s lookup of a
token sent in a JSON body. It parsed any body that happened to be JSON. It now reads the body only
when the `Content-Type` names JSON (case-insensitive, parameters ignored); otherwise it returns
`nothing`, the same as for an empty or malformed body. A request with no `Content-Type` is not JSON.

This is the accessor half of the rule the `Json{T}` extractor enforces with a `415`: a cross-site
page can send `text/plain` or no type without a CORS preflight, so a body that does not declare
itself JSON must not be read as JSON anywhere. The accessor answers `nothing` rather than throwing,
which keeps its existing contract.

For `CSRFMiddleware`, a token sent inside a JSON body now counts only when the request's
`Content-Type` is JSON. A token in the header or a form field is unaffected.

The bare parser `json(req)` is unchanged and still parses whatever it is given.

### How to find the calls to migrate

```bash
rg -n 'getjson\(|payload\(' <app>/src
# Clients or tests that send JSON bodies without the header.
rg -n 'Request\("(POST|PUT|PATCH|DELETE)",[^)]*\[\]' <app>/test
```

### Migrate your app

```julia
# ✗ before — read as JSON although the request never said so
req = HTTP.Request("POST", "/items", [], """{"n":1}""")
getjson(req)["n"]          # 1   → now `getjson(req) === nothing`

# ✓ after — declare the body
req = HTTP.Request("POST", "/items", ["Content-Type" => "application/json"], """{"n":1}""")
getjson(req)["n"]          # 1

# ✓ or, when the type genuinely cannot be trusted and you mean to parse anyway
json(req)["n"]             # the explicit parser ignores the Content-Type
```
