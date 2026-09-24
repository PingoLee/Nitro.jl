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
getip
setip!
getcontext
Nitro.Principal
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
`400` without calling the handler. The bound value is in the parameter's `.payload` (`.value` for
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
Cookie
Session
Context
validate
ValidationError
UnsupportedMediaTypeError
extract
```
