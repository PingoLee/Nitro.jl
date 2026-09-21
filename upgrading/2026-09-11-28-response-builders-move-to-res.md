## Response building consolidates into `Res` — the top-level `html`/`js`/`css`/`xml`/`text`/`binary`/`file`/`redirect` builders are gone (#28)

- **Version**: 0.4.0
- **Nitro ref**: #28; `src/response.jl`, `src/utilities/render.jl` (deleted), `src/util.jl`,
  `src/utilities/misc.jl`, `src/Nitro.jl`, `src/core.jl`
- **Recorded**: 2026-09-11
- **Severity**: **breaking** — every call to a top-level response builder stops resolving, and
  two defaults change behavior silently. Part of the `0.1.x` pre-publish wave.

### What changed

Nitro had **two** response-building namespaces that disagreed with each other. `Res`
(`src/response.jl`) carried the intent builders; a second set of content-type builders lived as
top-level exports in `src/utilities/render.jl`, inherited unchanged from the Oxygen.jl fork. Three
names — `json`, `file` and `redirect` — existed in **both** with divergent bodies, headers and
defaults, and `text`/`json`/`binary` doubled as *request body parsers*, so the same exported name
meant opposite things depending on the argument type.

**`Res` is now the only response-building namespace.** `src/utilities/render.jl` is deleted, the
top-level `redirect` in `src/utilities/misc.jl` is deleted, and `Nitro` no longer exports `html`,
`file`, `xml`, `js`, `css` or `redirect`. The bare names `text`, `json` and `binary` survive as
**request body parsers only**.

`Res` gained one name, `html`, rather than absorbing all six. `Res.send` already produced
`text/plain`, so a `Res.text` would have shipped as an exact synonym; instead `send` gained a
`content_type` keyword and a `Vector{UInt8}` method, which covers what `text`, `binary`, `js`,
`css` and `xml` did.

**What this forces, beyond the renames.** Two defaults changed, and neither fails loudly:

- **`Res.file` no longer forces a download.** It used to default to
  `disposition="attachment"`; it now emits **no** `Content-Disposition` unless you pass
  `disposition=` or `filename=`. This is what lets `staticfiles`/`spafiles`/`dynamicfiles` route
  through it — the old default would have served an SPA's `index.html` as a download.
- **`redirect` was 307, `Res.redirect` is 302.** The deleted top-level `redirect(path; code=307)`
  preserved the request method and body; `Res.redirect(url; status=302)` lets a client turn a POST
  into a GET. If your redirect follows a non-GET request, pass `status=307` explicitly.
- **`Res.json(bytes)` no longer JSON-encodes the byte array.** `Res.json` gained a
  `Vector{UInt8}` method that sends the bytes verbatim, on the assumption they are already
  serialized JSON. Before, `Res.json(UInt8[0x31, 0x32])` produced the body `[49,50]`; it now
  produces `12`. Only affects callers who passed raw bytes and wanted them encoded as an array.

One more observable difference: `Res.file` applies caller-supplied `headers` **last**, so a
`Content-Type` you pass to `staticfiles(...; headers=[...])` now wins instead of being overwritten.

### How to find the calls to migrate

```bash
# 1. Response builders that no longer exist. Any hit is a hard error at call time.
#    The `[^A-Za-z0-9_.]` class skips a leading dot so `Res.file(` is not a false hit,
#    while the optional `Nitro\.` still catches the fully-qualified form.
rg -n '(^|[^A-Za-z0-9_.])(Nitro\.)?(html|js|css|xml|file|redirect)\s*\(' <app>/src

# 2. The pipe form -- easy to miss, same breakage.
rg -n '\|>\s*(Nitro\.)?(html|js|css|xml|text|json|binary|file|redirect)\b' <app>/src

# 3. `text`/`json`/`binary` used to BUILD a response. The parser forms still work, so the
#    second filter drops calls whose argument is a Request or Response.
#    CAVEAT: `rg -v` filters by LINE, so a line carrying BOTH a parser and a builder --
#    `Res.send(text(r) * json(payload))` -- is dropped whole. Drop the `| rg -v` once and
#    skim for mixed lines before trusting the filtered list.
rg -n '(^|[^A-Za-z0-9_.])(Nitro\.)?(text|json|binary)\s*\(' <app>/src \
  | rg -v '(text|json|binary)\((req|r|res|response)\b'

# 4. The function-as-value form -- `map(json, xs)`, `cb = html`. Neither of the greps above
#    sees these, and they fail at call time far from where they were written. This one is a
#    SKIM list, not a hit list: it also matches these names inside string literals such as
#    "text/plain", so expect noise.
rg -n '(^|[^A-Za-z0-9_.])(html|js|css|xml|file|redirect|text|json|binary)([^A-Za-z0-9_( ]|\s*$|\s*,)' <app>/src

# 5. SILENT: Res.file callers that relied on the old `attachment` default.
rg -n 'Res\.file\s*\(' <app>/src

# 6. SILENT: redirects issued after a non-GET request, which needed 307.
rg -n 'redirect\s*\(' <app>/src

# 7. SILENT: Res.json called with a Vector{UInt8} -- it now passes the bytes through
#    instead of JSON-encoding them as an array of integers.
rg -n 'Res\.json\s*\(' <app>/src
```

### Migrate your app

```julia
# ✗ before -- top-level builders
html("<h1>$title</h1>")
text("plain body")
css(sheet)
js(script)
xml(feed)
binary(bytes)
json(Dict("id" => 1))
Dict("id" => 1) |> json          # the pipe form breaks too

# ✓ after -- one namespace
Res.html("<h1>$title</h1>")
Res.send("plain body")
Res.send(sheet;  content_type="text/css")
Res.send(script; content_type="application/javascript")
Res.send(feed;   content_type="application/xml")
Res.send(bytes)
Res.json(Dict("id" => 1))
Dict("id" => 1) |> Res.json
```

The two silent ones:

```julia
# ✗ before -- forced a download
Res.file("report.pdf")
# ✓ after -- say so
Res.file("report.pdf"; disposition="attachment")

# ✗ before -- 307, method and body preserved
redirect("/done")
# ✓ after -- Res.redirect is 302; ask for 307 if a POST must stay a POST
Res.redirect("/done"; status=307)
```

An app that already writes every response through `Res.json`/`Res.send`/`Res.status` and never
calls `Res.file` or `redirect` needs no change.
