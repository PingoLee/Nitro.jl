# #618, the maintainer battery: the report of bench/julia/battery.sh's run, as markdown.
#
# Columns are keyed by the build each row ran on, never by the commit suffix alone (m1 and m2 are two
# builds of the same commit, `b4f05f4d47*` and `b4f05f4d47`): ctl (the control, the tag), m1 (session
# 1's build of the patch), m2 (the clean rebuild), official (the juliaup binary), ws and base
# (JuliaLang/julia#62285's head). A value is a median over rounds with [min–max]; a ratio is the median
# of the per-round ratios with [min–max]. Rotated blocks: round r runs the columns in their listed
# order shifted by (r - 1) mod n, so the per-round lines carry each column's position.
#
# Item 3's exit logs (the mark-all switch): one line per process, written at exit. A process is
# attributed to a test set by its program file (a subprocess a set starts), or, for a process with no
# program file (a runner worker, a Distributed worker, a `-e` child), by its exit time: a runner
# worker exits right after its last set ends (the runner removes it once the queue has nothing left for
# it), and a child exits while its set runs. The time attribution is inferred, and is marked so.
#
# Usage: julia bench/julia/battery_report.jl <OUT>   (OUT: bench/results/618-battery)
using Statistics, Dates

const OUT = ARGS[1]
io = stdout

function readtsv(path; header = nothing)
    isfile(path) || return Dict{String,String}[]
    lines = filter(!isempty, readlines(path))
    isempty(lines) && return Dict{String,String}[]
    hdr = header === nothing ? split(lines[1], '\t') : header
    body = header === nothing ? lines[2:end] : lines
    rows = Dict{String,String}[]
    for l in body
        f = split(l, '\t')
        f[1] == hdr[1] && continue   # a repeated header
        push!(rows, Dict(String(hdr[i]) => String(get(f, i, "")) for i in eachindex(hdr)))
    end
    rows
end
num(s) = (x = tryparse(Float64, s); x === nothing ? NaN : x)
fmt(x) = isnan(x) ? "–" : isinf(x) ? string(x) : abs(x) >= 1e5 ? string(round(Int, x)) : abs(x) >= 100 ? string(round(x; digits = 1)) :
         abs(x) >= 1 ? string(round(x; digits = 3)) : string(round(x; sigdigits = 4))
mmr(v) = isempty(v) ? "–" : "$(fmt(median(v))) [$(fmt(minimum(v)))–$(fmt(maximum(v)))]"
overlap(a, b) = !isempty(a) && !isempty(b) && maximum(a) >= minimum(b) && maximum(b) >= minimum(a)
rotpos(i, r, n) = mod(i - 1 - mod(r - 1, n), n) + 1   # 1-based position of the column listed i-th, round r

# The build a spawn_order / nested row ran on, from its commit (and the token's build where present).
function build_of(commit::AbstractString)
    endswith(commit, "/local") && return "ctl"
    startswith(commit, "b4f05f4d47*") && return "m1"
    startswith(commit, "b4f05f4d47") && return "m2"
    return "official"
end
col3(r) = haskey(r, "col") ? r["col"] : build_of(r["commit"]) * (get(r, "variant", "A") in ("A", "N-none") ? "" : "-" * r["variant"])

# value[col][round] for the rows passing `sel`.
function byround(rows, sel, f; col = col3)
    d = Dict{String,Dict{Int,Float64}}()
    for r in rows
        sel(r) || continue
        get!(d, col(r), Dict{Int,Float64}())[parse(Int, r["round"])] = f(r)
    end
    d
end
vals(d, c) = haskey(d, c) ? [v for (_, v) in sort(collect(d[c]))] : Float64[]
ratios(d, a, b) = (haskey(d, a) && haskey(d, b)) ? [(r, d[a][r] / d[b][r]) for r in sort(collect(keys(d[a]))) if haskey(d[b], r)] : Tuple{Int,Float64}[]
rv(x) = last.(x)

"One line per cell: each column's median [range], then m1/ctl, m2/ctl, m2/m1 and whether the ranges overlap."
function threetable(io, title, cells, rows, f; cols = ["ctl", "m1", "m2"], perround = true, note = "")
    println(io, "\n### $title\n")
    note == "" || println(io, "*$note*\n")
    println(io, "| cell | ", join(cols, " | "), " | m1/ctl | m2/ctl | m2/m1 | m1 in ctl's range | m2 in ctl's range |")
    println(io, "|---|", repeat("--:|", length(cols) + 5))
    ds = []
    for (label, sel) in cells
        d = byround(rows, sel, f); push!(ds, (label, d))
        println(io, "| $label | ", join([mmr(vals(d, c)) for c in cols], " | "), " | ",
                mmr(rv(ratios(d, "m1", "ctl"))), " | ", mmr(rv(ratios(d, "m2", "ctl"))), " | ", mmr(rv(ratios(d, "m2", "m1"))), " | ",
                overlap(vals(d, "m1"), vals(d, "ctl")) ? "yes" : "**no**", " | ", overlap(vals(d, "m2"), vals(d, "ctl")) ? "yes" : "**no**", " |")
    end
    perround || return
    println(io)
    for (label, d) in ds
        n = length(cols)
        for (a, b) in (("m1", "ctl"), ("m2", "ctl"))
            ia, ib = findfirst(==(a), cols), findfirst(==(b), cols)
            println(io, "- $label $a/$b per round (positions $a,$b): ",
                    join(["r$r $(fmt(x)) ($(rotpos(ia, r, n)),$(rotpos(ib, r, n)))" for (r, x) in ratios(d, a, b)], " · "))
        end
        # Sign agreement: in how many rounds is each build below ctl.
        for a in ("m1", "m2")
            rs = rv(ratios(d, a, "ctl"))
            isempty(rs) || println(io, "  - $a below ctl in $(count(<(1), rs)) of $(length(rs)) rounds")
        end
    end
end

println(io, "# #618, the maintainer battery: report of $OUT\n")
dl = joinpath(OUT, "driver.log")
isfile(dl) && for l in eachline(dl)
    occursin(r"build [a-z0-9-]+: |step [a-z0-9]+: exit|STOP|driver done|cut", l) && println(io, "    ", l)
end

# ---------------------------------------------------------------- item 1 and 5: fib_fine alone
for (dir, title) in (("fib3", "item 1, fib_fine alone"), ("t20", "item 5, 2,0"), ("t21", "item 5, 2,1"), ("t40", "item 5, 4,0"), ("t41", "item 5, 4,1"))
    rows = readtsv(joinpath(OUT, dir, "fibabba-nested.tsv"))
    isempty(rows) && continue
    cells = [("fib_fine $th", r -> r["threads"] == th) for th in unique([r["threads"] for r in rows])]
    threetable(io, "$title: wall median s (lower is faster), $(length(unique([r["round"] for r in rows]))) rounds", cells, rows, r -> num(r["wall_median_s"]))
end

# ---------------------------------------------------------------- item 3: Julia's own tests
const SUBPROC_SET = Dict("binarytree.jl" => "gc", "chunks.jl" => "gc", "copyto.jl" => "gc", "linkedlist.jl" => "gc", "objarray.jl" => "gc",
    "print_process_affinity.jl" => "threads", "profile_spawnmany_exec.jl" => "threads", "distributed_exec.jl" => "Distributed",
    "channel_threadpool.jl" => "channel_threadpool", "threadpool_use.jl" => "threadpool_use", "ioloop_wakeup.jl" => "ioloop_wakeup",
    "runtests.jl" => "(the runner itself)")
subproc_set(file, args) = file == "threads_exec.jl" ? (args == "" ? "threads" : "Logging") : get(SUBPROC_SET, file, nothing)

# The runner's per-set lines: start time and elapsed seconds, per part log.
function set_windows(log)
    starts = Dict{String,DateTime}(); wins = Tuple{String,Float64,Float64}[]
    isfile(log) || return wins
    for l in eachline(log)
        m = match(r"^(\S+)\s+\((\d+)\)\s+\|\s+started at (\S+)", l)
        if m !== nothing
            starts[m[1]] = DateTime(m[3][1:min(end, 23)]); continue
        end
        m = match(r"^(\S+)\s+\((\d+)\)\s+\|\s+([0-9.]+)\s+\|", l)
        if m !== nothing && haskey(starts, m[1])
            push!(wins, (String(m[1]), datetime2unix(starts[m[1]]), datetime2unix(starts[m[1]]) + parse(Float64, m[3])))
        end
        m = match(r"^(\S+)\s+\((\d+)\)\s+\|\s+failed at (\S+)", l)
        m !== nothing && haskey(starts, m[1]) && push!(wins, (String(m[1]), datetime2unix(starts[m[1]]), datetime2unix(DateTime(m[3][1:min(end, 23)]))))
    end
    wins
end
# Exit time (local wall clock as unix seconds, the same frame as the runner's local timestamps).
const TZOFF = round(Int, (now() - now(UTC)).value / 1000)
exit_time(path) = mtime(path) + TZOFF

function attribute(file, args, t, wins)
    s = subproc_set(file, args)
    s === nothing || return (s, "read")
    file == "" || file == "-" || return ("(other: $file)", "read")
    ended = [w[1] for w in wins if w[3] - 1 <= t <= w[3] + 4]
    length(ended) == 1 && return (ended[1], "inferred: worker exit as the set ended")
    running = unique([w[1] for w in wins if w[2] <= t <= w[3]])
    length(running) == 1 && return (running[1], "inferred: exited while only this set ran")
    !isempty(ended) && return (join(sort(ended), "/"), "inferred: ambiguous")
    isempty(running) ? ("(between sets)", "inferred") : (join(sort(running), "/"), "inferred: ambiguous")
end

function summary_rows(log)
    rows = Dict{String,NTuple{4,Int}}()
    isfile(log) || return rows, ""
    txt = readlines(log)
    hdr = findlast(l -> occursin("Test Summary:", l) && occursin("Total", l), txt)
    hdr === nothing && return rows, ""
    hdrline = txt[hdr]
    # Numbers are right-aligned under their column's name: match each number by its end column to the
    # nearest header name's end column (a zero count is printed as blank).
    ends = [(String(m.match), m.offset + length(m.match) - 1) for m in eachmatch(r"Pass|Fail|Error|Broken|Total|Time", hdrline)]
    overall = ""
    for l in txt[hdr+1:end]
        occursin('|', l) || break
        name = strip(split(l, '|'; limit = 2)[1])
        v = Dict(c => 0 for c in ("Pass", "Fail", "Error", "Broken", "Total"))
        bar = findfirst('|', l)
        for m in eachmatch(r"\d+(\.\d+)?(m\d+\.\d+)?s?", l[bar+1:end])
            endsWith = bar + m.offset + length(m.match) - 1
            (endswith(m.match, "s") || occursin('.', m.match)) && continue   # the time column
            _, k = findmin(e -> abs(e[2] - endsWith), ends)
            c = ends[k][1]; c == "Time" && continue
            v[c] = parse(Int, m.match)
        end
        name == "Overall" ? (overall = "pass $(v["Pass"]), fail $(v["Fail"]), error $(v["Error"]), broken $(v["Broken"]), total $(v["Total"])") :
                            (rows[String(name)] = (v["Pass"], v["Fail"], v["Error"], v["Broken"]))
    end
    rows, overall
end

tdir = joinpath(OUT, "tests")
if isdir(tdir)
    println(io, "\n## Item 3: Julia's own tests\n")
    cols = sort(readdir(tdir); by = c -> (c == "ctl" ? 0 : c == "mv" ? 1 : c == "mall-unset" ? 2 : 3, something(tryparse(Int, split(c, '-')[end]), 0), c))
    ref = Dict(p => summary_rows(joinpath(tdir, "ctl", "tests-$p.log"))[1] for p in ("A", "B"))
    println(io, "| column | part A overall | part B overall | sets whose counts differ from ctl |")
    println(io, "|---|---|---|---|")
    for c in cols
        diffs = String[]; ov = String[]
        for p in ("A", "B")
            rows, o = summary_rows(joinpath(tdir, c, "tests-$p.log")); push!(ov, o == "" ? "(no summary)" : o)
            for (s, v) in rows
                get(ref[p], s, nothing) == v || push!(diffs, "$p:$s $(v) vs ctl $(get(ref[p], s, "–"))")
            end
            for s in keys(ref[p]); haskey(rows, s) || push!(diffs, "$p:$s missing"); end
        end
        println(io, "| $c | $(ov[1]) | $(ov[2]) | ", isempty(diffs) ? "none" : "**" * join(diffs, "; ") * "**", " |")
    end
    println(io, "\nA run that passes prints only its overall line, so the per-set comparison covers the parts that failed ",
            "(part A, through its baseline error). Part B's pass count follows Profile's ",
            "`test_has_task_profiler_sample_in_buffer`, one `@test` per profile sample block, and varies between unswitched builds too.")
    # Exit logs, per column with the switch.
    hdr = ["pid", "mode", "src", "threads", "f_first", "l_first", "r_first", "demoted", "r_ins", "f_again", "file", "args"]
    for c in cols
        ld = joinpath(tdir, c, "log")
        (isdir(ld) && !isempty(readdir(ld))) || continue
        wins = Dict(p => set_windows(joinpath(tdir, c, "tests-$p.log")) for p in ("A", "B"))
        aend = isfile(joinpath(tdir, c, "tests-A.log")) ? mtime(joinpath(tdir, c, "tests-A.log")) + TZOFF : Inf
        agg = Dict{String,Vector{Any}}()
        nofl = String[]
        for f in readdir(ld; join = true)
            endswith(f, ".tsv") || continue
            line = readchomp(f); isempty(line) && continue
            v = split(line, '\t'); length(v) < 10 && continue
            r = Dict(hdr[i] => String(get(v, i, "")) for i in eachindex(hdr))
            r["file"] = basename(r["file"])
            t = exit_time(f); part = t <= aend + 1 ? "A" : "B"
            set, how = attribute(r["file"], r["args"], t, wins[part])
            key = "$part $set"
            a = get!(agg, key, Any[0, 0, 0, 0, 0, 0, 0, Set{String}(), Set{String}()])
            a[1] += 1; r["mode"] != "unset" && (a[2] += 1); r["src"] == "fallback" && (a[3] += 1)
            a[4] += parse(Int, r["f_first"]); a[5] += parse(Int, r["r_first"]); a[6] += parse(Int, r["r_ins"]); a[7] += parse(Int, r["demoted"])
            push!(a[8], r["threads"]); push!(a[9], how)
            r["src"] == "fallback" && push!(nofl, "$(r["pid"]) $(r["threads"]) $(r["file"] == "" ? "(no program file)" : r["file"]) [$set]")
        end
        println(io, "\n### exit logs: $c\n")
        println(io, "| part, set | processes | switch on | via fallback | f_first | r_first | r_ins (all R inserts) | demoted | layouts | attribution | tested (a marked first enqueue) | R heaps reached |")
        println(io, "|---|--:|--:|--:|--:|--:|--:|--:|---|---|---|---|")
        for k in sort(collect(keys(agg)))
            a = agg[k]
            println(io, "| $k | $(a[1]) | $(a[2]) | $(a[3]) | $(a[4]) | $(a[5]) | $(a[6]) | $(a[7]) | $(join(sort(collect(a[8])), " ")) | $(join(sort(collect(a[9])), "; ")) | ",
                    a[4] + a[5] > 0 ? "yes" : "**no**", " | ", a[6] > 0 ? "yes" : "**no**", " |")
        end
        isempty(nofl) || println(io, "\nThrough the fallback directory (started with a replaced environment, so without the switch's variables): ", length(nofl), " processes: ", join(first(sort(nofl), 30), "; "))
    end
end

# ---------------------------------------------------------------- item 4: the stall repro
for blk in ("pos", "main8a", "main8b", "t2", "t4")
    d = joinpath(OUT, "stall-$blk")
    rows = readtsv(joinpath(d, "runs.tsv"))
    isempty(rows) && continue
    println(io, "\n### item 4, stall block $blk\n")
    println(io, "| label | ok | stuck | timeout | other | of | seconds median [max] | counts (last run's log) |")
    println(io, "|---|--:|--:|--:|--:|--:|---|---|")
    for lab in unique([r["build"] for r in rows])
        rs = [r for r in rows if r["build"] == lab]
        cnt(o) = count(r -> r["outcome"] == o, rs)
        secs = [num(r["seconds"]) for r in rs]
        lastlog = joinpath(d, "$lab-r$(rs[end]["run"]).log")
        cl = isfile(lastlog) ? something(findlast(l -> startswith(l, "validate: counts"), readlines(lastlog)), 0) : 0
        cs = cl == 0 ? "–" : replace(readlines(lastlog)[cl], "validate: counts " => "")
        println(io, "| $lab | $(cnt("ok")) | $(cnt("stuck")) | $(cnt("timeout")) | $(cnt("other")) | $(length(rs)) | $(fmt(median(secs))) [$(fmt(maximum(secs)))] | $cs |")
    end
    bad = [r for r in rows if r["outcome"] != "ok"]
    isempty(bad) || println(io, "\nNot ok: ", join(["$(r["build"]) r$(r["run"]) $(r["outcome"]) ($(r["last_line"]))" for r in first(bad, 12)], "; "))
end

# ---------------------------------------------------------------- item 2: pfib(25)
const PCOLS = ["ctl", "m1", "m2", "root", "all", "ws", "base"]
for tag in ("21", "20", "80")
    rows = [r for r in readtsv(joinpath(OUT, "pfib-$tag.tsv")) if !occursin("FAILED", get(r, "min_s", ""))]
    failed = [r for r in readtsv(joinpath(OUT, "pfib-$tag.tsv")) if occursin("FAILED", get(r, "min_s", ""))]
    isempty(rows) && continue
    println(io, "\n### item 2, pfib(25) at $(rows[1]["layout"]): seconds per call (median of the round's samples)\n")
    d = byround(rows, r -> true, r -> num(r["median_s"]); col = r -> r["label"])
    dmin = byround(rows, r -> true, r -> num(r["min_s"]); col = r -> r["label"])
    println(io, "| column | median s | min s | /ctl (per-round median ratio) | allocs | maxrss MB |")
    println(io, "|---|--:|--:|--:|--:|--:|")
    for c in PCOLS
        haskey(d, c) || continue
        base = c in ("ws",) ? "base" : "ctl"
        rr = c == "base" ? "–" : mmr(rv(ratios(d, c, base))) * (base == "base" ? " (/base)" : "")
        al = [num(r["allocs"]) for r in rows if r["label"] == c]; rss = [num(r["maxrss_mb"]) for r in rows if r["label"] == c]
        println(io, "| $c | $(mmr(vals(d, c))) | $(mmr(vals(dmin, c))) | $rr | $(fmt(median(al))) | $(fmt(median(rss))) |")
    end
    isempty(failed) || println(io, "\nFailed processes: ", join(["$(r["label"]) r$(r["round"]) $(r["min_s"])" for r in failed], "; "))
end
cnt = readtsv(joinpath(OUT, "pfib-count.tsv"))
if !isempty(cnt)
    println(io, "\n### item 2, live tasks (untimed, one run per layout)\n")
    println(io, "| layout | column | mode | peak live tasks | spawned | maxrss MB |")
    println(io, "|---|---|---|--:|--:|--:|")
    for r in cnt
        println(io, "| $(r["layout"]) | $(r["label"]) | $(r["mode"]) | $(get(r, "peak_live", "")) | $(get(r, "spawned", "")) | $(get(r, "maxrss_mb", "")) |")
    end
end

# ---------------------------------------------------------------- item 1 and 5: spawn_order and tasks.jl
function microrows(path)
    out = Dict{String,String}[]
    isfile(path) || return out
    for l in eachline(path)
        f = split(l, '\t'); length(f) >= 8 || continue
        tok = String(f[4]); v, b = occursin('%', tok) ? split(tok, '%') : (tok, "")
        col = b == "control" ? "ctl" : b == "mark1" ? "m1" : b == "mark" ? "m2" : String(b)
        m = match(r"\bns_per_op=([0-9.eE+-]+)", l); m === nothing && continue
        push!(out, Dict("round" => String(f[1]), "threads" => String(f[3]), "col" => col, "name" => String(f[7]), "ns" => m[1]))
    end
    out
end
for (dir, title) in (("leans", "item 1, the leans"), ("t20", "item 5, 2,0"), ("t21", "item 5, 2,1"), ("t40", "item 5, 4,0"), ("t41", "item 5, 4,1"))
    sp = readtsv(joinpath(OUT, dir, "costrounds-spawn.tsv"))
    if !isempty(sp)
        cells = [("H=0 $(th) $(cl) C=$(c)", r -> r["threads"] == th && r["clients"] == cl && r["c"] == c && r["mode"] == "spawn")
                 for (th, cl, c) in unique([(r["threads"], r["clients"], r["c"]) for r in sp if r["mode"] == "spawn"])]
        threetable(io, "$title: H = 0, throughput (req/s)", cells, sp, r -> num(r["rps"]))
    end
    mi = microrows(joinpath(OUT, dir, "costrounds-micro.tsv"))
    if !isempty(mi)
        cells = [("$(th) $(n)", r -> r["threads"] == th && r["name"] == n) for (th, n) in unique([(r["threads"], r["name"]) for r in mi])]
        threetable(io, "$title: tasks.jl (ns per op, lower is faster)", cells, mi, r -> num(r["ns"]); )
    end
end

# ---------------------------------------------------------------- item 7: corners (spawn_order, two columns)
for (file, title, keyf) in (("shaperounds-spawn.tsv", "item 7, the async shape (500:2, 8,1 :interactive clients)", r -> "$(get(r, "shape", "?"))"),
                            ("fairrounds-spawn.tsv", "item 7, the starved cell with :interactive clients", r -> "$(r["threads"]) $(r["clients"])"))
    rows = readtsv(joinpath(OUT, "corners", file))
    isempty(rows) && continue
    println(io, "\n### $title\n")
    println(io, "| cell | column | p99 ms | throughput | slowest client's requests |")
    println(io, "|---|---|--:|--:|--:|")
    for k in unique(keyf.(rows)), c in unique(col3.(rows))
        rs = [r for r in rows if keyf(r) == k && col3(r) == c]
        isempty(rs) && continue
        println(io, "| $k | $c | $(mmr(num.(getindex.(rs, "p99_ms")))) | $(mmr(num.(getindex.(rs, "rps")))) | $(mmr(num.(get.(rs, "count_min", "")))) |")
    end
end
for f in ("validate-async-spawn.log", "validate-mixed-plain.log", "validate-mixed-async.log")
    p = joinpath(OUT, "corners", f)
    isfile(p) && println(io, "\n- $f: ", join([l for l in eachline(p) if occursin(r"credit-run|async children|validate|FAIL|assert"i, l)][1:min(end, 8)], " · "))
end

# ---------------------------------------------------------------- servers (fairness.sh blocks)
srvlabel(m) = endswith(m, "@A0%official") ? "A0" : endswith(m, "@M-none%official") ? "M-none" : occursin("@N%mark", m) ? "N" :
              endswith(m, "%control") ? "ctl" : endswith(m, "%mark") ? "m2" : endswith(m, "%official") ? "official" : m
results_of(tag) = (m = nothing; isfile(dl) && for l in eachline(dl)
    mm = match(Regex("results: (\\S*$(tag)\\S*\\.tsv)"), l); mm === nothing || (m = mm[1]) end; m)
for (tag, title) in (("plain-8_0", "item 1, /plaintext, a fresh server process a round, 8,0"), ("plain-8_1", "item 1, /plaintext, fresh, 8,1"),
                     ("cell1-fresh", "item 1, cell 1, fresh, 8,1"), ("cell1-82", "item 7, cell 1 at 8,2 and 8,1"))
    # fairness.sh prints its results path into the driver log; the block's label is in the gated line.
    p = nothing
    if isfile(dl)
        lines = readlines(dl); i = findfirst(l -> occursin("618bat-$tag", l), lines)
        if i !== nothing
            for l in lines[i:end]; mm = match(r"results: (\S+\.tsv)", l); if mm !== nothing; p = mm[1]; break; end; end
        end
    end
    (p === nothing || !isfile(p)) && continue
    rows = [r for r in readtsv(p) if r["round"] != "0"]
    lay(m) = (x = match(r"@(\d+,\d+)", m); x === nothing ? "" : x[1])
    nlay = length(unique(lay.(getindex.(rows, "mode"))))
    for r in rows; r["col"] = srvlabel(r["mode"]) * (nlay > 1 ? " " * lay(r["mode"]) : ""); end
    cs = unique(getindex.(rows, "col"))
    refof(c) = (b = split(c)[1]; l = length(split(c)) > 1 ? " " * split(c)[2] : ""; (b in ("A0", "M-none") ? "official" : "ctl") * l)
    rcs = [c for c in cs if !(split(c)[1] in ("ctl", "official")) && refof(c) in cs]
    println(io, "\n### $title ($(basename(p)))\n")
    println(io, "| metric | ", join(cs, " | "), " | ", join(["$c / $(refof(c))" for c in rcs], " | "), " |")
    println(io, "|---|", repeat("--:|", length(cs) + length(rcs)))
    for metric in ("rps", "oha_rps", "p99_ms", "p50_ms", "max_ms", "conn_min", "listen_ovf", "gc_ms")
        haskey(rows[1], metric) || continue
        d = byround(rows, r -> true, r -> num(r[metric]); col = r -> r["col"])
        all(c -> all(isnan, vals(d, c)), cs) && continue
        println(io, "| $metric | ", join([mmr(vals(d, c)) for c in cs], " | "), " | ",
                join([mmr(rv(ratios(d, c, refof(c)))) for c in rcs], " | "), " |")
    end
end
