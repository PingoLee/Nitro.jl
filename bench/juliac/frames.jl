# Count a `build.sh` log's verifier errors by their first frame inside Nitro's `src/` (#718).
#
#   julia bench/juliac/frames.jl bench/results/juliac-<stamp>-<entry>-<mode>.log
#
# docs/design/juliac-trim.md §1 counts errors this way rather than by the raw total, because the
# verifier reports the first dynamic call on each path and one line of Nitro can account for
# many frames below it. An error with no frame in `src/` is counted under "outside src/", with
# its own first frame, so an upstream wall stays visible. A row names the file, line and function
# (empty for an anonymous closure). Each error is printed twice by the verifier, so the counts here
# are the log's, not the number of distinct sites.

const LOG = get(ARGS, 1, "")
isfile(LOG) || error("usage: frames.jl <build.sh log>")

# A stack line is ` [k] func(…)` followed by `   @ Module path:line`.
const FRAME = r"^\s*\[\d+\] (.*)$"
const WHERE = r"^\s*@ \S+ (.+):(\d+)"

function first_frames(lines::Vector{String})
    counts = Dict{String,Int}()
    i = 1
    while i <= length(lines)
        if startswith(lines[i], "Verifier error")
            mine, other = nothing, nothing
            j = i + 1
            while j <= length(lines) && !startswith(lines[j], "Verifier ") &&
                  !startswith(lines[j], "Failed to compile") && !startswith(lines[j], "build:")
                m = match(FRAME, lines[j])
                if m !== nothing && j < length(lines)
                    w = match(WHERE, lines[j + 1])
                    if w !== nothing
                        func = first(split(m.captures[1], '('))
                        path = w.captures[1]
                        k = findlast("/src/", path)
                        if k !== nothing && occursin(r"Nitro|worktrees|/app/", path) && mine === nothing
                            mine = string(path[k.start+1:end], ":", w.captures[2], " ", func)
                        elseif other === nothing
                            other = string(basename(path), " ", func)
                        end
                    end
                end
                j += 1
            end
            key = mine !== nothing ? mine : string("outside src/: ", something(other, "?"))
            counts[key] = get(counts, key, 0) + 1
            i = j
        else
            i += 1
        end
    end
    return counts
end

counts = first_frames(readlines(LOG))
for (k, n) in sort!(collect(counts); by = last, rev = true)
    println(lpad(n, 4), "  ", k)
end
println(lpad(sum(values(counts); init = 0), 4), "  total")
