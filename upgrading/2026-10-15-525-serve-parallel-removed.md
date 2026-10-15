## `serve(...; parallel=...)` is removed — every request always runs on its own task (#525)

- **Version**: 0.6.0
- **Nitro ref**: [#525](https://github.com/PingoLee/Nitro.jl/issues/525) ; `src/core/lifecycle.jl`
- **Recorded**: 2026-10-15
- **Severity**: **breaking (removed kwarg)** — a `serve` call that still passes `parallel` no
  longer starts.

### What changed

`serve(; parallel = true)` was the per-request `Threads.@spawn` that moves each handler off
HTTP.jl's connection task. That spawn is now unconditional, and the keyword is gone. `parallel =
false` made the server slower in every thread layout it was measured in. Under the default
`--threads=N` (`N,1`), every handler ran on the single interactive thread whatever `-t` said. With
no interactive pool (`--threads=N,0`), it served 4–9% fewer requests per second, with a higher p99
(#492). The warning that talked users out of it (#454) is gone with it.

There is no compatibility shim. The keyword now falls through to HTTP.jl's `listen!`, so `serve`
throws a `MethodError` at startup that names it, and binds nothing:

```
MethodError: no method matching listen!(...; ..., parallel::Bool, ...)
... got unsupported keyword argument "parallel"
```

The startup banner no longer says `parallel mode:`. It reads ` Nitro <version>  (8 threads + 1
interactive, GC target 2.8 GiB)`. Update anything that parses the banner.

### How to find the calls to migrate

```bash
rg -n '\bparallel\b\s*[=,)]' <app>/src <app>/test <app>/bin   # also the `serve(...; parallel)` shorthand
rg -n 'unsupported keyword argument "parallel"' <app's startup log>
```

### Migrate your app

```julia
# ✗ before
serve(app; host = "0.0.0.0", port = 8080, parallel = true)
serve(app; host = "0.0.0.0", port = 8080, parallel = false)

# ✓ after — delete the argument
serve(app; host = "0.0.0.0", port = 8080)
```

If `parallel = false` was there to keep handlers that are not thread-safe from running
concurrently, say so for the whole process instead: start it with `julia --threads=1`.
