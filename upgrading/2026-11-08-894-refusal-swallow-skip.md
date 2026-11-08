## A refused body declaring more than 3 MiB is answered at once — a write-then-read client may now see a reset

- **Version**: Unreleased
- **Nitro ref**: #894 (follow-up to #780); `src/core/transport.jl` (`stream_handler`,
  `_send_rejection!`, `_SWALLOW_SKIP_ABOVE_BYTES`, `_SWALLOW_READ_BYTES`)
- **Recorded**: 2026-11-08
- **Severity**: **behavior change** — no Nitro API changes. One client shape gets a reset where it
  used to get a clean close, on the refusals Nitro answers before any middleware runs.

### What changed

Two refusals happen before your middleware runs: the `413` for a body over `max_body_bytes`, and
the `503` for a request over `max_concurrent_requests`. Before answering either one, Nitro reads
and discards up to 2 MiB of the request body for up to 5 s. When a connection is closed with
request data still unread, the close is a reset, and a reset can cost the client the response it
was sent. Reading first is what prevents that. HTTP.jl then drains up to 1 MiB more after the
response.

1. **A body that declares more than 3 MiB is no longer read** (the 2 MiB plus HTTP.jl's 1 MiB).
   The refusal is written at once and the connection closed.
   - **Why:** past both budgets the close was usually a reset anyway, after Nitro had held the
     refusal open for as long as the client took to send, up to 4 s in #780's measurement.
   - **Not affected:** a chunked body, which declares no length, and any body of 3 MiB or less.
     Both keep the read.
2. **A `413` gives its `max_concurrent_requests` slot back as soon as it is refused**, before the
   read above. A client sending an oversized body slowly no longer occupies a slot for those 5 s,
   so it can no longer starve other requests into `503`s. Nothing to migrate.

**The client shape that changes:** a client that writes its whole request body before reading the
response, sends a declared length (not chunked) of more than 3 MiB, and is refused.
- **Before:** at full speed on Linux loopback, this client sometimes got a clean close. On the
  `413` path that was 1 of 5 runs in #780 and 5 of 5 in #894's re-measurement; on the `503` path,
  2 of 5 in both. How often depends on how much the kernel's receive buffer absorbs.
- **Now:** its write fails with a connection reset every time.
- **On Linux** the client still reads the status from its receive queue after the failed write.
- **At risk:** a client on **Windows**, or one that gives up when its write fails, can lose the
  status and see only the reset.

**Not affected:**
- curl sends `Expect: 100-continue` for a body over 1 MiB, so it is refused before it sends
  anything, as before.
- Browsers, and clients that read the response while they send, stop sending once the status
  arrives.

### How to find the calls to migrate

Find where your server sets its body ceiling:

```bash
grep -rn "max_body_bytes" src/ bin/ *.jl
```

A migration is owed only if all three are true:
- legitimate clients send fixed-length bodies of more than 3 MiB;
- those bodies can be over your `max_body_bytes`, or can arrive while the server is at
  `max_concurrent_requests`;
- those clients must see the `413` or `503` reliably, not a reset.

Programmatic uploaders on Windows are the case to check.

### Migrate your app

Pick whichever fits:
- raise `max_body_bytes` above the largest body those clients legitimately send, so it is not
  refused;
- put a reverse proxy in front that enforces the limit itself (nginx `client_max_body_size`);
- have the client send `Expect: 100-continue`, so it is refused before it sends the body.

```julia
# ✗ before: 2 MiB ceiling, while clients upload files of up to 10 MiB
serve(app; max_body_bytes = 2 * 1024^2)

# ✓ after: the ceiling covers the largest legitimate upload; a larger one is an abusive client,
# and a reset is the correct answer for it
serve(app; max_body_bytes = 16 * 1024^2)
```
