## The `req.<property>` shorthands are removed — read the request through exported functions (#151)

- **Version**: 0.4.0
- **Nitro ref**: #151 (splits out of #32); `src/core.jl`, `src/Nitro.jl`,
  `src/middleware/csrf_middleware.jl`, `test/http_internals_contract_tests.jl`, `README.md`,
  `docs/src/`
- **Recorded**: 2026-09-12
- **Severity**: **breaking, and it fails LOUDLY — with one exception, below.** Every removed
  shorthand now raises `FieldError` at the call site, naming the property, and no value
  changes shape underneath you. Part of the `0.1.x` pre-publish wave.

  **The exception: a shorthand read wrapped in `try`/`catch` degrades SILENTLY.**

  ```julia
  user = try req.user catch; nothing end     # was: the principal.  now: always nothing.
  ```

  The `FieldError` is caught by the app's own handler, so the read quietly becomes the
  fallback instead of throwing. On an auth path that turns "who is this?" into "nobody"
  without a single log line — and if the surrounding code treats `nothing` as *unauthenticated
  but allowed*, it is an authorization hole rather than an outage. This is not hypothetical:
  Nitro's own CSRF middleware used exactly that shape to read the request body. **Grep for it
  first** (step 4 below); it is the only part of this migration a test suite may not catch.

### What changed

Nitro used to install eleven DX shorthands on `HTTP.Request` — `req.params`, `req.query`,
`req.json`, `req.form`, `req.input`, `req.data`, `req.files`, `req.post`, `req.session`,
`req.user`, `req.ip` — by `@eval`ing a `Base.getproperty(::HTTP.Request, ::Symbol)` from
`Core.__init__`. They are gone. Read the request through the exported accessor functions
instead.

The shorthands were not an *extension* of HTTP.jl. The method Nitro defined had the **same
signature** as HTTP.jl's own `Base.getproperty(::Request, ::Symbol)`, so it did not add a more
specific method — it **replaced** HTTP's in the method table, for the whole Julia process:

```julia
julia> using Nitro; import HTTP
julia> only(methods(Base.getproperty, (HTTP.Request, Symbol))).module
Nitro.Core          # before #151 — HTTP's own method was gone
HTTP                # after
```

That is type piracy on a foreign type, and its blast radius was every `HTTP.Request` in the
session, including requests belonging to packages that had never heard of Nitro. It also
obliged Nitro's version to stay a strict superset of HTTP's *forever* — any property HTTP added
later would silently fall through to `getfield` until someone noticed.

The sugar was not buying anything the public API did not already provide, so it was deleted
rather than policed. Five accessors were added to close the gaps where no function existed.

**What is unaffected:** `req.context` and `req.version` revert to HTTP.jl's own
implementations and keep working unchanged — `req.context` is still the place to pass values
down a request. So do the real fields: `req.method`, `req.target`, `req.body`, `req.headers`,
`req.response`. Only the eleven Nitro-invented properties are gone.

### How to find the calls to migrate

```bash
# 1. Every call site. Each hit is a compile-clean line that now throws at runtime, so
#    grep is the migration -- there is no deprecation window to lean on.
rg -n '\breq\.(params|query|json|form|input|data|files|post|session|user|ip)\b' <app>

# 2. Your request variable may not be named `req`. Widen it, then read the hits:
rg -n '\b[a-z_][a-z0-9_]*\.(params|query|json|form|input|data|files|post|session|user|ip)\b' <app>

# 3. NOT matches to rewrite -- step 2 will show these, and rewriting them breaks working code:
#      Res.json(...) / JSON.json(...)      -- response building and serialization
#      json(res) / formdata(res)           -- parsing a RESPONSE body
#      f.data, file.data                   -- `FormFile` fields
#      payload.files, data.files           -- fields of YOUR MultipartForm{T} struct
#      rec.query, rec.context              -- access-log record fields
#      request.session                     -- Django/Python, in migration docs
#      HTTP.post(...)                      -- the client verb

# 4. THE DANGEROUS ONE -- a shorthand read inside a `try`/`catch`. This does NOT throw at
#    you; the FieldError is swallowed and the read silently becomes your fallback value.
#    Audit every hit by hand, and do the auth-path ones first.
rg -n -U --multiline-dotall \
  'try.{0,200}\breq\.(params|query|json|form|input|data|files|post|session|user|ip)\b.{0,200}?catch' <app>

# 5. Did you define your own `getproperty` on HTTP.Request to add shorthands of your own?
#    Same piracy, same reason to drop it.
rg -n 'getproperty\(.*HTTP\.Request' <app>
```

### Migrate your app

Ten of the eleven map onto a function that already existed; `req.user` gained one.

| before | after | note |
|---|---|---|
| `req.params` | `getparams(req)` | already exported |
| `req.query` | `getquery(req)` | already exported |
| `req.session` | `getsession(req)` | already exported |
| `req.ip` | `getip(req)` | already exported |
| `req.input`, `req.data` | `payload(req)` | already exported |
| `req.user` | `getuser(req)` | **new** |
| `req.json` | `getjson(req)` | **new** |
| `req.form` | `getform(req)` | **new** |
| `req.files` | `getfiles(req)` | **new** |
| `req.post` | `getpost(req)` | **new** |

```julia
# ✗ before
function handler(req)
    id   = req.params["id"]
    body = req.json
    who  = req.user
    up   = req.files["avatar"]
    return Res.json(Dict("id" => id, "n" => length(body), "who" => who))
end

# ✓ after
function handler(req)
    id   = getparams(req)["id"]
    body = getjson(req)
    who  = getuser(req)
    up   = getfiles(req)["avatar"]
    return Res.json(Dict("id" => id, "n" => length(body), "who" => who))
end
```

**Four of these are not the substitution you would guess**, so do not let a find/replace pick
the wrong target:

- **`req.json` is `getjson(req)`, not `json(req)`.** Both parse the same body, but `getjson`
  **memoizes per request** the way `req.json` did — two reads, one parse, and both reads return
  the *same* object. `json(req)` re-parses on every call. It remains the right choice when you
  need `json(req; kwargs...)`, the typed `json(req, T)`, or to parse an `HTTP.Response`.
- **`req.form` is `getform(req)`, not `formdata(req)`** — same split.
- **`req.files` is `getfiles(req)`, NOT `multipart(req)`.** `multipart(req)` returns files *and*
  text fields in one `Dict`; `req.files` was the file-parts-only view, typed
  `Dict{String, Union{FormFile, Vector{FormFile}}}`. Substituting `multipart` silently widens
  what your handler iterates over.
- **`req.post` is `getpost(req)`, NOT `multipart(req)`** — the text-fields-only half, for the
  same reason.

Behavior is otherwise identical: same values, same per-request caching, same live-handle
semantics (mutating what an accessor returns is visible to later reads, so treat the result as
read-only).

### These are five new exported names, and they can collide

`Nitro` now exports `getuser`, `getjson`, `getform`, `getfiles`, and `getpost`. If your app
defines one of those in the **same module** that does `using Nitro`, yours shadows Nitro's and
nothing breaks. But if it lives in a submodule that *exports* it — `MyApp.Accessors`,
`MyApp.Requests` — and both are brought in:

```julia
using Nitro
using MyApp.Accessors      # also exports `getjson`

getjson(req)               # UndefVarError: `getjson` not defined
```

Julia does not pick a winner between two `using`-exported bindings of the same name; it makes
the name ambiguous and any use of it an error. Qualify the one you mean (`Nitro.getjson(req)`,
`Accessors.getjson(x)`) or stop exporting yours.

```bash
# Does your app define any of the five?
rg -n '\b(function |const )?(getuser|getjson|getform|getfiles|getpost)\b\s*[({=]' <app>/src
```

An app that reads the request only through extractors (`Json{T}`, `Query{T}`, `Path{T}`,
`Form{T}`, `MultipartForm{T}`) or through scalar handler parameters needs no change — those
never went through the property sugar.
