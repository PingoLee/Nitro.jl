## `PormGSessionStore` routes every query to its `db_key` (#199)

- **Version**: 0.4.0
- **Nitro ref**: #199; `ext/NitroPormGExt.jl`, `src/exts.jl`,
  `docs/src/tutorial/sessions_and_auth.md`, `docs/src/tutorial/cookies/sessions.md`,
  `test/extensions/pormg_session_tests.jl`
- **Recorded**: 2026-09-15
- **Severity**: **behaviour, and it changes which database your sessions live in.** No source
  edit is forced and the `"db"` default is unchanged. But PormG-backed sessions were broken
  outright for any app with more than one PormG connection loaded, so for those apps this is a
  repair rather than a re-routing — and where sessions land moves either way.

### What changed

`pormg_nitro_session(; db_key="db")` accepted a `db_key`, used it to create `nitro_session`, and
then threw it away. `PormGSessionStore` had no `db_key` field, and all four query sites —
`Base.get`, `set_session!`, `delete_session!`, `cleanup_expired_sessions!` — called
`model.objects` directly.

That is *not* "wrote to the wrong database", which is what it looks like. `_define_session_model()`
builds the session model with a bare `PormG.Models.Model` and never passes it to `set_models`, so
the model carries no connection binding. PormG resolves an unbound, unrouted query as *the sole
loaded connection if there is exactly one, otherwise `InvalidConfigurationError`*. So:

- **One PormG connection loaded** — queries resolved to it by accident and sessions worked,
  whatever `db_key` said.
- **Two or more loaded** — **every session query threw**, `db_key` irrelevant. `Base.get` and
  `cleanup_expired_sessions!` catch and swallow, so reads degraded to "no session" with one
  `@warn` each: users silently logged out on every request, and the prune silently never ran.
  `set_session!` and `delete_session!` rethrow, so writes surfaced as errors out of the request
  path.

`PormGSessionStore` now carries `db_key::String` (default `"db"`), `pormg_nitro_session` passes
its own key through, and every query routes through `_session_objects(store)` — the same shape
`PormGWorkerStore` has always used via `_task_objects`.

**One case this does not reach.** `db_key` routes the *query*; PormG's
`ensure_model_transaction_scope` gates on the *model's* binding, which is still unset. A session
query issued while a PormG transaction is active on the calling task therefore still raises —
swallowed on the read paths and propagated on the write paths, just as above — whatever `db_key`
says. `PormGWorkerStore` has the same gap. If you wrap session writes in
`run_in_transaction`, that is #202 — this entry does not fix it.

### How to find the calls to migrate

```bash
rg -n 'pormg_nitro_session|PormGSessionStore' <app>/src
```

Then check how many connections the app loads — `PormG.Configuration.load_many([...])`, or several
`load(...)` calls. One connection: nothing changes for you. Two or more: sessions were not working
before this release, and now are.

### Migrate your app

**If you call `pormg_nitro_session`, there is no code edit** — the call already names the key and
it is simply honoured now. The work is operational, not textual; see the two checks below.

The one real source edit is for apps that build the store by hand. `PormGSessionStore` is not
exported (`NitroPormGExt` exports only `PormGWorkerStore` and `pormg_nitro_worker`), so this is
reached through the extension module:

```julia
ext = Base.get_extension(Nitro, :NitroPormGExt)

# ✗ before — no way to say which connection; queries resolved only by accident, or threw
store = ext.PormGSessionStore(model = my_model)

# ✓ after — the keyword is additive and defaults to "db", so add it only if you need another
store = ext.PormGSessionStore(model = my_model, db_key = "sessions")
```

Two things to check once, at deploy:

1. **Point `db_key` at the connection the table is actually on.** If you worked around this by
   loading only one connection so the fallback picked it up, that key is now the one to pass.
2. **Rows written to the fallback connection are orphaned.** Sessions are short-lived and expiry
   is enforced on read, so the cost is a one-time logout rather than data loss — drop the stray
   `nitro_session` table on the connection that was never meant to hold it.
