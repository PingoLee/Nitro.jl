---
description: Create a new API route, handler, and test for Nitro.jl
---

# Add Route Workflow

When the user asks to add a new route, follow these exact steps to maintain the Nitro.jl architecture.

## 1. Create the Handler
- If the route belongs to an existing domain (e.g., `users`, `products`), open the corresponding file (e.g., `src/api/users.jl`).
- If it's a new domain, create a new file and `include()` it in the main application file.
- Create a function that accepts `req::HTTP.Request` and any defined path parameters (`<int:id>`).
- Use the `Res` module to return the response (e.g., `return Res.json(...)` or `return Res.status(...)`).

## 2. Register the Route
- Locate the main `urlpatterns` block where routes are grouped.
- Add your new route using the `path()` function.
- Example: `path("/my-new-route", my_handler, method="GET")`
- If adding to a sub-router, ensure it's registered via `include_routes()`.

## 3. Apply Middleware/Guards (If applicable)
- Does the route require authentication? Add `guards=[login_required()]` to the `path` definition.
- Does it require an admin role? Add `guards=[login_required(), role_required("admin")]`.

## 4. Write tests
- Open the relevant test file in the `test/` directory.
- Add a `@test` verifying the endpoint behavior.
- Ensure you test the "happy path" (200 OK) and any expected error paths (e.g., 401 Unauthorized if guards are used).

// turbo-all
## 5. Verify the Route
Run the test suite to ensure the new route works and hasn't broken anything else.
Command: `julia --project=. -e "using Pkg; Pkg.test()"`
