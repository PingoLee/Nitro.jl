## `mustache` parses its template when the handler is built, so a malformed one throws there (#550)

- **Version**: Unreleased
- **Nitro ref**: [#550](https://github.com/PingoLee/Nitro.jl/issues/550) ; `ext/MustacheExt.jl`
- **Recorded**: 2026-10-21
- **Severity**: behavior change (when a template error is raised)

### What changed

`mustache(template::String)`, `mustache(path; from_file = true)` and `mustache(io::IO)` used to
keep the template as a string and hand it to `Mustache.render` on every call, which tokenized it
again each time. They now parse it once, when `mustache(...)` builds the handler, and render each
request from the parsed tokens, as `mustache(tokens::MustacheTokens)` and `otera(...)` already did.
Rendered output is unchanged.

The visible difference is **when a malformed template fails**. Mustache rejects a tag left open
(`{{name`), a section closed that was never opened (`{{/items}}`), and a section closed under
another name (`{{#a}}…{{/b}}`). Such a template used to build a handler without complaint and
throw `ArgumentError` on every request it served. It now throws that `ArgumentError` from the
`mustache(...)` call itself. That is usually at module load or route setup, so the app fails to
start instead of answering every request to that route with an error.

A `tags = (open, close)` keyword is still honoured. It is now spent on the one parse instead of
on each render.

### How to find the calls to migrate

Find every handler built from a string, a file or an IO:

```bash
grep -rn -E 'mustache\(' --include=*.jl .
```

Calls on an `mt"…"` literal or a `Mustache.parse(…)` result were already parsed up front and are
unaffected. For the rest, build each one once (start the app, or run its test suite). A template
that now throws at that point was already failing every request that rendered it: fix the template
the error names.

### Migrate your app

```julia
# ✗ before: built without complaint; every GET /report failed with ArgumentError
report = mustache("<ul>{{#rows}}<li>{{name}}</li>{{/row}}</ul>")

# ✓ after: the same call throws ArgumentError at startup; close the section under its own name
report = mustache("<ul>{{#rows}}<li>{{name}}</li>{{/rows}}</ul>")
```
