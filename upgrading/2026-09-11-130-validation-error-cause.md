## `ValidationError` no longer renders or serializes its `.cause` (#130)

- **Version**: 0.4.0
- **Nitro ref**: #130 (follow-up to #72); `src/errors.jl`, `docs/src/tutorial/request_body.md`
- **Recorded**: 2026-09-11
- **Severity**: **breaking (JSON output shape)** — a security fix; part of the `0.1.x` pre-publish
  wave.

### What changed

`ValidationError` wraps the exception that actually failed in `.cause`, and parsers quote their
input. A JSON parse `ArgumentError` echoes the offending bytes verbatim, so the submitted request
body came back out through every path that rendered the error:

```julia
# a POST whose password contains a backslash — an invalid JSON escape, no attacker required
sprint(showerror, err)
# before → Validation Error: Failed to serialize data for | parameter: credentials | ...
#          Caused by: ArgumentError: encountered invalid escape character in json string: "s3cr3t\qX"

JSON.json(err)
# before → {"msg":"Invalid query parameter 'limit': expected Int64",
#           "cause":{"msg":"invalid JSON at byte position 1 ... s3cr3t... ^"}}
```

#72 made `.msg` value-free. `.cause` was left open and is reachable the same three ways `.msg` was:
`showerror`, `show` (which a `SimpleLogger` or a structured sink reaches for `exception=err`), and
JSON — and the JSON path reaches the **client**, not just the log.

All three now mask the cause down to its **type**, which carries no submitted bytes:

```julia
sprint(showerror, err)   # after → Validation Error: <msg>            (no "Caused by:" line)
repr(err)                # after → ValidationError("<msg>", ArgumentError(…))
JSON.json(err)           # after → {"msg":"<msg>","cause":"ArgumentError"}
```

`.msg` still renders and still serializes — a mask that swallowed the struct would break the
app-level error envelope this exists to serve. The `.cause` **field is unchanged**: same name, same
`Union{Nothing, Exception}` type, still directly readable.

**What this forces.** Two shapes:

1. **An app that serializes a `ValidationError`** — an error envelope like
   `Res.json(Dict("error" => err))`, a `format_response` return, or structured logging that
   JSON-encodes a struct holding one — now emits `"cause"` as a **string type name** where it was
   an **object**. A consumer doing `body["error"]["cause"]["msg"]` breaks; it is now
   `body["error"]["cause"]`. Note the before-behavior was shipping the submitted payload to that
   consumer, so this is a leak you want closed, not a capability you want back.
2. **An app that displayed the cause for diagnosis** — anything rendering `sprint(showerror, err)`
   or `repr(err)` in a dev-mode diagnostic — silently shows less. Nothing throws.

Both recover the detail explicitly, and only where you actually want it:

```julia
sprint(io -> showerror(io, err; cause = true))   # the full chain, as before
Nitro.Errors.cause_report(err)                   # the same, as a String
err.cause                                        # the exception itself, unchanged
```

Treat what those return as the request body itself: never a log sink, never a response body, never
a bug report. There is deliberately no global switch and no environment variable — a process-wide
"show causes" flag is the thing that ends up on in production.

### How to find the calls to migrate

```bash
# Julia side — apps that serialize or render a ValidationError
rg -n 'ValidationError' --glob '*.jl' | rg -n 'json|Res\.|format_response|showerror|repr|string\('

# Client side — the consumer that actually breaks is whatever reads the JSON, and for an
# SPA/API-first framework that is the front end. Do NOT restrict this one to *.jl.
rg -n '\bcause\b' <app>/frontend/src <app>/src
rg -n '\["cause"\]\s*\[|\.cause\.msg|cause\?\.msg' <app>
```

### Before → after

```julia
# before — dev diagnostic that silently lost its detail
@info "rejected" detail = sprint(showerror, err)
# after
@info "rejected" detail = err.msg                       # value-free, safe to ship
# ...or, at a REPL only:
println(Nitro.Errors.cause_report(err))

# before — consumer reading the serialized cause as an object
reason = body["error"]["cause"]["msg"]
# after
reason = body["error"]["cause"]                         # e.g. "ArgumentError"
```

An app that never renders or serializes a `ValidationError` — the common case, since
`handle_error` has always returned a fixed `{"message": "400: Bad Request"}` — needs no change.
