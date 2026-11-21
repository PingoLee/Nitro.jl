# The report of bench/julia/bypass.sh's question 1 (#618, agent-config #82 Idea 13): four columns,
# ctl (the tag), m1 and m2 (two builds of the mark), bp (the bypass build), in the cells it ran; and,
# when the driver reran cells with a second build of the bypass commit (bp2, under <OUT>/bp2/), those
# cells with ctl, m2, bp and bp2.
#   julia bench/julia/bypass_report.jl <OUT>        (OUT: the driver's results directory)
#   DECIDE_OUT=<file>: also write, for the six cells of the prompt, "step<TAB>cell<TAB>reading" (the
#   driver's `decide` step: a cell read as the path is rerun with bp2).
# Per cell: each column's median [min-max] over rounds; the per-round ratios m2/bp, bp/ctl, m2/ctl
# and m2/m1, median [min-max], with how many rounds lean each way; the position each column took in
# each round; and a reading of the cell against the prompt's three outcomes (layout, path, neither).
# A ratio is slower/faster as the metric says: fib_fine and tasks.jl are times (above 1 = slower),
# spawn_order is throughput (below 1 = slower). Stdlib only.

const OUT = isempty(ARGS) ? error("usage: julia bypass_report.jl <OUT>") : ARGS[1]

med(v) = (s = sort(v); n = length(s); n == 0 ? NaN : isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
f3(x) = isnan(x) ? "-" : string(round(x; digits = 3))
fmt(v) = isempty(v) ? "-" : string(f3(med(v)), " [", f3(minimum(v)), "-", f3(maximum(v)), "]")

const ALLCOLS = ["ctl", "m1", "m2", "bp", "bp2"]
# fib_fine and spawn_order rows name the build by its commit: ctl the tag, m1 the dirty-tree build of
# the mark, m2 its clean rebuild, bp the bypass commit, bp2 its second build (a tree marked dirty by
# an untracked file, which Julia reads at run time: the image is built from the same sources).
function col_of_commit(c)
    c = first(split(c, '/'))
    c == "c1ac32ab73" && return "ctl"
    c == "b4f05f4d47*" && return "m1"
    c == "b4f05f4d47" && return "m2"
    c == "fc9fb3e643" && return "bp"
    c == "fc9fb3e643*" && return "bp2"
    error("unknown build $c")
end
const TOKEN = Dict("A%control" => "ctl", "N-none%mark1" => "m1", "N-none%mark" => "m2", "N-none%bypass" => "bp",
                   "N-none%bypass2" => "bp2")

# cell => round => col => (value, position)
const DATA = Dict{String,Dict{Int,Dict{String,Tuple{Float64,Int}}}}()
const LOWER_BETTER = Dict{String,Bool}()
function addrow!(cell, r, col, v, lower)
    d = get!(() -> Dict{Int,Dict{String,Tuple{Float64,Int}}}(), DATA, cell)
    rd = get!(() -> Dict{String,Tuple{Float64,Int}}(), d, r)
    haskey(rd, col) && error("$cell round $r: two rows for $col")
    rd[col] = (v, length(rd) + 1)
    LOWER_BETTER[cell] = lower
end

function read_tsv(path)
    lines = readlines(path)
    hdr = split(lines[1], '\t')
    return [Dict(zip(hdr, split(l, '\t'))) for l in lines[2:end] if !isempty(l) && !startswith(l, "julia\t")]
end

const STEP_OF = Dict{String,String}()   # cell => the driver step that ran it
const SPAWNS = Dict{String,Int}()       # fib_fine cell => tasks spawned per run (for ns per spawn)
function read_dir(base, pre)
    isdir(base) || return
    for d in sort(readdir(base))
        p = joinpath(base, d)
        # only question 1's step directories (f21, c41, ...): not q3spawn, window, prego or bp2
        (isdir(p) && occursin(r"^[fc][0-9]{2}$", d)) || continue
        f = joinpath(p, "fibabba-nested.tsv")
        if isfile(f)
            for row in read_tsv(f)
                row["bench"] == "fib_fine" || continue
                cell = "$(pre)fib_fine $(row["threads"]) (s)"
                STEP_OF[cell] = d
                SPAWNS[cell] = parse(Int, row["spawns"])
                addrow!(cell, parse(Int, row["round"]), col_of_commit(row["commit"]), parse(Float64, row["wall_median_s"]), true)
            end
        end
        f = joinpath(p, "costrounds-spawn.tsv")
        if isfile(f)
            for row in read_tsv(f)
                cell = "$(pre)H = 0 C = $(row["c"]) $(row["clients"]) $(row["threads"]) (rps)"
                STEP_OF[cell] = d
                addrow!(cell, parse(Int, row["round"]), col_of_commit(row["commit"]), parse(Float64, row["rps"]), false)
            end
        end
        f = joinpath(p, "costrounds-micro.tsv")
        if isfile(f)
            for l in readlines(f)
                x = split(l, '\t')
                length(x) >= 8 || continue
                name = x[7]
                name in ("SpawnWait", "FanOut1000") || continue
                startswith(x[8], "ns_per_op=") || continue
                cell = "$(pre)tasks.jl $(name) $(x[3]) (ns)"
                STEP_OF[cell] = d
                addrow!(cell, parse(Int, x[1]), TOKEN[x[4]], parse(Float64, x[8][11:end]), true)
            end
        end
    end
end
read_dir(OUT, "")
const BP2 = "bp2 rerun: "
read_dir(joinpath(OUT, "bp2"), BP2)
# The prompt's six cells (the battery's cells where m1 and m2 agreed off ctl at 2 and 4 threads).
const SIX = ["fib_fine 2,1 (s)", "H = 0 C = 50 default 2,1 (rps)", "H = 0 C = 50 default 4,1 (rps)",
             "tasks.jl FanOut1000 2,0 (ns)", "tasks.jl FanOut1000 2,1 (ns)", "tasks.jl SpawnWait 2,1 (ns)",
             "tasks.jl SpawnWait 4,1 (ns)"]
const FLOOR = Dict{String,Float64}()
const READING = Dict{String,String}()

isempty(DATA) && error("no rows under $OUT")
# The main cells first (their floors are the bp2 reruns' floors), then the reruns.
for cell in sort(collect(keys(DATA)); by = c -> (startswith(c, BP2), c))
    rounds = DATA[cell]
    rs = sort(collect(keys(rounds)))
    cols = [c for c in ALLCOLS if any(r -> haskey(rounds[r], c), rs)]
    full = [r for r in rs if all(c -> haskey(rounds[r], c), cols)]
    println("## ", cell, "  (", length(full), " complete rounds of ", length(rs), ")")
    vals(c) = [rounds[r][c][1] for r in full]
    for c in cols
        println("  ", rpad(c, 4), fmt(vals(c)))
    end
    ratio(a, b) = [rounds[r][a][1] / rounds[r][b][1] for r in full]
    slower(x) = LOWER_BETTER[cell] ? x > 1 : x < 1
    R = Dict{String,Vector{Float64}}()
    for (a, b) in (("m2", "bp"), ("bp", "ctl"), ("m2", "ctl"), ("m2", "m1"), ("m1", "ctl"),
                   ("m2", "bp2"), ("bp2", "ctl"), ("bp2", "bp"))
        (a in cols && b in cols) || continue
        v = ratio(a, b); R["$a/$b"] = v
        println("  ", rpad("$a/$b", 8), fmt(v), "   slower in ", count(slower, v), " of ", length(v))
    end
    println("  positions (round: order of columns):")
    for r in full
        println("    r", r, ": ", join(sort(cols; by = c -> rounds[r][c][2]), " "),
                "   m2/bp ", f3(rounds[r]["m2"][1] / rounds[r]["bp"][1]),
                " bp/ctl ", f3(rounds[r]["bp"][1] / rounds[r]["ctl"][1]),
                " m2/ctl ", f3(rounds[r]["m2"][1] / rounds[r]["ctl"][1]),
                "bp2" in cols ? string(" m2/bp2 ", f3(rounds[r]["m2"][1] / rounds[r]["bp2"][1]),
                                       " bp2/ctl ", f3(rounds[r]["bp2"][1] / rounds[r]["ctl"][1])) : "")
    end
    # The reading, a hint against the prompt's outcomes: the floor is m2/m1's distance from 1 (at
    # least 0.5%; a rerun takes its main cell's floor); "off" is a median ratio farther from 1 than
    # the floor.
    main = replace(cell, BP2 => "")
    floor_ = haskey(R, "m2/m1") ? max(abs(med(R["m2/m1"]) - 1), 0.005) : get(FLOOR, main, 0.005)
    FLOOR[cell] = floor_
    off(v) = abs(med(v) - 1) > floor_
    mbp, bc, mc = R["m2/bp"], R["bp/ctl"], R["m2/ctl"]
    # Where bp2 ran, each bypass build is read on its own, by direction: "towards" is off in the
    # direction m2 is off ctl. A build is path-like when m2 is off it towards and it is not off ctl
    # towards; layout-like when m2 is within the floor of it and it is off ctl towards; between when
    # both m2/b and b/ctl are off towards (it sits between ctl and m2).
    sg = sign(med(mc) - 1)
    towards(v) = off(v) && sign(med(v) - 1) == sg
    function kind(b)
        mb, bc_ = R["m2/$b"], R["$b/ctl"]
        towards(mb) && !towards(bc_) && return "path"
        !off(mb) && towards(bc_) && return "layout"
        towards(mb) && towards(bc_) && return "between"
        return "unclear"
    end
    key, reading = if !off(mc)
        "none", "nothing to attribute: m2 is within the floor of ctl in this run"
    elseif !haskey(R, "m2/bp2")
        if !off(mbp) && off(bc) && sign(med(bc) - 1) == sg
            "layout", "layout: bp stands with the mark builds (m2/bp within the floor), off ctl as they are"
        elseif off(mbp) && !off(bc)
            "path", "path: bp stands with ctl, m2/bp carries the difference"
        else
            "neither", "neither: read the four columns"
        end
    else
        k1, k2 = kind("bp"), kind("bp2")
        if k1 == k2
            k1, string("the two bypass builds agree: both ", k1,
                       k1 == "path" ? " (with ctl, m2 off both)" : k1 == "layout" ? " (with the mark build, off ctl)" :
                       k1 == "between" ? " (each between ctl and m2: part path, part not)" : "")
        else
            "split", string("the two bypass builds disagree: bp ", k1, ", bp2 ", k2, " (one layout draw each; not the path)")
        end
    end
    READING[cell] = key
    println("  floor ", f3(floor_), "; reading (hint): ", reading)
    # The path's cost where both bypass builds ran: m2 against each, median of the per-round
    # differences, in ns per operation where the row allows it (fib_fine: per spawned task;
    # spawn_order: per request, the pool's wall time per request, 1e9/rps; tasks.jl: per op, and
    # FanOut1000 per task as well).
    if "bp2" in cols
        println("  bp2/bp ", fmt(R["bp2/bp"]),
                "; m2/bp ", f3(med(R["m2/bp"])), " m2/bp2 ", f3(med(R["m2/bp2"])),
                "; bp/ctl ", f3(med(R["bp/ctl"])), " bp2/ctl ", f3(med(R["bp2/ctl"])))
        for b in ("bp", "bp2")
            d = if endswith(cell, "(s)")
                [1e9 * (rounds[r]["m2"][1] - rounds[r][b][1]) / SPAWNS[cell] for r in full]
            elseif endswith(cell, "(rps)")
                [1e9 / rounds[r]["m2"][1] - 1e9 / rounds[r][b][1] for r in full]
            else
                [rounds[r]["m2"][1] - rounds[r][b][1] for r in full]
            end
            unit = endswith(cell, "(s)") ? "ns per spawned task" : endswith(cell, "(rps)") ? "ns per request (pool wall)" : "ns per op"
            extra = occursin("FanOut1000", cell) ? string(" (", f3(med(d) / 1000), " ns per task)") : ""
            println("  path cost m2 - ", rpad(b, 3), " ", fmt(d), " ", unit, extra)
        end
    end
    println()
end

if haskey(ENV, "DECIDE_OUT")
    open(ENV["DECIDE_OUT"], "w") do io
        for cell in SIX
            haskey(READING, cell) && println(io, STEP_OF[cell], '\t', cell, '\t', READING[cell])
        end
    end
end
