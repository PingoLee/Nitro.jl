# API

## Server

```@docs
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

Direct handler request ergonomics use `req.params`, `req.query`, `req.json`, `req.form`, `req.input`, `req.session`, and `req.ip`. `LazyRequest` remains the extractor-facing wrapper.

```@docs
Context
context
queryparams
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
