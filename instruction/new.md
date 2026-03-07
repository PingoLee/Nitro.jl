# Nitro.jl Forking Workflow (Revised)

This workflow defines the architectural evolution from Nitro.jl to **Nitro.jl**. The goal is to build a high-performance, developer-friendly framework specifically optimized for Julia-based SPA/API backends.

## Goals
1. **Django-like Routing**: Centralized URL dispatching with hierarchical inclusion.
2. **Integrated Persistence**: Seamless integration with **PormG.jl** as the recommended ORM, loaded via Julia **package extension** (`ext/NitroPormGExt.jl`). PormG.jl is an external package (`github.com/PingoLee/PormG.jl`) — Nitro works without it, but becomes a full-stack solution when combined.
   > [!NOTE]
   > PormG is NOT a hard dependency. Users who only need a JSON API server pay zero DB overhead. The extension auto-loads only when the user does `using Nitro, PormG`.
3. **Session Management**: Robust, multi-backend session handling (Cookie, Redis, PormG) (Django-like approach).
4. **SPA/API First**: Native support for JSON APIs, CORS, and History Mode routing for Quasar/Vue/React.
5. **Observability**: Structured JSON logging and telemetry for production monitoring.
   > [!NOTE]
   > Essential for moving Julia out of the "scientific computing bubble" and into corporate/enterprise environments where structured observability is mandatory.

## Workflow Steps

### 0. Subtraction (Strip Down the Core)
Before building new features, strip Nitro.jl of everything that doesn't belong in a stateless SPA/API server:
- **Delete modules**: `cron.jl`, `repeattasks.jl`, `metrics.jl`, `autodoc.jl`.
- **Clean references**: Remove all cron/task/metrics/docs logic from `core.jl`, `context.jl`, `types.jl`, `methods.jl`, `routerhof.jl`, and the main `Nitro.jl` module.
- **Remove unused deps**: Strip `Statistics`, `RelocatableFolders` from `Project.toml`.
- **Delete test files**: `crontests.jl`, `metricstests.jl`, `autodoctests.jl`, `reflectiontests.jl`, `cronmanagement.jl`, `taskmanagement.jl`.
  > [!NOTE]
  > Background workers (cron/repeat tasks) will be extracted into a separate standalone package (see `todo.md`). This keeps the HTTP server stateless and horizontally scalable.

### 1. Refactor the Routing System
- Move from purely macro-based routing to a centralized `urlpatterns` approach.
- **Path Converters**: Implement `<int:id>`, `<uuid:key>`, and `<str:slug>` with automatic type conversion.
- **Route Inclusion**: Enable `include("api/urls.jl")` to allow modular application structures.
- **Metaprogramming**: Use Julia macros to pre-compile route patterns into a high-speed Trie at startup.

### 2. PormG.jl Integration via Package Extension
All PormG-related code lives in `ext/NitroPormGExt.jl`, loaded automatically when the user has both `Nitro` and `PormG` installed.
- **Connection Pooling**: Implement a middleware that provides a managed database connection from PormG.jl to each request.
  > [!NOTE]
  > This avoids developers having to manage connections manually in each route handler.
- **Transaction Context**: Wrap request handlers in optional transaction scopes.
- **DI Container**: Provide a simple way to inject services or configuration into handlers.
- **Project.toml Configuration**:
  ```toml
  [weakdeps]
  PormG = "<uuid>"

  [extensions]
  NitroPormGExt = "PormG"
  ```

### 3. Session & Security Middleware
- **Session Backends**: Support `CookieBackend` (encrypted) and `DatabaseBackend` (via PormG.jl).
- **Security Defaults**: Force `HttpOnly`, `Secure`, and `SameSite=Lax` for all session cookies.
- **CORS**: Build a high-performance CORS middleware that handles pre-flight requests (OPTIONS) without triggering the full handler logic.
- **Guards & Route Decorators** (Django-like `@login_required`):
  Guards are composable functions that run before a route handler. If a guard returns a response, the handler is skipped.
  ```julia
  # Define guards as regular functions
  function login_required(; redirect_url="/login")
      return function(req)
          if !haskey(req.session, "user_id")
              return redirect(redirect_url)
          end
          nothing  # nil = continue to handler
      end
  end

  function role_required(role::String)
      return function(req)
          if req.session["role"] != role
              return res.status(403).json(Dict("error" => "Forbidden"))
          end
          nothing
      end
  end

  # Usage — stackable guards array
  route("/dashboard", method=GET, guards=[login_required()]) do req
      res.json(Dict("message" => "Welcome!"))
  end

  route("/admin", method=GET, guards=[
      login_required(redirect_url="/login"),
      role_required("admin")
  ]) do req
      res.json(Dict("admin_panel" => true))
  end
  ```
  > [!NOTE]
  > Guards are regular Julia functions — easy to test in isolation, compose via arrays, and reuse across routes. Julia macros (`@login_required`) can be offered as optional syntactic sugar on top.

### 4. SPA & Static File Handling
- **History Mode Support (Dev Mode)**: Built-in fallback that serves `index.html` for non-API 404 errors. This enables Quasar/Vue/React Router to work during local development without nginx.
  > [!IMPORTANT]
  > In production, nginx handles static files and SPA fallback via `try_files $uri $uri/ /index.html;` — this is significantly faster than serving through Julia. Nitro becomes a **pure API server** behind nginx.
- **Compression**: Add native Gzip/Brotli support for static assets (dev mode; nginx handles this in production).
- **JSON Optimization**: Use `StructTypes.jl` or specialized encoders for ultra-fast PormG-to-JSON serialization.

### 5. Lifecycle & Telemetry
- **Graceful Shutdown**: Implement listeners for `SIGTERM` to close PormG.jl connection pools and flush logs before the process exits.
  > [!NOTE]
  > Crucial for data integrity in high-performance servers. Without graceful shutdown, in-flight database transactions and buffered logs can be lost.
- **Structured Logging**: Replace standard output with JSON logs (Timestamp, Level, RequestID, Path, Latency).

### 6. Centralized Configuration (`settings.jl`)
Inspired by Django's `settings.py` — a single file that is THE source of truth for all framework configuration. Nitro reads it automatically on `serve()`.
```julia
# settings.jl
module Settings

# Core
const DEBUG = get(ENV, "NITRO_DEBUG", "true") == "true"
const SECRET_KEY = ENV["NITRO_SECRET_KEY"]
const PORT = parse(Int, get(ENV, "NITRO_PORT", "8080"))

# Database (used by PormG extension when loaded)
const DATABASE = Dict(
    "engine"   => "postgresql",
    "host"     => get(ENV, "DB_HOST", "localhost"),
    "port"     => parse(Int, get(ENV, "DB_PORT", "5432")),
    "name"     => get(ENV, "DB_NAME", "myapp"),
    "user"     => get(ENV, "DB_USER", "postgres"),
    "password" => ENV["DB_PASSWORD"],
)

# Sessions
const SESSION_BACKEND = :cookie  # :cookie | :database | :redis
const SESSION_MAX_AGE = 86400    # 24 hours

# Security
const CORS_ORIGINS = ["http://localhost:9000", "https://myapp.com"]
const ALLOWED_HOSTS = ["myapp.com", "localhost"]

# Middleware pipeline (order matters!)
const MIDDLEWARE = [
    Nitro.SecurityMiddleware,
    Nitro.SessionMiddleware,
    Nitro.CORSMiddleware,
]

end # module
```
> [!NOTE]
> Because `settings.jl` is just Julia code, it supports `ENV` reads, conditionals, and imports natively. Unlike Node.js (fragmented config) or Go (boilerplate structs), Nitro knows exactly where to look — and validates all settings at startup before accepting any requests.

## Go-Inspired Concurrency Model
- **Request/Response Objects**: Provide a predictable API: `res.json(data)`, `res.status(201)`, `req.params`.
- **Predictable Pipeline**: Middleware execution must be strictly linear.
- **Concurrency**: All handlers run via `Threads.@spawn` (like Go goroutines). Each request is dispatched to an available thread from the pool. No handler can starve others — if one blocks, the remaining threads keep serving.
  > [!IMPORTANT]
  > Julia's `@spawn` tasks are lightweight (like Go goroutines), NOT heavy OS threads. This is fundamentally different from Node.js's single-threaded event loop. Julia does NOT need PM2/cluster mode for performance.
  ```julia
  # ALL handlers are @spawn'd to the thread pool by default
  route("/api/users", method=GET) do req
      users = PormG.query(User)  # I/O — thread yields, others keep working
      res.json(users)
  end

  route("/api/schedule", method=POST) do req
      result = heavy_computation(req.body)  # CPU — runs on one thread, others unaffected
      res.json(result)
  end
  ```

## Deployment Architecture (Nginx + Nitro.jl)

In production, Nitro.jl runs as a **pure API server** behind nginx:

```
Client ──▶ Nginx (port 80/443)
             ├── /api/*    ──▶ proxy_pass http://127.0.0.1:8080  (Nitro.jl)
             └── /*        ──▶ try_files (SPA static files served by nginx)
```

- **Nginx responsibilities**: SSL termination, static file serving (SPA), Gzip/Brotli compression.
- **Nitro responsibilities**: API routing, sessions, PormG queries, business logic.
- **Startup**: `julia -t auto app.jl` — all CPU cores are used natively via `@spawn`. No PM2 or cluster mode needed.
- **Multi-process (optional)**: Nginx can load-balance across N Nitro processes, but only for **redundancy**, NOT for performance. A single `julia -t auto` process already uses all cores. Use cases for multi-process:
  - **Zero-downtime deploys**: Restart one process while others keep serving requests.
  - **Fault isolation**: If one process crashes (e.g., OOM, unhandled exception), the others survive and nginx automatically routes around it.
  - **Memory limits**: If a single long-running process grows too large, it can be recycled independently without dropping all active connections.

## Implementation Guidelines
- Prioritize **Type Stability** in the `Request` object to avoid performance regression.
- Maintain a "Pay only for what you use" philosophy — PormG integration lives in `ext/NitroPormGExt.jl` (a Julia package extension), Sessions can work without a DB (cookie-only mode).
- Ensure 100% test coverage for the `PormG` connection lifecycle within the extension.
- PormG.jl is developed externally at `github.com/PingoLee/PormG.jl` (branch `feature/sqlite-support`). Nitro pins a compatible version range but does not vendor the code.