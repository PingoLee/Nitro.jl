# Nitro.jl Routing & Ergonomics Instructions

When writing or modifying routes in **Nitro.jl**, you must follow these rules:

## Routing: Django-Style
- **Use `urlpatterns`**: Always use the centralized `urlpatterns` and `path()` paradigm instead of the old macro-based routing (`@get`, `@post`).
- **Path Converters**: Use `<int:id>`, `<str:slug>`, `<uuid:key>` for path parameters.
- **Modularity**: Sub-routers should be logically separated into their own files and imported using `include_routes()`.

## Request and Response Ergonomics
- **Request Properties**: Use the strict shorthand property accessors (`req.params`, `req.query`, `req.session`, `req.ip`) instead of `req.context` lookup.
- **Response Builders**: Always return responses using the `Res` module functions (`Res.json()`, `Res.status()`, `Res.send()`). Avoid returning raw dictionaries or raw strings directly from handlers.
