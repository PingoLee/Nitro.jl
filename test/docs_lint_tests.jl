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
