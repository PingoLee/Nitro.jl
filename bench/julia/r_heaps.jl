# The native mark's R heaps (#618) are stock's four heap functions copied and renamed. A merge or a
# rebase can silently keep an old copy (a three-way merge kept the tag's R pop without a conflict), so
# the copy is regenerated from the base's own functions and then checked. Rerun both at every rebase.
#
#   julia r_heaps.jl gen   <base partr.jl>                   # print the R block, made from the base
#   julia r_heaps.jl check <base partr.jl> <branch partr.jl> # exit 1 unless the branch's R copy and
#                                                            # its stock_* functions equal the base's
#
# `gen` renames by text, comments included, as the tag's copy did. `check` is independent of it: it
# parses both files, renames symbols in the base's syntax tree, drops line numbers and compares the
# trees, so it is token-for-token equality up to the renaming, comments and layout aside.

const STOCK = ("multiq_size", "multiq_insert", "multiq_deletemin", "multiq_check_empty")
const RENAME = Dict{Symbol,Symbol}(
    :heaps => :r_heaps, :heaps_lock => :r_heaps_lock,
    (Symbol(f) => Symbol("r_", f) for f in STOCK)...)

# The four functions' source text, in file order, each from its `function` line to its closing `end`.
function stock_text(src::String)
    lines = split(src, '\n')
    out = String[]
    for f in STOCK
        i = findfirst(l -> startswith(l, "function $f("), lines)
        i === nothing && error("no `function $f(` in the base file")
        j = findnext(l -> l == "end", lines, i)
        push!(out, join(lines[i:j], '\n'))
    end
    return out
end

function gen(base::String)
    text = join(stock_text(read(base, String)), "\n\n")
    # Longest names first, on word boundaries: `heaps_lock` before `heaps`, and `tpheaps`, `taskheap`,
    # `multiq_sift_up` and `multiq_sift_down` untouched.
    for (from, to) in sort!(collect(RENAME); by = p -> -length(String(p.first)))
        text = replace(text, Regex("\\b" * String(from) * "\\b") => String(to))
    end
    print(text, "\n")
end

strip_lines(x) = x
strip_lines(x::Expr) = Expr(x.head, (strip_lines(a) for a in x.args if !(a isa LineNumberNode))...)
rename(x, m) = x
rename(x::Symbol, m) = get(m, x, x)
rename(x::Expr, m) = Expr(x.head, (rename(a, m) for a in x.args)...)

fname(ex::Expr) = (ex.head === :function && ex.args[1] isa Expr && ex.args[1].head === :call) ? ex.args[1].args[1] : nothing
fname(::Any) = nothing

function defs(path::String)
    src = read(path, String)
    # From 1.14 the syntax version is per project and `Meta.parseall` reads 1.13 syntax outside one;
    # ask for this julia's own (master's partr.jl uses `*%`, new in 1.14).
    top = VERSION >= v"1.14-" ? Base.JuliaSyntax.parseall(Expr, src; filename = path, version = VERSION) :
                                Meta.parseall(src; filename = path)
    # A file the running parser cannot read parses to an :error node, not an exception: refuse it
    # (so check master's partr.jl with a julia built from master).
    any(a -> a isa Expr && a.head in (:error, :incomplete), top.args) &&
        error("cannot parse $path with this julia ($VERSION): run the check with a build of the base")
    d = Dict{Symbol,Expr}()
    walk(x) = nothing
    function walk(x::Expr)
        if x.head === :function
            n = fname(x)
            n isa Symbol && (d[n] = strip_lines(x))
        elseif x.head in (:toplevel, :module, :block)
            foreach(walk, x.args)
        end
        return nothing
    end
    walk(top)
    return d
end

function check(base::String, branch::String)
    b, r = defs(base), defs(branch)
    bad = 0
    for f in STOCK
        s = Symbol(f)
        # The branch renames stock's three entry points `stock_*`; `multiq_size` keeps its name.
        sname = f == "multiq_size" ? s : Symbol("stock_", f)
        want_stock = rename(b[s], Dict(s => sname))
        got_stock = get(r, sname, nothing)
        ok_s = got_stock !== nothing && got_stock == want_stock
        want_r = rename(b[s], RENAME)
        got_r = get(r, Symbol("r_", f), nothing)
        ok_r = got_r !== nothing && got_r == want_r
        println(rpad(String(sname), 28), ok_s ? "equal" : got_stock === nothing ? "MISSING" : "DIFFERS",
                "    ", rpad("r_$f", 24), ok_r ? "equal" : got_r === nothing ? "MISSING" : "DIFFERS")
        bad += !ok_s + !ok_r
    end
    println(bad == 0 ? "r_heaps check: PASS (the R copy and stock_* equal the base's four functions)" :
                       "r_heaps check: FAIL ($bad of 8 differ)")
    exit(bad == 0 ? 0 : 1)
end

if length(ARGS) == 2 && ARGS[1] == "gen"
    gen(ARGS[2])
elseif length(ARGS) == 3 && ARGS[1] == "check"
    check(ARGS[2], ARGS[3])
else
    println(stderr, "usage: julia r_heaps.jl gen <base partr.jl> | check <base partr.jl> <branch partr.jl>")
    exit(2)
end
