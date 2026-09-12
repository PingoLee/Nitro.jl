module Util

using Reexport
using ..Res

# Bring all our utilities under one module

include("utilities/bodyparsers.jl"); @reexport using .BodyParsers
# No `import .BodyParsers: ...` here on purpose (#28). That import existed ONLY so the
# deleted `render.jl` could ADD response-building methods to the parser generics rather
# than shadow them. Response building now lives in `Res`; re-adding it would invite that
# shadowing bug back. `@reexport using .BodyParsers` above already publishes the names.
include("utilities/misc.jl");
include("utilities/fileutil.jl");


end