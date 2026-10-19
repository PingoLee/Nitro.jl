## Error log records carry a `LoggedException`, not the exception that was thrown (#613)

- **Version**: Unreleased
- **Nitro ref**: [#613](https://github.com/PingoLee/Nitro.jl/issues/613) ; `src/errors.jl`, `src/utilities/misc.jl`, `src/middleware/access_log.jl`, `src/core/framework_middleware.jl` ; [#651](https://github.com/PingoLee/Nitro.jl/issues/651) ; `src/Workers/`, `src/types.jl`
- **Recorded**: 2026-10-19
- **Severity**: behavior change (logging). The client response is unchanged, and so is the console
  text, though it is no longer coloured. A log sink or filter that reads the record's `exception`
  value gets a different type.

### What changed

When a handler or a middleware throws, the error boundary logs `@error "ERROR: "` with an
`exception` kwarg. That kwarg used to hold the live exception: `exception = (e, backtrace)`.
`ConsoleLogger` renders it with `showerror`, which prints a `MethodError`'s arguments and a
`TypeError`'s value only as **types**. A sink that `show`s the record instead (a JSON or structured
logger) printed the objects themselves. So a handler that threw a `MethodError` over a parsed body,
a token or the request wrote the password, the token or the request's query string to the log.

The record now holds `(Nitro.Errors.LoggedException, backtrace)`. A `LoggedException` has two
fields:

- `type::Symbol`: the original's type **name**, such as `:MethodError` or `:ArgumentError`;
- `text::String`: what `showerror` printed for the original.

`show` and `showerror` both print `text`, so every sink records what the console shows. The
backtrace is unchanged.

The same type replaces the exception in four other warnings:

- `AccessLog: skip hook errored`
- `AccessLog: annotate hook errored`
- `AccessLog: failed to capture request`
- `AccessLog: sink failed`, plus the console line's `access_log_skip hook errored`

Worker log records carry it too ([#651](https://github.com/PingoLee/Nitro.jl/issues/651)). Every
`Nitro.Workers` log line with an `exception` kwarg now carries a `LoggedException`: zombie
recovery, the retention scheduler, the teardown paths, and the external consumer (`consume!`). That
includes the error a worker store rethrows, such as a `PormG.DatabaseError`. On PostgreSQL that
object's `.cause` holds the server's full message, and a constraint violation's `DETAIL` quotes the
task row. So do `Error in LifecycleMiddleware.on_startup` and `on_shutdown`, for **any**
lifecycle hook that throws: the worker hook's boot sweep rethrows a store's error into them. A
filter that matched a worker record's exception as `isa PormG.DatabaseError` now
matches `.type`: `:IntegrityError`, `:OperationalError` or `:StatementError`.

`text` is still whatever `showerror` prints. An exception whose own message quotes a value prints
that value, on the console as before and now in every sink. A
`LoggedException` keeps arguments out, not messages.

Unaffected:

- The status codes and response bodies.
- What `ConsoleLogger` prints, apart from colour. The text is rendered once, with `:limit => true`
  and no colour, before any sink sees it, so the red highlighting in a `MethodError`'s candidate list
  is gone in a terminal.
- `serve(...; catch_errors = false)` and `internalrequest(...; catch_errors = false)`: Nitro writes
  no record of its own, and the original exception propagates as before.

### How to find the calls to migrate

Only code that reads a log record's `exception` value is affected: a custom `AbstractLogger`, or a
`LoggingExtras` filter or transformer. Search for it:

```bash
grep -rn -E ':exception|\.exception\b|kwargs\[:exception\]' --include=*.jl .
```

Review each hit that inspects the exception's type or fields. A filter that only formats the record
with `showerror` or `string` needs no change.

### Migrate your app

```julia
# ✗ before -- dispatched on the live exception's type
is_db_error(log) = (ex = get(log.kwargs, :exception, nothing);
                    ex isa Tuple && ex[1] isa LibPQ.Errors.PQResultError)

# ✓ after -- match on the type NAME the record carries
is_db_error(log) = (ex = get(log.kwargs, :exception, nothing);
                    ex isa Tuple && ex[1] isa Nitro.Errors.LoggedException &&
                    ex[1].type === :PQResultError)
```

To inspect a live exception while you debug, run the request with
`internalrequest(app, req; catch_errors = false)`. The original then reaches you as it was thrown.
