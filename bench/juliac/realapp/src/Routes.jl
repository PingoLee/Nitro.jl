module Routes

using Nitro: path, RouteDefinition
import ..HealthHandlers

urlpatterns() = RouteDefinition[
    path("/health", HealthHandlers.health, method = "GET"),
]

end # module
