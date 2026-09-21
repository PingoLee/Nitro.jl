## Worker stores implement `get_error_redactor` / `set_error_redactor!`, and stored error text is capped (#140)

- **Version**: 0.4.0
- **Nitro ref**: #140; `src/Workers/registry.jl`, `src/Workers/execution.jl`, `src/Workers/api.jl`,
  `src/Workers/queue.jl`, `ext/NitroPormGExt.jl`, `docs/src/tutorial/workers.md`
- **Recorded**: 2026-09-13
- **Severity**: **breaking for custom worker stores, and it fails LOUDLY** — a store without the
  two new methods raises `StoreInterfaceError` naming them. For apps using a shipped store this is
  a **behaviour** change only: a failed task's stored `error` is now truncated past
  `MAX_STORED_ERROR_CHARS`.

### What changed

A failed task's `error` is rendered from the exception the **application's** callback threw, and
exceptions quote their input. A callback that parses user-submitted data hands its parser's
`ArgumentError` the offending bytes, and those bytes reached the store — for `PormGWorkerStore`, a
`TEXT` column — with no cap, no redaction path, and nothing in the store docs warning that the
field is attacker-influenceable.

This is the same shape #130 closed on `ValidationError.cause`, at a different trust boundary. There
Nitro created the situation by deserializing a client payload, so Nitro owed the mask; here the
exception is the app's own, so the answer is a bound plus a hook rather than a blanket mask.

Three parts:

- `MAX_STORED_ERROR_CHARS` (2048) caps the stored text, counted in **characters** so truncation
  cannot split a codepoint. `format_error` is unchanged and still unbounded — it is exported, and
  capping it would have changed what every existing caller gets back.
- `get_error_redactor` / `set_error_redactor!` are new required `AbstractWorkerStore` methods,
  shaped exactly like the existing `queue_authorizer` / `watch_authorizer` pairs: a `Ref{Any}` slot
  invoked through `Base.invokelatest`. The redactor receives `(exception, rendered)` with the
  **full** text and its result is then capped. A redactor that throws is caught; the task still
  reports `FAILED` and the stored text degrades to the exception type.
- Retention was already bounded when cleanup is on (`worker_startup` defaults to
  `cleanup_enabled=true`, `cleanup_interval_hours=24`), so this closes the cap and the hook, not
  the lifetime.

### How to find the calls to migrate

```bash
# Custom worker stores owe the two new methods.
grep -rn "<: AbstractWorkerStore" --include=*.jl .

# Task callbacks that interpolate data into an exception are the ones this protects.
grep -rn "submit_task\|submit_sequential_task" --include=*.jl .
```

```julia
using Nitro.Workers
missing_store_methods(MyWorkerStore)   # :get_error_redactor / :set_error_redactor! in here
```

### Before → after

```julia
# BEFORE — no such hook; whatever the app threw was stored verbatim
struct MyWorkerStore <: AbstractWorkerStore
    # ...
    queue_authorizer::Ref{Any}
    watch_authorizer::Ref{Any}
end

# AFTER — one more slot, and the pair that reads it
struct MyWorkerStore <: AbstractWorkerStore
    # ...
    queue_authorizer::Ref{Any}
    watch_authorizer::Ref{Any}
    error_redactor::Ref{Any}
end

Nitro.Workers.get_error_redactor(store::MyWorkerStore) = store.error_redactor[]
function Nitro.Workers.set_error_redactor!(store::MyWorkerStore, redactor)
    store.error_redactor[] = redactor
    return redactor
end
```

An app whose task callbacks can carry user data into an exception message should also install one:

```julia
set_error_redactor!(store, (exc, rendered) -> string(nameof(typeof(exc))))
```
