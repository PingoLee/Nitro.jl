# Responses

`Res` is the response-building namespace for handlers: `Res.json`, `Res.html`, `Res.send`, `Res.status`,
`Res.file`, `Res.redirect` and `Res.sse`. The bare names `text`, `json` and `binary` are *request body
parsers* (see [Request Body Parsers](@ref)), not response builders.

`Res.sse` is the one builder whose body is not materialized when it returns — it opens a
Server-Sent Events stream that a producer fills afterwards. `Res.pause` is the wait between two of
its events, and it returns early when the server shuts down. See
[Streaming And Server-Sent Events](@ref) for the shape and its limits.

```@docs
Res
Res.json
Res.html
Res.send
Res.status
Res.file
Res.redirect
Res.sse
Res.pause
Res.SSE_MAX_EVENT_BYTES
```
