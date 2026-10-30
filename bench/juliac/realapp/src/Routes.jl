module Routes

using Nitro: path, RouteDefinition
import ..HealthHandlers, ..ItemHandlers, ..MiscHandlers

# `session` and `bearer` are built in `main`, after the database is loaded: the PormG session
# store connects when it is constructed.
urlpatterns(; session, bearer) = RouteDefinition[
    path("/health", HealthHandlers.health, method = "GET"),
    path("/items", ItemHandlers.list_items, method = "GET"),
    path("/items/<int:id>", ItemHandlers.get_item, method = "GET"),
    path("/items", ItemHandlers.create_item, method = "POST"),
    path("/items/validated", ItemHandlers.validated, method = "POST"),
    path("/search/<str:category>", ItemHandlers.search, method = "GET"),
    path("/session", MiscHandlers.session_visits, method = "GET", middleware = [session]),
    path("/me", MiscHandlers.me, method = "GET", middleware = [bearer]),
    path("/file", MiscHandlers.file, method = "GET"),
    path("/bad", MiscHandlers.bad, method = "GET"),
]

end # module
