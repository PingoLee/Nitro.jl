# #745: turn a `--trace-compile` file into a roots file, one signature per line, for
# `roots_loader.jl` to root with `Base.Experimental.entrypoint` while an image is built.
#
#   julia bench/juliac/roots.jl <trace.jl> <roots.txt>
#
# A trace line is `precompile(Tuple{…})`, possibly after a `#= … =#` timing prefix. What cannot be
# rooted from text is counted and dropped here:
#   - closures: a signature naming a `var"#…"` type (an anonymous function or a closure; its type
#     name is a gensym of the tracing process, not a name the build process can resolve);
#   - unparsed: any line that is not a `precompile(Tuple{…})` call.
# What survives can still fail while the image is built (a name that does not resolve, a
# signature that is not a dispatch tuple); roots_loader.jl counts those.

length(ARGS) == 2 || error("usage: roots.jl <trace.jl> <roots.txt>")
const TRACE, OUT = ARGS

const LINE = r"^(?:#=.*?=#\s*)?precompile\((Tuple\{.*\})\)\s*(?:#.*)?$"

kept = String[]
closures = 0
unparsed = 0
total = 0
for line in eachline(TRACE)
    isempty(strip(line)) && continue
    global total += 1
    m = match(LINE, line)
    if m === nothing
        global unparsed += 1
    elseif occursin("var\"#", m.captures[1])
        global closures += 1
    else
        push!(kept, m.captures[1])
    end
end
unique!(kept)
open(OUT, "w") do io
    foreach(sig -> println(io, sig), kept)
end
println("roots.jl: $total trace lines; $(length(kept)) distinct signatures kept; ",
        "dropped $closures closure lines, $unparsed unparsed lines -> $OUT")
