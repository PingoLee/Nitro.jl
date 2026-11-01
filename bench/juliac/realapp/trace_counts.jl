# What each route's first request compiled, by package (#744): reads the per-route files
# trace.sh writes (`<route>.jl`, one `precompile(...)` statement per line) and counts the
# statements by the package of the function being compiled, the callee in `Tuple{typeof(f), …}`
# (or the type in `Tuple{Type{T}, …}`, or the module of a closure in `getfield(M, …)`). Base and
# Core count as Base; anything not listed below counts as `other`, and the report names them.
#
#   julia bench/juliac/realapp/trace_counts.jl bench/results/realapp-trace-<stamp>

const PACKAGES = ["Nitro", "PormG", "Postgres", "HTTP", "Reseau", "JSON", "StructUtils", "Base"]

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
    for r in routes
        lines = filter(l -> startswith(l, "precompile("), readlines(joinpath(dir, r * ".jl")))
        counts = Dict{String,Int}()
        for l in lines
            o = owner(l)
            if o in PACKAGES
                counts[o] = get(counts, o, 0) + 1
            else
                counts["other"] = get(counts, "other", 0) + 1
                others[o] = get(others, o, 0) + 1
            end
        end
        println("| ", r, " | ", length(lines), " | ", join((get(counts, p, 0) for p in PACKAGES), " | "),
                " | ", get(counts, "other", 0), " |")
    end
    isempty(others) || println("\nother: ", join(("$k $v" for (k, v) in sort(collect(others); by = last, rev = true)), ", "))
end

main(ARGS[1])
