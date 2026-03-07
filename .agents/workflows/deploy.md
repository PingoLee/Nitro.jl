---
description: Prepare and validate the application for production deployment
---

# Production Deployment Workflow

When the user wants to prepare the application for production, execute these pre-flight checks.

## 1. Environment Configuration Check
- Verify that a `settings.jl` or `.env` template exists.
- Ensure `DEBUG` mode is configured to be `false` in production.
- Verify that `SESSION_BACKEND` and `SECRET_KEY` are read from the environment.

## 2. Dependency Audit
- Check `Project.toml` to ensure no test-only dependencies are creeping into the main `[deps]`.
- Verify the `[extensions]` block is correctly configured for `PormG.jl` (if used).

## 3. Nginx / Infrastructure Setup
- If requested, generate or verify the `nginx.conf` stub to ensure it correctly proxies requests to the Nitro.jl backend (`proxy_pass http://127.0.0.1:8080`) and handles SPA fallback (`try_files $uri $uri/ /index.html;`).

// turbo-all
## 4. Final Verification
Run the full test suite one last time.
Command: `julia --project=. -e "using Pkg; Pkg.test()"`

Format the codebase to ensure consistency.
Command: `julia --project=. -e "using JuliaFormatter; format(\"src\"); format(\"test\")"`
