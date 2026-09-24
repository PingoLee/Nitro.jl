# Application And Server

[`App`](@ref) is the application handle. Every routing, serving and cookie function takes one as
its first argument, and each also has an argument-less form bound to a process-wide default app —
convenient in a script, but prefer an explicit `App` in library code and tests.

```@docs
App
serve
terminate
internalrequest
getexternalurl
resetstate
Nitro.Core.Constants.SHUTDOWN_TIMEOUT_SECONDS
Nitro.Core.Constants.DEFAULT_MAX_BODY_BYTES
```

## Environment Resolution

```@docs
current_env
sync_pormg_env!
```
