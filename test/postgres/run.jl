# The PostgreSQL race suite (#407): what the PormG worker store promises only on a real
# PostgreSQL -- the guarded deletes' re-check after a row-lock wait, `claim_next!`'s
# `SKIP LOCKED`, `requeue_expired!` against a renewal, the upgrade boot, and several consumer
# processes draining one queue. SQLite serializes writers, so the `@testitem` suite cannot stage
# any of it; `test/extensions/pormg_worker_tests.jl` pins the rendered SQL shapes instead.
#
#   NITRO_PG_CONNINFO="host=… port=… user=… password=… dbname=…" \
#   PORMG_POSTGRES_DRIVER=LibPQ \
#   julia --threads=2 test/postgres/run.jl
#
# `PORMG_POSTGRES_DRIVER` picks the driver the store's pool is built with: `LibPQ` (the default)
# or `Postgres`. CI runs both, in the `postgres` job of `.github/workflows/ci.yml`. Postgres.jl
# connects over TCP only, so give it `host=127.0.0.1`, not a Unix-socket directory.
#
# The database must be disposable: the suite drops and recreates `nitro_task` there, and needs a
# superuser for the upgrade scenario's event trigger.
#
# A separate entry point rather than `@testitem`s, on purpose: the default suite stays
# database-free, and the harness's no-silent-skip rule (`SKIPS_OK`) stays empty -- an item that
# skipped without a database would be exactly the quiet skip that rule refuses. Nothing here is
# named `*_tests.jl`, so the completeness check in `test/harness_manifest.jl` does not collect it.
#
# The environment is built here, from Nitro's own `Project.toml`: Nitro developed from this
# checkout, PormG at the `[sources]` url + rev pinned there -- read, not repeated, so this file is
# not a second pin -- and both drivers. LibPQ and Postgres.jl are not Nitro test dependencies.
# `NITRO_PG_ENV` names a directory to build it in and reuse (local reruns); CI builds it fresh.

using Pkg, TOML

const NITRO_ROOT = dirname(dirname(@__DIR__))

function build_env!(dir::AbstractString)
    Pkg.activate(dir)
    isfile(joinpath(dir, "Manifest.toml")) && return dir
    pormg = TOML.parsefile(joinpath(NITRO_ROOT, "Project.toml"))["sources"]["PormG"]
    # Precompiled once, at the end, not by each `add`. Adding LibPQ downgrades `Decimals`, which
    # PormG (already added) depends on, and the automatic precompile inside that `add` then fails
    # with "Unknown package: Decimals" (Julia 1.13.2). The same environment precompiles cleanly
    # in a separate step -- which the drain's consumer processes then load instead of each
    # compiling it again.
    withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
        Pkg.develop(PackageSpec(path = NITRO_ROOT))
        Pkg.add(PackageSpec(url = pormg["url"], rev = pormg["rev"]))
        Pkg.add(["LibPQ", "Postgres", "Test"])
    end
    Pkg.precompile()
    return dir
end

const PG_ENV = build_env!(get(ENV, "NITRO_PG_ENV", mktempdir()))

include(joinpath(@__DIR__, "scenarios.jl"))
