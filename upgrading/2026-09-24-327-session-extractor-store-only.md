## `Session{T}` — reads only an `AbstractSessionStore{String}` app context

- **Version**: Unreleased
- **Nitro ref**: [#327](https://github.com/PingoLee/Nitro.jl/issues/327) ; `src/extractors.jl`,
  `src/types.jl`
- **Recorded**: 2026-09-24
- **Severity**: breaking — a `Session{T}` parameter whose app context is a `Dict`, a `NamedTuple`
  or any other non-store value now always binds no session (`payload === nothing`).

### What changed

The `Session{T}` extractor looked the session cookie's value up in the **app context**, and when
the context was not a session store it indexed it directly: `get(context, cookie_value, nothing)`.
That was meant for a `Dict` of sessions, but it made no difference what the `Dict` held. An app
whose context was its **configuration** — `serve(context = Dict("admin_defaults" => ...))` — let a
client pick any entry by name: `Cookie: session=admin_defaults` bound that entry as the session.
Without a cookie `secret_key` the cookie is plaintext, so the client chose the key freely.

The extractor now reads only a context that is an `AbstractSessionStore{String}`
(`MemoryStore`, `PormGSessionStore`, or your own), through `get_session`, which also applies the
expiry rule. Any other context binds no session, and Nitro logs one warning naming the context's
type. The raw-`SessionPayload` handling that went with the old fallback is gone too; a store's
payloads are unwrapped by `get_session`.

Two related changes ride along:

- A stored value that is **not a `T`** now binds no session. It used to reach the validator with
  the wrong type and answer **500** with a logged backtrace — for `Session{Any}` even when the
  value was fine. `Session{Any}` now binds whatever the store holds. The same fix covers the
  other extractors: `Body{Any}`, `Json{Any}` and `Cookie{Any}` bind too — the first two could
  not even be registered before.
- An ordinary exception from the store still binds no session, as before (#254).

### How to find the calls to migrate

```bash
# Routes that read Session{T} ...
rg -n 'Session\{' <app>/src

# ... and what the app hands in as the context. A Dict / NamedTuple / struct here is no longer read.
rg -n 'context\s*=' <app>/src <app>/test
```

### Migrate your app

```julia
# ✗ before — a plain Dict as the session store
sessions = Dict{String, User}()
sessions[sid] = user
serve(context = sessions)

# ✓ after — a MemoryStore (which also expires entries) behind the same extractor
sessions = MemoryStore{String, User}()
Nitro.Types.set_session!(sessions, sid, user; ttl = 3600)
serve(middleware = [SessionPruner(sessions)], context = sessions)
```

An app whose context is configuration and that never meant it as a session store needs no change:
its `Session{T}` parameters were never meant to bind, and now they cannot.
