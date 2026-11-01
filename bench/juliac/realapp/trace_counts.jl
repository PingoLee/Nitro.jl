# What each route's first request compiled, by package (#744): reads the per-route files
# trace.sh writes (`<route>.jl`, one `precompile(...)` statement per line) and counts the
# statements by the package of the function being compiled, the callee in `Tuple{typeof(f), …}`
# (or the type in `Tuple{Type{T}, …}`, or the module of a closure in `getfield(M, …)`). Base and
# Core count as Base; anything not listed below counts as `other`, and the report names them.
# A trace taken with TRACE_TIMING=1 (`--trace-compile-timing`) prefixes each statement with its
# compile time, `#= 12.3 ms =#`; the report then gives the milliseconds per package too.
#
#   julia bench/juliac/realapp/trace_counts.jl bench/results/realapp-trace-<stamp>

const PACKAGES = ["Nitro", "PormG", "Postgres", "HTTP", "Reseau", "JSON", "StructUtils", "Base"]

const TIMING = r"^#=\s*([0-9.]+) ms =#\s*"

# The statement's compile time in ms (0.0 when the trace was not timed) and the statement itself.
function split_timing(line::AbstractString)
    m = match(TIMING, line)
    m === nothing && return 0.0, line
    return parse(Float64, m[1]), line[length(m.match)+1:end]
end

function owner(line::AbstractString)
    s = replace(line, r"^precompile\(Tuple\{" => "")
    while true
        t = replace(s, r"^(typeof\(|Type\{|getfield\(|var\")" => "")
        t == s && break
        s = t
    end
    m = match(r"^([A-Za-z_][A-Za-z0-9_]*)", s)
    m === nothing && return "other"
    root = m[1] in ("Base", "Core") ? "Base" : m[1]
    return root
end

function main(dir)
    routes = sort([splitext(f)[1] for f in readdir(dir) if endswith(f, ".jl") && !startswith(f, "full-")])
    println("| route | statements | ", join(PACKAGES, " | "), " | other |")
    println("|---|--:|", repeat("--:|", length(PACKAGES) + 1))
    others = Dict{String,Int}()
    timed = false
    cell(c, t, k) = timed ? string(get(c, k, 0), " (", round(Int, get(t, k, 0.0)), " ms)") : string(get(c, k, 0))
    for r in routes
        lines = [split_timing(l) for l in readlines(joinpath(dir, r * ".jl"))]
        filter!(l -> startswith(l[2], "precompile("), lines)
        counts = Dict{String,Int}(); ms = Dict{String,Float64}()
        for (t, l) in lines
            timed |= t > 0
            o = owner(l)
            k = o in PACKAGES ? o : "other"
            o in PACKAGES || (others[o] = get(others, o, 0) + 1)
            counts[k] = get(counts, k, 0) + 1
            ms[k] = get(ms, k, 0.0) + t
        end
        total = timed ? string(length(lines), " (", round(Int, sum(first, lines; init = 0.0)), " ms)") : string(length(lines))
        println("| ", r, " | ", total, " | ", join((cell(counts, ms, p) for p in PACKAGES), " | "),
                " | ", cell(counts, ms, "other"), " |")
    end
    isempty(others) || println("\nother: ", join(("$k $v" for (k, v) in sort(collect(others); by = last, rev = true)), ", "))
end

main(ARGS[1])
