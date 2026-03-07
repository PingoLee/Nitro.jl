# Project Todos

## Architecture
- [ ] **Background Workers Package**: Create a separate standalone package (e.g., `NitroWorkers.jl` or similar) to handle background tasks, cron jobs, and repeat tasks. 
  - **Justification**: In an SPA/API-first Node.js/Django style architecture, HTTP servers should be stateless and dedicated entirely to request/response handling. Background jobs in the same process cause memory/CPU spikes that degrade API performance and make horizontal scaling difficult (multiple instances would run duplicate cron jobs).
  - **Action Item**: Extract the `cron.jl`, `repeattasks.jl`, and task management logic currently being deleted from Nitro's core into this new decoupled package.

- [ ] **Session Middleware**: Check if is possible to implement a session middleware that stores session data in a database or other persistent storage in future versions (im want add PormG for this and redis for this)

- [ ] **Django route style**: 
  - Check if is possible remove the macros,
  - Check if is need keep the routes without macro

- [ ] **Tests**: 
  -  Use a same patern of test macro from Genie