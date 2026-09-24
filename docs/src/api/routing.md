# Routing API

Routes are declared Django-style: [`path`](@ref) builds a [`RouteDefinition`](@ref),
[`urlpatterns`](@ref) registers a group of them under a prefix, and [`include_routes`](@ref)
composes another module's route list under a sub-prefix. There are no macro or function route
registrars. The walkthrough is in [Path Parameters](../tutorial/path_parameters.md) and
[Bigger Applications](../tutorial/bigger_applications.md).

```@docs
path
urlpatterns
include_routes
url
RouteDefinition
router
```

## Static And SPA Mounts

```@docs
staticfiles
dynamicfiles
spafiles
```
