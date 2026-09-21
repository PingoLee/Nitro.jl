module Middleware
using Reexport

# First, and deliberately NOT `@reexport`ed: `JanitorMiddleware` is internal plumbing that
# `rate_limiter.jl` and `session_middleware.jl` reach as `using ..JanitorMiddleware` (#190).
include("middleware/janitor.jl")
include("middleware/extract_ip.jl"); @reexport using .ExtractIPMiddleware
include("middleware/rate_limiter.jl"); @reexport using .RateLimiterMiddleware
include("middleware/auth_middleware.jl"); @reexport using .AuthMiddleware
include("middleware/cors_middleware.jl"); @reexport using .CORSMiddleware
include("middleware/security_headers.jl"); @reexport using .SecurityHeadersMiddleware
include("middleware/csrf_middleware.jl"); @reexport using .CSRFMiddleware_
include("middleware/session_middleware.jl"); @reexport using .SessionMiddleware_
include("middleware/guards.jl"); @reexport using .GuardsMiddleware
include("middleware/access_log.jl"); @reexport using .StructuredAccessLogMiddleware

end