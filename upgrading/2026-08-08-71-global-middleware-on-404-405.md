## Global middleware now runs on unmatched (404) and method-mismatched (405) requests (#71)

- **Version**: 0.2.0
- **Nitro ref**: #71; `src/routerhof.jl`, `src/core.jl`
- **Recorded**: 2026-08-08
- **Severity**: **behavior (middleware now runs on 404/405)** — bug fix.

Global middleware — the `middleware=[...]` vector passed to `serve` — now runs on **every**
request, including ones that match no route (404) and ones whose path matches but whose method
does not (405).

Previously this depended on something unrelated: `compose` was only installed when the app had
registered at least one route with per-route `middleware=`, and `compose`'s unmatched branch
called the inner handler directly, skipping the global chain. So an app **with** per-route
middleware silently exempted 404s and 405s from all global middleware, while an app **without**
any ran it on them. The two are now consistent, matching what the routing docs already described.

**Who this affects.** Only apps that use per-route middleware *and* global middleware. If your
global middleware assumed it only ever saw matched routes, it now also sees unmatched ones:

- an auth middleware that rejects unauthenticated requests will return **401 instead of 404** for
  unknown paths;
- a session middleware will create a session and emit `Set-Cookie` on 404 responses;
- a rate limiter will now count unmatched requests — this is usually the point, since it closes a
  bypass where 404 probes were never limited.

**How to find the calls to migrate**

```bash
rg -n 'serve\(' --glob '*.jl' -A5 | rg 'middleware\s*='
```

For each global middleware in those vectors, ask whether it is correct for a request that matches
no route. Nitro's own middleware needs no change.

**Before → after** — a global auth middleware that should not turn unknown paths into 401s.
Scope it to the subtree it actually guards:

```julia
# before — fine only while unmatched requests never reached it
auth = handler -> function (req)
    isauthenticated(req) || return json(Dict("error" => "unauthorized"); status = 401)
    return handler(req)
end

# after — guard the paths it owns; everything else falls through to the router
auth = handler -> function (req)
    if startswith(req.target, "/api/") && !isauthenticated(req)
        return json(Dict("error" => "unauthorized"); status = 401)
    end
    return handler(req)
end
```

Alternatively, move it off the global list and attach it per route with
`path(...; middleware = [GuardMiddleware(login_required())])`, which never sees unmatched
requests at all.
