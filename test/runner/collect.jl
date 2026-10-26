# Collection: turn test files into `TestItem` and `TestSetup` records WITHOUT running any of them.
#
# A file is parsed, not `include`d. Its top level may hold only `@testitem` and `@testsetup`
# calls -- the rule ReTestItems enforced through its `include` mapexpr -- and every way of
# breaking that, or of writing an item this runner would silently mis-run, is a
# `CollectionError` naming the file and line. Nothing is evaluated here, so a collection error
# can never be a half-run suite.

struct CollectionError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CollectionError) = print(io, "CollectionError: ", e.msg)

struct TestSetup
    name::Symbol
    file::String
    line::Int
    # The parsed `module` expression, kept whole. Execution swaps only its name slot, so the
    # runner never rebuilds the `:module` AST itself -- rebuilding it positionally is exactly
    # what broke ReTestItems on 1.14, where the expression carries a syntax version (#112).
    expr::Expr
end

struct TestItem
    name::String
    tags::Vector{Symbol}
    setups::Vector{Symbol}
    file::String       # absolute
    relfile::String    # relative to the project root, `/`-separated, for messages
    line::Int
    body::Expr         # the `begin ... end` block, with its parsed line numbers
end

# The only keywords this runner implements. ReTestItems also accepted `retries`, `timeout`,
# `skip`, `failfast` and `default_imports`; none is used here, and accepting one without
# implementing it would run the item differently from what its header says.
const ITEM_KEYWORDS = (:tags, :setup)

_where(relfile, line) = string(relfile, ":", line)
_fail(relfile, line, msg) = throw(CollectionError(string(_where(relfile, line), ": ", msg)))

"""
    setup_name_and_body(ex) -> (name, body)

Read a `module` expression's name and body from the END of its arguments. Julia 1.14 parses
`module M ... end` as `Expr(:module, v"1.14", true, :M, body)` where earlier versions give
`Expr(:module, true, :M, body)`; counting from the end reads both.
"""
function setup_name_and_body(ex::Expr)
    ex.head === :module && length(ex.args) >= 3 || return (nothing, nothing)
    return (ex.args[end-1], ex.args[end])
end

function _symbols(v, relfile, line, kw)
    v isa Expr && v.head === :vect ||
        _fail(relfile, line, "`$kw` must be a literal vector, as in `$kw=[...]`")
    out = Symbol[]
    for x in v.args
        s = kw === :tags ? (x isa QuoteNode && x.value isa Symbol ? x.value : nothing) :
                           (x isa Symbol ? x : nothing)
        s === nothing && _fail(relfile, line, kw === :tags ?
            "`tags` must list quoted symbols, as in `tags=[:core]`; got `$x`" :
            "`setup` must list @testsetup module names, as in `setup=[NitroCommon]`; got `$x`")
        push!(out, s)
    end
    return out
end

function _item(ex::Expr, file, relfile, line)
    length(ex.args) >= 4 || _fail(relfile, line, "`@testitem` needs a name and a `begin ... end` body")
    name = ex.args[3]
    name isa String || _fail(relfile, line,
        "the `@testitem` name must be a string literal (an interpolated name cannot be selected by `--name`); got `$name`")
    body = ex.args[end]
    body isa Expr && body.head === :block ||
        _fail(relfile, line, "`@testitem \"$name\"` must end in a `begin ... end` body")
    tags, setups = Symbol[], Symbol[]
    seen = Symbol[]
    for kw in ex.args[4:end-1]
        kw isa Expr && kw.head === :(=) && kw.args[1] isa Symbol ||
            _fail(relfile, line, "`@testitem \"$name\"` options must be `keyword=value`; got `$kw`")
        k = kw.args[1]
        k in ITEM_KEYWORDS || _fail(relfile, line,
            "unknown `@testitem` keyword `$k` on \"$name\". This runner implements only " *
            join(("`$x`" for x in ITEM_KEYWORDS), " and ") * ", and refuses the rest rather than ignore them")
        k in seen && _fail(relfile, line, "`@testitem \"$name\"` repeats the keyword `$k`")
        push!(seen, k)
        if k === :tags
            tags = _symbols(kw.args[2], relfile, line, :tags)
        else
            setups = _symbols(kw.args[2], relfile, line, :setup)
        end
    end
    return TestItem(name, tags, setups, file, relfile, line, body)
end

function _setup(ex::Expr, file, relfile, line)
    mod = length(ex.args) == 3 ? ex.args[3] : nothing
    mod isa Expr && mod.head === :module ||
        _fail(relfile, line, "`@testsetup` takes exactly one `module Name ... end`")
    name, _ = setup_name_and_body(mod)
    name isa Symbol || _fail(relfile, line, "`@testsetup module` needs a plain module name; got `$name`")
    return TestSetup(name, file, line, mod)
end

"""
    collect_file(file, relfile) -> (items, setups)

Parse one test file into its records, in source order. `relfile` is how messages name it.
"""
function collect_file(file::AbstractString, relfile::AbstractString)
    file, relfile = String(file), String(relfile)
    top = Meta.parseall(read(file, String); filename = file)
    items, setups = TestItem[], TestSetup[]
    names = Set{String}()
    line = 0
    for ex in top.args
        if ex isa LineNumberNode
            line = ex.line
            continue
        end
        if ex isa Expr && ex.head in (:error, :incomplete)
            detail = isempty(ex.args) ? "" : (ex.args[1] isa Exception ?
                     sprint(showerror, ex.args[1]) : string(ex.args[1]))
            _fail(relfile, line, "does not parse: $detail")
        end
        if ex isa Expr && ex.head === :macrocall && length(ex.args) >= 2
            ln = ex.args[2] isa LineNumberNode ? ex.args[2].line : line
            if ex.args[1] === Symbol("@testitem")
                it = _item(ex, file, relfile, ln)
                # ReTestItems enforced this per file too. A duplicate would make `--name`
                # select two items, and a failure report ambiguous.
                it.name in names && _fail(relfile, ln, "a second `@testitem \"$(it.name)\"` in the same file")
                push!(names, it.name)
                push!(items, it)
                continue
            elseif ex.args[1] === Symbol("@testsetup")
                push!(setups, _setup(ex, file, relfile, ln))
                continue
            end
        end
        _fail(relfile, line,
            "only `@testitem` and `@testsetup` may appear at the top level of a test file; " *
            "found `$(first(string(ex), 60))`. Code outside an item would run at collection, " *
            "in no item, with no result to report it")
    end
    return items, setups
end

# Lexical path order, compared component by component. This is the order ReTestItems ran
# the suite in -- it sorted each directory's children by path -- and so the order the suite has
# always passed in. Comparing components rather than whole strings is what puts the directory
# `middleware/` ahead of the file `middleware_cache_tests.jl`, exactly as ReTestItems did.
sort_files(files, root) = sort(files; by = f -> splitpath(relpath(f, root)))

"""
    resolve_paths(paths) -> Vector{String}

Expand each path to test files: a directory to every test file under it (the harness's own
`discover_test_files`, dot-paths pruned), a file to itself. A path that does not exist, or a
file that is not a test file, is an error, never a warning and a shorter run.
"""
function resolve_paths(paths)
    out = String[]
    for p in paths
        p = abspath(p)
        if isdir(p)
            append!(out, normpath.(joinpath.(p, NitroTestHarness.discover_test_files(p))))
        elseif isfile(p)
            NitroTestHarness.is_test_file(basename(p)) ||
                error("Not a test file: $p\nTest files end in `_test.jl`, `_tests.jl`, `-test.jl` or `-tests.jl`.")
            push!(out, normpath(p))
        else
            error("No such test path: $p")
        end
    end
    return unique(out)
end

"""
    collect_suite(files; root) -> (items, setups)

Collect every file, in lexical path order relative to `root` (the project directory, which is
also how messages name files). Setup names must be unique across the run.
"""
function collect_suite(files; root::AbstractString)
    items, setups = TestItem[], Dict{Symbol,TestSetup}()
    for f in sort_files(files, root)
        rel = replace(relpath(f, root), '\\' => '/')
        its, sts = collect_file(f, rel)
        append!(items, its)
        for s in sts
            haskey(setups, s.name) && _fail(rel, s.line,
                "`@testsetup module $(s.name)` is already defined at $(relpath(setups[s.name].file, root)):$(setups[s.name].line)")
            setups[s.name] = s
        end
    end
    return items, setups
end

"""
    select_items(items; tags, skip_tags, name) -> Vector{TestItem}

The run's selection, through `NitroTestHarness.selects`: the one rule `harness_tests.jl` pins.
"""
select_items(items; tags = Symbol[], skip_tags = Symbol[], name = nothing) =
    filter(it -> NitroTestHarness.selects(it.name, it.tags; tags, skip_tags, name), items)

# SplitMix64: a deterministic stream that does not depend on `Random`, whose generators are not
# promised to produce the same numbers across Julia versions. A seed printed by one run must
# reproduce its order on every version the suite runs on.
mutable struct SplitMix64
    s::UInt64
end
function _next!(r::SplitMix64)
    r.s += 0x9e3779b97f4a7c15
    z = r.s
    z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return z ⊻ (z >> 31)
end
function _shuffle!(v, r::SplitMix64)
    for i in length(v):-1:2
        j = Int(_next!(r) % UInt64(i)) + 1
        v[i], v[j] = v[j], v[i]
    end
    return v
end

"""
    shuffle_items(items, seed) -> Vector{TestItem}

Shuffle the order of the files, then the order of the items within each file, deterministically
from `seed`. A file's items stay together, as they do in an ordered run.
"""
function shuffle_items(items, seed::Integer)
    r = SplitMix64(UInt64(seed))
    groups = Vector{TestItem}[]
    for it in items
        if isempty(groups) || groups[end][1].file != it.file
            push!(groups, TestItem[])
        end
        push!(groups[end], it)
    end
    _shuffle!(groups, r)
    foreach(g -> _shuffle!(g, r), groups)
    return reduce(vcat, groups; init = TestItem[])
end
