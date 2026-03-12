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

```@docs
Context
context
queryparams
formdata
```

## Responses

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

## Utilities

```@docs
redirect
resetstate
```
