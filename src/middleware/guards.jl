module GuardsMiddleware

using HTTP
using ...Core: getsession
using ...Types: Nullable

export GuardMiddleware

"""
    GuardMiddleware(guards::Function...)

Creates a middleware from one or more guard functions. Guards are composable 
pre-handler functions that run before the route handler.

## Guard Contract
- A guard receives an `HTTP.Request` and returns either:
  - `nothing` → continue to the next guard or handler
  - An `HTTP.Response` → short-circuit and return this response immediately

## Built-in Guard Factories

### `login_required(; redirect_url="/login")`
Checks for `getsession(req)["user_id"]`. Redirects if not found.

### `role_required(role::String)`
Checks for `getsession(req)["role"]`. Returns 403 if mismatch.

## Example
```julia
# Define guards
function login_required(; redirect_url="/login")
    return function(req)
        session = isnothing(getsession(req)) ? Dict{String,Any}() : getsession(req)
        if !haskey(session, "user_id")
            return HTTP.Response(302, ["Location" => redirect_url])
        end
        nothing
    end
end

# Use as middleware
path("/dashboard", dashboard_handler, method="GET",
    middleware=[GuardMiddleware(login_required())])

# Or stack multiple guards
path("/admin", admin_handler, method="GET",
    middleware=[GuardMiddleware(
        login_required(),
        role_required("admin"),
    )])
```
"""
function GuardMiddleware(guards::Function...)
    return function(handle::Function)
        return function(req::HTTP.Request)
            # Run each guard in order
            for guard in guards
                result = guard(req)
                if result isa HTTP.Response
                    return result  # Short-circuit
                end
            end
            # All guards passed, proceed to handler
            return handle(req)
        end
    end
end

# ─── Built-in Guards ──────────────────────────────────────────────────

"""
    login_required(; redirect_url="/login", session_key="user_id")

Guard that checks if the user is authenticated by looking for a key in the session.
Returns a redirect response if not authenticated, `nothing` if OK.

## Example
```julia
path("/dashboard", handler, middleware=[GuardMiddleware(login_required())])
```
"""
function login_required(; redirect_url::String="/login", session_key::String="user_id")
    return function(req::HTTP.Request)
        session = isnothing(getsession(req)) ? Dict{String,Any}() : getsession(req)
        if !haskey(session, session_key)
            return HTTP.Response(302, ["Location" => redirect_url])
        end
        nothing
    end
end

"""
    role_required(role::String; session_key="role")

Guard that checks if the user has the required role in their session.
Returns a 403 Forbidden response if the role doesn't match.

## Example
```julia
path("/admin", handler, middleware=[GuardMiddleware(
    login_required(),
    role_required("admin"),
)])
```
"""
function role_required(role::String; session_key::String="role")
    return function(req::HTTP.Request)
        session = isnothing(getsession(req)) ? Dict{String,Any}() : getsession(req)
        user_role = get(session, session_key, nothing)
        if isnothing(user_role) || user_role != role
            return HTTP.Response(403, ["Content-Type" => "application/json"], 
                codeunits("{\"error\":\"Forbidden\"}"))
        end
        nothing
    end
end

export login_required, role_required

end # module
