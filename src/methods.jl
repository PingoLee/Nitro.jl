# This is where methods are coupled to a global state

"""
    resetstate()

Reset all the internal state variables
"""
function resetstate()
    # prevent context reset when created at compile-time
    if (@__MODULE__) == Nitro
        CONTEXT[] = Nitro.Core.App()
        Nitro.Workers.reset_runtime!()
    end
end

"""
    serve(; middleware=[], host="127.0.0.1", port=8080, kwargs...) -> Union{Server, Nothing}

Start the Nitro HTTP server with the registered routes. Runs until `terminate()`
(or `Ctrl-C`); pass `async=true` to return immediately and serve in the background.

Returns the running `Server` in `async=true` mode; in blocking mode it returns
`nothing`, since the server has already shut down by the time control returns and a
shut-down handle is not useful. The returned handle is safe to display: Nitro gives
its servers a custom `show` that prints only the address (see `NitroStreamHandler`),
so secrets captured in the handler closures — cookie/JWT `secret_key`, API keys, DB
credentials — are never printed by an accidental REPL auto-display, `@show`, string
interpolation, or logging. (`dump` bypasses `show` and still walks raw fields; that
is explicit introspection, not accidental disclosure.)

# Keyword arguments
- `middleware=[]`: global middleware applied to every request, outermost first. It sees
  `req.target` in the form the router matches (#341): an absolute-form target
  (`http://host/users`) arrives reduced to its path and query (`/users`), and a path with an
  empty segment (`//admin/…`) is answered `400` before any middleware runs. So a
  `startswith(req.target, "/admin/")` test sees every request routed to a literal `/admin/…`
  path. It does not cover a file below a static mount, whose path is percent-decoded after
  middleware runs (`/files/%70rivate/x` is `private/x`). Guards on the route or router remain
  the place to authorize.
- `host="127.0.0.1"`, `port=8080`: listen address. Keep `host` on loopback when a
  reverse proxy terminates TLS in front of Nitro.
- `async=false`: when `true`, return the running `Server` instead of blocking.
- `parallel=true`: handle requests on the thread pool via `Threads.@spawn`.
- `serialize=true`: auto-format handler return values into responses (see `Res`).
- `catch_errors=true`: convert an error thrown by a handler **or by middleware** into a
  generic `500 Internal Server Error` and log it with its backtrace. A `ValidationError` becomes
  a `400` instead and is recorded at `@debug` only; an `InterruptException` from middleware
  propagates rather than becoming a response. **Stack traces are never sent to the
  client** — the body is always `{"message": "500: Internal Server Error"}`. Applies only with
  `serialize=true`.
- `show_errors=true`: gate **server-side** error logging only (not the client
  response). Leave it `true` in production so failures are recorded in your logs;
  `false` merely silences those logs and does *not* harden the already-generic response.
- `access_log=true`: emit one log line per request. By default only the request
  **path** is logged — query strings are redacted so tokens, API keys, and OAuth
  `code`/`state` carried in URLs never reach the logs.
- `access_log_query=false`: set `true` to log the full target including the query
  string. Only enable when you are certain no secrets travel in query strings.
- `prefix=nothing`: strip a global URL prefix (e.g. `"/api"`) before routing. It matches whole
  path segments: `/api`, `/api/users` and `/api?x=1` are served (as `/`, `/users` and `/?x=1`),
  while `/apiadmin/users` is a `404`, not `/admin/users`. Everything outside the prefix is a
  `404` before any of your middleware runs, and the target global middleware sees keeps its
  leading `/`.
  Trailing slashes are dropped (`"/api/"` is `"/api"`). The prefix is matched byte for byte
  against the raw request-target, so write it as clients send it: ASCII, percent-encoded with
  uppercase escapes, and with no `?`, `#`, whitespace, empty or dot segments. Anything else,
  including `""` and `"/"`, is an `ArgumentError`.
- `revise=:none`: `:lazy`/`:eager` enable Revise-based hot reload (dev only).
- `secret_key`, `httponly`, `secure`, `samesite`: override cookie defaults for this run.
- `shutdown_timeout=10.0`: seconds `terminate` waits for in-flight requests to drain
  before force-closing what remains. `0` skips the graceful phase entirely.
- `max_body_bytes=64*1024*1024`: ceiling on a buffered request body. A request declaring or
  sending more is answered **413** before any middleware runs, and its connection is closed.
  Pass `nothing` to buffer without a ceiling. The default matches the cap the bundled HTTP fork
  already enforces on its non-streaming path, which Nitro's stream handler bypasses (#17).
  Two limits of the check are worth knowing: it does **not** cover WebSocket frames, which leave
  the HTTP stream entirely at upgrade and are bounded by HTTP's own `maxframesize`; and it is a
  floor, not a replacement for `client_max_body_size` at your reverse proxy, which rejects
  oversized uploads before they reach Julia at all. Asking for a ceiling alongside a custom
  `handler` throws, because the handler reads the body itself and Nitro cannot enforce one there;
  pass `max_body_bytes = nothing` if you want to state that explicitly.
- `max_fields=1000`: ceiling on the number of fields in one request, per source: query
  parameters, urlencoded form fields, multipart parts, and the object keys of a JSON body (the
  whole document). A request over it is answered **400** before those fields are hashed into a
  `Dict` (#327). `0` means unlimited. Django's `DATA_UPLOAD_MAX_NUMBER_FIELDS`, same default.
  It also applies to `internalrequest` against the app, and to a parser called outside any
  request (`DEFAULT_MAX_FIELDS`).
- `reuseaddr`: forwarded to `HTTP.listen!`. Defaults to `true` on Linux/macOS, where it
  allows rebinding a port still in `TIME_WAIT`, and to **`false` on Windows**, where
  `SO_REUSEADDR` instead lets a second process bind a port another is actively listening
  on — turning a port conflict into two servers silently splitting the traffic.

Calling `serve` on an app that is **already serving** throws an `ArgumentError`: the second
call would overwrite the running server's handle and strand its port. Terminate that app
first, or give the second listener its own `App`.

**Ctrl-C is honored at both points it can land (#185).** An interrupt inside a startup hook lets
the remaining hooks finish, then unwinds through `terminate` and rethrows — so the app is left
not-serving and `serve` can simply be retried. An interrupt out of the blocking wait
(`async = false`) is the documented way to stop the server, and now tears it down before
returning rather than leaving the listener up.

IP-based controls (rate limiting, audit logging) key on the socket peer address,
resolved for both plain-HTTP and direct-TLS listeners. Behind a reverse proxy,
configure `ExtractIP`/`RateLimiter` with both `trusted_proxies` and the
`forwarded_header` your proxy writes so per-client limits work.

See also `terminate`, `RateLimiter`, and `ExtractIP`.
"""
function serve(; kwargs...)
    async = Base.get(kwargs, :async, false)
    # Whether the server this `finally` would tear down is OURS to tear down. Decided from
    # the context *before* the call, not from a flag set after it: if something is already
    # serving, `Core.serve` rejects this call and that server belongs to somebody else —
    # terminating it here would do the very thing the rejection message asks the caller to do
    # deliberately, making a refused `serve()` lethal to a healthy one. Reading the context up
    # front also still cleans up when a throw lands *after* the handle was installed, which a
    # post-hoc `started = true` would miss.
    ours = !isopen(CONTEXT[].service)
    try
        # Returns the running `HTTP.Server` when async; `nothing` in blocking mode (the
        # server is already down by then, so the handle would be useless). Either way the
        # handle is safe to display — `Nitro.Core.NitroStreamHandler` gives it a `show`
        # that prints only the address, never the secrets captured in handler closures.
        return Nitro.Core.serve(CONTEXT[]; kwargs...)
    finally
        # close server on exit if we aren't running asynchronously
        if !async && ours
            try
                terminate()
            catch e
                # This path's contract is already "Ctrl-C is the quiet exit". `terminate` now
                # rethrows an interrupt raised inside a shutdown hook or the drain (#185), but it
                # does so only AFTER completing the teardown, so there is nothing left to clean
                # up — and printing a stacktrace over a clean shutdown would be noise. Anything
                # else is a real teardown failure and stays loud.
                e isa InterruptException || rethrow()
            finally
                # only reset state on exit if we aren't running asynchronously & are running it interactively
                isinteractive() && resetstate()
            end
        end
    end
end


"""
    serveparallel(; middleware::Vector=[], handler=stream_handler, host="127.0.0.1", port=8080, serialize=true, async=false, catch_errors=true, docs=true, metrics=true, kwargs...)

"""
function serveparallel(; kwargs...)
    @warn "serveparallel() is deprecated. serve() now runs in parallel by default using Threads.@spawn. Please use serve() instead."
    serve(; kwargs...)
end


"""
    worker_startup(; kwargs...)

Create a lifecycle middleware that starts `Nitro.Workers` when `serve()` starts and
shuts the worker runtime down when the server terminates.
"""
worker_startup(; kwargs...) = Nitro.Workers.startup(CONTEXT[]; kwargs...)


### Core Routing Functions (Internal plumbing for path() and urlpatterns()) ###

function route(methods::Vector{String}, path::Union{String,HOFRouter}, func::Function)
    for method in methods
        Nitro.Core.register(CONTEXT[], method, path, func)
    end
end

# This variation supports the do..block syntax
route(func::Function, methods::Vector{String}, path::Union{String,HOFRouter}) = route(methods, path, func)


"""
    staticfiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing,
                include_hidden::Bool=false, allow_symlink_escape::Bool=false,
                etag=:weak_stat, cache_control=nothing, cache=:eager,
                stream_threshold=8*1024*1024, cache_max_bytes=64*1024*1024)

Mount the servable files inside `folder` under `mountdir`, reading each one **once at startup** —
fast to serve, but a change on disk needs a restart. Use [`dynamicfiles`](@ref) to re-read per
request, or [`spafiles`](@ref) for a single-page app.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

It is also **validated**, and throws `ArgumentError` at mount time rather than registering a mount
that cannot work. A segment is refused when it would register as a router pattern (`*`, `**`, or one
containing `{`/`}`) — the rule that has always applied to filenames, so a mount cannot claim URLs a
file may not — or when it is not a legal URL path segment (outside RFC 3986 `pchar`). The router
compares path segments byte for byte and never percent-decodes, so `"my static"` and `"café"` are
refused while `"my%20static"` and `"caf%C3%A9"` mount and serve: the encoded spelling is the one a
conforming client sends. A relative dot-segment (`.`, `..`) is refused too, because clients strip it
before sending.

Note `"café"`, `"a#b"`, `"a|b"` and `"100%"` *were* reachable by a client that sends raw bytes instead
of encoding them (curl does), so refusing them takes a working mount away from those callers, and the
encoded spelling is a different byte string that will not answer them. Only a space, a `?` and
control characters were strictly unmatchable.

Returns `Vector{Pair{String,String}}` — `route => filepath` for everything it registered, in
registration order. An `index.html` contributes two pairs naming the *same* file: its own route and
the bare directory route (`/docs/index.html` also registers `/docs`, and a top-level one registers
`/`). Use `first.(result)` for the routes alone.

Not every file in `folder` is served. These are refused:

- **Hidden entries** — any path component starting with `.` *relative to `folder`*, so `.env` and
  everything under `.git/`. A symlink is judged by what it resolves to as well as by its own name.
- **Symlinks resolving outside `folder`**, so `data.csv -> /etc/passwd` is not served.
- **Filenames the router reads as patterns** — `*` and `**` are wildcards that would shadow sibling
  URLs, and a name containing `{` or `}` is parsed as a path parameter and throws at registration,
  which would stop the server booting.
- **Anything that is not a regular file** — symlinked directories, FIFOs, devices.

A filename that needs percent-encoding is **not** refused — it is served at its **encoded route**.
`café.txt` mounts at `/static/caf%C3%A9.txt` and `my file.txt` at `/static/my%20file.txt`, which are
the URLs a conforming client sends; the router compares path segments byte for byte and never
decodes, so **no conforming client** could reach the unencoded spellings. The returned pair carries
the encoded route and the raw filesystem path, so **do not re-derive one from the other** — read the
route from `first(pair)` rather than rebuilding it from the filename.

Only characters that RFC 3986 forbids in a path segment are encoded, so a name that already works
keeps its exact URL: `report(1).txt`, `a+b.txt`, `v1.2~beta.txt`, `a:b.txt` and `a@b.txt` are all
unchanged. The two costs, both real: a **literal `%`** in a filename is itself encoded, so
`my%20file.txt` moves to `/static/my%2520file.txt` (it has to — otherwise one URL would name both
that file and the encoded form of `my file.txt`); and a non-browser client that was sending raw
UTF-8 bytes to reach `café.txt` gets a 404, because `café` and `caf%C3%A9` are different byte
strings under a byte-exact matcher.

`include_hidden=true` serves dotfiles and `allow_symlink_escape=true` serves escaping symlinks; both
widen what is publicly reachable, so set them deliberately. Note they interact: with
`allow_symlink_escape=true`, a link pointing at a dotfile *outside* the folder is served regardless
of `include_hidden`, because the hidden rule is only meaningful relative to the mount.

These rules are evaluated once, at mount time. A directory whose contents untrusted users can change
belongs behind a reverse proxy — see `docs/design/static-serving-boundary.md`.

To serve a directory that is itself dotted, mount it as its own root — the rule tests components
*below* `folder`, never `folder`'s own name:

```julia
staticfiles("public/.well-known", ".well-known")
```

Note this registers only the files present at startup; anything written later (an ACME
`acme-challenge` token, say) needs its own route.

# Caching, validators and memory

| Keyword | Default | Effect |
|---|---|---|
| `etag` | `:weak_stat` | `W/"<size>-<mtime>"`. Also `:strong` (sha256 of the body served), a `String` used verbatim, or `nothing` for no `ETag` |
| `cache_control` | `nothing` | emitted verbatim when given. **No default is invented** — hashed build output wants a year and an unhashed `index.html` wants zero, and guessing high pins a client to a stale asset |
| `cache` | ``:eager`` | `:eager` reads at mount and holds; `:lazy` reads on first request into a byte-bounded LRU; `:none` re-reads per request |
| `stream_threshold` | 8 MiB | a file larger than this is streamed in chunks rather than buffered, so peak memory is a buffer and not the file. `0` disables streaming |
| `cache_max_bytes` | 64 MiB | the `:lazy` budget, in bytes across the whole mount |

The mount answers conditional GETs (`If-None-Match` / `If-Modified-Since` → `304`) and byte ranges
(`Range` → `206`, an unsatisfiable one → `416`). [`Res.file`](@ref) gives a handler the same thing.

**Validators describe the bytes actually sent.** Under `:eager` and `:lazy` those are a snapshot,
so a change on disk is not picked up and the `ETag` does not move either; under `:none` both track
the file. A mount never re-`stat`s to *detect* a change — which files exist is decided once, at
mount time.

**`etag = :strong` costs what it measures.** It hashes the body it is about to send, so under
`:eager` that is once per file at mount, but under `:none` — and for an entry too large for the
`:lazy` budget — it is a full hash **on every request**. `dynamicfiles(dir; etag = :strong)` over a
100 MB file hashes 100 MB per request. `:weak_stat` is the default for this reason.

**The mount serves `GET` and `HEAD`.** Another method on a mounted file is a `405` whose `Allow`
lists `GET, HEAD` plus any application route at that path. A path naming no mounted file gets
what the router answers there, apart from the mount itself: a `405` with that path's `Allow` when
an application route serves it under another method, otherwise a `404` (#284).

"""
staticfiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:eager,
    stream_threshold::Integer=Nitro.Core.MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=Nitro.Core.MOUNT_CACHE_MAX_BYTES
) = Nitro.Core.staticfiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape, etag, cache_control, cache, stream_threshold, cache_max_bytes)


"""
    spafiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing,
             include_hidden::Bool=false, allow_symlink_escape::Bool=false)

Mount `folder` for a Single Page Application. In addition to registering its servable files, this
registers a catch-all route under `mountdir` that serves `index.html` for any unmatched request,
enabling SPA History Mode routing.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

It is also **validated**, and throws `ArgumentError` at mount time rather than registering a mount
that cannot work. A segment is refused when it would register as a router pattern (`*`, `**`, or one
containing `{`/`}`) — the rule that has always applied to filenames, so a mount cannot claim URLs a
file may not — or when it is not a legal URL path segment (outside RFC 3986 `pchar`). The router
compares path segments byte for byte and never percent-decodes, so `"my static"` and `"café"` are
refused while `"my%20static"` and `"caf%C3%A9"` mount and serve: the encoded spelling is the one a
conforming client sends. A relative dot-segment (`.`, `..`) is refused too, because clients strip it
before sending.

Note `"café"`, `"a#b"`, `"a|b"` and `"100%"` *were* reachable by a client that sends raw bytes instead
of encoding them (curl does), so refusing them takes a working mount away from those callers, and the
encoded spelling is a different byte string that will not answer them. Only a space, a `?` and
control characters were strictly unmatchable.

Returns `Vector{Pair{String,String}}` — `route => filepath` for everything it registered, in
registration order. An `index.html` contributes two pairs naming the *same* file: its own route and
the bare directory route (`/docs/index.html` also registers `/docs`, and a top-level one registers
`/`). Use `first.(result)` for the routes alone.

Which files are servable — and the `include_hidden` / `allow_symlink_escape` opt-outs — is described
in [`staticfiles`](@ref); the same rules apply here. Three SPA-specific consequences:

- The history-mode fallback is registered **only if `index.html` itself is servable.** If it is
  refused (an escaping symlink, say), the fallback is skipped and a warning is logged, rather than
  serving through the mount rules on every unmatched path. Servability is decided by looking the
  file up in what the mount registered, so the fallback serves exactly the bytes the mount chose.
- The fallback route (`/<prefix>/**`) is **not** in the returned vector. It is a catch-all rather
  than a mounted file, and it has no filepath of its own to pair with.
- Because the fallback answers any unmatched path under the mount, a file that *was* refused reads
  as `index.html` with a 200 rather than a 404. That is not a leak, but it can be confusing in logs.
  A filename needing percent-encoding is no longer in that class: it is mounted at its encoded
  route, so `/<prefix>/caf%C3%A9.txt` serves the asset rather than silently resolving to the app
  shell ([#121](https://github.com/PingoLee/Nitro.jl/issues/121)).

# Caching, validators and memory

| Keyword | Default | Effect |
|---|---|---|
| `etag` | `:weak_stat` | `W/"<size>-<mtime>"`. Also `:strong` (sha256 of the body served), a `String` used verbatim, or `nothing` for no `ETag` |
| `cache_control` | `nothing` | emitted verbatim when given. **No default is invented** — hashed build output wants a year and an unhashed `index.html` wants zero, and guessing high pins a client to a stale asset |
| `cache` | ``:eager`` | `:eager` reads at mount and holds; `:lazy` reads on first request into a byte-bounded LRU; `:none` re-reads per request |
| `stream_threshold` | 8 MiB | a file larger than this is streamed in chunks rather than buffered, so peak memory is a buffer and not the file. `0` disables streaming |
| `cache_max_bytes` | 64 MiB | the `:lazy` budget, in bytes across the whole mount |

The mount answers conditional GETs (`If-None-Match` / `If-Modified-Since` → `304`) and byte ranges
(`Range` → `206`, an unsatisfiable one → `416`). [`Res.file`](@ref) gives a handler the same thing.

**Validators describe the bytes actually sent.** Under `:eager` and `:lazy` those are a snapshot,
so a change on disk is not picked up and the `ETag` does not move either; under `:none` both track
the file. A mount never re-`stat`s to *detect* a change — which files exist is decided once, at
mount time.

**`etag = :strong` costs what it measures.** It hashes the body it is about to send, so under
`:eager` that is once per file at mount, but under `:none` — and for an entry too large for the
`:lazy` budget — it is a full hash **on every request**. `dynamicfiles(dir; etag = :strong)` over a
100 MB file hashes 100 MB per request. `:weak_stat` is the default for this reason.

**The mount serves `GET` and `HEAD`.** Another method on a mounted file is a `405` whose `Allow`
lists `GET, HEAD` plus any application route at that path. A path naming no mounted file gets
what the router answers there, apart from the mount itself: a `405` with that path's `Allow` when
an application route serves it under another method, otherwise a `404` (#284). History mode is the
exception for `GET` and `HEAD`: a miss gets the app shell, even at a path an application route
answers under another method.

"""
spafiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:eager,
    stream_threshold::Integer=Nitro.Core.MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=Nitro.Core.MOUNT_CACHE_MAX_BYTES
) = Nitro.Core.spafiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape, etag, cache_control, cache, stream_threshold, cache_max_bytes)


"""
    dynamicfiles(folder::String, mountdir::String="static"; headers::Vector=[], loadfile::Nullable{Function}=nothing,
                 include_hidden::Bool=false, allow_symlink_escape::Bool=false,
                 etag=:weak_stat, cache_control=nothing, cache=:none,
                 stream_threshold=8*1024*1024, cache_max_bytes=64*1024*1024)

Mount the servable files inside `folder` under `mountdir`, re-reading each one **on every request**
so changes on disk are picked up without a restart. Use [`staticfiles`](@ref) to snapshot at startup
instead.

`mountdir` is normalized: surrounding whitespace and `/` are stripped, so `"static"`, `"/static"`,
`"static/"` and `"/static/"` are the same mount, and `""`, `"/"` and whitespace all mount at the router
root.

It is also **validated**, and throws `ArgumentError` at mount time rather than registering a mount
that cannot work. A segment is refused when it would register as a router pattern (`*`, `**`, or one
containing `{`/`}`) — the rule that has always applied to filenames, so a mount cannot claim URLs a
file may not — or when it is not a legal URL path segment (outside RFC 3986 `pchar`). The router
compares path segments byte for byte and never percent-decodes, so `"my static"` and `"café"` are
refused while `"my%20static"` and `"caf%C3%A9"` mount and serve: the encoded spelling is the one a
conforming client sends. A relative dot-segment (`.`, `..`) is refused too, because clients strip it
before sending.

Note `"café"`, `"a#b"`, `"a|b"` and `"100%"` *were* reachable by a client that sends raw bytes instead
of encoding them (curl does), so refusing them takes a working mount away from those callers, and the
encoded spelling is a different byte string that will not answer them. Only a space, a `?` and
control characters were strictly unmatchable.

Returns `Vector{Pair{String,String}}` — `route => filepath` for everything it registered, in
registration order. An `index.html` contributes two pairs naming the *same* file: its own route and
the bare directory route (`/docs/index.html` also registers `/docs`, and a top-level one registers
`/`). Use `first.(result)` for the routes alone.

Which files are servable — and the `include_hidden` / `allow_symlink_escape` opt-outs — is described
in [`staticfiles`](@ref); the same rules apply here. They are evaluated **once, at mount time**: this
re-reads file *contents* per request, not the directory listing or the rules. Only files present at
startup get a route, so a directory that gains files at runtime needs a handler, not a mount.

That makes this the wrong tool for a directory untrusted users can write to — a file swapped for a
symlink after startup is not re-checked. Put a reverse proxy in front of such a directory; see
`docs/design/static-serving-boundary.md`.

# Caching, validators and memory

| Keyword | Default | Effect |
|---|---|---|
| `etag` | `:weak_stat` | `W/"<size>-<mtime>"`. Also `:strong` (sha256 of the body served), a `String` used verbatim, or `nothing` for no `ETag` |
| `cache_control` | `nothing` | emitted verbatim when given. **No default is invented** — hashed build output wants a year and an unhashed `index.html` wants zero, and guessing high pins a client to a stale asset |
| `cache` | ``:none`` | `:eager` reads at mount and holds; `:lazy` reads on first request into a byte-bounded LRU; `:none` re-reads per request |
| `stream_threshold` | 8 MiB | a file larger than this is streamed in chunks rather than buffered, so peak memory is a buffer and not the file. `0` disables streaming |
| `cache_max_bytes` | 64 MiB | the `:lazy` budget, in bytes across the whole mount |

The mount answers conditional GETs (`If-None-Match` / `If-Modified-Since` → `304`) and byte ranges
(`Range` → `206`, an unsatisfiable one → `416`). [`Res.file`](@ref) gives a handler the same thing.

**Validators describe the bytes actually sent.** Under `:eager` and `:lazy` those are a snapshot,
so a change on disk is not picked up and the `ETag` does not move either; under `:none` both track
the file. A mount never re-`stat`s to *detect* a change — which files exist is decided once, at
mount time.

**`etag = :strong` costs what it measures.** It hashes the body it is about to send, so under
`:eager` that is once per file at mount, but under `:none` — and for an entry too large for the
`:lazy` budget — it is a full hash **on every request**. `dynamicfiles(dir; etag = :strong)` over a
100 MB file hashes 100 MB per request. `:weak_stat` is the default for this reason.

**The mount serves `GET` and `HEAD`.** Another method on a mounted file is a `405` whose `Allow`
lists `GET, HEAD` plus any application route at that path. A path naming no mounted file gets
what the router answers there, apart from the mount itself: a `405` with that path's `Allow` when
an application route serves it under another method, otherwise a `404` (#284).

"""
dynamicfiles(
    folder::String,
    mountdir::String="static";
    headers::Vector=[],
    loadfile::Nullable{Function}=nothing,
    include_hidden::Bool=false,
    allow_symlink_escape::Bool=false,
    etag = :weak_stat,
    cache_control::Union{Nothing,AbstractString}=nothing,
    cache::Symbol=:none,
    stream_threshold::Integer=Nitro.Core.MOUNT_STREAM_THRESHOLD,
    cache_max_bytes::Integer=Nitro.Core.MOUNT_CACHE_MAX_BYTES
) = Nitro.Core.dynamicfiles(CONTEXT[], CONTEXT[].service.router, folder, mountdir; headers, loadfile, include_hidden, allow_symlink_escape, etag, cache_control, cache, stream_threshold, cache_max_bytes)

"""
    getexternalurl()

Return the external URL of the service
"""
function getexternalurl() :: String
    external_url = CONTEXT[].service.external_url[]
    if isnothing(external_url)
        error("getexternalurl() is only available when the service is running")
    end
    return external_url
end

"""
    url(name; kwargs...)

Build a URL path for a named route registered through `path(..., name="...")`.
Keyword arguments fill the route parameters.
"""
function url(name::String; kwargs...)
    return Nitro.Core.Routing.url(CONTEXT[], name; kwargs...)
end

"""
    internalrequest(req::Nitro.Request; middleware::Vector=[], serialize::Bool=true, catch_errors=true, context=missing)
    internalrequest(app::App, req::Nitro.Request; kwargs...)

Sends an internal request to the server, allowing for communication between different parts of the application.

!!! warning "A privileged call that skips your global middleware"
    `internalrequest` runs only the `middleware` you pass **to this call**. It does not run the
    global list given to `serve(middleware = …)`, so authentication, sessions, CSRF and rate
    limiting installed there do **not** apply. Route and router middleware, and the guards
    attached through them, still run. Once `serve(prefix = …)` has run, its prefix applies too,
    so include it in the target.

    The request's client IP is `127.0.0.1` unless it already carries one (`setip!`), and a
    request object reused across calls keeps whatever address the previous call left. So a route
    that trusts loopback, or is protected only by global middleware, is reachable through it.
    **Never build the target from client input**: a handler that does lets its caller reach those
    routes too.

Errors go through the same error handling `serve` uses. With `catch_errors=true` (the default), an
exception thrown by a handler **or by middleware** is logged with its backtrace and comes back as
the generic `500` response, instead of being raised. A `ValidationError` comes back as a `400`,
recorded at `@debug` only. An `InterruptException` from middleware is still raised. Pass `catch_errors=false` to have the exception raised to the caller,
which is usually what a test asserting on it wants.

!!! warning "A streamed response body is yours to close"
    This runs the whole pipeline **minus the socket layer**, so it never reaches the write path
    that drains and closes a streaming body. A handler using `Res.file(req, path; stream = true)`,
    or a mounted file above `stream_threshold`, therefore hands back a response whose body is an
    **open cursor**. Drain it with `HTTP.body_read!` until it returns `0`, or call
    `HTTP.body_close!` — otherwise the file handle stays open, which on Windows also blocks
    deleting the file. Over a real socket this never applies: the write path always closes.
"""
internalrequest(req::Nitro.Request; middleware::Vector=[], serialize::Bool=true, catch_errors=true, context=missing) = 
    Nitro.Core.internalrequest(CONTEXT[], req; middleware, serialize, catch_errors, context)

"""
    router(prefix::String = ""; 
                tags::Vector{String} = Vector{String}(), 
                middleware::Nullable{Vector} = nothing)

Create a new router instance.

# Arguments
- `prefix::String`: A string to be prefixed to all routes in this router.
- `tags::Vector{String}`: A vector of strings to tag the router for documentation and management purposes.
- `middleware::Nullable{Vector}`: Optional middleware to be applied to all routes in the router.
  It runs top-down in list order, after global middleware and before each route's own.

# Returns
A router instance that can be used to define and manage a set of related routes.
"""
function router(prefix::String = ""; 
                tags::Vector{String} = Vector{String}(), 
                middleware::Nullable{Vector} = nothing)

    return Nitro.Core.router(CONTEXT[], prefix; tags, middleware)
end

"""
    urlpatterns(prefix, routes...)
    urlpatterns(prefix, routes::Vector{RouteDefinition})

Register routes on the global app, each under `prefix`. The same as
`urlpatterns(app, prefix, routes...)` with the argument-less singleton as `app`.
"""
urlpatterns(prefix::String, routes::Nitro.Core.Routing.RouteDefinition...) = 
    Nitro.Core.Routing.urlpatterns(CONTEXT[], prefix, routes...)

urlpatterns(prefix::String, routes::Vector{Nitro.Core.Routing.RouteDefinition}) =
    Nitro.Core.Routing.urlpatterns(CONTEXT[], prefix, routes)




### Cookie functions ###

"""
    configcookies(defaults::Dict)
    configcookies(; kwargs...)

Configure global cookie defaults for the application. Returns `nothing`.

`secret_key` may be an `AbstractString` or a [`SecretString`](@ref); either way it is stored as a
`SecretString`. Anything else -- bytes, a `Base.SecretBuffer` -- is an `ArgumentError`.
"""
function configcookies(defaults::Dict)
    CONTEXT[].service.cookies[] = Nitro.Core.load_cookie_settings!(defaults)
    # Not the config: returning it put the key in front of every REPL auto-display (#307).
    return nothing
end

function configcookies(; kwargs...)
    configcookies(Dict(string(k) => v for (k, v) in kwargs))
end

# #308 moved the argument-less helpers from the GLOBAL app's cookie config to the SERVING app's.
# One setup is worse off for it: a key configured on the global app (`configcookies(secret_key =
# …)`, no `app`) while an explicit `App` is served. Those helpers used to encrypt under the global
# key by accident; now they would write plaintext without a word. Say so, once, where the mix is
# visible. Never names the key.
function _warn_shadowed_cookie_key(app::App, kwargs)
    app === CONTEXT[] && return nothing
    isnothing(CONTEXT[].service.cookies[].secret_key) && return nothing
    isnothing(app.service.cookies[].secret_key) || return nothing
    isnothing(Base.get(kwargs, :secret_key, nothing)) || return nothing
    @warn "Nitro: a cookie secret_key is configured on the GLOBAL app (`configcookies(secret_key = …)`), " *
          "but the App being served has none, so any cookie it sets is NOT encrypted. `get_cookie`/" *
          "`set_cookie!` use the configuration of the app serving the request (#308) -- configure " *
          "this one with `configcookies(app; secret_key = …)` or `serve(app; secret_key = …)`. " *
          "(An app that sets no cookies can ignore this.)" maxlog = 1
    return nothing
end

# The app whose cookie config the argument-less helpers use: the one SERVING this request, and
# the global app only outside any request (#308). They used to read `CONTEXT[]` always, so an app
# built with an explicit `App` silently wrote plaintext and trusted raw client values -- its key
# lived on the serving app. See `Nitro.Core.SERVING_APP` (src/core/pipeline.jl).
_cookie_app() = something(Nitro.Core.SERVING_APP[], CONTEXT[])

"""
    get_cookie(req::Nitro.Request, name::String, default::Any=nothing; kwargs...)

Get a cookie value from an Nitro request, using the cookie configuration of the [`App`](@ref)
**serving this request** — or the global app when called outside any request. Decrypts
automatically when that app has a `secret_key`; an encrypted cookie that does not open reads as
`default`. The same as `get_cookie(app, req, name, default; kwargs...)` with that app.
"""
function get_cookie(req::Nitro.Request, name::String, default::Any=nothing; kwargs...)
    return get_cookie(_cookie_app(), req, name, default; kwargs...)
end

"""
    set_cookie!(res::Nitro.Response, name::String, value::Any; kwargs...)

Set a cookie on an Nitro response, using the cookie configuration of the [`App`](@ref)
**serving this request** — or the global app when called outside any request. Encrypts when that
app has a `secret_key`. The same as `set_cookie!(app, res, name, value; kwargs...)` with that app.
"""
function set_cookie!(res::Nitro.Response, name::String, value::Any; kwargs...)
    return set_cookie!(_cookie_app(), res, name, value; kwargs...)
end



### Terminate Function ###

"""
    terminate(context::App; timeout = nothing)
    terminate(; timeout = nothing)

Stop the running server: run every `LifecycleMiddleware` shutdown hook and close the listener.
A no-op when nothing is serving. (There is no middleware cache to drop: each pipeline owns its
own, so the next `serve()` starts cold.)

Shutdown is a **bounded graceful drain**, modeled on Go's `http.Server.Shutdown(ctx)`. The
listening socket is released immediately — the port is free as soon as `terminate` is entered
— then Nitro waits up to `timeout` seconds for in-flight requests to finish and force-closes
whatever remains.

`timeout` defaults to the server's own `serve(shutdown_timeout = …)`, itself defaulting to
`Nitro.Core.SHUTDOWN_TIMEOUT_SECONDS` (10 seconds). `timeout = 0` skips the graceful phase.

**This budget is not the whole exit time.** Every `LifecycleMiddleware` shutdown hook runs *before*
the drain begins, and a hook may block: `worker_startup`'s drains in-flight background tasks for up
to `WORKER_DRAIN_TIMEOUT_SECONDS` (5 seconds) of its own. The two are consecutive, so size them
together against a container's stop grace period.

**Long-lived connections are always cut at the timeout.** A WebSocket, SSE, or STREAM handler
holds its connection for its whole lifetime, so the drain can never wait it out. If such a
handler has to finish cleanly, give it a shutdown signal of its own — an `Event` or `Channel`
notified from a `LifecycleMiddleware`'s `on_shutdown`, which runs *before* the drain begins.

!!! warning
    Do not call `terminate()` from inside a request handler. The handler's own connection is
    what the drain is waiting on, so the graceful phase is guaranteed to reach its timeout.

!!! note "Ctrl-C during shutdown"
    An interrupt raised inside a shutdown hook or during the drain does not abandon the teardown:
    every remaining hook still runs, the lifecycle state is still cleared, and the listener is
    still closed — an interrupted drain escalates straight to a force-close, cutting in-flight
    requests rather than waiting out the remaining budget. `terminate` then rethrows the
    `InterruptException`, so it is the one documented way this function throws (#185).

See also `serve`.
"""
terminate(context::App; timeout::Nullable{Real} = nothing) =
    Nitro.Core.terminate(context; timeout)
terminate(; timeout::Nullable{Real} = nothing) = terminate(CONTEXT[]; timeout)


### Setup Docs Strings ###


# `serve` and `terminate` used to be propagated here too. They now carry their docstrings directly
# (above), because a copy leaves the original on `Nitro.Core` where Documenter counts it as a
# docstring missing from the manual (#186). `staticfiles`/`dynamicfiles`/`spafiles` carry their own
# docstrings above, and `Nitro.Core` has none for them, so propagating would replace real docs.
for method in [:internalrequest]
    eval(quote
        @doc (@doc(Nitro.Core.$method)) $method
    end)
end





# ── The explicit `App` surface (#31) ────────────────────────────────────────────────────
#
# Everything above this line is the SINGLETON convenience layer: one-argument-shorter forms
# that read and write the process-wide `CONTEXT[]`. Every one of them is defined HERE, in
# `Nitro`, which means it SHADOWS the same-named function `using .Core` brought in from
# `Nitro.Core` — so before this block, `Nitro.urlpatterns` had only the `CONTEXT[]` methods
# and `Core`'s `(ctx, …)` methods were unreachable through `using Nitro`. Exporting `App`
# without these forwards would have produced a public type with no public API taking it.
#
# Each forward is deliberately thin: it adds the `App` method to the `Nitro`-level function
# and hands straight to the implementation, which already took an app-shaped first argument.
# No behavior is defined here.
#
# `route` is absent on purpose -- it is plumbing for `path`/`urlpatterns`, not public API
# (nitro-core §3). `resetstate` is absent because it is singleton-shaped by definition: the
# `App` equivalent is constructing a new `App`.

"""
    serve(app::App; kwargs...)

Serve `app`. Same keywords as [`serve()`](@ref); see [`App`](@ref) for the handle.

Unlike the singleton form this never calls `resetstate()` on exit — that resets the global
context, which has nothing to do with `app`. A blocking call still terminates the listener
it started.
"""
function serve(app::App; kwargs...)
    _warn_shadowed_cookie_key(app, kwargs)
    async = Base.get(kwargs, :async, false)
    # Same reasoning as the singleton form above: decide ownership BEFORE the call, so a
    # rejected `serve` never tears down the healthy server that caused the rejection.
    ours = !isopen(app.service)
    try
        return Nitro.Core.serve(app; kwargs...)
    finally
        if !async && ours
            try
                terminate(app)
            catch e
                # Same guard as the singleton form above, and for a sharper reason: an exception
                # out of a `finally` REPLACES whatever was propagating. Unguarded, a second Ctrl-C
                # landing in this teardown would overwrite the interrupt `startserver` is already
                # carrying — or print a stacktrace over a clean shutdown. `terminate` completes
                # its sequence before rethrowing (#185), so there is nothing left to do here.
                e isa InterruptException || rethrow()
            end
        end
    end
end

worker_startup(app::App; kwargs...) = Nitro.Workers.startup(app; kwargs...)

"""
    getexternalurl(app::App) -> String

The URL `app` is serving on. Throws if it is not running.
"""
function getexternalurl(app::App) :: String
    external_url = app.service.external_url[]
    isnothing(external_url) && error("getexternalurl is only available while the app is serving")
    return external_url
end

url(app::App, name::String; kwargs...) = Nitro.Core.Routing.url(app, name; kwargs...)

internalrequest(app::App, req::Nitro.Request; middleware::Vector=[], serialize::Bool=true,
                catch_errors=true, context=missing) =
    Nitro.Core.internalrequest(app, req; middleware, serialize, catch_errors, context)

router(app::App, prefix::String = "";
       tags::Vector{String} = Vector{String}(),
       middleware::Nullable{Vector} = nothing) =
    Nitro.Core.router(app, prefix; tags, middleware)

"""
    urlpatterns(app::App, prefix, routes...)
    urlpatterns(app::App, prefix, routes::Vector{RouteDefinition})

Register a group of [`RouteDefinition`](@ref)s on `app`, each under the URL `prefix` (`""` for
none). This is the Django `urlpatterns` list: build the routes with [`path`](@ref), and compose
modules' route lists with [`include_routes`](@ref).

```julia
urlpatterns(app, "/api/v1",
    path("/users", list_users),
    path("/users/<int:id>", get_user; name = "user-detail"),
)
```
"""
urlpatterns(app::App, prefix::String, routes::Nitro.Core.Routing.RouteDefinition...) =
    Nitro.Core.Routing.urlpatterns(app, prefix, routes...)

urlpatterns(app::App, prefix::String, routes::Vector{Nitro.Core.Routing.RouteDefinition}) =
    Nitro.Core.Routing.urlpatterns(app, prefix, routes)

staticfiles(app::App, folder::String, mountdir::String="static"; kwargs...) =
    Nitro.Core.staticfiles(app, app.service.router, folder, mountdir; kwargs...)

spafiles(app::App, folder::String, mountdir::String="static"; kwargs...) =
    Nitro.Core.spafiles(app, app.service.router, folder, mountdir; kwargs...)

dynamicfiles(app::App, folder::String, mountdir::String="static"; kwargs...) =
    Nitro.Core.dynamicfiles(app, app.service.router, folder, mountdir; kwargs...)

"""
    configcookies(app::App, defaults::Dict)
    configcookies(app::App; kwargs...)

Set `app`'s cookie defaults. The only one of these forms that MUTATES the app. Returns `nothing`.
"""
function configcookies(app::App, defaults::Dict)
    app.service.cookies[] = Nitro.Core.load_cookie_settings!(defaults)
    return nothing
end

configcookies(app::App; kwargs...) =
    configcookies(app, Dict(string(k) => v for (k, v) in kwargs))

"""
    get_cookie(app::App, req::Nitro.Request, name::String, default::Any=nothing; kwargs...)

Read cookie `name` from `req` with `app`'s cookie configuration. `encrypted` defaults to whether
`app` has a `secret_key`; an encrypted cookie that does not open — tampered, expired, sealed under
another key or for another cookie name — reads as `default`. Keyword arguments are those of
[`Nitro.Cookies.get_cookie`](@ref).
"""
function get_cookie(app::App, req::Nitro.Request, name::String, default::Any=nothing; kwargs...)
    secret_key = app.service.cookies[].secret_key
    # `encrypted` defaults to whatever the app's config implies.
    encrypted = Base.get(kwargs, :encrypted, !isnothing(secret_key))
    return Nitro.Core.get_cookie(req, name, default; secret_key=secret_key, encrypted=encrypted, kwargs...)
end

"""
    set_cookie!(app::App, res::Nitro.Response, name::String, value::Any; kwargs...)

Append a `Set-Cookie` for `name` to `res` with `app`'s cookie defaults, encrypting when `app` has
a `secret_key`. Keyword arguments are those of [`Nitro.Cookies.set_cookie!`](@ref).
"""
set_cookie!(app::App, res::Nitro.Response, name::String, value::Any; kwargs...) =
    Nitro.Core.set_cookie!(res, name, value; config=app.service.cookies[], kwargs...)
