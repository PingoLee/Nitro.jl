## `getform` / `payload` / `Form{T}` — only an urlencoded or untyped body is read as a form

- **Version**: Unreleased
- **Nitro ref**: [#345](https://github.com/PingoLee/Nitro.jl/issues/345) ; `src/utilities/bodyparsers.jl`,
  `src/extractors.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — `getform(req)`, `formdata(req)` and `payload(req)` ignore a body that
  declares a `Content-Type` other than `application/x-www-form-urlencoded`, and `Form{T}` answers
  `415` for one.

### What changed

`formdata` excluded only multipart and JSON bodies. Any other body containing `=`, such as
`text/plain`, `application/xml` or `text/html`, was parsed as urlencoded. Its `&`-separated pieces
were merged into `payload(req)` as "form" keys, and under `serve(max_fields = …)` a body with many
`&` (HTML entities, say) made `payload` answer `400`.

A body is now read as a form only when the request declares `application/x-www-form-urlencoded`
(case-insensitive, parameters such as `charset` ignored) or declares **no** `Content-Type`. The
untyped case is kept for hand-built `HTTP.Request`s and clients that send no type. For any other declared type
`getform`/`formdata` return an empty `Dict`, and `payload(req)` leaves the body out.

`Form{T}` now checks the same rule up front. A request with another declared type used to bind an
empty form, which gave a `400`, or a `200` built entirely from defaults when every field of a
`@kwdef` struct had one. It is now a `415 Unsupported Media Type`, like `Json{T}` and
`MultipartForm{T}`.

`CSRFMiddleware` reads a form-field token through `getform`, so a token sent in a `text/plain` (or
XML, HTML, …) body no longer counts. A token in the header, in an urlencoded body, or in a JSON body
sent as JSON is unaffected.

### How to find the calls to migrate

```bash
rg -n 'getform\(|formdata\(|payload\(|Form\{' <app>/src
# Clients or tests that send key=value bodies under another declared type.
rg -n '"Content-Type" => "text/(plain|html)"' <app>/test
```

### Migrate your app

```julia
# ✗ before — read as a form although it declared text/plain
req = HTTP.Request("POST", "/login", ["Content-Type" => "text/plain"], "user=ann&pw=x")
getform(req)["user"]       # "ann"  → now `getform(req)` is empty; `Form{Login}` answers 415

# ✓ after — declare the form (or send no Content-Type)
req = HTTP.Request("POST", "/login",
                   ["Content-Type" => "application/x-www-form-urlencoded"], "user=ann&pw=x")
getform(req)["user"]       # "ann"
```
