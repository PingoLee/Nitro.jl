## `url()` — a value the route would not accept throws instead of building a URL

- **Version**: Unreleased
- **Nitro ref**: [#328](https://github.com/PingoLee/Nitro.jl/issues/328) ; `src/routing.jl`,
  `src/types.jl`, `src/context.jl`
- **Recorded**: 2026-09-25
- **Severity**: behavior change — a `url(...)` call that used to return a string now throws an
  `ArgumentError` when a parameter value is empty, `.`/`..`, or does not parse as its converter's
  type.

### What changed

`url()` percent-escaped `/`, `?` and `#`, but passed `""`, `"."` and `".."` through unchanged, and
never checked a value against the route's converter:

| Call | Before | After |
|---|---|---|
| `url(app, "org-page"; org = "", page = "evil.example")` for `/{org}/{page}` | `"//evil.example"` — scheme-relative, an open redirect once handed to `Res.redirect` | `ArgumentError` |
| `url(app, "user-delete"; name = "..")` for `/users/{name}/delete` | `"/users/../delete"` — a client or proxy resolves it to `/delete` | `ArgumentError` |
| `url(app, "item"; id = "abc")` for `/items/<int:id>` | `"/items/abc"` — a link the route answers with a `400` | `ArgumentError` |

Now it applies the rule Django's `reverse()` does and refuses a value the route itself would not
accept. `""`, `"."` and `".."` are refused for every parameter. Under a converter (`<int:>`,
`<float:>`, `<bool:>`, `<uuid:>`), the value must also parse as that type, using the same parser
the router binds the segment with. So `id = 42` and `id = "42"` both still build `/items/42`, and
`x = NaN` for a `<float:x>` is refused. A plain `{param}` or `<str:>` parameter gets only the first
rule.

The error message names the parameter and the route, never the value.

### How to find the calls to migrate

```bash
# Every reverse lookup. The ones to look at build a parameter from data that can be empty
# (an optional field, a blank form value) or is not guaranteed to match the converter.
rg -n '\burl\(' <app>/src <app>/test
```

### Migrate your app

```julia
# ✗ before — an empty slug silently built "//", and the redirect left the site
Res.redirect(url("org-page"; org = user.org_slug, page = page))
# ✓ after — decide what an empty value means before building the URL
isempty(user.org_slug) ? Res.redirect(url("home")) :
    Res.redirect(url("org-page"; org = user.org_slug, page = page))

# ✗ before — a non-numeric id built a URL the route answers with a 400
url("item"; id = params["id"])
# ✓ after — validate (or parse) first; `url` now throws ArgumentError on it
url("item"; id = parse(Int, params["id"]))
```
