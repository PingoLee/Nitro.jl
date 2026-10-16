# One password check at the default costs (#587): how long `check_password` holds its thread. A
# login handler runs it on a `:default` thread, and neither encoder yields: PBKDF2 is one libcrypto
# ccall, bcrypt is a pure-Julia loop. So this time is a hold in the sense of #467 and #588, and the
# login endpoint is a computing handler every app has. Run at one thread.
#
#   NITRO_BENCH_GROUPS=passwords julia --project=bench --threads=1 bench/runbenchmarks.jl
#
# `socket/server.jl`'s `LOGIN=1` serves the same two checks as `/login` and `/login_bcrypt`, for
# `stall.sh`'s `login` and `login_bcrypt` variants.
SUITE["passwords"] = BenchmarkGroup()

const BENCH_PASSWORD = "correct horse battery staple"
# Minted once, at the defaults: pbkdf2_sha256 at `DEFAULT_PBKDF2_ITERATIONS`, bcrypt at
# `DEFAULT_BCRYPT_COST`.
const BENCH_PBKDF2_HASH = Nitro.Auth.make_password(BENCH_PASSWORD)
const BENCH_BCRYPT_HASH = Nitro.Auth.make_password(BENCH_PASSWORD; algorithm = "bcrypt")

SUITE["passwords"]["check_pbkdf2_default"] =
    @benchmarkable Nitro.Auth.check_password(BENCH_PASSWORD, BENCH_PBKDF2_HASH) evals=1
SUITE["passwords"]["check_bcrypt_default"] =
    @benchmarkable Nitro.Auth.check_password(BENCH_PASSWORD, BENCH_BCRYPT_HASH) evals=1
