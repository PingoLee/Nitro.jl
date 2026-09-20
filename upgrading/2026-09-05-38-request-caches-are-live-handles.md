## `req.query`, `req.params` and `headers(req)` are cached per request, so they are live handles (#38)

- **Version**: 0.3.0
- **Nitro ref**: #38; `src/types.jl`, `src/core.jl`
- **Recorded**: 2026-09-05
- **Severity**: **behavior** — a mutation that used to be silently discarded now persists.

### What changed

`pathparams`, `queryvars` and `headers` were the only request accessors with no memoization: each
one rebuilt its whole `Dict` on every call. Because the parameter binder calls them **once per
bound parameter**, a handler with three query parameters re-parsed the same unchanged target three
times. They are now parsed once per request and cached in the request context, exactly as
`req.json` and `req.form` always have been.

The consequence is a contract inversion. These accessors used to return a **fresh `Dict` per
call**, so mutating the result was a harmless no-op. They now return the **same `Dict`** for the
lifetime of the request, so a mutation is visible to every later reader — including `req.input` and
any parameter binding that has not run yet.

```julia
q = req.query
q["injected"] = "1"

req.query            # BEFORE: unchanged — `q` was a throwaway copy
req.query["injected"] # AFTER:  "1" — `q` IS the cached table
req.input["injected"] # AFTER:  "1" — `req.input` merges from the same table
```

`req.json` and `req.form` have always behaved this way, so this makes the five accessors
consistent rather than introducing a new hazard.

### How to find the calls to migrate

Look for writes into a value read out of one of these accessors — the read is harmless, the
mutation is what changed:

```bash
grep -rnE '(req|request)\.(query|params)' --include=*.jl .   | grep -vE '^\s*#'
grep -rn 'headers(req' --include=*.jl .
```

Then check each hit for an assignment, `delete!`, `merge!`, `push!` or `empty!` applied to the
result. A call that only *reads* — `req.query["page"]`, `get(req.query, "q", "")`, `haskey`,
iteration — needs no change and is now strictly faster.

### Before → after

```julia
# BEFORE — mutating the snapshot to carry a value onward. Worked only because the
# mutation was discarded; the next reader got a clean table anyway.
function handler(req)
    q = req.query
    q["tenant"] = resolve_tenant(req)   # invisible to everything downstream
    ...
end

# AFTER — pass values down the request through `req.context`, which is what it is for.
function handler(req)
    req.context[:tenant] = resolve_tenant(req)
    ...
end
```

If you genuinely need a private copy to modify, take one explicitly:

```julia
q = copy(req.query)
```

### These accessors are now writes, so do not fan them out across tasks

Caching means the first read of `req.query`, `req.params` or `headers(req)` **writes** into the
request context. That is unsynchronized, exactly as `req.json` and `req.form` have always been, and
it is safe under Nitro's own concurrency model: one task owns a request end to end
(`parallel_stream_handler` spawns one task and the connection task blocks in `wait`), and HTTP.jl
allocates a fresh `Request` per keep-alive iteration, so no request object is shared between tasks.

What changed is that a handler which *itself* fans out is no longer safe to write this way:

```julia
# was fine before — `req.query` was a pure read
# now a data race: several tasks can miss the cache, build, and write the same Dict
@sync for k in keys(req.query)
    Threads.@spawn work(req.query[k])
end

# force the caches first, on one task, then fan out over the value
q = req.query
@sync for k in keys(q)
    Threads.@spawn work(q[k])
end
```

### Not affected

Malformed input still raises rather than caching a bad value: `queryvars` throws `ValidationError`
on invalid percent-encoding or invalid UTF-8, a throwing builder caches nothing, and the error
handler still reports `400`.

`req.params` is deliberately **not** cached while it is `nothing`. `HTTP.getparams` reads a context
slot the router fills, and middleware runs before the router, so a pre-router read (a guard reading
`req.params`, or anything touching `req.input`) must not memoize the miss — it would make the path
binder index into `nothing` and 500 every parameterized route. Such a read still sees `nothing`, and
caching begins once the router has populated the slot.

`req.input` needed a second, separate rule, because it merges a *copy* of the path params rather
than reading them through: a merge performed before the router ran produced an input map with the
path params missing, and caching that handed every later reader the truncated version — a 200 with
silently wrong data. That merge is now rebuilt once if it was cached before the params appeared.
This also fixes a pre-existing bug: middleware calling `payload(req)` or reading
`req.input["tenant"]` already poisoned `req.input` for the whole request before these caches
existed.
