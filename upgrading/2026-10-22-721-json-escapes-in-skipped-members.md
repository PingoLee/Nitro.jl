## `Json{T}` refuses an invalid string escape in a member `T` does not declare (#721)

- **Version**: Unreleased
- **Nitro ref**: [#721](https://github.com/PingoLee/Nitro.jl/issues/721) ; [#577](https://github.com/PingoLee/Nitro.jl/issues/577) ; `Project.toml` (`JSON` compat)
- **Recorded**: 2026-10-22
- **Severity**: behavior change (request bodies)

### What changed

`Json{T}` skips the members of a JSON body that `T` does not declare. That skip used to check
everything except the escapes inside the member's strings, so a body such as
`{"name":"lamp","note":"bad \q escape"}` bound a `T` without a `note` field, while `getjson(req)`
and `JsonFragment{T}` refused the same body.

It is now a `400` through `Json{T}` too. The change is upstream: JSON.jl 1.12.0 checks every escape
when it skips a value ([JuliaIO/JSON.jl#516](https://github.com/JuliaIO/JSON.jl/pull/516)). Nitro's
`JSON` compat is now `"1.12.1"`, so every environment that resolves this Nitro behaves this way;
1.12.1 rather than 1.12.0 because it fixes a slow parse of documents holding many very long integers
([JuliaIO/JSON.jl#523](https://github.com/JuliaIO/JSON.jl/pull/523)).

An application that also depends on `JSON` directly with an upper bound below `1.12.1` no longer
resolves against this Nitro; raise that bound.

### How to find the calls to migrate

There is no server call to grep: no handler signature or Nitro API changed, only which request
bodies are accepted. What can break is a **client** or a **test fixture** that sends hand-built
JSON with a backslash in a field the server ignores, which used to answer `200`. Look for JSON
written by string concatenation or templates rather than by a serializer, in the fields your
types do not declare:

```bash
grep -rnE --exclude-dir=node_modules --exclude-dir=.git \
  --include=*.jl --include=*.js --include=*.ts --include=*.py --include=*.json \
  '\\[^"\\/bfnrtu]|\\u[^0-9a-fA-F]' .
```

The pattern is a backslash followed by a character JSON does not allow after one, or a `\u` not
followed by a hex digit. It is a starting point, not a verdict: it also matches ordinary
source-language escapes, so read each hit, and only JSON text sent to the server matters. Fix
it at the sender, by escaping the backslash (`\\`) or by building the body with a JSON
serializer. A body built by a JSON library is always valid and is not affected. If the project
also lists `JSON` in its own `Project.toml`, check that its `[compat]` admits `1.12.1`:

```bash
grep -n '^JSON *=' Project.toml
```

### Migrate your app

```text
POST /search   Content-Type: application/json
{"name": "lamp", "note": "bad \q escape"}       # `note` is not a field of the bound type

✗ before: 200, bound as if `note` were absent
✓ after:  400, the same answer getjson(req) and JsonFragment{T} already gave
```

The fix is at the sender: send `"note": "bad \\q escape"` (an escaped backslash), or drop the
member. If the server must accept it, there is no setting for that: invalid JSON is refused by
every JSON extractor.
