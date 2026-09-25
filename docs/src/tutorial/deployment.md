# Running in Production

This page is about the Julia process itself: how many threads to give it and how much memory to
tell its garbage collector it has. What sits in *front* of that process — TLS, static assets,
body caps, the real client IP — is covered in [Behind a Reverse Proxy](reverse_proxy.md).

## Threads

`serve()` runs every request on its own `Threads.@spawn` task in Julia's default thread pool. There
is no event loop and no cluster of worker processes; the thread count is how many requests can
**compute** at once. (How many can be *in flight* at once is a different number, bounded only if
you set `serve(max_concurrent_requests = …)`; see [Sizing it](@ref) below.) Start the server with
it set:

```bash
julia --threads=auto --project -e 'using MyApp; MyApp.start_server()'
```

A bare `julia` starts with **one** default thread, so a CPU-bound handler holds up every other
request until it returns. The startup banner prints what you got, along with the GC target
covered in [Memory and GC](@ref) below — check it on the target machine, not on your laptop:

```
 Nitro <version>  (parallel mode: 8 threads + 1 interactive, GC target 2.8 GiB)
```

The thread count is the default pool, where handlers run. Julia 1.12 also starts one
*interactive* thread; HTTP.jl accepts connections there, and no handler ever runs on it.

A process with no GC target prints `GC target: none`. When the environment is `prod`
(`NITRO_ENV=prod`), `serve` also logs a warning about it at startup, even with
`show_banner = false`, so it reaches your log alerting. Nothing refuses to start and nothing is
set for you: the banner and the warning only report what the process was started with.

`--threads=auto` means one thread per CPU (on Linux and Windows, per CPU the process's affinity
mask allows). Julia also sizes its parallel
GC to the same number unless you pass `--gcthreads`, so the thread count reaches the collector as
well as the handlers. Pin an explicit number (`--threads=8`) when the process shares its host.

## Memory and GC

Set a heap-size hint on every server process, and size it on purpose:

```bash
julia --threads=auto --heap-size-hint=3G --project -e 'using MyApp; MyApp.start_server()'
```

### What Julia does without one

The garbage collector steers by a target heap size. Unless something sets that target, **there
isn't one**: on Julia 1.12 and 1.13, with no hint and no container limit, the GC's ceiling is
2 PiB. How soon
it collects is then governed only by its own growth heuristics, and nothing about the machine
tells it to try harder as memory runs out. A server whose live data is a few GB can keep growing
until the kernel's OOM killer ends it, and on a host shared with other services that killer may
pick one of *them* first.

Three things set the target, and the first one present wins:

| Source | Example | Notes |
|---|---|---|
| `--heap-size-hint` | `--heap-size-hint=3G` | Accepts `K`, `M`, `G`, `T`, or `%` |
| `JULIA_HEAP_SIZE_HINT` | `Environment=JULIA_HEAP_SIZE_HINT=3G` | Same syntax, read when the flag is absent. The only option when you do not control the command line |
| A cgroup memory limit | systemd `MemoryMax=`, `docker run --memory`, a Kubernetes `resources.limits.memory` | Read **automatically** when neither of the above is set |

So a container or a systemd unit with a memory limit already gets a sensible GC target without a
hint. `%` is also measured against that limit: inside a 4 GiB cgroup, `--heap-size-hint=75%` means
3 GiB, whatever the host has. `julia --help` and the Julia manual say "physical memory", but the
implementation uses the cgroup limit when there is one; reported upstream as
[JuliaLang/julia#63337](https://github.com/JuliaLang/julia/issues/63337).

### Sizing it

The GC reserves **250 MiB** of the hint for memory it does not manage (LLVM, C libraries), aims the
heap at the remainder, and starts collecting hard at about 80% of that. Two consequences:

- **Too low is worse than none.** When the target sits below your live set, every collection
  finds nothing to free and the next allocation triggers another one. The process does not
  crash; it stops making progress. Measured on Julia 1.12: a job with ~190 MiB of live data under
  `--heap-size-hint=400M` (a working target of ~120 MiB) ran 1,246 full collections and did not
  finish, where the same job with no hint took 14 seconds.
- **Size it from peak concurrent load, not idle memory.** Every in-flight request holds its own
  live data, and `--threads` does **not** limit how many are in flight. HTTP.jl starts a task per
  connection and Nitro one per request, and a task waiting on a slow body yields its thread to the
  next request. So unless you cap it, the bound is open connections, not threads. With the 64 MiB
  `serve(max_body_bytes = …)` default, 200 concurrent uploads can hold ~12.8 GB of request bodies
  before any handler allocates anything. That memory is **live**, so no hint reclaims it.

A workable starting point: the hint at the steady-state RSS you observe under realistic load plus
headroom, and at least 250 MiB below whatever limit the host or cgroup enforces.

### Bounding requests in flight

Three settings look related to request memory, and only one of them bounds how much of it is live
at once:

| Setting | Bounds | Does not bound |
|---|---|---|
| `--heap-size-hint` | When the GC works hard | Live data — the GC cannot free a body a request is still holding |
| `serve(max_body_bytes = …)` | One request's body | How many of them are held at once |
| `serve(max_concurrent_requests = …)` | How many requests are held at once | The size of each — that is `max_body_bytes`, and body memory is at most the product of the two |

`max_concurrent_requests` is off by default, like Go's `net/http`. Set it to a number of requests
your memory can hold at once, `max_body_bytes` each, with the hint's headroom left over:

```julia
# 3 GiB of hint, uploads up to 16 MiB: at most 64 × 16 MiB = 1 GiB of bodies in flight
serve(app; max_body_bytes = 16 * 1024^2, max_concurrent_requests = 64)
```

A request that arrives with the limit already in flight is answered `503` with `Retry-After: 1`
before its body is read, and its connection is closed. Each HTTP/2 stream counts as one request.
A request holds its slot while its body is read, its handler runs and a buffered response is
written. A streaming response (`Res.sse`, a streamed `Res.file`) gives the slot back once it starts
streaming, because it holds little memory and can stay open for hours. A **WebSocket** holds its
slot for its whole lifetime, and so does a `STREAM` handler, so leave room for those in the
number.

In front of Nitro, nginx's `max_conns` on the `upstream` block's `server` line is the proxy-side
equivalent. Open-source nginx has no queue behind it, so requests over its limit get a `502`
rather than waiting.

### systemd

A hint and a cgroup limit do different jobs. The **hint** tells the GC where to aim. The **cgroup**
is the wall: it bounds the whole process, including memory the GC never sees, and it confines an
out-of-memory kill to this unit instead of letting the kernel choose a victim host-wide.

```ini
# /etc/systemd/system/myapp.service
[Service]
Environment=NITRO_ENV=prod
Environment=JULIA_HEAP_SIZE_HINT=3G
ExecStart=/usr/local/bin/julia --threads=auto --project=/srv/myapp -e 'using MyApp; MyApp.start_server()'
MemoryMax=4G
Restart=on-failure
```

Keep the hint below `MemoryMax=`, with room for everything outside the Julia heap.

!!! warning "The hint is a target, not a limit"
    Neither the hint nor the cgroup makes Julia throw an `OutOfMemoryError` when the heap outgrows
    it. The GC collects harder and then keeps allocating: the source calls the target "a
    suggestion" that it "will go above … rather than halting". A genuine leak still ends in a
    `SIGKILL` from the kernel, with no Julia backtrace, **whether or not a hint is set**. Verified
    on Julia 1.12: a leaking process with `--heap-size-hint=400M` inside a 700 MiB cgroup exited
    137, with nothing printed.

    What the hint removes is the *other* cause of that kill: a heap that grew because nothing asked
    the GC to collect, not because the live data needed the room.

### After an unexplained kill

The process vanished, the application log just stops, and there is no stack trace. Confirm it was
memory first. The kernel recorded it:

```bash
systemctl status myapp          # "Failed with result 'oom-kill'" when the cgroup limit fired
journalctl -k | grep -i oom     # the kernel's own record, naming the killed process
```

Then work out which of the two causes it was:

1. **If no hint and no cgroup limit were set**, add both and reproduce. If the process now holds
   steady, the heap was growing because nothing bounded it, and the fix is the configuration
   above.
2. **If it still dies, the live data really is growing.** A kill leaves nothing behind, so collect
   the evidence while the process is still alive. `GC.enable_logging(true)` prints a line for
   every collection. A periodic `@info` of `Base.gc_live_bytes()` and `Sys.maxrss()` shows which
   one is climbing: live bytes rising means something is holding references (a cache, a session
   store, a module-level collection); RSS rising while live bytes stay flat points outside the
   Julia heap.
