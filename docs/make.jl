using Documenter
using Nitro

makedocs(
    sitename = "Nitro.jl",
    format = Documenter.HTML(),
    # `checkdocs = :exports`, not Documenter's `:all` default: `:all` demands that EVERY
    # docstring under `src/`+`ext/` appear in a `@docs` block — 192 of them, mostly internal
    # helpers (`rename_key!`, `build_ip_extractor`, …) that are deliberately not public API.
    #
    # `:exports` counts every name a submodule exports, not only what `Nitro` exports, so
    # helpers that `Core`'s submodules export to each other count too. They are rendered on
    # `api/internals.md` under a "not public API" banner.
    #
    # `checkdocs_ignored_modules` is NOT an option for them. Documenter 1.19's `submodules()`
    # drops the ignore set on its recursive call, so only DIRECT children of `Nitro` can be
    # ignored, and every plumbing module (`RouterHOF`, `Handlers`, `Reflection`) sits under
    # `Core`. Passing them there is silently a no-op (#186).
    #
    # This check only sees docstrings that EXIST. An exported name with no docstring at all
    # passes it silently, and #186 left that backlog (mostly `Auth` and `Workers`) untouched.
    checkdocs = :exports,
    # No `warnonly`: every Documenter category is a hard error (#170 narrowed it from `true`,
    # #186 emptied it). That includes `:missing_docs` (a docstring on an exported name that no
    # `@docs` block renders) and `:docs_block` (a `@docs` entry with no docstring, a duplicate,
    # or an undefined binding). Do not reintroduce the keyword; fix the docs instead.
    #
    # A docstring can be rendered in only one `@docs` block. Tutorials link to the API pages
    # with `[`name`](@ref)` rather than repeating a block. And when `Nitro` defines a function
    # that shadows a `Core` one (`serve`, `terminate`, `urlpatterns`), the docstring goes on the
    # `Nitro` binding. A copy left on the `Core` binding counts as missing.
    modules = [Nitro],
    pages = [
        "Overview" => "index.md",
        "API Reference" => [
            "api/app.md",
            "api/routing.md",
            "api/requests.md",
            "api/responses.md",
            "api/sessions.md",
            "api/middleware.md",
            "api/auth.md",
            "api/workers.md",
            "api/worker_store.md",
            "api/internals.md",
        ],
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
            "tutorial/streaming.md",
            "tutorial/environment.md",
            "tutorial/secrets.md",
            "tutorial/reverse_proxy.md",
            "tutorial/deployment.md",
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


