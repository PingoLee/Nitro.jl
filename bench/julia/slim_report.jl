# The report of bench/julia/slim.sh's part B (#618, agent-config #82 Idea 14): what the unmarked path
# of the mark costs where a spawn is the whole operation, and whether a slimmer path removes it.
# Columns: ctl (the tag), m2 (the mark), bp and bp2 (two builds of the bypass commit: the zero of the
# path), s1 and s2 (the slim candidates), and w2 (a second build of the winner, in the reruns).
#   julia bench/julia/slim_report.jl <OUT>        (OUT: the driver's results directory)
#   SLIM_COMMITS="s1=<commit> s2=<commit>": the candidates' commits (the driver exports them); w2 is
#   the winner's commit with a `*` (its tree is marked dirty by an untracked file, as bp2's is).
#   DECIDE_OUT=<file>: write the winner of the main steps (c21 c41 f21): "winner<TAB>slim1|slim2|none",
#   then one line a path cell. DECIDE2_OUT=<file>: the reruns (r21 r41): "holds<TAB>yes|no".
# Per cell: each column's median [min-max] over rounds; the per-round ratios, median [min-max], with
# how many rounds lean slower; each round's order of columns; the differences in ns per op (tasks.jl
# per op, spawn_order per request as the pool's wall time 1e9/rps, fib_fine per spawned task).
# A candidate STANDS with the bypass builds in a cell when the medians of cand/bp and cand/bp2 are both
# within the spread of 1, the spread being max(|median bp2/bp - 1|, 0.5%). It WINS when it stands in
# the three path cells (H = 0 C = 50 :default 2,1; SpawnWait 2,1; SpawnWait 4,1) and m2 is off both
# bypass builds (outside the spread) in at least one of them: something was there to remove. s1 is
# taken over s2 when both win. Stdlib only.

const OUT = isempty(ARGS) ? error("usage: julia slim_report.jl <OUT>") : ARGS[1]

med(v) = (s = sort(v); n = length(s); n == 0 ? NaN : isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
f3(x) = isnan(x) ? "-" : string(round(x; digits = 3))
f1(x) = isnan(x) ? "-" : string(round(x; digits = 1))
fmt(v; f = f3) = isempty(v) ? "-" : string(f(med(v)), " [", f(minimum(v)), "-", f(maximum(v)), "]")

const ALLCOLS = ["ctl", "m2", "bp", "bp2", "s1", "s2", "w2"]
const CANDS = ["s1", "s2", "w2"]
const COMMIT = Dict("c1ac32ab73" => "ctl", "b4f05f4d47" => "m2", "fc9fb3e643" => "bp", "fc9fb3e643*" => "bp2")
for kv in split(get(ENV, "SLIM_COMMITS", ""))
    k, c = split(kv, '=')
    COMMIT[c] = String(k)
end
const WINNER_FILE = joinpath(OUT, "winner")
if isfile(WINNER_FILE)
    w = strip(read(WINNER_FILE, String))
    if w in ("slim1", "slim2")
        for (c, l) in collect(COMMIT)
            l == (w == "slim1" ? "s1" : "s2") && (COMMIT[c * "*"] = "w2")
        end
    end
end
col_of_commit(c) = (c = first(split(c, '/')); haskey(COMMIT, c) ? COMMIT[c] : error("unknown build $c (set SLIM_COMMITS)"))
const TOKEN = Dict("A%control" => "ctl", "N-none%mark" => "m2", "N-none%bypass" => "bp", "N-none%bypass2" => "bp2",
                   "N-none%slim1" => "s1", "N-none%slim2" => "s2", "N-none%slimw2" => "w2")

# cell => round => col => (value, position)
const DATA = Dict{String,Dict{Int,Dict{String,Tuple{Float64,Int}}}}()
const LOWER_BETTER = Dict{String,Bool}()
const SPAWNS = Dict{String,Int}()
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

const RERUN = "rerun: "
function read_step(p, pre)
    f = joinpath(p, "fibabba-nested.tsv")
    if isfile(f)
        for row in read_tsv(f)
            row["bench"] == "fib_fine" || continue
            cell = "$(pre)fib_fine $(row["threads"]) (s)"
            SPAWNS[cell] = parse(Int, row["spawns"])
            addrow!(cell, parse(Int, row["round"]), col_of_commit(row["commit"]), parse(Float64, row["wall_median_s"]), true)
        end
    end
    f = joinpath(p, "costrounds-spawn.tsv")
    if isfile(f)
        for row in read_tsv(f)
            cell = "$(pre)H = 0 C = $(row["c"]) $(row["clients"]) $(row["threads"]) (rps)"
            addrow!(cell, parse(Int, row["round"]), col_of_commit(row["commit"]), parse(Float64, row["rps"]), false)
        end
    end
    f = joinpath(p, "costrounds-micro.tsv")
    if isfile(f)
        for l in readlines(f)
            x = split(l, '\t')
            length(x) >= 8 || continue
            name = x[7]
            name in ("SpawnWait", "FanOut1000", "PingPong") || continue
            startswith(x[8], "ns_per_op=") || continue
            cell = "$(pre)tasks.jl $(name) $(x[3]) (ns)"
            addrow!(cell, parse(Int, x[1]), TOKEN[x[4]], parse(Float64, x[8][11:end]), true)
        end
    end
end
# SLIM_DIRS: the step directories to read (slim2.sh, #618 Idea 16: "c21 c41 f21 f81 a4cost", and "weak" alone).
for d in split(get(ENV, "SLIM_DIRS", "c21 c41 f21"))
    isdir(joinpath(OUT, d)) && read_step(joinpath(OUT, d), "")
end
for d in ("r21", "r41")
    isdir(joinpath(OUT, d)) && read_step(joinpath(OUT, d), RERUN)
end
isempty(DATA) && error("no rows under $OUT")

const PATH = ["H = 0 C = 50 default 2,1 (rps)", "tasks.jl SpawnWait 2,1 (ns)", "tasks.jl SpawnWait 4,1 (ns)"]
const STANDS = Dict{Tuple{String,String},Bool}()   # (cell, cand) => stands with bp and bp2
const M2OFF = Dict{String,Bool}()                  # cell => m2 off both bypass builds

for cell in sort(collect(keys(DATA)); by = c -> (startswith(c, RERUN), c))
    rounds = DATA[cell]
    rs = sort(collect(keys(rounds)))
    cols = [c for c in ALLCOLS if any(r -> haskey(rounds[r], c), rs)]
    full = [r for r in rs if all(c -> haskey(rounds[r], c), cols)]
    println("## ", cell, "  (", length(full), " complete rounds of ", length(rs), "; columns ", join(cols, " "), ")")
    vals(c) = [rounds[r][c][1] for r in full]
    for c in cols
        println("  ", rpad(c, 4), fmt(vals(c)))
    end
    ratio(a, b) = [rounds[r][a][1] / rounds[r][b][1] for r in full]
    slower(x) = LOWER_BETTER[cell] ? x > 1 : x < 1
    R = Dict{String,Vector{Float64}}()
    pairs_ = [("bp2", "bp"), ("m2", "bp"), ("m2", "bp2"), ("bp", "ctl"), ("bp2", "ctl"), ("m2", "ctl")]
    for c in CANDS
        append!(pairs_, [(c, "bp"), (c, "bp2"), ("m2", c), (c, "ctl")])
    end
    "w2" in cols && push!(pairs_, ("w2", "s1"), ("w2", "s2"))
    for (a, b) in pairs_
        (a in cols && b in cols) || continue
        v = ratio(a, b); R["$a/$b"] = v
        println("  ", rpad("$a/$b", 8), fmt(v), "   slower in ", count(slower, v), " of ", length(v))
    end
    # Differences in ns per op, median of the per-round differences.
    unit = endswith(cell, "(s)") ? "ns per spawned task" : endswith(cell, "(rps)") ? "ns per request (pool wall)" : "ns per op"
    nsop(r, c) = endswith(cell, "(s)") ? 1e9 * rounds[r][c][1] / SPAWNS[cell] :
                 endswith(cell, "(rps)") ? 1e9 / rounds[r][c][1] : rounds[r][c][1]
    for (a, b) in [("m2", "bp"), ("m2", "bp2"), ("bp2", "bp"), [(c, "bp") for c in CANDS]..., [(c, "bp2") for c in CANDS]...,
                   [("m2", c) for c in CANDS]...]
        (a in cols && b in cols) || continue
        d = [nsop(r, a) - nsop(r, b) for r in full]
        println("  ", rpad("$a - $b", 10), fmt(d; f = f1), " ", unit)
    end
    println("  positions (round: order of columns):")
    for r in full
        println("    r", r, ": ", join(sort(cols; by = c -> rounds[r][c][2]), " "))
    end
    if "bp" in cols && "bp2" in cols
        spread = max(abs(med(R["bp2/bp"]) - 1), 0.005)
        within(v) = abs(med(v) - 1) <= spread
        m2off = "m2" in cols && !within(R["m2/bp"]) && !within(R["m2/bp2"])
        M2OFF[cell] = m2off
        line = ["spread ", f3(spread), "; m2 ", m2off ? "OFF both bypass builds" : "not off both"]
        for c in CANDS
            c in cols || continue
            st = within(R["$c/bp"]) && within(R["$c/bp2"])
            STANDS[(cell, c)] = st
            push!(line, "; ", c, st ? " stands with bp and bp2" : " does not stand")
        end
        println("  ", join(line))
    end
    println()
end

function verdict(cells, cand)
    all(c -> get(STANDS, (c, cand), false), cells) || return false
    return any(c -> get(M2OFF, c, false), cells)
end
main_win = verdict(PATH, "s1") ? "slim1" : verdict(PATH, "s2") ? "slim2" : "none"
println("main steps: winner ", main_win, " (s1 ", join((get(STANDS, (c, "s1"), false) ? "+" : "-" for c in PATH)),
        ", s2 ", join((get(STANDS, (c, "s2"), false) ? "+" : "-" for c in PATH)),
        ", m2 off ", join((get(M2OFF, c, false) ? "+" : "-" for c in PATH)), " over ", join(PATH, " | "), ")")
if haskey(ENV, "DECIDE_OUT")
    open(ENV["DECIDE_OUT"], "w") do io
        println(io, "winner\t", main_win)
        for c in PATH
            println(io, c, "\tm2off=", get(M2OFF, c, false), "\ts1=", get(STANDS, (c, "s1"), false), "\ts2=", get(STANDS, (c, "s2"), false))
        end
    end
end
RP = [RERUN * c for c in PATH]
if any(c -> haskey(DATA, c), RP)
    w = isfile(WINNER_FILE) ? strip(read(WINNER_FILE, String)) : "none"
    wc = w == "slim1" ? "s1" : w == "slim2" ? "s2" : ""
    holds = !isempty(wc) && verdict(RP, wc) && verdict(RP, "w2")
    println("reruns: the winner ", w, " and its second build w2 ", holds ? "both stand" : "do NOT both stand",
            " (", wc, " ", join((get(STANDS, (c, wc), false) ? "+" : "-" for c in RP)),
            ", w2 ", join((get(STANDS, (c, "w2"), false) ? "+" : "-" for c in RP)),
            ", m2 off ", join((get(M2OFF, c, false) ? "+" : "-" for c in RP)), ")")
    haskey(ENV, "DECIDE2_OUT") && write(ENV["DECIDE2_OUT"], string("holds\t", holds ? "yes" : "no", "\n"))
end
