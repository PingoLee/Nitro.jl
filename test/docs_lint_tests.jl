@testitem "docs_lint reads a CRLF checkout like an LF one (#820)" tags=[:core] begin

# `.github/scripts/docs_lint.jl` ran only on CI's LF checkout. On a Windows checkout under
# `core.autocrlf=true` every line ends in `\r`, which defeats each `(?m)…$` anchor:
# `block_scalar` stopped recognising `description: >-\r`, so four folded skill descriptions
# were policed as plain scalars and the lint was red on a clean `main`. The script stays
# importable for exactly this: these assertions call its functions on fixtures of both
# endings.

using Test

const LINT = joinpath(pkgdir(Nitro), ".github", "scripts", "docs_lint.jl")
lint = Module(:DocsLintUnderTest)
Base.include(lint, LINT)

folded(eol) = join(["---", "name: demo", "description: >-",
                    "  Add a route end-to-end: handler, path() registration.", "---", "body"], eol)
inline(eol) = join(["---", "name: demo",
                    "description: Add a route end-to-end: handler.", "---", "body"], eol)

problem(text) = lint.block_scalar(text, "description") ? nothing :
                lint.yaml_scalar_problem("description", lint.front_matter(text)["description"])

mktempdir() do dir
    for (eol, label) in (("\n", "LF"), ("\r\n", "CRLF"))
        f = joinpath(dir, "folded_$label.md")
        write(f, folded(eol))
        i = joinpath(dir, "inline_$label.md")
        write(i, inline(eol))

        @testset "$label: a folded `>-` description is exempt" begin
            text = lint.readtext(f)
            @test !occursin('\r', text)
            @test lint.block_scalar(text, "description")
            @test problem(text) === nothing
        end

        # The exemption must not widen into a pass for everything: an inline `: ` is still
        # the hazard the check exists for, whatever the line endings.
        @testset "$label: an unquoted inline `: ` is still a finding" begin
            @test problem(lint.readtext(i)) == "`description` contains \": \" but is not quoted"
        end
    end

    # The defect itself, pinned: the raw CRLF text is what the lint used to see.
    @test !lint.block_scalar(folded("\r\n"), "description")
end

end

@testitem "docs_lint holds documented guard/auth keyword signatures to src/ (#873)" tags=[:core] begin

# Check H reads both sides with Base's parser. These pin the extractors on the shapes the
# docs and the source actually use, the comparison rules (names as sets, literal defaults
# only), and the drift that motivated it: the stale `login_required` docstring of #872,
# which named the right keywords and the wrong default.

using Test

const LINT = joinpath(pkgdir(Nitro), ".github", "scripts", "docs_lint.jl")
lint = Module(:DocsLintSignaturesUnderTest)
Base.include(lint, LINT)

srcdef(code, name) = only(lint.source_definitions(Meta.parseall(code), name))
kwnames(kws) = first.(kws)
doc_kws(call) = lint.kwargs_of(lint.parse_doc_call(call))

@testset "source side: every definition form, and the docstring beside it" begin
    code = """
    module M
    \"\"\"
        f(x; a = 1, b = nothing)

    An example: `f(1; a = 2)`.
    \"\"\"
    function f(x::Int; a::Int = 1,
               b::Union{Nothing, String} = nothing, rest...)
        return x
    end
    g(x::T; k::Symbol = :equals) where {T} = x
    \"\"\"
        h(; z = 1)
    \"\"\"
    @noinline function h(; z::Int = 1)::Int
        return z
    end
    end
    """
    sig, doc = srcdef(code, :f)
    @test kwnames(lint.kwargs_of(sig)) == [:a, :b, Symbol("rest...")]
    @test startswith(lint.signature_block(doc), "    f(x; a = 1, b = nothing)")
    @test !occursin("example", lint.signature_block(doc))

    sig, doc = srcdef(code, :g)
    @test lint.kwargs_of(sig) == [:k => QuoteNode(:equals)]
    @test doc === nothing

    # A docstring above a macro-wrapped definition still reaches it (review of #873).
    sig, doc = srcdef(code, :h)
    @test lint.kwargs_of(sig) == [:z => 1]
    @test strip(lint.signature_block(doc)) == "h(; z = 1)"

    # A call written inside a string is not a definition.
    @test isempty(lint.source_definitions(Meta.parseall("\"\"\"\n    f(x; a = 2)\n\"\"\"\nh() = 1"), :f))
end

@testset "doc side: comments, placeholders, multi-line, example calls" begin
    text = """
    ```julia
    login_required(;      redirect_url::Nullable{String} = nothing,  # nothing => "/login"
                          session_key::String = "user_id", denied = nothing)  # not both
    kid_required(allowed; denied = <403>)   # reads getprincipal(req).kid
    ```
    GuardMiddleware(login_required(), kid_required(keys))
    login_required()
    """
    calls = lint.doc_calls(text, "login_required")
    @test first.(calls) == [2]                       # the line, for the finding's message
    @test kwnames(doc_kws(last(only(calls)))) == [:redirect_url, :session_key, :denied]
    @test doc_kws(last(only(lint.doc_calls(text, "kid_required")))) == [:denied => lint.DOC_PLACEHOLDER]
    @test lint.parse_doc_call("f(; a = <default 401s>, b = <403 Forbidden>)") !== nothing
    # A `#` inside a string stays.
    @test lint.strip_comment("a = \"x#y\"  # comment") == "a = \"x#y\"  "

    # An example that starts a line with a keyword call reads as a signature, indented or not;
    # one on the line of what holds it does not.
    @test first.(lint.doc_calls("BearerAuth(v; a = 1)\nmiddleware = [\n    BearerAuth(v; a = f),\n]", "BearerAuth")) == [1, 3]
    @test length(lint.doc_calls("BearerAuth(v; a = 1)\nmiddleware = [BearerAuth(v; a = f)]", "BearerAuth")) == 1
end

@testset "comparison: names as sets, and every literal default the doc writes" begin
    src = lint.kwargs_of(srcdef("f(x; a::String = \"u\", k::Symbol = :equals, denied = _forbidden, req, n = 1.0, m = missing) = x", :f)[1])
    drift(call) = lint.kwarg_drift(doc_kws(call), src)
    ok = "a = \"u\", k = :equals, denied = <403>, req, n = 1.0, m = missing"

    @test isempty(drift("f(x; $ok)"))
    @test isempty(drift("f(x; m = missing, n = 1.0, req, denied = <403>, k = :equals, a = \"u\")"))  # order
    @test isempty(drift("f(x; a, k, denied, req, n, m)"))   # an omitted default is an abbreviation
    @test isempty(drift("f(x; a = \"u\", k = :equals, denied = DEFAULT_DENIAL, req, n = 1.0, m = missing)"))  # a non-literal
    @test only(drift("f(x; a = \"u\", k = :equals, req, n = 1.0, m = missing)")) == "does not document keyword(s) `denied`"
    @test only(drift("f(x; $ok, extra = 2)")) == "documents keyword(s) the method does not take: `extra`"
    @test only(drift("f(x; a = \"v\", k = :equals, denied = <403>, req, n = 1.0, m = missing)")) ==
          "`a` defaults to `\"u\"` in the method, but the doc writes `\"v\"`"
    @test only(drift("f(x; a = \"u\", k = :contains, denied = <403>, req, n = 1.0, m = missing)")) ==
          "`k` defaults to `:(:equals)` in the method, but the doc writes `:(:contains)`"
    # Review of #873: each of these used to pass.
    @test only(drift("f(x; a = \"u\", k = :equals, denied = nothing, req, n = 1.0, m = missing)")) ==
          "`denied` defaults to `_forbidden` in the method, but the doc writes `nothing` " *
          "(write a placeholder such as `<403>` for a private default)"
    @test only(drift("f(x; a = \"u\", k = :equals, denied = <403>, req = 1, n = 1.0, m = missing)")) ==
          "`req` is a required keyword in the method, but the doc gives it the default `1`"
    @test only(drift("f(x; a = \"u\", k = :equals, denied = <403>, req, n = 1, m = missing)")) ==
          "`n` defaults to `1.0` in the method, but the doc writes `1`"
    @test only(drift("f(x; a = \"u\", k = :equals, denied = <403>, req, n = 1.0, m = nothing)")) ==
          "`m` defaults to `missing` in the method, but the doc writes `nothing`"
end

@testset "#872: the stale login_required docstring is a finding" begin
    guards = read(joinpath(pkgdir(Nitro), "src", "middleware", "guards.jl"), String)
    sig, _ = srcdef(guards, :login_required)
    stale = "login_required(; redirect_url = \"/login\", session_key = \"user_id\", denied = nothing)"
    @test lint.kwarg_drift(doc_kws(stale), lint.kwargs_of(sig)) ==
          ["`redirect_url` defaults to `nothing` in the method, but the doc writes `\"/login\"`"]
end

@testset "lint_signatures fails closed on a fixture tree" begin
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "src", "g.jl"), """
        \"\"\"
            guard(; denied = <403>)
        \"\"\"
        guard(; denied = _forbidden) = nothing
        undocumented(; denied = _forbidden) = nothing
        twice(; a = 1) = 1
        twice(x; a = 1) = x
        \"\"\"
            drifted(; a = 1)
        \"\"\"
        drifted(; a = 1, b = 2) = nothing
        \"\"\"
            stale(; redirect_url = "/login", denied = nothing)
        \"\"\"
        stale(; redirect_url = nothing, denied = nothing) = nothing
        """)
        write(joinpath(root, "ref.md"), """
        guard(; denied = <403>)
        undocumented(; denied = <403>)
        drifted(; a = 1, b = 2)
        stale(; redirect_url = nothing, denied = nothing)
        """)
        errs(name) = (e = String[]; lint.lint_signatures(e; root, doc = "ref.md",
                                                          checks = [name => "src/g.jl"]); e)
        @test isempty(errs("guard"))
        @test only(errs("undocumented")) == "src/g.jl (docstring of `undocumented`): no docstring, so no signature to check"
        @test occursin("has 2 method definitions", only(errs("twice")))
        # A definition that moved away stops the check there: nothing to compare the doc with.
        @test occursin("has 0 method definitions", only(errs("absent")))
        @test only(errs("drifted")) ==
              "src/g.jl (docstring of `drifted`): `drifted` does not document keyword(s) `b` (method in `src/g.jl`)"

        # #872's shape, end to end: the docstring's default drifted, the reference's did not.
        @test only(errs("stale")) ==
              "src/g.jl (docstring of `stale`): `stale` `redirect_url` defaults to `nothing` in the " *
              "method, but the doc writes `\"/login\"` (method in `src/g.jl`)"

        # The reference writing only an example call, no signature, is a finding too; and so is
        # writing two, with the lines named so the example is easy to find.
        write(joinpath(root, "ref.md"), "guard()\n")
        @test only(errs("guard")) ==
              "ref.md: expected one `guard(…; …)` signature at the start of a line, found 0"
        write(joinpath(root, "ref.md"), "guard(; denied = <403>)\n\nmiddleware = [\n    guard(; denied = f),\n]\n")
        @test only(errs("guard")) ==
              "ref.md: expected one `guard(…; …)` signature at the start of a line, found 2 (lines 1, 4)"
    end
end

end
