## In a juliac executable, an error leaving `serve` is a value-free `LoggedException`, and `@main` prints `Nitro.startup_failure_text` (#749, #752)

- **Version**: Unreleased
- **Nitro ref**: #749, #752; `src/methods.jl`, `src/errors.jl`, `src/Nitro.jl`
- **Recorded**: 2026-10-25
- **Severity**: behavior change, only in an executable built by `juliac` (trimmed or not). Under the JIT nothing changes.

### What changed

An executable built by `juliac` prints an exception that escapes `main` by walking its raw fields,
so any secret the exception reaches (a CSRF secret, a JWT key, a `SecretString`'s contents) is
written to `stderr` in clear.

- **`serve` throws a value-free exception there.** In a juliac executable, trimmed or `--trim=no`,
  an error that leaves either `serve` form is rethrown as a `Nitro.Errors.LoggedException`. Its
  `type` is the original's type name (`:AddressInUseError`, `:MethodError`). Its `text` keeps the
  message of an `ArgumentError` or an `ErrorException`, or the address of a port already in use.
  The backtrace is kept, and nothing else is. An interrupt still passes through as itself. Under
  the JIT, `serve` rethrows the original exception, as before. So code that catches a specific
  exception type around `serve`, typically `HTTP.AddressInUseError` to fall back to another port,
  stops matching in an executable.
- **`LoggedException` and its two fields are public** (not exported), and so is the new
  `Nitro.startup_failure_text(e)::String`. That helper builds the line for any exception: the
  same text `serve` keeps, or the type name with its contents withheld. It keeps an
  `ErrorException`'s or an `ArgumentError`'s message verbatim, so the app's own messages must not
  interpolate a secret.
- **Every juliac executable's `@main` catches what escapes and prints that line** on
  `Core.stderr`. `serve` cannot reach a failure in the app's own start-up code before it, so that
  failure still leaks without the recipe. The recipe in `docs/src/tutorial/deployment.md` is
  required for every juliac executable, trimmed or not.

`serve` recognizes an executable by `Main._main`, the entry point both juliac build scripts define.
An application that defines a global `_main` in `Main` itself makes a JIT session read as an
executable too. Rename it.

### How to find the calls to migrate

```bash
# Code that catches a specific exception around serve:
grep -rn -A8 'serve(' --include=*.jl . | grep -E 'AddressInUseError|catch'
# An executable's entry point, and the earlier form of the recipe:
grep -rn -E '@main|LoggedException|nameof\(typeof\(e\)\)' --include=*.jl .
# A global `_main` defined by the application:
grep -rn -E '(function|const)[[:space:]]+_main\b|^[[:space:]]*_main[[:space:]]*(\(|=)' --include=*.jl .
```

### Before → after

```julia
# before: a port already in use, caught by type
try
    serve(app; port)
catch e
    e isa HTTP.AddressInUseError || rethrow()
    serve(app; port = port + 1)
end

# after: in an executable it arrives as a LoggedException carrying the type's name
try
    serve(app; port)
catch e
    in_use = e isa HTTP.AddressInUseError ||
             (e isa Nitro.Errors.LoggedException && e.type === :AddressInUseError)
    in_use || rethrow()
    serve(app; port = port + 1)
end
```

```julia
# before: no handler, or the earlier recipe
function (@main)(args::Vector{String})::Cint
    serve(app; host = "0.0.0.0", port = 8080)
    return Cint(0)
end

# after: catch what escapes and print the value-free line
function (@main)(args::Vector{String})::Cint
    try
        # load the config, resolve the secrets, run the initializers, then:
        serve(app; host = "0.0.0.0", port = 8080)
    catch e
        e isa InterruptException && rethrow()
        println(Core.stderr, "start-up failed: ", Nitro.startup_failure_text(e))
        return Cint(1)
    end
    return Cint(0)
end
```
