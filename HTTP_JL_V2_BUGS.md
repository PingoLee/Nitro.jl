# HTTP.jl v2 issues found during the Nitro.jl migration — ALL RESOLVED

Three upstream Windows/Reseau issues surfaced while migrating Nitro.jl from HTTP.jl v1 to
v2. **All three are now fixed upstream.** This file is kept as a short record of what was
found and which release resolved each; there are **no remaining blockers**. Safe to delete.

Platform: Windows 11, Julia 1.12.6.

| # | Issue | Fixed in |
|---|-------|----------|
| 1 | `listen!` empty-body response (OPTIONS/204/304/HEAD) corrupted the keep-alive connection → next request `ParseError: unexpected EOF`. `serve!` was unaffected. | **HTTP v2.2.0** |
| 2 | Reseau same-process loopback latency ~1–1.6 s/request at runtime (25 reqs ≈ 24–41 s). | **HTTP v2.2.0** |
| 3 | Reseau same-process loopback deadlock in the **precompile context** (`jl_generating_output`) — HTTP's bundled `@compile_workload`, and any downstream live-server precompile workload, hung `Pkg.precompile()` forever on Windows. | **HTTP v2.3.0 / Reseau v1.3.1** |

## Verification on HTTP v2.3.0 / Reseau v1.3.1

- Full Nitro suite: **1694 passed, 0 failed** (1 intentional `@test_broken`).
- HTTP precompiles on a clean install **without** the depot patch that was previously
  required (its bundled loopback workload no longer hangs).
- A live-server round-trip inside Nitro's own `@compile_workload` completes (exit 0) where
  it previously hung (exit 124 / 200 s timeout).

## Migration footnote (not an HTTP bug)

The first *network* request to a freshly-loaded Nitro server still costs ~3 s of one-time
JIT compilation. This is **not** the Reseau issue and cannot be removed via a live-server
precompile workload: the request path is specialized on the user's specific
handler/middleware closure types, which only exist at runtime, so a sample precompile route
can't stand in for arbitrary user routes. Steady-state latency is ~0.15 ms/request,
matching raw Reseau. Tests that fire timed bursts warm the route first (see the rate-limiter
tests).
