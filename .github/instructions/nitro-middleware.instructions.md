---
applyTo: "**/*.jl"
description: "Nitro.jl middleware and security rules — linear execution order, guards vs middleware, session management"
---

# Nitro.jl Middleware & Security Instructions

When working with middleware, security, or sessions in **Nitro.jl**, adhere to these guidelines:

## Security & Middleware
- **Linear Execution**: Middleware executes strictly Top-Down: Global Prefix Middleware -> Custom Middleware -> Defaults -> Router.
- **Guards vs Middleware**:
  - Use **Guards** (e.g., `login_required`, `role_required`) for route-specific authentication or authorization. Guards are functions that run before the handler and can abort the request early.
  - Use **Middleware** (e.g., `SessionMiddleware`, `RateLimiter`) for global, application-wide, or router-wide checks and mutations.

## Session Management
- Ensure `SessionMiddleware` is configured properly in the global pipeline for stateful apps.
- Access session data directly via `req.session`.
