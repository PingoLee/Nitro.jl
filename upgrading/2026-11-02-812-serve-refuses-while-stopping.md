## `serve(app)` is refused until `terminate(app)` has returned

- **Version**: Unreleased
- **Nitro ref**: #812 ; `src/core/lifecycle.jl` (`serve`, `terminate`), `src/context.jl`
  (`Service.phase`)
- **Recorded**: 2026-11-02
- **Severity**: behavior change. A `serve` that used to succeed while the same app's `terminate`
  was still draining now throws an `ArgumentError`. Code that serves an app only after its
  `terminate` has returned is unaffected.

### What changed

`terminate` releases the port as soon as its drain begins. A `serve` of the same `App` called
from then on used to pass the already-serving guard, and the run being stopped then ran its
`on_stopped` hooks while the new run was serving. Those hooks release what a request may still
be using: `pormg_nitro_pools` closes the app's connection pools, under the queries the new run had
already started.

`serve` now refuses the app until `terminate` has returned, its last `on_stopped` hook included,
with an `ArgumentError` that says the app is still stopping. It is refused the same way while
another `serve` of the app is still starting. A second `App` in the same process is not affected.

Two smaller changes come with it:

- A `terminate` called while another `terminate` of the same app is running returns at once. It
  used to run every shutdown hook a second time.
- A `serve` that fails before its listener is up (an address already in use) no longer leaves its
  `serve(middleware = …)` lifecycle registered, so the next `serve` does not start that list
  alongside its own.

### How to find the calls to migrate

```
grep -rnE '(@spawn|@async|Task\().*terminate\(' src/ test/
```

A hit is a `terminate` that runs on a task of its own (a `terminate` inside a multi-line task body
needs `grep -rn 'terminate(' src/ test/` and a look at each call). Check whether a `serve` of the same app
can run before that task has finished, for example a restart loop that stops the app on one task
and serves it again on another.

### Migrate your app

```julia
# ✗ before: the new run starts while the old one is still draining
stopping = Threads.@spawn terminate(app)
serve(app; async = true, port = 8081)          # now an ArgumentError: the app is still stopping

# ✓ after: wait for the old run to finish stopping
stopping = Threads.@spawn terminate(app)
wait(stopping)
serve(app; async = true, port = 8081)
```

To run two servers at the same time, give the second one its own `App`.
