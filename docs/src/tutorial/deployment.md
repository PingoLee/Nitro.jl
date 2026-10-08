# Running in Production

This page is about the Julia process itself: how many threads to give it, how much memory to
tell its garbage collector it has, and what its first requests cost. What sits in *front* of that
process — TLS, static assets, body caps, the real client IP — is covered in
[Behind a Reverse Proxy](reverse_proxy.md).

## HTTP/1.x only

`serve` listens in plaintext and speaks **HTTP/1.x only**. A client that opens a connection with
the cleartext HTTP/2 (h2c) preface is answered `400` and disconnected. No browser speaks h2c, so
the only clients this turns away are ones configured for it on purpose. HTTP/2 and TLS belong at
the reverse proxy, which should talk HTTP/1.1 to Nitro. nginx's `proxy_pass` never speaks HTTP/2
upstream (keep the `proxy_http_version 1.1` from [Behind a Reverse Proxy](reverse_proxy.md): its
default is 1.0, which loses keep-alive). Proxies and platforms that can be told to use HTTP/2
upstream need that turned off: Caddy's `versions h2c` transport option, an Envoy cluster with
HTTP/2 protocol options, Cloud Run's "end-to-end HTTP/2".

h2c is refused rather than served because Nitro's request handling, and HTTP.jl's HTTP/2 server
under it, were not safe on it. For example, a `413` or `503` refusal on an HTTP/2 stream could not
bound its wait for a body that never arrives, and so could hold a `max_concurrent_requests` slot
forever ([#375](https://github.com/PingoLee/Nitro.jl/issues/375)).

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
*interactive* thread, in a pool of its own: `--threads=8` means 8 default threads **and** 1
interactive one. HTTP.jl runs its accept loop and every connection's task there, reading each
request's head before handing it on. With the default `parallel = true`, Nitro starts every
request on its own task in the default pool, so no handler runs on the interactive thread.

A process with no GC target prints `GC target: none`. When the environment is `prod`
(`NITRO_ENV=prod`), `serve` also logs a warning about it at startup, even with
`show_banner = false`, so it reaches your log alerting. Nothing refuses to start and nothing is
set for you: the banner and the warning only report what the process was started with.

`--threads=auto` means one thread per CPU (on Linux and Windows, per CPU the process's affinity
mask allows). Julia also sizes its parallel
GC to the same number unless you pass `--gcthreads`, so the thread count reaches the collector as
well as the handlers. Pin an explicit number (`--threads=8`) when the process shares its host.
Leave `--gcthreads` at that default on a host of its own: Julia's collector stops every handler
while it marks the heap, so the more threads share the marking, the shorter that pause. Lower it
only when the CPUs it would use belong to something else.

### Do not turn off `parallel`

`serve(parallel = false)` skips the per-request task: each handler runs on its connection's task,
on the interactive thread. The whole server then handles requests on the interactive pool alone
(**one** thread unless `--threads=N,M` raised it), however many default threads `--threads` gave
it.
Go can serve a connection's requests on that connection's goroutine and still use every core,
because goroutines run on all of them; HTTP.jl's connection tasks run only on the interactive
pool, so in Julia the per-request task is what reaches the other threads. When the process has
more than one default thread and an interactive one, `serve(parallel = false)` logs a warning
saying so.

### The interactive thread

For N above 1, `--threads=N` is short for `--threads=N,1`: the second number is the interactive
pool. (`--threads=1` gives it none, and so does `--threads=N,0`; HTTP.jl then runs its connection
tasks in the default pool, and what follows does not apply.) Every
request passes through that pool once, for HTTP.jl to read its head and for Nitro to start its
task, so at a high enough request rate the one interactive thread is the bottleneck while the
default threads wait for work. Handler cost decides where that happens. A route that does real
work (a database query, a template) runs into the default pool's limit first, and a second
interactive thread changes nothing. Small, fast responses at tens of thousands of requests per
second hit the interactive thread first.

On one machine, with the server pinned to 4 cores (8 logical CPUs) and serving a minimal route
(Julia 1.12.7, `bench/socket/run.sh`), `--threads=8,2` served roughly a quarter to a half more
requests per second than `--threads=8`, and HTTP.jl on its own moved the same way. If load
tests show the default threads idle while throughput stops climbing, try `--threads=N,2` and
measure; there is no reason to raise it otherwise.

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

### What the process costs at rest

A Julia server holds a few hundred MiB before it holds any request data: the runtime, its
system image, LLVM's compiler, and the compiled code of every package it loaded. Measured
resident memory (RSS), on Julia 1.12.7, Linux x86-64, `--threads=8`, rounded to
5 MiB:

| Process | At rest | After one request per route | After 60 s of load |
|---|---|---|---|
| `julia`, no packages loaded | 245 MiB | — | — |
| HTTP.jl serving three routes, Nitro not loaded | 380 MiB | 405 MiB | — |
| Nitro `serve()`, no middleware | 450 MiB | 465 MiB | 490 MiB |
| Nitro `serve()` with PormG loaded | 625 MiB | 645 MiB | 650 MiB |

These are floors, not totals: your own code, your other dependencies (a database driver, a
template engine), and the data your handlers hold come on top. The load was `oha` at 50
connections against a small JSON route; `bench/socket/rss.sh` reproduces the table on your
machine. PormG was loaded without a database connection, so a live driver adds to its row.

Two things the table says about sizing:

- **The floor does not grow with traffic.** The rise after load is the first requests' compiled
  code and the GC's working room, and it stops there: the same load rose about 30 MiB above the
  warm reading whether it ran for 60 seconds or for 180. Memory that keeps climbing under steady
  load is your data, not the floor; see [After an unexplained kill](@ref).
- **`--threads` does not multiply it.** The same server measured within 15 MiB at
  `--threads=1` and `--threads=8`. Threads add request *capacity*; what they cost in memory is the
  data the extra concurrent requests hold, which is the next section.

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
headroom, and at least 250 MiB below whatever limit the host or cgroup enforces. That
steady state starts from the floor above, so a container limit of 512 MiB is too small for any
Nitro process, and one of 1 GiB leaves only about half of it for your code and data.

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
before its body is read, and its connection is then closed. A request holds its slot while its
body is read, its handler runs and its response is written to the socket. That includes a streamed
`Res.file`: it is sent in 64 KiB chunks, so it holds one chunk of memory rather than the file, but
it keeps its slot until the last chunk is written — a slow client downloading a large file holds a
slot for the whole transfer. Only a response with no length — `Res.sse` — gives its slot back once
it starts streaming, because it has no end the server controls and can stay open for hours. A
`STREAM` handler holds its slot for its whole lifetime, so leave room for those in the number.

A **WebSocket** holds its slot for its whole lifetime too, unless you give WebSockets a budget of
their own. A few hundred idle chat or notification sockets would otherwise fill the cap while using
almost no memory, and every ordinary request would get a `503`:

```julia
# Up to 64 ordinary requests in flight, and up to 1000 open WebSockets besides
serve(app; max_concurrent_requests = 64, max_upgraded_connections = 1000)
```

With `max_upgraded_connections` set, an upgrade takes a slot of that budget before the handshake
and gives its request slot back once the `101` is sent — the split ASP.NET Core's Kestrel makes
between `MaxConcurrentConnections` and `MaxConcurrentUpgradedConnections`. When the budget is full
the upgrade is answered `503` with `Retry-After: 1`, and no `101`. That refusal comes from the
route's handler, after your middleware, so it appears in the access log and a request your auth
refuses never takes a slot. A `STREAM` handler is not an upgrade and stays on the request cap: it
has no moment at which it turns from a request into a long-lived connection. Nor does a handshake
that carried a request body: the body stays reachable from the handler for the socket's life, so
that socket keeps its request slot as well.

The budget bounds how many sockets are open, not what each one holds. An idle socket costs little,
but a message a client sends is buffered whole, up to HTTP.jl's frame and fragment limits, which
Nitro does not currently lower — and messages your handler has not read yet queue without a limit,
so a handler that falls behind a fast client lets that one socket grow.

The cap bounds how many requests are held, not for how long. With `read_timeout` off (the default),
a client that sends a head and then trickles its body holds a slot as long as it likes, and without
`write_timeout` so does one that stops reading its response; a handful of such clients can hold
every slot, and everyone else gets `503`s. Behind nginx with its default request and response
buffering, Nitro never sees a slow client. **Exposed directly, set both timeouts with the cap:**

```julia
serve(app; max_concurrent_requests = 64, read_timeout = 60, write_timeout = 30)
```

`write_timeout` bounds each write to the socket, which is not the same unit for every response. A
streamed file — `Res.file(...; stream = true)`, or a mounted file over `stream_threshold` — writes
once per 64 KiB chunk, so however large the file, only a client that takes longer than
`write_timeout` to accept one chunk is cut — about 2 KiB/s at `write_timeout = 30`. An
`Res.sse` stream writes once per event, so only an event that stalls is cut. An in-memory response
with a length (`Res.json`, `Res.send`, a buffered `Res.file`) goes out on HTTP/1.1 as **one** write
at the end, so for it the timeout bounds the whole transfer: size it for your largest such response
to your slowest client.

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

## Cold start

Julia compiles a method the first time it runs with a given set of argument types, so the first
request a fresh process serves pays for compiling the code it reaches. On a default
`serve()` with one plain route (Julia 1.12.7, `bench/socket/first_request.sh`), the first request
took about **1 second** and the second about half a millisecond. Most of that second is paid
once per process; every route your app adds then pays its own, smaller share the first time it
is hit, and so does a middleware stack other than the default one.

Nitro already ships what it can: its `PrecompileTools` workload (`src/precompile.jl`) runs the
router, the serializer, the typed extractors and static and SPA mounts while the package
precompiles, and compiles (without running) the transport layer of a default `serve()` — no
`middleware`, the access log on — so that code is cached with Nitro itself. What it cannot reach
is HTTP.jl's own connection loop, which only a live socket drives, a transport with any other
middleware stack, and your application's handlers.

That matters wherever a fresh process takes traffic at once: a deploy, a restart after a crash,
an autoscaled replica. Two remedies, in order of effort:

- **Warm it before it takes traffic.** Start the new process, request your important routes
  from the same host (a health check that touches them, or a short script), and only then let
  the proxy or the orchestrator route to it — a Kubernetes readiness probe, or starting the new
  unit before stopping the old one. Each route compiles once per process, so this costs seconds
  at startup and nothing after.
- **Build a system image** with [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl),
  giving it a precompile script that exercises your routes over a real socket. The compiled code
  is then in the image the process starts from, including the HTTP.jl paths the workload above
  cannot reach. It costs a build step, an image to rebuild whenever a dependency changes, and a
  larger file to ship.

Either way, measure the first request on the target machine; a laptop with a warm package cache
says little about a fresh container.
