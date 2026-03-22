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
formdata
```

## Responses

The `Res` module is the preferred response surface for handlers and includes `Res.json`, `Res.send`, `Res.status`, `Res.file`, and `Res.redirect`.

```@docs
html
text
json
file
xml
js
css
binary
Res
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
GuardMiddleware
login_required
role_required
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

## Utilities

```@docs
redirect
resetstate
```
