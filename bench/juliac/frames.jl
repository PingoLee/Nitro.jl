# Count a `build.sh` log's verifier errors by their first frame inside Nitro's `src/` (#718).
#
#   julia bench/juliac/frames.jl bench/results/juliac-<stamp>-<entry>-<mode>.log
#
# docs/design/juliac-trim.md §1 counts errors this way rather than by the raw total, because the
# verifier reports the first dynamic call on each path and one line of Nitro can account for
# many frames below it. An error with no frame in `src/` is counted under "outside src/", with
# its own first frame, so an upstream wall stays visible. A row names the file, line and function
# (empty for an anonymous closure). The verifier can report one site more than once, so the counts
# here are the log's, not the number of distinct sites.
#
# It reads the format of Julia 1.13's verifier (JuliaC), which spreads the statement over several
# lines and leaves a blank line before the stack. A warning has the same `Error #N:` header:
#
#   Error #4: unresolved call from statement getindex(
#     getfield((…)::App, :app_context::Symbol)::Ref{Any}
#   )::Any
#
#   Stacktrace:
#    [1] (::Nitro.Core.var"#_app_context_seed##2#…"{…})(req::Request{HTTP.EmptyBody})
#      @ Nitro.Core ~/app/Nitro.jl/src/core/pipeline.jl:33
#
# The log ends with `Trim verify finished with N errors, M warnings.`, which this script checks
# its total against. Julia 1.12's bundled driver printed `Verifier error #N:` with the statement
# on one line; that format left with the 1.12 floor (#526).

const LOG = get(ARGS, 1, "")
isfile(LOG) || error("usage: frames.jl <build.sh log>")

# An error starts at its header; its frames are the ` [k] func(…)` / `   @ Module path:line` pairs
# after `Stacktrace:`, which keeps a statement's own text out of the frame match.
const HEADER = r"^Error #\d+: "
const FRAME = r"^\s*\[\d+\] (.*)$"
const WHERE = r"^\s*@ \S+ (.+):(\d+)"
const SUMMARY = r"^Trim verify finished with (\d+) errors?, (\d+) warnings?"

block_end(line) = occursin(HEADER, line) || occursin(SUMMARY, line) ||
                  startswith(line, "Failed to compile") || startswith(line, "build:")

function first_frames(lines::Vector{String})
    counts = Dict{String,Int}()
    i = 1
    while i <= length(lines)
        if occursin(HEADER, lines[i])
            mine, other = nothing, nothing
            in_stack = false
            j = i + 1
            while j <= length(lines) && !block_end(lines[j])
                if startswith(lines[j], "Stacktrace:")
                    in_stack = true
                elseif in_stack && j < length(lines) && (m = match(FRAME, lines[j])) !== nothing
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

lines = readlines(LOG)
counts = first_frames(lines)
for (k, n) in sort!(collect(counts); by = last, rev = true)
    println(lpad(n, 4), "  ", k)
end
total = sum(values(counts); init = 0)
println(lpad(total, 4), "  total")

# The verifier's own count, when the log has it: a mismatch means a block this parser missed, or
# a log cut short (stderr redirected to a file rather than piped, see build.sh).
summary = findlast(l -> occursin(SUMMARY, l), lines)
if summary === nothing
    total > 0 && println("warning: no `Trim verify finished` line; the log may be truncated")
else
    m = match(SUMMARY, lines[summary])
    reported = parse(Int, m.captures[1]) + parse(Int, m.captures[2])
    reported == total || println("warning: the verifier reported $reported, this parser found $total")
end
