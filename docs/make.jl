using Documenter
using Nitro

makedocs(
    sitename = "Nitro.jl",
    format = Documenter.HTML(),
    # `checkdocs = :exports`, not Documenter's `:all` default: `:all` demands that EVERY
    # docstring under `src/`+`ext/` appear in a `@docs` block — 192 of them, mostly internal
    # helpers (`rename_key!`, `build_ip_extractor`, …) that are deliberately not public API.
    # `:exports` brings that to 117. It does NOT reach zero, which is why `:missing_docs` is
    # still in `warnonly` below.
    checkdocs = :exports,
    # `warnonly` is a NARROWED list, not `true` (#170). Everything NOT listed here is a hard
    # error — that is every Documenter category except these two, including `:doctest`,
    # `:example_block`, `:eval_block`, `:meta_block` and `:parse_error`. None of those appear
    # in `docs/src/` today, so the tightening costs nothing now; if you add a `@example` block
    # it has to actually run.
    #
    # The category this was done FOR is `:cross_references`: a dangling `@ref` is exactly the
    # failure that let `LifecycleMiddleware` sit undocumented while `extension_points.md`
    # silently could not link to it.
    #
    # `:missing_docs` (117) and `:docs_block` (18 — exported names in a `@docs` block with no
    # docstring, plus two duplicates) stay warnings only because clearing them is a docs sweep
    # across auth, extractors, cookies and routing. Shrink this list, never grow it.
    warnonly = [:missing_docs, :docs_block],
    modules = [Nitro],
    pages = [
        "Overview" => "index.md",
        "api.md",
        "upgrading.md",
        "Manual" => [
            "tutorial/first_steps.md",
            "tutorial/bi_app_config.md",
            "tutorial/hot_reload.md",
            "tutorial/workers.md",
            "tutorial/request_types.md",
            "tutorial/path_parameters.md",
            "tutorial/query_parameters.md",
            "tutorial/request_body.md",
            "tutorial/file_uploads.md",
            "tutorial/environment.md",
            "tutorial/secrets.md",
            "tutorial/reverse_proxy.md",
            "tutorial/authentication.md",
            "tutorial/sessions_and_auth.md",
            "tutorial/passwords.md",
            "Cookies and Sessions" => [
                "tutorial/cookies/basics.md",
                "tutorial/cookies/configuration.md",
                "tutorial/cookies/security.md",
                "tutorial/cookies/sessions.md"
            ],  
            "tutorial/bigger_applications.md",
            "tutorial/extension_points.md",
        ]
    ]
)

# Deploys to the `gh-pages` branch of THIS repository, which is what
# https://pingolee.github.io/Nitro.jl/ serves.
#
# `repo` used to name `NitroFramework/Nitro.jl`, which does not exist. Documenter treats an
# unreachable deploy target as "not deploying" and returns quietly rather than failing, so
# every build went green and nothing was ever published: no `gh-pages` branch, Pages not
# enabled, and the docs URL `UPGRADING.md` sends every upgrading app to returning 404.
#
# `devbranch` is pinned rather than left to Documenter's auto-detection. Current versions
# resolve it by querying the remote's HEAD, which works but depends on the CI checkout having
# a usable remote; naming it costs nothing and makes the `main`-not-`master` assumption
# explicit, since that mismatch is what silently disabled the other docs workflow.
deploydocs(
    repo = "github.com/PingoLee/Nitro.jl.git",
    devbranch = "main",
    push_preview = false
)


