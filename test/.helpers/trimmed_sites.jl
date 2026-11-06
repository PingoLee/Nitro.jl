# The trimmed-only branches, listed (#858). Included by `test/trimmed_branches_tests.jl` and by
# the child it spawns, `trimmed_child.jl`. Plain Julia: it loads nothing.
#
# Under the JIT `_trimmed()` is the constant `false`, so every branch it guards is dead code there
# and CI never runs one. Each site is listed here once, by its file and the function it sits in,
# with how it is tested:
#
#   :A  behavioural. The child runs it on the same inputs before and after redefining
#       `_trimmed()` to `true`, and the two results must agree.
#   :B  a refusal, or a fallback the trimmed image takes instead. In the child, the method's
#       optimized code holds no dynamic call, and what it throws or returns names a type, never
#       a value.
#   (:exempt, reason)  tested elsewhere, or unreachable in a trimmed image; the reason says which.
#
# `trimmed_sites` finds every site in `src/` and `ext/`. The test fails on one that is not listed
# here, so a new trimmed branch is decided on before it merges.

const TRIMMED_SITES = Dict{Tuple{String, String}, Any}(
    # ── A ───────────────────────────────────────────────────────────────────────────────────
    ("src/middleware/session_middleware.jl", "_session_changed") => :A,
    ("src/middleware/session_middleware.jl", "_copy_session") => :A,
    ("src/types.jl", "_copy_session_value") => :A,
    ("src/Auth/jwt.jl", "_parse_jwt_claims") => :A,
    ("src/Auth/validators.jl", "_validator_takes_request") => :A,
    ("src/middleware/auth_middleware.jl", "_validate_token") => :A,

    # ── B ───────────────────────────────────────────────────────────────────────────────────
    ("src/jsonvalue.jl", "_with_foreign_json_value") => :B,
    ("src/jsonvalue.jl", "_foreign_equal") => :B,
    ("src/jsonvalue.jl", "_foreign_copy") => :B,
    ("src/types.jl", "_is_nonempty_abstract") => :B,
    ("src/types.jl", "_pathparams_foreign") => :B,
    ("src/middleware/session_middleware.jl", "_copy_foreign_session") => :B,
    ("src/core/request.jl", "_with_foreign_session") => :B,
    ("src/middleware/extract_ip.jl", "_extract_foreign!") => :B,
    ("src/middleware/guards.jl", "_with_foreign_claims") => :B,
    ("src/middleware/guards.jl", "_foreign_contains") => :B,
    ("src/Auth/claims.jl", "_claim_int_abstract") => :B,
    ("src/Auth/claims.jl", "_claim_string_other") => :B,
    ("src/Auth/validators.jl", "_warn_iss") => :B,
    ("src/middleware/csrf_middleware.jl", "_foreign_binding") => :B,
    ("src/middleware/csrf_middleware.jl", "_foreign_field_token") => :B,
    ("src/middleware/access_log.jl", "_client_ip_string") => :B,
    ("src/routeendpoint.jl", "_format_unregistered") => :B,
    ("src/routeendpoint.jl", "_with_unlisted_body") => :B,
    ("src/routerhof.jl", "register_route_lifecycle!") => :B,
    ("src/routerhof.jl", "register_serve_lifecycle!") => :B,

    # ── Exempt ──────────────────────────────────────────────────────────────────────────────
    ("src/context.jl", "ServerHandle") => (:exempt,
        "the server handle's foreign calls: test/juliac_internals_contract_tests.jl"),
    ("src/context.jl", "Base.isopen") => (:exempt,
        "the server handle's foreign calls: test/juliac_internals_contract_tests.jl"),
    ("src/context.jl", "Base.wait") => (:exempt,
        "the server handle's foreign calls: test/juliac_internals_contract_tests.jl"),
    ("src/context.jl", "_shutdown_server") => (:exempt,
        "the server handle's foreign calls: test/juliac_internals_contract_tests.jl"),
    ("src/context.jl", "_close_eager_revise") => (:exempt,
        "the Revise watcher, which a trimmed image never starts (serve refuses Revise there)"),
    ("src/core/lifecycle.jl", "_with_stdout") => (:exempt,
        "the banner's output stream, which only a running executable can tell apart"),
    ("src/core/lifecycle.jl", "_stdout_color") => (:exempt,
        "the banner's colour, which only a running executable can tell apart"),
    ("src/core/lifecycle.jl", "serve") => (:exempt,
        "Revise refused in a trimmed image: REVISE=refused in test/juliac_internals_contract_tests.jl"),
    ("src/core/lifecycle.jl", "_serve_pipeline") => (:exempt,
        "the eager Revise watcher, which the refusal in serve folds away"),
    ("src/routeendpoint.jl", "RouteEndpoint") => (:exempt,
        "the route endpoint's ccall to an exported thunk, which only a --trim build has: " *
        "test/juliac_internals_contract_tests.jl"),
    ("src/routeendpoint.jl", "call_chain") => (:exempt,
        "the chain endpoint's ccall to an exported thunk, which only a --trim build has: " *
        "test/juliac_internals_contract_tests.jl"),
    ("src/routeendpoint.jl", "serve_lifecycle_entry") => (:exempt,
        "the lifecycle hooks' foreign calls: test/juliac_internals_contract_tests.jl"),
    ("src/routeendpoint.jl", "_run_lifecycle") => (:exempt,
        "the lifecycle hooks' foreign calls: test/juliac_internals_contract_tests.jl"),
    ("src/methods.jl", "_rethrow_value_free") => (:exempt,
        "the value-free rethrow: test/juliac_internals_contract_tests.jl (trimmed gate)"),
)

# How many `_trimmed()` calls each listed function holds, where that is not one. A second site in a
# listed function is a new branch too, and its count is what makes the guard see it.
const TRIMMED_SITE_COUNTS = Dict{Tuple{String, String}, Int}(
    ("src/core/lifecycle.jl", "serve") => 2,    # the Revise refusal, then the branch it folds away
)

"""
    trimmed_sites(root) -> Vector{NamedTuple}

Every call to `_trimmed()` (bare or qualified) in the `.jl` files under `root/src` and
`root/ext`, as `(; file, func, line)`. `file` is relative to `root`, with `/`; `func` is the name of
the function definition it sits in, as written (`"Base.isopen"`), or `"<toplevel>"`. The files are
parsed, so a comment or a docstring never counts. Neither does a quoted expression: that is where
`_trimmed()` is redefined, not where it is read. `line` is the last line marker before the call,
which for a short-form definition spanning lines is the definition's first line.

What it cannot see, none of which `src/` does today: a site in code built from a quote
(`Core.eval(M, quote … end)`, `@eval :(…)`), one a macro expands to, and `_trimmed` passed as a
value rather than called.
"""
function trimmed_sites(root::AbstractString)
    found = NamedTuple{(:file, :func, :line), Tuple{String, String, Int}}[]
    for dir in ("src", "ext")
        isdir(joinpath(root, dir)) || continue
        for (path, _, files) in walkdir(joinpath(root, dir)), name in sort(files)
            endswith(name, ".jl") || continue
            full = joinpath(path, name)
            file = replace(relpath(full, root), '\\' => '/')
            _walk_trimmed!(found, file, Meta.parseall(read(full, String); filename = file),
                           "<toplevel>", Ref(0))
        end
    end
    return found
end

_is_trimmed_ref(x) = x === :_trimmed ||
    (x isa Expr && x.head === :. && length(x.args) == 2 && x.args[2] == QuoteNode(:_trimmed)) ||
    (x isa GlobalRef && x.name === :_trimmed)

# The name a definition's signature gives, as written, or `nothing` when `ex` is not a call shape.
function _signature_name(sig)
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    sig isa Expr && sig.head === :call || return nothing
    f = sig.args[1]
    f isa Symbol && return string(f)
    f isa Expr && f.head === :. && return string(f)
    f isa Expr && f.head === :(::) && return string(f.args[end])   # (::T)(…)
    f isa Expr && f.head === :curly && return string(f.args[1])    # T{P}(…)
    return string(f)
end

function _walk_trimmed!(found, file, ex, func, line::Ref{Int})
    if ex isa LineNumberNode
        line[] = ex.line
        return
    end
    ex isa Expr || return
    ex.head === :quote && return
    if ex.head === :call && _is_trimmed_ref(ex.args[1])
        push!(found, (; file, func, line = line[]))
    end
    if ex.head in (:function, :(=)) && length(ex.args) == 2
        name = _signature_name(ex.args[1])
        if name !== nothing && (ex.head === :function || _is_call_signature(ex.args[1]))
            # The signature is not a use; only the body is walked, under the new name.
            _walk_trimmed!(found, file, ex.args[2], name, line)
            return
        end
    end
    for a in ex.args
        _walk_trimmed!(found, file, a, func, line)
    end
end

# `f(x) = …` defines a method; `x = f(y)` and `a.b = c` do not.
function _is_call_signature(lhs)
    while lhs isa Expr && lhs.head in (:where, :(::))
        lhs.head === :(::) && length(lhs.args) == 1 && return false
        lhs = lhs.args[1]
    end
    return lhs isa Expr && lhs.head === :call
end
