using Documenter
using Nitro

makedocs(
    sitename = "Nitro.jl",
    format = Documenter.HTML(),
    warnonly = true,  # everything is just a warning
    modules = [Nitro],
    pages = [
        "Overview" => "index.md",
        "api.md",
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
            "tutorial/secrets.md",
            "tutorial/sessions_and_auth.md",
            "tutorial/passwords.md",
            "Cookies and Sessions" => [
                "tutorial/cookies/basics.md",
                "tutorial/cookies/configuration.md",
                "tutorial/cookies/security.md",
                "tutorial/cookies/sessions.md"
            ],  
            "tutorial/cron_scheduling.md",
            "tutorial/bigger_applications.md",
            "tutorial/oauth2.md"
        ]
    ]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo = "github.com/NitroFramework/Nitro.jl.git",
    push_preview = false
)


