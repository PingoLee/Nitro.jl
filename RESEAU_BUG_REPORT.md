# Bug: Reseau (HTTP.jl v2 transport) — same-process loopback request never gets its response read completion (Windows)

When an HTTP/Reseau client and an HTTP/Reseau server run **in the same process** and talk
over loopback, the client request never receives a response: the client's read completion
is never delivered, so the call fails at its `request_timeout`.

**Likely the root cause of [JuliaWeb/HTTP.jl#1252](https://github.com/JuliaWeb/HTTP.jl/issues/1252)** ("HTTP v2 takes an inordinately long time / appears stuck to precompile" on Julia 1.12, Windows), since HTTP v2's bundled precompile workload does exactly this in-process loopback.

## Environment
- OS: Windows 11 Pro (10.0.26200)
- Julia: 1.12.6 (x64, juliaup `release`)
- HTTP.jl: v2.0.0
- Reseau: v1.1.4 (HTTP v2's transport backend)

## Symptom
The core, reliably reproducible symptom: a same-process loopback client request **does
not return a response and fails at its `request_timeout`** (see the minimal repro below —
with an explicit 4s timeout it errors cleanly after ~4s; it is the *response read* that
never completes, not the connect or the request send).

Downstream consequence: HTTP v2's bundled precompile workload ([`src/precompile.jl`])
starts 6 in-process servers and drives them with the in-process HTTP **client**, so it
hits this on its very first request. In practice precompilation then **appears stuck**
(progress bar parks at `◑ HTTP`, must be Ctrl-C'd, leaves a stale `*.ji.pidfile`) — this
is what makes `using HTTP` unusable on Windows until the workload is disabled. (I have not
measured whether the workload eventually errors out on its own vs. truly never returns, so
I'm only claiming "does not complete in reasonable time / must be interrupted".)

The same failure breaks **any** in-process integration test that starts a server and
calls it with the HTTP client in the same process (the standard test pattern).

## Minimal reproduction
```julia
using HTTP
server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
    return HTTP.Response(200, "pong")
end
addr = HTTP.server_addr(server)
# Times out after request_timeout; never returns a response:
HTTP.get("http://$addr/ping"; connect_timeout=2.0, request_timeout=4.0, retry=false)
```

Error (client side):
```
http timeout during request
caused by: i/o timeout
  _wait_iocp_completion!  Reseau/src/iopoll/fd.jl:437
  _read_ptr_some!         Reseau/src/iopoll/fd.jl:695
  _readbytes_some!        Reseau/src/3_tcp.jl:779
  ...
```

## Notes for the active #1252 root-cause investigation
Two data points that may not be in the existing reports:
1. **This is not Linux-1.11+-only — it reproduces on Windows + Julia 1.12.6.** A
   precompile-workload gate scoped to Linux 1.11+ (e.g. the closed #1274) would leave
   this lane broken.
2. **It is not precompile-specific.** The minimal repro above hits the failure in a bare
   REPL with no precompilation involved, so it isolates the issue to the transport /
   in-process loopback poller rather than the `@compile_workload` machinery.

## Triangulation (which component is at fault)
| HTTP client | HTTP server | Same process | Result |
|-------------|-------------|--------------|--------|
| stdlib `Sockets` (libuv) | HTTP/Reseau | yes | ✅ works |
| HTTP/Reseau | stdlib `Sockets` (libuv) | yes | ✅ works |
| HTTP/Reseau | HTTP/Reseau | yes | ❌ **request times out** |

So neither the Reseau client read path nor the Reseau server path is broken in
isolation — the failure only occurs when **both endpoints are driven by Reseau's
single IOCP poller in the same process**.

## Where it fails (precise)
With logging in the server handler, in the failing both-Reseau case:
- client `ConnectEx` completes ✅
- client write (request) ✅
- server `AcceptEx` completes, server reads request, **handler is invoked** ✅
- **client's `WSARecv` completion for the response is never delivered** ❌ → times out

Only the client's response-read completion is lost.

## Ruled out (tested workarounds that did NOT help)
- Thread count: fails with both `-t 1` and `-t auto`.
- Sleeping scheduler / lost wakeup: a busy `Threads.@spawn` `sleep` ticker **and** a
  libuv `Timer(...; interval)` keepalive both fail to resolve it.
- GC safepoints: `GC.enable(false)` around the request does not help.

The failure is **deterministic**, not a timing race.

## Suspected mechanism
Reseau's poller runs on a **detached foreign OS thread** created via raw `CreateThread`
(`src/iopoll/runtime.jl` `_spawn_detached_thread`), and wakes parked Julia tasks by
calling `schedule(task)` from that thread (`src/iopoll/types.jl:156`,
`pollnotify!`). The completion drain is `GetQueuedCompletionStatusEx`
(`src/iopoll/iocp.jl:_backend_poll_once!`). When two mutually-dependent sockets are
serviced by the one poller in-process, the client read completion is not routed to its
waiter. (A `__init__` comment in `runtime.jl` already notes foreign-thread hazards on
Windows.)

## Impact
- HTTP v2 does not finish precompiling on Windows (the bundled workload triggers it).
- In-process server+client integration tests time out.
- Real deployments (server with *external* clients, or client to *external* servers)
  are unaffected — only same-process loopback between two Reseau endpoints.

## Workarounds for users (today)
- Pin `HTTP = "1"` (libuv transport; no Reseau).
- Or disable the bundled precompile workload to at least let v2 precompile/load
  (does not fix in-process tests).
