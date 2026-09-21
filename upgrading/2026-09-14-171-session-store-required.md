## `SessionMiddleware` requires an explicit `store`; the shared default store is gone (#171)

- **Version**: 0.4.0
- **Nitro ref**: #171 (follow-up to #36 / PR #168); `src/middleware/session_middleware.jl`,
  `src/middleware/csrf_middleware.jl`, `src/types.jl`, `src/Nitro.jl`, `docs/src/index.md`,
  `docs/src/tutorial/`, `README.md`, `.github/skills/nitro-usage/`
- **Recorded**: 2026-09-14
- **Severity**: **breaking, and it fails LOUDLY** — omitting `store` is an `UndefKeywordError`
  at construction, before a single request is served. There is no configuration in which the
  old call quietly keeps working. An app that already passes `store=` needs **no edit at all**;
  the entire Nitro test suite was in that position, which is why this break costs nothing to
  take now.

### What changed

`SessionMiddleware`'s `store` keyword defaulted to a module-level
`const DEFAULT_STORE = MemoryStore{String, Dict{String,Any}}()`. That constant was a
**process-wide mutable session table**, so every `SessionMiddleware()` built without `store=`
shared it — including middlewares belonging to different `App`s. Since #31 made `App` an
ordinary object that several instances can coexist as, that meant two independent applications
in one process silently shared a session table, and two tests that both forgot `store=` leaked
sessions into each other with no way to reset between them (the binding was `const`).

#36 made it worse in a way nothing yet depends on: each `SessionMiddleware` activation owns its
own prune janitor, so N default-constructed middlewares meant N janitors sweeping one shared
store on N independent intervals. Nothing was incorrect — pruning is idempotent — but the
ownership was unstateable.

`store` is now a **required keyword** with no default, so there is no implicit global left to
share. This is the same correction #31 applied to `CONTEXT[]`: a process-wide singleton replaced
by a value the caller owns.

Two supporting additions, both purely additive:

- `MemoryStore()` — a zero-argument constructor for `MemoryStore{String, Dict{String,Any}}`,
  which is exactly the type `SessionMiddleware` pins `store` to. Each call builds a separate
  table.
- `MemoryStore` and `AbstractSessionStore` are now **exported from `Nitro`**. They were exported
  from `Nitro.Types` but never re-exported at the top level, so `using Nitro; MemoryStore` was
  an `UndefVarError` — which also means the in-memory example in
  `docs/src/tutorial/sessions_and_auth.md` never ran as written. A required `store` has to be
  satisfiable without reaching into `Nitro.Types`.

### How to find the calls to migrate

```bash
# 1. Every construction site. Most are multi-line, so match the opening paren and read the
#    following lines -- a single-line regex misses the common form.
grep -rn "SessionMiddleware(" --include=*.jl .

# 2. Of those, the ones that are already fine: they name a store.
grep -rn -A8 "SessionMiddleware(" --include=*.jl . | grep "store *="

# 3. The zero-argument form, which is always broken now.
grep -rnE "SessionMiddleware\(\s*\)" --include=*.jl .

# 4. If you reached the old shared default deliberately, this finds it. The name is removed,
#    so any hit is a compile error waiting to happen.
grep -rn "DEFAULT_STORE" --include=*.jl .
```

### Before → after

The zero-argument form, and any call that omitted `store`:

```julia
# before -- silently shared one process-wide table with every other such call
serve(middleware = [SessionMiddleware()])

# after -- the app owns its store
store = MemoryStore()
serve(middleware = [SessionMiddleware(store = store)])
```

Keyword calls that set cookie attributes but no store:

```julia
# before
SessionMiddleware(cookie_name = "nitro_session", max_age = 3600, secure = true)
# after
SessionMiddleware(store = MemoryStore(), cookie_name = "nitro_session",
                  max_age = 3600, secure = true)
```

Already passing a store — **no edit needed**, in either the database or the in-memory case:

```julia
store = pormg_nitro_session(db_key = "db")
serve(middleware = [SessionMiddleware(store = store)])
```

If you were relying on two middlewares sharing the default store — for example a session
middleware and a `SessionPruner` in the same process — pass them *the same* store explicitly,
which is what the old code was doing implicitly:

```julia
# after -- the sharing is now visible in the source
store = MemoryStore()
serve(middleware = [SessionMiddleware(store = store),
                    SessionPruner(store; interval = Minute(5))])
```

Finally, you can drop the `Nitro.Types.` qualifier if you were using one:

```julia
# before
store = Nitro.Types.MemoryStore{String, Dict{String,Any}}()
# after
store = MemoryStore()
```
