# API

## Server

```@docs
App
serve
terminate
internalrequest
```

## Routing

```@docs
path
urlpatterns
include_routes
url
RouteDefinition
convert_django_path
router
```

## Context And Requests

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
| `getip(req)` | Client IP, with `ExtractIP` in the pipeline |

The bare `text`, `json`, `binary`, `formdata` and `multipart` below are the *body parsers* those
accessors are built on: they re-read and re-parse on every call, take keyword arguments, and also
accept an `HTTP.Response`. Reach for the `get*` accessor in a handler and the parser when you need
a one-off parse with options. `LazyRequest` remains the extractor-facing wrapper.

```@docs
Context
queryparams
getparams
getquery
getjson
getform
getfiles
getpost
payload
getsession
getuser
getip
getcontext
text
json
binary
formdata
```

## Responses

`Res` is the response-building namespace for handlers: `Res.json`, `Res.html`, `Res.send`, `Res.status`,
`Res.file` and `Res.redirect`. The bare names `text`, `json` and `binary` are *request body
parsers* (see [Context And Requests](@ref)), not response builders.

```@docs
Res
Res.json
Res.html
Res.send
Res.status
Res.file
Res.redirect
```

## Cookies And Sessions

```@docs
configcookies
get_cookie
set_cookie!
Cookie
Session
SessionMiddleware
```

## Middleware

```@docs
BearerAuth
Cors
RateLimiter
ExtractIP
extract_ip
getpeerip
GuardMiddleware
login_required
role_required
AccessLog
AccessRecord
```

## Files

```@docs
staticfiles
dynamicfiles
spafiles
```

## File Uploads

```@docs
FormFile
multipart
Files
```

## Secrets

```@docs
SecretString
reveal
```

## Environment

```@docs
current_env
sync_pormg_env!
```

## Utilities

```@docs
resetstate
```
