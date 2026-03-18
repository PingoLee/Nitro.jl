# Development Hot Reload

This guide explains how to use `Revise.jl` with Nitro during development without loading `Revise` in production.

The intended workflow is:

- development sessions load `Revise`
- production sessions load only `Nitro`

Nitro integrates with `Revise` as an optional package extension, so hot reload is only active when `Revise` is actually loaded.

## When To Use This

Use hot reload when you are actively editing routes, middleware, or app code and want the running server to pick up changes without restarting the whole Julia session.

Use normal startup in production, CI, or any deployment where you want the smallest runtime surface.

## Basic Development Setup

For a simple Nitro app, start Julia and load `Revise` before `Nitro`:

```julia
using Revise
using Nitro
using HTTP

function health(req::HTTP.Request)
    return Res.json(Dict("ok" => true))
end

urlpatterns("",
    path("/health", health, method="GET"),
)

serve(revise=:lazy)
```

This does two things:

1. `Revise` becomes available in the Julia session.
2. Nitro's `Revise` extension loads automatically and enables the `revise` option.

## Available Modes

Nitro supports three values for the `revise` keyword.

### `revise=:none`

Disables hot reload.

```julia
serve(revise=:none)
```

This is the default behavior.

### `revise=:lazy`

Checks for revisions before handling each request.

```julia
serve(revise=:lazy)
```

This is usually the easiest development mode to reason about.

### `revise=:eager`

Waits for revision notifications and applies them in the background.

```julia
serve(revise=:eager)
```

Use this if you prefer code changes to be revised as soon as they are detected.

## Production Setup

Production should not load `Revise`.

```julia
using Nitro

serve()
```

That keeps the production process simpler and avoids loading any hot-reload machinery.

## Package-Based Apps

Many Nitro applications are packaged as a Julia module instead of a single script. Your `BI.jl` layout is a good example of that pattern.

In that setup, the end user usually does not call `serve(...)` directly. They call a package function such as `start_server(...)`.

For hot reload to be usable there, the package wrapper should expose a `revise` keyword and pass it through to Nitro.

For example:

```julia
module MyApp

using Nitro

function start_server(; revise=:none, async=false)
    # app bootstrap here
    serve(; revise=revise, async=async)
end

end
```

Then the end user runs development mode like this:

```julia
using Revise
using MyApp

MyApp.start_server(revise=:lazy)
```

And production like this:

```julia
using MyApp

MyApp.start_server()
```

## Does This Fit A `BI.jl`-Style App?

Yes, with one requirement.

If your app module contains:

```julia
using Nitro

function start_server(...)
    serve(...)
end
```

then the Revise integration fits well. The only thing you need is to expose the `revise` option in that wrapper.

For example, change:

```julia
function start_server(env::String=current_env(); async=false)
    serve(; async=async)
end
```

to:

```julia
function start_server(env::String=current_env(); async=false, revise=:none)
    serve(; async=async, revise=revise)
end
```

Then the end user can do:

```julia
using Revise
using BI

BI.start_server("dev"; revise=:lazy)
```

## Important Rule About Load Order

In development, load `Revise` before the application package.

Good:

```julia
using Revise
using BI
```

Not recommended:

```julia
using BI
using Revise
```

The first pattern is the safe and expected one for a Revise-based development session.

## Troubleshooting

### "Revise support is unavailable"

This means Nitro did not detect active Revise hooks.

Check the following:

1. `Revise` is installed in the active Julia environment.
2. You loaded `Revise` before `Nitro` or your Nitro-based application package.
3. Your app wrapper passes `revise=:lazy` or `revise=:eager` through to `serve(...)`.

### My package starts Nitro, but hot reload never turns on

Your package wrapper probably does not forward the `revise` keyword yet.

### Should I use this in production?

No. Production should just start the app without loading `Revise`.

## Summary

- `Revise` is optional
- development loads `Revise` first
- production does not load `Revise`
- package-based apps should forward `revise` from their own startup function to `Nitro.serve(...)`