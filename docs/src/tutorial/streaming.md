# Streaming And Server-Sent Events

Most endpoints compute a body and return it. Some cannot: a long import wants to report progress
while it runs, an LLM proxy wants to forward tokens as they arrive, a dashboard wants to be told
when something changed instead of asking every two seconds.

Nitro has two shapes for that, and they are not equivalent.

| | [`Res.sse`](@ref) | `method = "STREAM"` |
|---|---|---|
| What the handler returns | an ordinary `HTTP.Response` | nothing — it writes the socket itself |
| Middleware | **applies normally** | runs, and guards can refuse the request, but **what it adds to the response is silently discarded** |
| Protocol | Server-Sent Events (`text/event-stream`) | anything you write |
| Framing | chunked, one chunk per event | yours |

**Reach for `Res.sse` unless you need to control the response head yourself.** The middleware row
is the reason, and it is covered below.

## Server-Sent Events with `Res.sse`

```julia
using Nitro

function ticks(req)
    return Res.sse() do events
        for i in 1:10
            isopen(events) || break            # the client hung up
            write(events, SSEEvent(string(i); event = "tick", id = string(i)))
            sleep(1)
        end
    end
end

app = App(mod = @__MODULE__)
urlpatterns(app, "", [path("/events", ticks)])
serve(app)
```

The browser side is `EventSource`, which reconnects on its own:

```javascript
const es = new EventSource("/events");
es.addEventListener("tick", e => console.log(e.lastEventId, e.data));
es.onerror = () => {/* EventSource retries by itself; do not reopen here */};
```

`Res.sse` sets `Content-Type: text/event-stream`, `Cache-Control: no-cache` and
`X-Accel-Buffering: no`, declares no `Content-Length`, and therefore streams `Transfer-Encoding:
chunked` — one chunk per event, flushed as it is written. Headers you pass yourself are applied
last, so a `Cache-Control` of your own wins.

### Events are `SSEEvent` values

`SSEEvent` is re-exported, so `using Nitro` is enough:

```julia
SSEEvent("hello")                                  # data: hello
SSEEvent("hello"; event = "greeting")              # a named event type
SSEEvent("a\nb")                                   # one event, two `data:` lines
SSEEvent("42"; id = "42")                          # sets Last-Event-ID for reconnects
SSEEvent(""; retry = 5000)                         # tell the client how long to wait
```

`event` and `id` are single-line fields and `SSEEvent` **rejects CR and LF in both** (plus NUL in
`id`, which browser parsers require). That is not a formality: a bare carriage return is a valid SSE line terminator, so a value that carries one
could forge extra fields — or an early event boundary — in every connected client. Put untrusted
text in `data`, where line breaks are re-emitted as additional `data:` lines and cannot escape the
event.

!!! note "`format_sse_message` is gone"
    Nitro used to ship its own framer. It rejected LF but not CR, so it had exactly the injection
    hole described above. `SSEEvent` replaces it — see the upgrade log entry for #160.

### Closing the stream is what ends the response

The response is open until the stream is closed. With the `do`-block form, Nitro closes it when your
producer returns or throws, so you rarely think about it. The argument-less form hands you the
response with the stream still open, and closing it is then yours:

```julia
function manual(req)
    response = Res.sse()
    events = response.body::HTTP.SSEStream
    Threads.@spawn begin
        try
            write(events, SSEEvent("from my own task"))
        finally
            close(events)                      # without this the connection never finishes
        end
    end
    return response
end
```

A producer that returns without closing holds the connection open for the life of the process.

!!! warning "A replaced response orphans the producer"
    The producer form spawns its task when the handler *builds* the response, not when the response
    is written. If a middleware outside the handler then discards that response and returns a
    different one — an error handler converting a later throw into a 500, or your own middleware
    substituting a response — nothing ever drains or closes the `SSEStream`. The producer keeps
    writing into a buffer no one reads, for the life of the process.

    Nitro's framework middleware does not do this (`Cors`, `SecurityHeaders`, the session, CSRF and
    rate-limiter layers all add headers and keep the body), so you hit this only with a custom
    middleware that replaces a response after the handler has run. If you write one, exempt your
    SSE routes from it, or use the argument-less form and spawn the producer yourself so you own
    its lifetime.

### Pace the producer, and check `isopen`

`max_len` caps one serialized event (16 MiB by default, [`Res.SSE_MAX_EVENT_BYTES`](@ref)). It does
**not** bound the stream's buffer, which grows without limit — so a producer that writes much faster
than the client reads accumulates in memory. Two habits avoid it:

- give the producer a natural cadence (a `sleep`, a poll interval, or waiting on a `Channel`);
- check `isopen(events)` each iteration.

That check is also how a disconnected client stops the *work* rather than merely stopping the
writes. A disconnect closes the stream from underneath the producer, so a loop that tests
`isopen(events)` simply exits on its next pass — nothing is thrown and nothing is logged. A producer
that does not test it instead throws on its next `write`; Nitro treats that as a normal ending too,
at debug level rather than error, because a disconnect is how most SSE connections end. An exception
your producer raises for its own reasons is still reported at error level.

### Keeping the connection alive

Nitro sets none of HTTP.jl's read, write or idle timeouts, so nothing in the server closes a quiet
stream. Proxies are less patient. If your stream can be silent for longer than the proxy's idle
timeout, send a heartbeat:

```julia
write(events, SSEEvent(""; event = "ping"))
```

See [Behind a Reverse Proxy](@ref) for the nginx and Caddy configuration — in particular
`proxy_buffering off`, which is the server-side half of the `X-Accel-Buffering: no` header
`Res.sse` already sends.

### Shutdown cuts long-lived connections

A handler that holds its connection for its whole lifetime is **always cut at**
`serve(shutdown_timeout = …)`: the graceful drain has nothing to wait out, so it reaches its
timeout and force-closes. A producer parked in `write` unwinds the moment the socket is torn down.
One parked on a `sleep`, a `Channel` or an `Event` does not — if it must finish cleanly, give it a
shutdown signal of its own from a `LifecycleMiddleware`'s `on_shutdown`, which runs *before* the
drain begins. See [`terminate`](@ref).

## Why not a `STREAM` route?

A `method = "STREAM"` handler receives the raw `HTTP.Stream` and writes the response itself:

```julia
function raw(stream::HTTP.Stream)
    HTTP.setheader(stream, "Content-Type" => "text/plain")
    startwrite(stream)
    write(stream, "chunk")
    closewrite(stream)
end

path("/raw", raw, method = "STREAM")
```

Writing on the stream marks the response as started, and Nitro's stream handler then **skips
serializing the response the middleware chain returned**. Everything that chain would have added is
dropped: `Cors` headers, [`SecurityHeaders`](@ref), a session `Set-Cookie`, anything your own
middleware appends. Nothing errors — the headers are simply not there.

The chain still *runs* before the handler, though. Global, router and route middleware all apply to
`STREAM` and `WEBSOCKET` routes, as they do to `method = "*"` ones. A guard that refuses the request
returns its own response before the handler starts, and that response is written normally:

```julia
path("/raw", raw, method = "STREAM",
     middleware = [GuardMiddleware(login_required(), role_required("admin"))])
```

What such a middleware gets back from the handler is **not** what the client received. The handler
usually returns `nothing`, and the default serializer turns that into a placeholder `200` response
with a `null` JSON body (under `serve(serialize = false)` the middleware gets the `nothing` itself).
A middleware that logs the status, audits the body or computes an ETag from it is reading that
placeholder, not the bytes the handler wrote to the socket.

So a `STREAM` route owns its entire response head, including every security header it needs. Use it
when that is what you want (a custom protocol, a non-SSE byte stream). For SSE, `Res.sse` returns a
real response and the chain applies exactly as it does to JSON.

WebSockets are the other raw shape — `path("/ws", handler, method = "WEBSOCKET")`, where the handler
takes a `WebSocket`. SSE is one-directional and rides plain HTTP; prefer it when the client only
needs to *listen*.

## Streaming a large file

Unrelated to SSE, but the same neighbourhood: `Res.file(req, path; stream = true)` sends a file in
64 KiB chunks so peak memory is a buffer rather than the file. Static mounts do it automatically
above `stream_threshold` (8 MiB by default). See [`Res.file`](@ref) and [`staticfiles`](@ref).

## Recipe: worker progress over SSE

This is the case [`Workers`](@ref) exists to be paired with — a background job that reports
progress, and a browser that draws a progress bar without polling.

The pieces already exist: a callback updates `TaskInfo.progress` through `update_progress!`, and
`get_task_status` reads it back. What SSE changes is *where* the polling happens: once, on the
server, instead of once per client per second over HTTP.

```julia
using Nitro
using Nitro.Workers

app = App(mod = @__MODULE__)

# Whatever your auth stores, this is where it becomes a worker identity.
# `getuser` is deliberately open-typed, so this bridge is application-specific.
function owner_for(req)
    user = getuser(req)
    if user isa Principal
        # `Principal.id` is `Nullable{String}`: a token with no subject claim still
        # authenticates, and `Owner(nothing)` has no method. Refuse rather than 500.
        isnothing(user.id) && throw(Nitro.AuthorizationError("token carries no subject"))
        return Owner(user.id)
    end
    user isa AbstractDict && return Owner(string(user["user_id"]))
    throw(Nitro.AuthorizationError("no user on this request"))
end

# Submit the job. `update_progress!` is the only supported way to write progress.
# Note `submit_task(app, …)`: the App-first form resolves the runtime `worker_startup`
# installed. A bare `submit_task(…)` would use `default_runtime()` instead -- a different
# runtime with a different store, so the drain, the cleanup scheduler and any custom
# `store =` backend would all be pointed at tasks that are not there.
function start_import(req)
    task_id = submit_task(app, "import", function (task_info)
        for row in 1:100
            update_progress!(task_info, row)
            sleep(0.1)
        end
        return "imported"
    end, owner_for(req))
    return Res.json(Dict("task_id" => task_id))
end

const TERMINAL = ("COMPLETED", "FAILED", "CANCELLED", "NOT_FOUND")

function task_events(req, task_id::String)
    owner = owner_for(req)

    # Authorize BEFORE opening the stream. Once the SSE head is on the wire the status cannot
    # change, so a 404 has to be an ordinary response. This call returns "NOT_FOUND" both for a
    # task that does not exist and for one the caller may not read -- deliberately the same
    # answer, so a client cannot probe which ids exist.
    initial = get_task_status(app, task_id, owner)
    initial[:status] == "NOT_FOUND" && return Res.json(Dict("error" => "unknown task"); status = 404)

    return Res.sse() do events
        last_progress = -1.0
        last_status = ""
        while isopen(events)
            snapshot = get_task_status(app, task_id, owner)
            status = snapshot[:status]

            # `get`, not `snapshot[:progress]`. A NOT_FOUND snapshot is exactly
            # `Dict(:error, :status)` with no other keys, and the row really can vanish
            # mid-stream because the retention sweep runs on its own schedule -- so indexing
            # would raise `KeyError` inside the producer and end the stream with no terminal
            # event at all. Falling back to `last_progress` makes the comparison below false,
            # so nothing is emitted for a row that is gone.
            progress = get(snapshot, :progress, last_progress)
            if progress != last_progress
                write(events, SSEEvent(string(progress); event = "task.progress"))
                last_progress = progress
            end

            # Progress goes out BEFORE the terminal check, so the poll that first sees
            # COMPLETED still delivers the final 100.0. Checking first would freeze the client's
            # bar at the last pre-terminal sample -- and a task that finishes inside one poll
            # interval would emit no progress at all.
            if status != last_status
                write(events, SSEEvent(status; event = "task.status"))
                last_status = status
            end
            if status in TERMINAL
                # `:error` carries the failure text on a FAILED or CANCELLED task. It is internal
                # text, so redact or map it before sending if your tasks can embed query
                # fragments, file paths or identifiers a client should not see.
                err = get(snapshot, :error, nothing)
                isnothing(err) || write(events, SSEEvent(err; event = "task.error"))
                break
            end
            sleep(0.25)
        end
    end
end

urlpatterns(app, "/api", [
    path("/imports", start_import, method = "POST",
         middleware = [GuardMiddleware(login_required())]),
    path("/tasks/<str:task_id>/events", task_events,
         middleware = [GuardMiddleware(login_required())]),
])

serve(app; middleware = [
    worker_startup(app),                      # App-first, to match `submit_task(app, …)`
    BearerAuth(Auth.jwt_validator(secret)),   # whatever populates `getuser(req)`
])
```

Note both halves of the authentication wiring, because the recipe does not work without either.
`login_required()` is **called** — it is a factory taking keyword arguments, so passing the bare
name makes every request raise. And `owner_for` reads `getuser(req)`, which only an auth middleware
populates, so one has to be installed; `BearerAuth` with a JWT validator is the shortest of the
shapes in [Authentication](@ref), and any of them works.

### Three limits worth knowing before you rely on this

**Task ids are strings, not UUIDs.** `submit_task` returns `"<user_id>::<task_key>"` for a
user-scoped task, so the route converter is `<str:task_id>` — `<uuid:…>` would never match. The only
UUID in the worker model is an internal run correlation id that is never exposed and is never a
capability.

The `::` needs no escaping: a colon is legal in a URL path segment, so
`/api/tasks/user-1::import/events` routes as-is. Percent-encoding it works too, because the path
parameter is decoded once on its way to the handler (`Types.pathparams`, not the router itself). What you must not do is split the id on `:` client-side and rebuild it —
the user id is part of the key, and a truncated id is simply a different task.

**Progress is in-process.** `update_progress!` writes the live `TaskInfo` object and does **not**
write the store. `get_task_status` prefers that live object, which is what makes progress visible
with no database round-trip — on the node running the task. The durable row only receives progress
at a terminal transition, so an SSE endpoint on a *different* process sees the status change but not
the intermediate percentages. If you run more than one node, route the events endpoint to the node
holding the task, or write your own progress rows.

**There is no `task.message`.** A task record carries `:error` and no other free-text field, so the
recipe emits `task.progress`, `task.status` and `task.error` only. A general message channel would
need a new carrier on the task model.

### Authorization is not optional here

`get_task_status` authorizes against the `Owner` you pass — a caller may read a task they own or
watch, and nothing else. Passing `System()` bypasses that check entirely, so never build it from
request data. The `GuardMiddleware(login_required())` on the route and the `Owner` derived from the
authenticated identity are two different checks and you want both: the guard decides whether there
is a user, the `Owner` decides which tasks that user can see.
