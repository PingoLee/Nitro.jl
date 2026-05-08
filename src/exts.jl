"""
This module holds all the partial function & struct definitions for all package extensions
"""

export ProtoBuffer, protobuf
export mustache, otera
export png, svg, pdf
export pormg_nitro_session

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
