# Where each slow request's time went, from a `PROBE=1 fairness.sh` run (#618). Joins, per run, the
# client's per-request trace (`r<round>-<mode>-client.tsv`: conn, seq, sent, received) with the
# server's `/probe` rows (`r<round>-<mode>-server.tsv`: conn, seq, sent, conn task, start, handler
# end, done) on (conn, seq), and splits each request's latency into segments:
#
#   before conn task   sent -> the connection task has the request head (kernel, the connection
#                      task being scheduled, the head's parse)
#   conn task -> start the connection task -> the task that runs the handler starts (the spawned
#                      task being scheduled; the pool's queue; ~0 in `bare_nospawn`)
#   before start       sent -> the handler task starts, in `nitro`, where the spawn is inside
#                      `serve()` and the two above cannot be told apart
#   handler            start -> the handler returned its response
#   write              the handler returned -> the response is written
#   after write        written -> the client has the whole response
#
#   julia bench/socket/probe_report.jl bench/results/fairness-<stamp>-raw
#
# One table per mode. Each cell is the median over the rounds with [min–max]: for all requests, the
# segment's median; for the slowest 1% by client latency, the segment's median and p90 and the
# share of those requests' summed latency it accounts for. Below each table: how many requests
# joined, the slowest 1%'s latency threshold, how many of them came from the most starved tenth of
# connections (fewest completed requests), and the smallest `before` segment seen, which would go
# negative if the two clocks disagreed.

raw = ARGS[1]

q(v, p) = isempty(v) ? NaN : sort(v)[clamp(ceil(Int, p * length(v)), 1, length(v))]
med(v) = q(v, 0.5)
fmt(x) = isnan(x) ? "–" : x >= 100 ? string(round(Int, x)) : string(round(x; sigdigits = 3))
cell(v) = isempty(v) ? "–" : string(fmt(med(v)), " [", fmt(minimum(v)), "–", fmt(maximum(v)), "]")

read_rows(path) = [parse.(Int64, split(l, '\t')) for l in eachline(path) if !isempty(l)]

runs = Dict{String, Vector{Tuple{Int, String}}}()   # mode label => [(round, stem)]
for f in readdir(raw)
    m = match(r"^r(\d+)-(.+)-server\.tsv$", f)
    m === nothing && continue
    isfile(joinpath(raw, "r$(m[1])-$(m[2])-client.tsv")) || continue
    push!(get!(runs, m[2], Tuple{Int, String}[]), (parse(Int, m[1]), joinpath(raw, "r$(m[1])-$(m[2])")))
end
isempty(runs) && error("probe_report.jl: no r<round>-<mode>-{client,server}.tsv pairs in $raw")

const BARE_SEGS = ["before conn task", "conn task -> start", "handler", "write", "after write"]
const NITRO_SEGS = ["before start", "handler", "write", "after write"]

for (label, rs) in sort!(collect(runs); by = first)
    segs = nothing
    stats = Dict{Tuple{String, Symbol}, Vector{Float64}}()   # (segment, stat) => one value per round
    footer = Dict{Symbol, Vector{Float64}}()
    push_stat!(k, x) = push!(get!(stats, k, Float64[]), x)
    push_foot!(k, x) = push!(get!(footer, k, Float64[]), x)
    for (_, stem) in sort(rs)
        client = read_rows(stem * "-client.tsv")
        server = Dict((r[1], r[2]) => r for r in read_rows(stem * "-server.tsv"))
        counts = Dict{Int64, Int}()
        for c in client
            counts[c[1]] = get(counts, c[1], 0) + 1
        end
        conns = sort!(collect(keys(counts)); by = c -> counts[c])
        starved = Set(conns[1:max(1, length(conns) ÷ 10)])
        joined = [(c, server[(c[1], c[2])]) for c in client if haskey(server, (c[1], c[2]))]
        isempty(joined) && continue
        has_conn = all(s[4] != 0 for (_, s) in joined)
        segs = has_conn ? BARE_SEGS : NITRO_SEGS
        # Every segment in ms, per request; the latency is the client's own.
        split_ms(c, s) = (has_conn ? [s[4] - c[3], s[5] - s[4], s[6] - s[5], s[7] - s[6], c[4] - s[7]] :
                                     [s[5] - c[3], s[6] - s[5], s[7] - s[6], c[4] - s[7]]) ./ 1e6
        lat = [(c[4] - c[3]) / 1e6 for (c, _) in joined]
        parts = [split_ms(c, s) for (c, s) in joined]
        cut = q(lat, 0.99)
        slow = findall(>=(cut), lat)
        for (j, name) in enumerate(segs)
            all_j = [p[j] for p in parts]
            slow_j = [parts[i][j] for i in slow]
            push_stat!((name, :all_med), med(all_j))
            push_stat!((name, :slow_med), med(slow_j))
            push_stat!((name, :slow_p90), q(slow_j, 0.9))
            push_stat!((name, :slow_share), 100 * sum(slow_j) / sum(lat[slow]))
        end
        push_foot!(:joined, 100 * length(joined) / length(client))
        push_foot!(:requests, length(client))
        push_foot!(:cut, cut)
        push_foot!(:starved, 100 * count(i -> joined[i][1][1] in starved, slow) / length(slow))
        push_foot!(:clock, minimum(p[1] for p in parts))
    end
    segs === nothing && continue
    println("\n**$label** ($(length(rs)) rounds)\n")
    println("| segment | all requests: median ms | slowest 1%: median ms | slowest 1%: p90 ms | slowest 1%: share of their latency |")
    println("|---|--:|--:|--:|--:|")
    for name in segs
        println("| ", name, " | ", cell(stats[(name, :all_med)]), " | ", cell(stats[(name, :slow_med)]), " | ",
                cell(stats[(name, :slow_p90)]), " | ", cell(stats[(name, :slow_share)]), "% |")
    end
    println("\nrequests per run ", cell(footer[:requests]), ", joined ", cell(footer[:joined]),
            "%; slowest 1% are >= ", cell(footer[:cut]), " ms, of which ", cell(footer[:starved]),
            "% came from the most starved tenth of connections; smallest `", segs[1], "` ",
            cell(footer[:clock]), " ms")
end
