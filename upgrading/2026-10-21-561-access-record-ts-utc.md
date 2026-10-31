## `AccessRecord.ts` and the `AccessLog` prune cutoff are UTC, no longer local time (#561)

- **Version**: 0.7.0
- **Nitro ref**: [#561](https://github.com/PingoLee/Nitro.jl/issues/561) ; `src/middleware/access_log.jl`
- **Recorded**: 2026-10-21
- **Severity**: behavior change (record contents, retention cutoff)

### What changed

`AccessLog` stamped each `AccessRecord` with `Dates.now()`, the server's local time. Each of those
calls goes through glibc's `localtime_r`, which takes a process-wide lock, so on a multithreaded
server every request queued on it. Measured on 4 threads: 527 ns of wall time per call, against
70 ns on one thread. `now(UTC)` takes no lock and stays at 33 ns on any number of threads.

`ts` is now `now(UTC)`. The `prune` callback's cutoff moved to the same clock, so it is
`now(UTC) - retention`, and a record and its cutoff still compare like for like.

Both values are still a plain `DateTime` with no zone attached, so nothing fails to compile or
throws. **The values just move by the server's UTC offset.** On a server already running in UTC,
nothing changes at all.

Unaffected: `duration_ms` (a monotonic clock), every other record field, and the console access
line from `serve(access_log = true)`.

### How to find the calls to migrate

Find the sinks and pruners:

```bash
grep -rn -A6 -E 'AccessLog\(|AccessRecord' --include=*.jl .
```

For each sink, check what it does with `ts`:
- **Stored in a column read as local time**, or shown to people as local time: convert it, or
  label the column UTC.
- **Compared with `now()`** anywhere else (dashboards, cleanup jobs): compare with `now(UTC)`.

For each `prune`, the cutoff it receives is now UTC, the same as the new `ts` values.

**Stored data.** Rows written before the upgrade hold local time and rows written after hold UTC.
West of UTC (the Americas), old rows look older than they are by the offset, so the first prunes
delete them up to that many hours early. East of UTC they are kept that much longer. If retention
is a legal bound, either convert the old rows once, or let one offset's worth of time pass before
relying on the cutoff to the hour.

To convert, **stop the server, convert, then start the new version**. Every row is then local
time, so the update needs no filter. Once the new version has written a row, `ts` alone can no
longer tell old rows from new ones: east of UTC, a new UTC row can be earlier than the deploy
time read as local. The rule is `UTC = local - offset`, where `offset` is the server's signed UTC
offset when the row was written. At UTC-3 that adds 3 hours; at UTC+2 it subtracts 2.

```sql
-- server stopped, before the new version writes; UTC-3 shown, so local - (-3 h) = local + 3 h.
-- If the retention window spans a DST change, convert each side with its own offset.
UPDATE access_log SET ts = ts + INTERVAL '3 hours';
```

### Migrate your app

```julia
# ✗ before: the sink treated ts as local time
sink = recs -> foreach(r -> insert_access_row!(local_ts = r.ts, path = r.path), recs)

# ✓ after: ts is UTC; store it as such (or convert explicitly for display)
sink = recs -> foreach(r -> insert_access_row!(ts_utc = r.ts, path = r.path), recs)
```
