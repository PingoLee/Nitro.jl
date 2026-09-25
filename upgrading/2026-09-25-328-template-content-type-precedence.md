## `mustache` / `otera` — an explicit `Content-Type` is no longer replaced by sniffing

- **Version**: Unreleased
- **Nitro ref**: [#328](https://github.com/PingoLee/Nitro.jl/issues/328) ; `src/utilities/misc.jl`,
  `ext/MustacheExt.jl`, `ext/OteraEngineExt.jl`
- **Recorded**: 2026-09-25
- **Severity**: behavior change — a rendered template served with a `Content-Type` passed in the
  per-call `headers` now keeps that type; with `mime_type` also set, the per-call type wins and is
  the only one sent.

### What changed

A renderer built without `mime_type` content-sniffed its output and **replaced** any
`Content-Type` the caller passed in `headers`. A template served as `text/plain` precisely so that
unescaped output would be safe went out as `text/html` as soon as a rendered value looked like
markup:

```julia
render = mustache("{{{msg}}}")
render(Dict("msg" => "<script>…</script>"); headers = ["Content-Type" => "text/plain"])
# before: Content-Type: text/html; charset=utf-8   ← a reflected script
# after:  Content-Type: text/plain
```

A renderer built **with** `mime_type` sent two `Content-Type` headers when the caller also passed
one: the template's first, then the caller's.

The `Content-Type` is now the first of these that applies, and only one is ever sent:

1. a `Content-Type` in the per-call `headers`;
2. the renderer's `mime_type`;
3. a type sniffed from the output (unchanged: a renderer with neither still sniffs).

`Nitro.Util.response` gained the `content_type` keyword that carries step 2.

### How to find the calls to migrate

```bash
# Renderers called with per-call headers. Only calls whose headers carry a Content-Type change.
rg -n 'headers\s*=' <app>/src | rg -i 'content-type'
rg -n '\b(mustache|otera)\(' <app>/src
```

### Migrate your app

A call only needs an edit if it relied on the old behavior, which means passing a `Content-Type`
while expecting the sniffed one (or the template's `mime_type`) to be what the client saw:

```julia
# ✗ before — the per-call type was silently replaced by the sniffed text/html
page(Dict("body" => html_fragment); headers = ["Content-Type" => "text/plain"])
# ✓ after — say what you mean; this is now what is sent
page(Dict("body" => html_fragment); headers = ["Content-Type" => "text/html; charset=utf-8"])
```
