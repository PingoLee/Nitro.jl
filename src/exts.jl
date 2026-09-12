"""
This module holds all the partial function & struct definitions for all package extensions
"""

export ProtoBuffer, protobuf
export mustache, otera
export png, svg, pdf
export pormg_nitro_session, pormg_nitro_worker, sync_pormg_env!

# Serialization extension definitions
function protobuf end
struct ProtoBuffer{T} <: Extractor{T}
    payload::T
end

# Templating extension definitions
function mustache end
function otera end

# Plotting extension definitions
function png end
function svg end
function pdf end

"""
    pormg_nitro_session(; db_key="db") -> PormGSessionStore

Create a database-backed session store using PormG.
Automatically ensures the `nitro_session` table and index exist (IF NOT EXISTS).

Requires `using PormG` and a configured PormG connection.

## Example
```julia
using Nitro, PormG
PormG.Configuration.load("db")

store = pormg_nitro_session()
serve(middleware=[SessionMiddleware(store=store)])
```
"""
function pormg_nitro_session end

"""
    sync_pormg_env!(; force::Bool = false) -> String

Publish Nitro's resolved environment ([`current_env`](@ref)) to `ENV["PORMG_ENV"]`, the
variable PormG's own configuration loader consults. Returns whatever `PORMG_ENV` holds
afterwards.

**A default, never a force.** With `force = false` (the default) an existing `PORMG_ENV` is
left exactly as it is. PormG's documented precedence stays intact either way:

```
env= kwarg  >  ENV["PORMG_ENV"]  >  `default_env:` in connection.yml  >  "dev"
```

so an explicit `env=` at a `load` call site always wins regardless of this function. Pass
`force = true` only to deliberately overwrite a value already there.

`NitroPormGExt.__init__` calls this for you at `using PormG`, which is what lets an app write
`PormG.Configuration.load_many(["db"])` with no `env=` and still get the right environment.
Call it by hand only if you set `NITRO_ENV` *after* loading PormG — see the load-order note in
the environment docs.

Requires `using PormG`; without the extension loaded this is a `MethodError`, exactly like
`pormg_nitro_worker`.

## Example
```julia
using Nitro, PormG
# ENV["PORMG_ENV"] is already seeded from NITRO_ENV here.
PormG.Configuration.load_many(["db"])
```
"""
function sync_pormg_env! end

"""
    pormg_nitro_worker(; db_key="db") -> PormGWorkerStore

Create a database-backed worker task store using PormG.
Automatically ensures the `nitro_task` table and index exist (IF NOT EXISTS).

Requires `using PormG` and a configured PormG connection.
"""
function pormg_nitro_worker end
