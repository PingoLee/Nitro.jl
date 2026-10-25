# Application And Server

[`App`](@ref) is the application handle. Every routing, serving and cookie function takes one as
its first argument, and each also has an argument-less form bound to a process-wide default app —
convenient in a script, but prefer an explicit `App` in library code and tests.

```@docs
App
Nitro.newapp
serve
terminate
internalrequest
getexternalurl
resetstate
Nitro.Core.Constants.SHUTDOWN_TIMEOUT_SECONDS
Nitro.Core.Constants.DEFAULT_READ_HEADER_TIMEOUT_SECONDS
Nitro.Core.Constants.DEFAULT_IDLE_TIMEOUT_SECONDS
Nitro.Core.Constants.DEFAULT_MAX_BODY_BYTES
Nitro.Core.Constants.DEFAULT_MAX_FIELDS
```

## Start-up Failures in a Compiled Executable

In an executable built by `juliac`, an exception that escapes `main` is printed field by field,
secrets included. `serve` replaces what leaves it with a value-free `LoggedException`, and an
executable's `@main` prints `Nitro.startup_failure_text(e)` for anything else. The recipe is in
[Compiling with juliac](@ref "Compiling with juliac (experimental)").

```@docs
Nitro.Core.Errors.startup_failure_text
Nitro.Core.Errors.LoggedException
```

## Environment Resolution

```@docs
current_env
sync_pormg_env!
```
