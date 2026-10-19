# Requests And Extractors

## Request Accessors

Handlers read the request through exported accessor functions — there is no `req.<property>`
sugar. Each accessor parses once per request and caches, so calling one twice is free and both
calls return the same object; treat what they return as read-only and pass values down a request
through `req.context`.

| Accessor | Gives you |
|----------|-----------|
| `getparams(req)` | Path parameters, percent-decoded exactly once |
| `getquery(req)` | Query-string parameters |
| `getjson(req)` | Parsed JSON body, or `nothing` when empty/malformed |
| `getform(req)` | Parsed urlencoded form body |
| `getfiles(req)` | File parts of a multipart body (Django `request.FILES`) |
| `getpost(req)` | Text fields of a multipart body (Django `request.POST`) |
| `payload(req)` | Merged input — `params > post > form > json > query` |
| `getsession(req)` | Session dict, with `SessionMiddleware` in the pipeline |
| `getuser(req)` | The authenticated user, once an auth middleware has run |
| `getprincipal(req)` | The verified token `Principal` — its `id`, `kid` and claims — whichever validator flow put it there |
| `getip(req)` | Client IP — the socket peer, or the forwarded client with `ExtractIP` |

`queryparams`, also exported, is `HTTP.queryparams` re-exported unchanged: it parses a URI's query
string with no caching. Inside a handler, `getquery(req)` is the accessor to use.

```@docs
getparams
getquery
getjson
getform
getfiles
getpost
payload
getsession
setsession!
getuser
getprincipal
getip
setip!
getcontext
Nitro.Principal
```

## Cancellation

A handler cannot be stopped from outside: Julia tasks cannot be killed. One that runs long asks
instead whether to stop, the same way a background job does. `cancel_requested(req)` turns `true`
when the client disconnects or `terminate` begins the shutdown drain, and `cancel_reason(req)`
says which. [Long-Running Handlers](@ref) has the pattern and what it costs.

```@docs
cancel_reason(::Nitro.Request)
cancel_requested(::Nitro.Request)
```

## Request Body Parsers

The bare `text`, `json`, `binary`, `formdata` and `multipart` are the *body parsers* the accessors
above are built on: they re-read and re-parse on every call, take keyword arguments, and also
accept an `HTTP.Response`. Reach for the `get*` accessor in a handler and the parser when you need
a one-off parse with options. They are not response builders; those live in [`Res`](@ref).

```@docs
text
json
binary
formdata
multipart
FormFile
```

## Extractors

An extractor is a handler parameter whose *type* says where its value comes from. Nitro binds it
before the handler runs, and a value that does not bind or does not validate is answered with a
`400` without calling the handler (a `415` when the body has the wrong media type). The exception
is [`Claims`](@ref), which binds the verified token claims rather than client input: it answers
`401` without a token principal and `403` when the claims do not bind, through its denial
factories (see [the error contract](../tutorial/authentication.md#Claims{T}-and-the-error-contract)). The bound value is in the parameter's `.payload` (`.value` for
[`Cookie`](@ref)). [Request Body](../tutorial/request_body.md),
[Query Parameters](../tutorial/query_parameters.md) and [File Uploads](../tutorial/file_uploads.md)
walk through them.

```@docs
Path
Query
Header
Json
JsonFragment
Form
Body
Files
MultipartForm
Claims
Cookie
Session
Context
validate
ValidationError
UnsupportedMediaTypeError
extract
```
