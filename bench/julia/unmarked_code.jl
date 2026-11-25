# #618: what the unmarked path compiles to on one build (the port to master's commit 2, after the
# tag's s1). For the scheduler's three entry points as their callers reach them, prints the
# instructions, the calls and their targets, the frame and the safepoint polls of the optimized
# code this build's compiler emits for this CPU. Read it on control, mark and mark-inline.
#
#   <julia> --startup-file=no bench/julia/unmarked_code.jl [--full] [--heaps]
#
# Instructions and calls come from `code_native` (Intel syntax, no debug info); safepoint polls from
# the optimized LLVM IR (`code_llvm`), where a poll is a volatile load of the safepoint page. `--full`
# also prints each function's native code.
using InteractiveUtils
const FULL = "--full" in ARGS
const P = Base.Partr
const MARK = hasfield(Task, :sched_class)

targets = Any[
    ("enq_work(::Task)", Base.enq_work, Tuple{Task}),
    ("trypoptask(::StickyWorkqueue)", Base.trypoptask, Tuple{Base.StickyWorkqueue}),
    ("Partr.multiq_insert(::Task, ::UInt16)", P.multiq_insert, Tuple{Task,UInt16}),
    ("Partr.multiq_check_empty()", P.multiq_check_empty, Tuple{}),
]
MARK && push!(targets, ("Partr.stock_multiq_insert(::Task, ::UInt16)", P.stock_multiq_insert, Tuple{Task,UInt16}))
# `--heaps`: also stock's pop, check and size, and the R heaps' four (the candidate's second version
# shares one body between the two sets; this is what its gate compares).
if MARK && "--heaps" in ARGS
    append!(targets, Any[
        ("Partr.stock_multiq_deletemin()", P.stock_multiq_deletemin, Tuple{}),
        ("Partr.stock_multiq_check_empty()", P.stock_multiq_check_empty, Tuple{}),
        ("Partr.multiq_size(::Int8)", P.multiq_size, Tuple{Int8}),
        ("Partr.r_multiq_size(::Int8)", P.r_multiq_size, Tuple{Int8}),
        ("Partr.r_multiq_insert(::Task, ::UInt16)", P.r_multiq_insert, Tuple{Task,UInt16}),
        ("Partr.r_multiq_deletemin()", P.r_multiq_deletemin, Tuple{}),
        ("Partr.r_multiq_check_empty()", P.r_multiq_check_empty, Tuple{}),
    ])
end

function summary(name, f, tt)
    io = IOBuffer()
    code_native(io, f, tt; syntax = :intel, debuginfo = :none, dump_module = false)
    nat = String(take!(io))
    code_llvm(io, f, tt; optimize = true, debuginfo = :none, dump_module = false)
    ir = String(take!(io))
    lines = [strip(l) for l in split(nat, '\n')]
    ins = filter(l -> !isempty(l) && !startswith(l, ';') && !startswith(l, '#') && !startswith(l, '.') &&
                      !endswith(l, ':'), lines)
    calls = filter(l -> occursin(r"^call\b", l), ins)
    tgt = map(calls) do l
        m = match(r"#\s*(.+)$", l)
        m === nothing ? replace(l, r"^call\s+" => "") : m.captures[1]
    end
    pushes = count(l -> occursin(r"^push\b", l), ins)
    sub = match(r"sub\s+rsp,\s*(\d+)", nat)
    polls = count(l -> occursin("load volatile", l) && occursin("safepoint", l), split(ir, '\n'))
    println(rpad(name, 46), " instructions ", lpad(length(ins), 4), ", calls ", length(calls),
            ", pushes ", pushes, ", stack ", sub === nothing ? 0 : sub.captures[1], " B, safepoint polls ", polls)
    for t in tgt
        println("    call -> ", t)
    end
    FULL && (println("--- native code of ", name); println(nat); println("--- end of ", name); println())
end

println("unmarked_code: ", VERSION, " ", Base.GIT_VERSION_INFO.commit_short, ", ", Sys.CPU_NAME,
        MARK ? ", mark build" : ", no mark")
for (name, f, tt) in targets
    summary(name, f, tt)
end
