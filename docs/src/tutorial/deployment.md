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
 Nitro <version>  (8 threads + 1 interactive, GC target 2.8 GiB)
```

The thread count is the default pool, where handlers run. Since 1.12, Julia also starts one
*interactive* thread, in a pool of its own: `--threads=8` means 8 default threads **and** 1
interactive one. HTTP.jl runs its accept loop and every connection's task there, reading each
request's head before handing it on. Nitro then starts every request on its own task in the
default pool, so no handler runs on the interactive thread.

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

### Every request gets its own task

The per-request task is not optional: `serve` has no keyword to turn it off. Go can serve a
connection's requests on that connection's goroutine and still use every core, because goroutines
run on all of them; HTTP.jl's connection tasks run only on the interactive pool, so in Julia the
per-request task is what reaches the other threads. Without it the whole server would handle
requests on the interactive pool alone (**one** thread unless `--threads=N,M` raised it), however
many default threads `--threads` gave it.

It pays with no interactive pool (`--threads=N,0`, below) too, where the connection tasks already
run on every default thread: on the machine measured below, skipping it at `--threads=8,0` served
4–9% fewer requests per second, with a higher p99.

If your handlers are not thread-safe, say so for the whole process: start it with `--threads=1`.

### The interactive thread

For N above 1, `--threads=N` is short for `--threads=N,1`: the second number is the interactive
pool. (`--threads=1` gives it none.) Every request passes through that pool once, for HTTP.jl to
read its head and for Nitro to start its task, so at a high enough request rate the one
interactive thread is the bottleneck while the default threads wait for work. Handler cost decides
where that happens. A route that does real work (a database query, a template) runs into the
default pool's limit first, and the interactive thread changes nothing. Small, fast responses at
tens of thousands of requests per second hit the interactive thread first.

`--threads=N,0` removes the interactive pool. HTTP.jl then runs its connection tasks in the
default pool, spread over every thread, the way Go places goroutines. On one machine, with the
server pinned to 4 cores (8 logical CPUs) and serving a minimal route (`bench/socket/run.sh` and
`bench/socket/contention.sh`, Julia 1.12.7 and 1.13.1 alike):

| | `--threads=8` (`8,1`) | `--threads=6,2` | `--threads=8,0` |
|---|---|---|---|
| Requests per second at saturation | 1× | about 1.4× | about 1.7× |
| p99 at a fixed rate well below saturation | about 1–2 ms | lowest, under 1.5 ms | about 2.5–4 ms |
| A cheap route while CPU-bound handlers or jobs fill the default threads | delayed | delayed most | delayed |

The last row is what the interactive thread does **not** do. Nitro starts every handler on the
default pool whatever the layout, so the interactive thread can accept a connection and read its
head while the default threads are busy, but the handler then waits for a default thread like any
other. A cheap health check behind handlers that each compute for 50 ms took as long at `8,1` as
at `8,0`, and longest at `6,2`, which has the fewest default threads to compute on. The same
holds for background jobs: [Workers](workers.md) runs them on the default pool too.

So:

- **Throughput-bound** (load tests show the default threads idle while throughput stops climbing):
  try `--threads=N,0`, with N the number of CPUs the process may use, and measure. Expect one to
  three milliseconds more at p99.
- **Latency-bound**: keep the interactive pool and give it a second thread within the same total,
  `--threads=N-2,2`. That had the lowest p99 in nearly every fixed-rate run.
- **CPU-bound handlers or jobs**: no layout protects the other requests from them, because Julia
  does not preempt a task that computes without yielding (measured in
  [Handlers that compute](@ref) below). Bound them instead, so some default
  threads stay free for requests: run CPU-heavy Workers jobs through a declared queue with a
  concurrency below the default thread count, such as `queues = ["compute" => max(N - 2, 1)]`
  (`submit_queued_task`), which runs at most that many at once and buffers up to 100 behind them
  (see [CPU-Bound Jobs](@ref)), or put a `yield()` inside a long loop (on Julia 1.13.0
  through 1.13.2, see the caveat in [Handlers that compute](@ref)).
  `max_concurrent_runs` does not make jobs wait: past it, `submit_task` refuses them.

**Stopping it.** `--threads=N,0` is a production layout, for a process stopped by its supervisor.
It is a worse one to press Ctrl-C at. In a REPL, Julia throws the interrupt into the task that last
waited on thread 1. With an interactive thread, thread 1 runs no handlers and none of Nitro's
background loops, and in the runs above the press behaved the same every time: ignored while the
server was saturated, then the next press, once idle, stopped `serve` cleanly. At `--threads=8,0`
thread 1 also runs handlers and background tasks (the session janitor, the Workers retention
scheduler), and the same press under load stopped `serve` at once in some runs, needed a second
press in most, and ended the whole Julia session in 2 of 10. Develop at the default layout, and
stop a production server with `terminate` or its process supervisor rather than Ctrl-C (see
`serve`'s docstring).

### Handlers that compute

A task gives up its thread only when it waits: on I/O, a lock, a `sleep` or a `yield()`. Julia
does not preempt one, so a handler that computes for 200 ms holds its default thread for
200 ms. Waiting on a database, another service or a file is not computing; those handlers give
their thread back while they wait and are not what this section is about. Measured
([#589](https://github.com/PingoLee/Nitro.jl/issues/589#issuecomment-6458357081)): on the same
8 default threads, 32 PormG queries each waiting 200 ms on PostgreSQL left the minimal route at
96% of its idle rate, where 8 handlers computing for 200 ms took it to 1.4%. A database wait
needs no queue; the connection pool, not the thread count, bounds how many run at once.
Those numbers are for PormG's default PostgreSQL driver, LibPQ, which parks the request task on
the socket while the query runs. PormG's Postgres.jl driver does the same, measured the same way
([run 3b](https://github.com/PingoLee/Nitro.jl/issues/589#issuecomment-6495113599)): the same
32 waits left the route at 99.9% and completed at 160 per second, where 8 held threads would
allow 40. A driver that waits inside a blocking call instead, such as a synchronous `ccall`
that returns only with the result, holds its default thread for the whole query exactly as
computing does: measure it before relying on this, and treat it like the CPU work below, which
does need the queue.

Size that pool for the requests that hold a connection at once, not for the database's cores.
PormG grows a pool up to 10 × its configured `pool_size`, and on its Postgres.jl driver a ceiling
below the requests holding a connection makes the rest queue for one: throughput drops and the
median latency rises ([#589, *Run 4b*](https://github.com/PingoLee/Nitro.jl/issues/589#issuecomment-6476507622)).
The answer that holds for a Go server on `pgx`, a pool about the size of the database's cores,
does not carry over.

On the machine above (`--threads=8`, so 8 default threads), `bench/socket/stall.sh` kept k
requests computing 200 ms each in flight while a load generator held 50 connections on a minimal
route, and measured that route. The same 200 ms of work was run three ways in Nitro: computing in
the handler, the same loop calling `yield()` every 2 ms, and moved to a Workers queue of
concurrency 6 with the handler answering `202`. Go's `net/http`, which preempts a computing
goroutine, ran the first shape on the same CPUs for reference. Each cell is the minimal route's
requests per second and p99. The queue column is from a second run the same day, after a fix to
the benchmark's own job counter; its k = 0 baseline was 102k and 2.4 ms.

| k | In the handler | `yield()` every 2 ms | Workers queue of 6, `202` | Go, in the handler |
|---|---|---|---|---|
| 0 | 100k, 2.6 ms | | | 238k, 3.4 ms |
| 1 | 99k, 2.7 ms | 99k, 2.6 ms | 101k, 2.5 ms | 228k, 3.4 ms |
| 4 | 96k, 2.9 ms | 95k, 3.0 ms | 98k, 3.0 ms | 156k, 1.8 ms |
| 6 | 60k, 4.0 ms | 70k, 4.0 ms | 61k, 3.8 ms | 93k, 3.1 ms |
| 7 | 18k, 9.7 ms | 32k, 7.4 ms | 61k, 3.7 ms | 57k, 5.7 ms |
| 8 | 1.5k, 192 ms | 16k, 10.5 ms | 60k, 4.0 ms | 26k, 19.9 ms |
| 16 | 221, 804 ms | 7.6k, 36 ms | 60k, 3.9 ms | 3.4k, 64 ms |

- **The knee is the default thread count.** With a few computing handlers the other requests
  barely notice. Near 8, a cheap request waits for a computing handler to finish, so its p99
  becomes the handlers' own run time: 192 ms behind 200 ms handlers. (The 8 CPUs here are 4
  cores' hyperthreads, which is why the drop begins at 6.) `--threads=8,0` measured the same:
  1.6k requests per second and a p99 of 213 ms at k = 8.
- **So the threshold is your latency budget.** The longest a handler may compute without yielding
  is the delay you accept for *every other* request on a busy server. For an API answering in
  milliseconds, that is a few milliseconds of computation. Measured against Go on an
  aggregation handler ([#590](https://github.com/PingoLee/Nitro.jl/issues/590)): at k = 8, a
  call of about 1 ms cost the minimal route throughput but no stall (p99 3.7 ms, the same as
  Go's). Nitro stopped matching Go between 11 and 33 ms per call: Go preempts the long calls,
  so its p99 levels off near 18 ms, while Nitro's becomes the call time. In a later run, not
  interleaved with Go's, the same loop calling `yield()` every 2 ms matched Go's throughput at
  k = 8 with a lower p99.
- **Past it, move the work to a queue** whose concurrency leaves threads free, and answer `202`
  with the task id ([CPU-Bound Jobs](@ref)). Only 6 jobs ever ran at once, so the minimal route
  kept about 60k requests per second at every k. The cost moves to the jobs: past what the queue
  can run, they wait in its buffer, and once the buffer is full (100 by default) a submit throws
  `WorkerCapacityError`, which Nitro answers `503`. At k = 16, half the submissions were refused.
- **Or `yield()` every 1–2 ms** in a loop that has to stay in the handler. It does not make the
  work cheaper, so throughput still falls, but it bounds the wait: a p99 of 10.5 ms at k = 8,
  lower than Go's 19.9 ms (Go preempts a goroutine after about 10 ms).
- **One caveat on Julia 1.13.0 through 1.13.2**
  ([#586](https://github.com/PingoLee/Nitro.jl/issues/586), reported upstream as
  [JuliaLang/julia#63882](https://github.com/JuliaLang/julia/issues/63882)).
  - **The stall:** in a repro with every default thread in a yielding loop for 1.5 s, a task
    parked in `sleep(0.001)` woke only when the loops ended. On 1.12.7 and on the 1.14
    development branch it woke a few milliseconds late.
  - **When it happens:** only while no other timer is alive in the process. Any second live
    `Timer` removes it, even one that never fires. New requests are not affected: the `yield()`
    column above did not change on 1.13.2.
  - **Nitro works around it while serving.** On 1.13.0-rc3 and later 1.13 releases, `serve`
    holds one `Timer` that never fires, and `terminate` closes it: one handle, nothing per
    request. `bench/socket/wake.sh` measured a Nitro server with no other timer on 1.13.2
    ([#598](https://github.com/PingoLee/Nitro.jl/issues/598)). It kept one handler parked in a
    10 ms `sleep` loop while 8 handlers yielded every 1 ms for 1.5 s. Without the guard the
    parked handler woke 1.48 s late in 3 runs of 3. With `serve`'s guard it woke 10–23 ms
    late, against 2–8 ms on 1.12.7 with no load beside it.
  - **What is still exposed:** a task that sleeps while no server is up, such as a script that
    runs yielding loops before or after `serve`. It can hold the same guard itself:
    `keepalive = Timer(typemax(Int32))`, and `close(keepalive)` when done.

**Every app has one such handler: the login.** One `check_password` at the default cost
computes without yielding for about 0.1 s (pbkdf2_sha256, 720,000 iterations) or 0.2 s
(bcrypt, cost 12). The same run with k logins in flight instead of `/cpu` (Julia 1.12.7,
[#587](https://github.com/PingoLee/Nitro.jl/issues/587)):

| k | pbkdf2: `/plaintext` rps, p99 | bcrypt: `/plaintext` rps, p99 |
|---|---|---|
| 0 | 99.7k, 2.3 ms | 99.7k, 2.3 ms |
| 4 | 92.6k, 3.5 ms | 93.9k, 2.6 ms |
| 8 | 2.1k, 122 ms | 1.3k, 237 ms |
| 16 | 291, 880 ms | 172, 1.6 s |

Eight sign-ins at once stalled the whole API while they ran, and so would eight guesses from a
credential-stuffing client. A `RateLimiter` on the login route bounds what one client can impose,
not what many impose together. **So Nitro bounds the checks itself**, the way the queue bounds
jobs: at most `password_concurrency()` hash at once (`nthreads(:default) - 2` by default), and
the rest wait parked ([Passwords](passwords.md#A-login-is-a-handler-that-computes)). The same
run on a quiet box, with the bound on, with it turned off, and with `/cpu_job` (the Workers queue
of 6), all interleaved in one session (Julia 1.12.7, medians of three rounds; a different day
from the table above, so compare within this table):

| k | pbkdf2, unbounded | pbkdf2, bounded | bcrypt, unbounded | bcrypt, bounded | `/cpu_job`, queue of 6 |
|---|---|---|---|---|---|
| 8 | 2.2k, 121 ms | 53k, 4.7 ms | 1.2k, 238 ms | 55k, 4.2 ms | 57k, 4.3 ms |
| 16 | 275, 1.15 s | 52k, 4.8 ms | 150, 2.7 s | 55k, 4.3 ms | 57k, 4.2 ms |

With the bound, the other routes keep 91–97% of the queue's throughput at both k, against 0.3–4%
without it. Logins pay for it. At k = 16 they ran at 44 per second (pbkdf2) and 24 (bcrypt)
instead of 57 and 32, and a sign-in past the bound waits for a permit: at k = 8 a login's median
went from 145 to 184 ms (pbkdf2) and from 263 to 336 ms (bcrypt). The wait is fairer, though:
at k = 16 a login's p99 was lower with the bound than without it (675 ms against 870 ms for
pbkdf2, 1.2 s against 2.1 s for bcrypt). `set_password_concurrency!` moves that
trade. The bound covers logins only: a Workers queue sized the same way takes its own threads
on top of it, so an app running both at full load should size the two together.

No setting in Nitro bounds a computing handler: `read_timeout` and `write_timeout` are socket
deadlines, and nothing can stop a task from outside. A handler can stop itself when its client
leaves or the server shuts down ([Long-Running Handlers](@ref)). The `AccessLog` middleware
records each request's `duration_ms`, which is where a slow handler shows up.

**Nitro's own primitives hold a thread too, in proportion to the body.** Parsing or building a
body is computing.
[#588](https://github.com/PingoLee/Nitro.jl/issues/588) measured one call each, on one thread on
Julia 1.12.7:

- JSON (`getjson`, `Json{T}`, `Res.json`) takes 0.4–1.1 ms at 100 KB and 4–11 ms at 1 MB, and
  grows linearly from there.
- Parsing a 10 MB multipart upload takes about 6 ms.
- A buffered `Res.file` of a 100 MiB file is a single 53 ms `read`.

Below the knee, the hold itself is not what other requests feel; the garbage collector is. #588's
stall pass kept 1–4 of these operations in flight on an 8-thread server. A minimal route lost
22–76% of its throughput, against at most 6% for a handler computing 200 ms without allocating.
Two things made the difference:

- **Allocation.** A large body allocates in proportion to its size, so collections come more
  often: 21–41% of the time went to GC, against about 7% with no large bodies. Only allocating
  less moves that.
- **Waiting for a safepoint.** A collection first stops every thread, and a thread inside a call
  that never reaches a safepoint keeps all the others waiting until the call returns. With four in
  flight, a buffered 100 MiB `Res.file` made each collection wait 43 ms and took the minimal
  route's p99 from 3 ms to 75 ms. A 64 MiB multipart upload made each collection wait 20 ms, for a
  p99 of 51 ms.

What Nitro does about each operation:

- **Large files stream by default.** `Res.file(req, path)` sends a file over 8 MiB in 64 KiB
  chunks, as static mounts do above `stream_threshold`. A chunk reads in about 6 µs, and the
  collector's wait stays under 0.1 ms. A streamed download gives its thread up whenever the client
  is slower than the server: eight downloads capped at 200 MiB/s each kept the minimal route at
  90% of its throughput. `stream = false` brings back the whole-file read for the cases that need
  the bytes in memory.
- **A multipart upload is copied out in chunks**, with a safepoint every 1 MiB. HTTP.jl's boundary
  scan, which comes first, still has no safepoint: about 33 ms for 64 MiB. Until that changes, a
  large upload delays every collection while it is scanned. If that is too much for your latency
  budget, lower `serve(max_body_bytes = …)` to the largest upload you need.
- **JSON** reaches safepoints as it allocates (0.4–3.5 ms per collection in the same run). Its cost
  is the allocation, and the default `max_fields` cap refuses a body with more than 1000 keys
  before parsing it.

Past the knee, a large body behaves like any other computing handler: the rule above applies.

### Long-Running Handlers

Nothing can stop a handler from outside. Julia tasks cannot be killed, and throwing into one that
is running is unsafe ([#127](https://github.com/PingoLee/Nitro.jl/issues/127)). So a handler that
runs long (a report, an export, a long poll) is asked to stop and decides for itself, as a
[background job](workers.md) is. `cancel_requested(req)` turns `true`, and `cancel_reason(req)`
says why, when:

- **`:client_disconnected`**: the client closed or reset the connection, so nobody will read the
  response.
- **`:shutdown`**: `terminate` has begun. The server is draining and will force-close whatever is
  still running after `shutdown_timeout`.

```julia
function export_report(req)
    rows = Row[]
    for page in 1:npages
        if cancel_requested(req)
            # A deploy: the client is still there, so tell it to retry.
            cancel_reason(req) === :shutdown && return Res.status(503)
            # The client left: nobody reads this status, but the access log records it.
            return Res.status(499)
        end
        append!(rows, fetch_page(page))
    end
    return Res.json(rows)
end
```

Without the check, the handler runs to the end and writes a response nobody reads. During a
deploy it is force-closed at the end of `shutdown_timeout` instead of finishing its own way.

**What a check costs.** Nitro probes the socket (a non-blocking peek, on the handler's own thread)
at most once every 10 ms. A check in between is a lookup in the request's context, a clock read
and two atomic loads, and allocates nothing, so polling in a hot loop is fine. A handler that
never checks pays nothing: no task is started for it and nothing is written to its request. The
probe never runs on the interactive thread.

**A check is not a yield.** It answers a question and gives up no thread. A loop that computes
still holds its thread until it returns ([Handlers that compute](@ref)). Check where you would
yield, or call both.

**What it cannot see:**
- A client that sends its request and then half-closes its side (`shutdown(SHUT_WR)`) reads as
  disconnected. Go's `net/http` treats it the same way.
- A pipelined next request, already sent on the same connection, hides a later disconnect.
- A connection that died without a FIN or a reset (a cable pulled, a NAT that dropped it) looks
  alive until the kernel gives up on it.
- Once the response is written, the client is no longer probed: the connection may already
  carry the next request.
- An `internalrequest` has no connection, so only `:shutdown` can fire.

Check from the handler's own task. Each check reads the request's context, as the other
per-request accessors do, and that context is not safe to read while another task writes to it.
Do not poll `req` from a task you spawn while the handler goes on using it.

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
streamed file — `Res.file(req, path)` over 8 MiB or with `stream = true`, or a mounted file over
`stream_threshold` — writes
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

## Compiling with juliac (experimental)

Julia can compile an application into a standalone executable with `juliac` (on 1.13, the
[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl) app), and
`--trim` drops every method the program cannot reach. Nitro is working towards `--trim=safe`, but
it does not build a Nitro app cleanly today. What is left, and how it is measured, is recorded in
`docs/design/juliac-trim.md` in the repository. This section covers the one rule that holds
whatever the build reports.

**A fatal error in a juliac executable prints its raw fields.** Under the JIT, an exception that
escapes your program is printed through `showerror` and the `show` methods. Nitro gives those
methods a masked form for every secret it holds: a [`SecretString`](@ref) prints `****`. An
executable built by `juliac`, trimmed or not (`--trim=no`), has no such display. The runtime prints
the exception by walking its fields, so any key, password or token the exception reaches is
written to `stderr` in clear, which in production usually means a log collector.

In a juliac executable, trimmed or not, `serve` handles its own part of this. An error that
leaves `serve` (a middleware that fails while the pipeline is built, or a port already in use) is
rethrown as a value-free [`Nitro.Errors.LoggedException`](@ref Nitro.Core.Errors.LoggedException).
It keeps the original's type name in `type` and, in `text`, the message of an `ArgumentError` or an
`ErrorException` (so Nitro's own refusals still read in full) or the address of a port already in
use. The backtrace is kept too, and nothing else. A port already in use is therefore caught as
`e isa Nitro.Errors.LoggedException && e.type === :AddressInUseError`, not as
`HTTP.AddressInUseError`. Under the JIT, `serve` rethrows the original exception unchanged.

Your own start-up code runs before `serve` and outside its frames, so the entry point still
catches what escapes. Print [`Nitro.startup_failure_text`](@ref Nitro.Core.Errors.startup_failure_text)
of it on `Core.stderr`, and exit non-zero. The line is built the same way whether `serve` already
replaced the exception or your own code threw it. It keeps the type's name, and the message of an
`ArgumentError` or an `ErrorException` verbatim. So never interpolate a secret into your own
`error(...)` or `ArgumentError(...)` message (`error("cannot reach $(db_url)")` prints the URL,
password included):

```julia
using Nitro

const app = App()
urlpatterns(app, "", path("/hello", req -> Res.send("Hello"); method = "GET"))

function (@main)(args::Vector{String})::Cint
    try
        # load the config, resolve the secrets, run the initializers, then:
        serve(app; host = "0.0.0.0", port = 8080)
    catch e
        e isa InterruptException && rethrow()
        println(Core.stderr, "start-up failed: ", Nitro.startup_failure_text(e))
        return Cint(1)
    end
    return Cint(0)
end
```

An app written by `Nitro.newapp` already has this entry point, as `main.jl` (see
[Bigger Applications](bigger_applications.md)). Its `main` takes the folder that holds `db/` as
`root`, and `main.jl` passes `APP_ROOT`, else the working directory: an executable cannot find it
with `pkgdir` or `@__DIR__`, which name the temporary copy of the project JuliaC built from.

Use `Core.stderr` and `Nitro.startup_failure_text`, not `@error "…" exception = e`: a trimmed
image cannot dispatch the logging machinery or `showerror` on an arbitrary exception, and an
untrimmed one would print what `showerror` prints, values included. `startup_failure_text` calls
neither. It gives the type's name only (`nameof`), never `typeof(e)` itself, because a type can
carry a value as a parameter.
The routes are registered at top level, so under `juliac` they run while the image is built and
`main` only serves. Keep the whole life of the server inside the `try`: with `serve(app; async =
true)`, a later `wait` on the server rethrows what the server task raised, and outside the `try`
that is printed raw.

How `serve` knows it runs in an executable: both juliac build scripts define `Main._main`, the C
entry point that calls your `main`. Do not define a global `_main` in `Main` yourself, or `serve`
treats a JIT session as an executable too, and replaces the exceptions that leave it there.
