## Scalar path & query params reject bad input with 400; `Nullable{T}` params bind their value (#18)

- **Version**: 0.2.0
- **Nitro ref**: #18; `src/utilities/misc.jl`, `src/core.jl`, `src/extractors.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior (status codes + optional-param binding)** — bug fix.

### What changed

Nitro had two binding paths that disagreed about whose fault a bad request is. Extractors
(`Json{T}`, `Query{T}`, `Path{T}`, …) routed every failure through a guard that produced a clean
`400`. Plain scalar parameters — `function get_user(req, id::Int)` — called `parseparam` unguarded,
so client input errors escaped as **`500 Internal Server Error`** with a full stack trace logged per
request. Both halves are fixed:

- **Malformed scalar path or query values are now `400`.** `/users/abc` against `<int:id>`, an
  out-of-range `@enum`, an empty `Char` segment, an `Int` that overflows — all `400`, not `500`. The
  converter remains a *binding* declaration rather than a routing filter, so this is a `400` and not
  a `404`; a route-level pattern could not reject the overflow case anyway.
- **A required query parameter that was not sent is now `400`.** It was a `KeyError` → `500`. A
  parameter *with* a declared default is unaffected: absence still falls back to the default.
- **`parseparam(::Union, …)` throws instead of returning the raw string.** When no member type
  parsed, it returned the unparsed `String` — a value outside the declared type, which reached the
  handler and typically became a `MethodError` → `500`. It is now a `400`.
- **`Nullable{T}` scalar params bind the client's value.** `Base.uniontypes` puts `Nothing` first and
  `JSON.parse(str, Nothing)` succeeds for *any* valid JSON, so `Union{Nothing, Int}` matched
  `Nothing` before it ever tried `Int`: **`?cursor=5` bound `nothing`.** `Nothing` is no longer a
  parse target, and neither is `Missing`, which had the identical defect.
- **`JsonFragment{T}` returns `400` for a body it cannot read.** The fragment key lookup sat outside
  the extractor guard, so a body missing the key (`KeyError`) or one that is not a JSON object at
  all (`MethodError`) escaped as a `500` while every sibling extractor returned a `400`.
- **Rejected requests are no longer logged with a backtrace.** `handlerequest` logs a
  `ValidationError` at `@debug` and genuine faults still log at `@error` with the full trace. This
  also removes the per-request stack trace that extractor `400`s were emitting, which made a spray
  of malformed URLs a log-flood vector. The `@debug` line deliberately does **not** include the
  `ValidationError` message: `try_validate` embeds a preview of the deserialized payload in it, so
  logging it would put a submitted password in the log.

The `400` response body is unchanged: the generic `{"message": "400: Bad Request"}`.

### How to find the calls to migrate

```bash
# Handlers with optional scalar path/query params — the silent half
rg -n 'Nullable\{|Union\{[^}]*Nothing' <app>/src

# Your own tests, and any client retry policy, asserting 5xx on bad input
rg -n '== 500|status.*500' <app>/test
```

The `Nullable{T}` change is the one that needs eyes. Nothing breaks at load time and nothing throws:
a handler that branched on `isnothing(cursor)` simply starts taking the other branch, because it now
receives the value the client actually sent. Read each hit and confirm the "absent" branch is still
what you want for a *present* value.

**One `Nullable{T}` case flips from `200` to `400`: a literal `?cursor=null`.** It used to be
absorbed by the `Nothing` member and bound `nothing`; now no member type accepts it. A JavaScript
client building `` `?cursor=${cursor}` `` with a null value emits exactly that string — omit the
parameter instead of sending `null`. (`?cursor=` with an empty value was already broken: it bound
the raw `""` and then `MethodError`'d into a `500`. It is now a clean `400`.)

### Migrate your app

```julia
# ✗ before — `?cursor=5` bound `nothing`, so this always took the first-page branch
function list_items(req, cursor::Nullable{Int} = nothing)
    return isnothing(cursor) ? first_page() : after(cursor)   # `after` was unreachable
end

# ✓ after — `?cursor=5` binds 5; absent still binds nothing; `?cursor=abc` is a 400
#   No source change is required, but verify the branch is correct now that both are reachable.

# ✗ before — a required query param that was not sent produced a 500
function search(req, q::String, limit::Int) ... end
# GET /search?q=chair   ->  500

# ✓ after
# GET /search?q=chair   ->  400   ... or give `limit` a default to make it genuinely optional:
function search(req, q::String, limit::Int = 20) ... end
```

If an app depends on the old status codes — an integration test asserting `500`, or an HTTP client
whose retry policy fires on 5xx and not 4xx — update it. Bad input now reports as bad input.
