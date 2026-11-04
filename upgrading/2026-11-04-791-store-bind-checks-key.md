## `PormGSessionStore` / `PormGWorkerStore` — a store refuses a `db_key` that is not loaded when it is built, not at its first query

- **Version**: Unreleased
- **Nitro ref**: #791 (item 1), #839, #841 ; `ext/NitroPormGExt.jl` (`_bind_model!`)
- **Recorded**: 2026-11-04
- **Severity**: behavior change. An app that loads its connections before it builds its stores, as
  the generated boot and `docs/src/tutorial/bigger_applications.md` do, needs no edit.

### What changed

A store that builds its own model binds that model to `db_key`. That bind used to assign
`model.connect_key = db_key` and accept any string. It now goes through
`PormG.Models.bind!` (PormG 0.9), which resolves the key first and then refuses a key that is
still not loaded, with an `InvalidConfigurationError` that names it.

| call, with `k` not loaded | before | now |
|---|---|---|
| `pormg_nitro_session(db_key = k)`, `pormg_nitro_worker(db_key = k)` | failed at construction with a bare `KeyError` | fails at construction with `InvalidConfigurationError` naming `k` |
| `PormGSessionStore(db_key = k)`, `PormGWorkerStore(db_key = k)`, built without `model =` | constructed; the failure came at the first query, or never, if the key was loaded before that | **refused at construction** |

The second row is the edit an app may owe. A store built before its connection was loaded used to
work as long as `load_many` ran before the first query. That covers a `const` store in a module
body, a store built in `main()` above the `load_many`, and one built in a test's setup before the
key is registered. Each now throws at the construction line.

Two things do not need an edit. A key a connection resolver serves (`PormG.set_connection_resolver`)
is now resolved at the bind, where before it was never resolved; that is a gain. A store built with
`model =` uses that model as given and skips the check, as before.

### How to find the calls to migrate

```
grep -rnE 'PormG(Session|Worker)Store\(|pormg_nitro_(session|worker)\(' --include=*.jl .
grep -rn 'KeyError' --include=*.jl . | grep -i -E 'session|worker|store'
```

For each hit of the first grep, check that its key is loaded (`load_many`, `load`, or a resolver)
**before** the line runs. For each hit of the second, check that no `catch` expects a `KeyError`
from a store or factory call: it is an `InvalidConfigurationError` now.

### Migrate your app

```julia
# ✗ before: the store is built before its connection is loaded
const SESSIONS = PormGSessionStore(db_key = "db")      # module body
function main()
    PormG.Configuration.load_many(["db"]; root, env)
    serve(app; middleware = [SessionMiddleware(store = SESSIONS)])
end

# ✓ after: build it in main(), after the load
function main()
    PormG.Configuration.load_many(["db"]; root, env)
    sessions = pormg_nitro_session(db_key = "db")
    serve(app; middleware = [SessionMiddleware(store = sessions)])
end
```
