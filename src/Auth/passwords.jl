using Bcrypt
using Printf

const DEFAULT_PBKDF2_ITERATIONS = 720000
const DEFAULT_PBKDF2_KEY_LENGTH = 32
const DEFAULT_BCRYPT_COST = 12
const DEFAULT_SPRING_ITERATIONS = 310000

# Ceilings on the work one password operation may cost (#311). A login endpoint hashes
# whatever an unauthenticated client submits, and verifies against cost parameters read out
# of the stored hash, so without them one request can pin a thread for as long as it likes.
# The encoder constructors enforce the same ceilings, so no encoder mints a hash that its
# own `matches` refuses.
const MAX_PASSWORD_BYTES = 4096            # Django's historical cap
# Bounds iterations x SHA-256 output blocks, since each 32-byte block of the key repeats every
# iteration: 10M one-block iterations, ~8x Django 6.0's 1.2M default, ~2 s through libcrypto.
const MAX_PBKDF2_ITERATIONS = 10_000_000
const MIN_PBKDF2_KEY_LENGTH = 16
const MAX_PBKDF2_KEY_LENGTH = 64           # two SHA-256 blocks
const MAX_BCRYPT_COST = 15                 # 8x the default of 12, ~2.7 s; Bcrypt.jl itself allows 31

const SUPPORTED_ALGORITHMS = ["pbkdf2_sha256", "bcrypt", "spring_sha256"]
# Future: push!(SUPPORTED_ALGORITHMS, "argon2") when backend is ready

const _DEFAULT_ALGORITHM = Ref{String}("pbkdf2_sha256")

_isalnum(char::Char) = isletter(char) || isdigit(char)

# Whether a password may be hashed at all. Checked before any hashing: `encode` and
# `make_password` throw on `false`, `matches` and `check_password` answer `false`.
_hashable(password::AbstractString) = !isempty(password) && ncodeunits(password) <= MAX_PASSWORD_BYTES

function _require_hashable(password::AbstractString)
    isempty(password) && throw(ArgumentError("Password cannot be empty"))
    ncodeunits(password) > MAX_PASSWORD_BYTES &&
        throw(ArgumentError("Password exceeds the $MAX_PASSWORD_BYTES-byte limit"))
    return nothing
end

_pbkdf2_key_length_ok(key_length::Integer) = MIN_PBKDF2_KEY_LENGTH <= key_length <= MAX_PBKDF2_KEY_LENGTH

# Both ranges are checked before the product, which therefore cannot overflow.
_pbkdf2_work_ok(iterations::Integer, key_length::Integer) =
    _pbkdf2_key_length_ok(key_length) && 1 <= iterations <= MAX_PBKDF2_ITERATIONS &&
    iterations * cld(key_length, 32) <= MAX_PBKDF2_ITERATIONS

function _check_pbkdf2_parameters(iterations::Int, key_length::Int)
    _pbkdf2_key_length_ok(key_length) ||
        throw(ArgumentError("Key length must be between $MIN_PBKDF2_KEY_LENGTH and $MAX_PBKDF2_KEY_LENGTH"))
    _pbkdf2_work_ok(iterations, key_length) ||
        throw(ArgumentError("Iterations must be at least 1, and iterations x 32-byte key blocks at most $MAX_PBKDF2_ITERATIONS"))
    return nothing
end

# A stored hash whose cost parameters are out of bounds is refused, not verified: it is
# corrupt, or someone wrote it to make every login to that account expensive. The hash is
# never logged.
function _refuse_stored_parameters()
    @warn "Stored password hash has out-of-range cost parameters; refusing to verify it. Re-hash with a supported encoder." maxlog=1
    return false
end

abstract type PasswordEncoder end

function encode end
function matches end
function upgrade_encoding end

DEFAULT_ALGORITHM() = _DEFAULT_ALGORITHM[]

function set_default_algorithm!(algorithm::String)
    alg = lowercase(algorithm)
    alg in SUPPORTED_ALGORITHMS || throw(ArgumentError("Unsupported algorithm: $algorithm. Supported: $(join(SUPPORTED_ALGORITHMS, ", "))"))
    _DEFAULT_ALGORITHM[] = alg
    return alg
end

struct ValidationResult
    valid::Bool
    errors::Vector{String}
    strength::Symbol
end

struct PasswordValidator
    min_length::Int
    max_length::Int
    require_uppercase::Bool
    require_lowercase::Bool
    require_digit::Bool
    require_special::Bool
    common_passwords::Set{String}
    messages::Dict{Symbol, String}

    function PasswordValidator(; min_length::Int=8,
        max_length::Int=128,
        require_uppercase::Bool=true,
        require_lowercase::Bool=true,
        require_digit::Bool=true,
        require_special::Bool=false,
        common_passwords::Union{Set{String}, Vector{String}, Nothing}=nothing,
        messages::Union{Dict{Symbol, String}, Nothing}=nothing)

        defaults = Dict(
            :min_length => "Password must be at least %d characters long",
            :max_length => "Password must not exceed %d characters",
            :require_uppercase => "Password must contain at least one uppercase letter",
            :require_lowercase => "Password must contain at least one lowercase letter",
            :require_digit => "Password must contain at least one digit",
            :require_special => "Password must contain at least one special character",
            :common_password => "Password is too common and easily guessable",
        )
        if messages !== nothing
            merge!(defaults, messages)
        end

        resolved_common = if common_passwords === nothing
            DEFAULT_COMMON_PASSWORDS
        elseif common_passwords isa Vector
            Set(lowercase.(common_passwords))
        else
            Set(lowercase.(collect(common_passwords)))
        end

        new(min_length, max_length, require_uppercase, require_lowercase, require_digit, require_special, resolved_common, defaults)
    end
end

struct PBKDF2PasswordEncoder <: PasswordEncoder
    iterations::Int
    salt_length::Int
    key_length::Int

    function PBKDF2PasswordEncoder(; iterations::Int=DEFAULT_PBKDF2_ITERATIONS, salt_length::Int=22, key_length::Int=DEFAULT_PBKDF2_KEY_LENGTH)
        _check_pbkdf2_parameters(iterations, key_length)
        salt_length < 8 && throw(ArgumentError("Salt length must be at least 8"))
        new(iterations, salt_length, key_length)
    end
end

struct BCryptPasswordEncoder <: PasswordEncoder
    cost::Int

    function BCryptPasswordEncoder(; cost::Int=DEFAULT_BCRYPT_COST)
        (cost < 4 || cost > MAX_BCRYPT_COST) && throw(ArgumentError("BCrypt cost must be between 4 and $MAX_BCRYPT_COST"))
        new(cost)
    end
end

struct SpringSecurityPBKDF2PasswordEncoder <: PasswordEncoder
    iterations::Int
    salt_length::Int
    key_length::Int

    function SpringSecurityPBKDF2PasswordEncoder(; iterations::Int=DEFAULT_SPRING_ITERATIONS, salt_length::Int=24, key_length::Int=DEFAULT_PBKDF2_KEY_LENGTH)
        _check_pbkdf2_parameters(iterations, key_length)
        salt_length < 8 && throw(ArgumentError("Salt length must be at least 8"))
        new(iterations, salt_length, key_length)
    end
end

struct DelegatingPasswordEncoder <: PasswordEncoder
    default_encoder::PasswordEncoder
    encoders::Dict{String, PasswordEncoder}

    function DelegatingPasswordEncoder(; default_algorithm::String=DEFAULT_ALGORITHM(), pbkdf2_iterations::Int=DEFAULT_PBKDF2_ITERATIONS, bcrypt_cost::Int=DEFAULT_BCRYPT_COST)
        encoders = Dict{String, PasswordEncoder}(
            "pbkdf2_sha256" => PBKDF2PasswordEncoder(iterations=pbkdf2_iterations),
            "bcrypt" => BCryptPasswordEncoder(cost=bcrypt_cost),
            "spring_sha256" => SpringSecurityPBKDF2PasswordEncoder(),
        )
        default_encoder = get(encoders, lowercase(default_algorithm), encoders["pbkdf2_sha256"])
        new(default_encoder, encoders)
    end
end

# ── Argon2 scaffolding (feature-gated, backend not yet available) ────────────
# These types and stubs define the public contract so extensions can reference
# them today. The real implementation lands when an Argon2 backend is ready.

struct Argon2PasswordEncoder <: PasswordEncoder
    memory_cost::Int      # KiB
    time_cost::Int        # iterations
    parallelism::Int
    hash_length::Int
    salt_length::Int

    function Argon2PasswordEncoder(; memory_cost::Int=65536, time_cost::Int=3, parallelism::Int=4, hash_length::Int=32, salt_length::Int=16)
        memory_cost < 8 && throw(ArgumentError("Argon2 memory_cost must be at least 8 KiB"))
        time_cost < 1 && throw(ArgumentError("Argon2 time_cost must be at least 1"))
        parallelism < 1 && throw(ArgumentError("Argon2 parallelism must be at least 1"))
        hash_length < 4 && throw(ArgumentError("Argon2 hash_length must be at least 4"))
        salt_length < 8 && throw(ArgumentError("Argon2 salt_length must be at least 8"))
        new(memory_cost, time_cost, parallelism, hash_length, salt_length)
    end
end

function encode(::Argon2PasswordEncoder, ::AbstractString)
    throw(ErrorException("Argon2 backend is not yet available. Install and load an Argon2 package to enable this encoder."))
end

function matches(::Argon2PasswordEncoder, ::AbstractString, ::AbstractString)
    throw(ErrorException("Argon2 backend is not yet available. Install and load an Argon2 package to enable this encoder."))
end

function upgrade_encoding(::Argon2PasswordEncoder, ::AbstractString)
    throw(ErrorException("Argon2 backend is not yet available. Install and load an Argon2 package to enable this encoder."))
end

"""
    parse_argon2_phc(encoded::AbstractString) -> NamedTuple or nothing

Parse an Argon2 PHC-format string into its components.
Returns `nothing` if the string is not valid Argon2 PHC format.

Expected format: `\$argon2id\$v=19\$m=<memory>,t=<time>,p=<parallelism>\$<salt_b64>\$<hash_b64>`
"""
function parse_argon2_phc(encoded::AbstractString)
    m = match(r"^\$argon2(id|i|d)\$v=(\d+)\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/=]+)\$([A-Za-z0-9+/=]+)$", encoded)
    m === nothing && return nothing
    return (
        variant = m.captures[1],
        version = parse(Int, m.captures[2]),
        memory_cost = parse(Int, m.captures[3]),
        time_cost = parse(Int, m.captures[4]),
        parallelism = parse(Int, m.captures[5]),
        salt_b64 = m.captures[6],
        hash_b64 = m.captures[7],
    )
end

# ── End Argon2 scaffolding ───────────────────────────────────────────────────

const DEFAULT_COMMON_PASSWORDS = Set([
    "password", "password1", "password123", "123456", "123456789", "12345678",
    "qwerty", "abc123", "monkey", "letmein", "dragon", "111111", "admin", "admin123",
    "root", "guest", "test", "changeme", "qwerty123", "qwertyuiop",
])

const GLOBAL_PASSWORD_ENCODER = Ref{DelegatingPasswordEncoder}(DelegatingPasswordEncoder())

function _generate_salt(length::Int=22)
    raw = secure_random_bytes(length)
    encoded = Base64.base64encode(raw)
    safe = replace(replace(encoded, '+' => '.'), '/' => '_')
    return safe[1:min(length, lastindex(safe))]
end

function _pbkdf2_sha256(password::AbstractString, salt::AbstractString, iterations::Int; key_length::Int=DEFAULT_PBKDF2_KEY_LENGTH)
    return _pbkdf2_hmac_sha256(password, salt, iterations, key_length)
end

function _constant_time_equals(left::AbstractString, right::AbstractString)
    ncodeunits(left) == ncodeunits(right) || return false
    diff = UInt8(0)
    for (lhs, rhs) in zip(codeunits(left), codeunits(right))
        diff |= xor(lhs, rhs)
    end
    return diff == 0
end

function _password_strength(password::AbstractString)
    score = 0
    len = ncodeunits(password)
    if len >= 16
        score += 3
    elseif len >= 12
        score += 2
    elseif len >= 8
        score += 1
    end
    any(isuppercase, password) && (score += 1)
    any(islowercase, password) && (score += 1)
    any(isdigit, password) && (score += 1)
    any(!_isalnum(char) for char in password) && (score += 2)
    (length(unique(password)) / max(len, 1)) > 0.7 && (score += 1)

    if score >= 7
        return :strong
    elseif score >= 5
        return :good
    elseif score >= 3
        return :fair
    end
    return :weak
end

function validate(validator::PasswordValidator, password::AbstractString)
    errors = String[]
    if ncodeunits(password) < validator.min_length
        push!(errors, Printf.format(Printf.Format(validator.messages[:min_length]), validator.min_length))
    end
    if ncodeunits(password) > validator.max_length
        push!(errors, Printf.format(Printf.Format(validator.messages[:max_length]), validator.max_length))
    end
    if validator.require_uppercase && !any(isuppercase, password)
        push!(errors, validator.messages[:require_uppercase])
    end
    if validator.require_lowercase && !any(islowercase, password)
        push!(errors, validator.messages[:require_lowercase])
    end
    if validator.require_digit && !any(isdigit, password)
        push!(errors, validator.messages[:require_digit])
    end
    if validator.require_special && !any(!_isalnum(char) for char in password)
        push!(errors, validator.messages[:require_special])
    end
    if lowercase(password) in validator.common_passwords
        push!(errors, validator.messages[:common_password])
    end
    return ValidationResult(isempty(errors), errors, _password_strength(password))
end

function encode(encoder::PBKDF2PasswordEncoder, password::AbstractString)
    _require_hashable(password)
    salt = _generate_salt(encoder.salt_length)
    hash = Base64.base64encode(_pbkdf2_sha256(password, salt, encoder.iterations; key_length=encoder.key_length))
    return string("pbkdf2_sha256\$", encoder.iterations, "\$", salt, "\$", hash)
end

function matches(encoder::PBKDF2PasswordEncoder, password::AbstractString, encoded_hash::AbstractString)
    encoded = String(strip(String(encoded_hash)))
    isempty(encoded) && return false
    _hashable(password) || return false
    startswith(encoded, "pbkdf2_sha256\$") || return false
    parts = split(encoded, '\$')
    length(parts) == 4 || return false
    iterations = tryparse(Int, parts[2])
    isnothing(iterations) && return false
    _pbkdf2_work_ok(iterations, encoder.key_length) || return _refuse_stored_parameters()
    computed = Base64.base64encode(_pbkdf2_sha256(password, parts[3], iterations; key_length=encoder.key_length))
    return _constant_time_equals(computed, parts[4])
end

function upgrade_encoding(encoder::PBKDF2PasswordEncoder, encoded_hash::AbstractString)
    encoded = String(strip(String(encoded_hash)))
    startswith(encoded, "pbkdf2_sha256\$") || return true
    parts = split(encoded, '\$')
    length(parts) == 4 || return true
    iterations = tryparse(Int, parts[2])
    isnothing(iterations) && return true
    return iterations < encoder.iterations
end

_is_bcrypt_hash(encoded::AbstractString) =
    startswith(encoded, "\$2a\$") || startswith(encoded, "\$2b\$") || startswith(encoded, "\$2y\$")

# Every bcrypt verification goes through here -- `matches` and both of `check_password`'s
# `bcrypt$` / `{bcrypt}` prefix forms -- so this is where the cost bound lives. The cost is
# read from the stored hash, and each step doubles the work: 31, which Bcrypt.jl accepts,
# is about 2^19 times the default.
function _check_bcrypt(password::AbstractString, encoded_hash::AbstractString)
    hash = String(strip(String(encoded_hash)))
    isempty(hash) && return false
    _hashable(password) || return false
    _is_bcrypt_hash(hash) || return false
    cost = try
        Bcrypt.Cost(Vector{UInt8}(codeunits(hash)))
    catch
        return false
    end
    cost <= MAX_BCRYPT_COST || return _refuse_stored_parameters()
    return Bcrypt.CompareHashAndPassword(hash, String(password))
end

function encode(encoder::BCryptPasswordEncoder, password::AbstractString)
    _require_hashable(password)
    if sizeof(password) > 72
        @warn "Password exceeds 72 bytes, will be truncated by BCrypt" maxlog=1
    end
    return String(Bcrypt.GenerateFromPassword(password, encoder.cost))
end

function matches(::BCryptPasswordEncoder, password::AbstractString, encoded_hash::AbstractString)
    return _check_bcrypt(password, encoded_hash)
end

function upgrade_encoding(encoder::BCryptPasswordEncoder, encoded_hash::AbstractString)
    encoded = String(strip(String(encoded_hash)))
    if !startswith(encoded, "\$2a\$") && !startswith(encoded, "\$2b\$") && !startswith(encoded, "\$2y\$")
        return true
    end
    try
        current_cost = Bcrypt.Cost(Vector{UInt8}(codeunits(encoded)))
        return current_cost < encoder.cost
    catch
        return true
    end
end

function encode(encoder::SpringSecurityPBKDF2PasswordEncoder, password::AbstractString)
    _require_hashable(password)
    salt_bytes = secure_random_bytes(encoder.salt_length)
    salt_b64 = Base64.base64encode(salt_bytes)
    derived = _pbkdf2_sha256(password, String(salt_b64), encoder.iterations; key_length=encoder.key_length)
    hash_b64 = Base64.base64encode(derived)
    return string("sha256:", encoder.iterations, ":", encoder.key_length, ":", salt_b64, ":", hash_b64)
end

function matches(::SpringSecurityPBKDF2PasswordEncoder, password::AbstractString, encoded_hash::AbstractString)
    encoded = String(strip(String(encoded_hash)))
    isempty(encoded) && return false
    _hashable(password) || return false
    parts = split(encoded, ':')
    length(parts) == 5 || return false
    parts[1] == "sha256" || return false
    iterations = tryparse(Int, parts[2])
    key_length = tryparse(Int, parts[3])
    (isnothing(iterations) || isnothing(key_length)) && return false
    # This format carries its own key length, so bound it as well as the iterations: 0 used
    # to derive an empty key that matched ANY password (`sha256:1:0:AAAA:`), a short one lets
    # random passwords collide, and a long one multiplies the work per iteration.
    _pbkdf2_work_ok(iterations, key_length) || return _refuse_stored_parameters()
    salt_bytes, stored = try
        Base64.base64decode(parts[4]), Base64.base64decode(parts[5])
    catch
        return false
    end
    length(stored) == key_length || return false
    derived = _pbkdf2_sha256(password, String(Base64.base64encode(salt_bytes)), iterations; key_length=key_length)
    return _constant_time_equals(Base64.base64encode(derived), parts[5])
end

function upgrade_encoding(encoder::SpringSecurityPBKDF2PasswordEncoder, encoded_hash::AbstractString)
    parts = split(String(strip(String(encoded_hash))), ':')
    length(parts) == 5 || return true
    parts[1] == "sha256" || return true
    iterations = tryparse(Int, parts[2])
    isnothing(iterations) && return true
    return iterations < encoder.iterations
end

function encode(encoder::DelegatingPasswordEncoder, password::AbstractString)
    return encode(encoder.default_encoder, password)
end

function matches(encoder::DelegatingPasswordEncoder, password::AbstractString, encoded_hash::AbstractString)
    encoded = String(strip(String(encoded_hash)))
    isempty(encoded) && return false
    if startswith(encoded, "pbkdf2_sha256\$")
        return matches(get(encoder.encoders, "pbkdf2_sha256", encoder.default_encoder), password, encoded)
    elseif startswith(encoded, "sha256:")
        return matches(get(encoder.encoders, "spring_sha256", SpringSecurityPBKDF2PasswordEncoder()), password, encoded)
    elseif startswith(encoded, "\$2a\$") || startswith(encoded, "\$2b\$") || startswith(encoded, "\$2y\$")
        return matches(get(encoder.encoders, "bcrypt", BCryptPasswordEncoder()), password, encoded)
    end
    # Security: never fall back to comparing the supplied password against the
    # stored value as plaintext. An unknown/corrupted hash format must fail to
    # match rather than risk authenticating a plaintext-stored credential.
    @warn "Unknown or unsupported password hash format; refusing to match. Re-hash with a supported encoder." maxlog=1
    return false
end

function upgrade_encoding(encoder::DelegatingPasswordEncoder, encoded_hash::AbstractString)
    encoded = String(strip(String(encoded_hash)))
    if startswith(encoded, "pbkdf2_sha256\$")
        return upgrade_encoding(get(encoder.encoders, "pbkdf2_sha256", encoder.default_encoder), encoded)
    elseif startswith(encoded, "sha256:")
        return upgrade_encoding(get(encoder.encoders, "spring_sha256", SpringSecurityPBKDF2PasswordEncoder()), encoded)
    elseif startswith(encoded, "\$2a\$") || startswith(encoded, "\$2b\$") || startswith(encoded, "\$2y\$")
        return upgrade_encoding(get(encoder.encoders, "bcrypt", BCryptPasswordEncoder()), encoded)
    end
    return true
end

function is_password_usable(encoded::AbstractString)
    encoded = strip(encoded)
    isempty(encoded) && return false
    startswith(encoded, "pbkdf2_sha256\$") && return true
    startswith(encoded, "sha256:") && return true
    startswith(encoded, "\$2a\$") && return true
    startswith(encoded, "\$2b\$") && return true
    startswith(encoded, "\$2y\$") && return true
    startswith(encoded, "\$argon2") && return true
    return false
end

"""
    make_password(password; algorithm = DEFAULT_ALGORITHM(), iterations = 720_000, bcrypt_cost = 12) -> String

Hash `password` for storage, in the wire format of `algorithm` — `"pbkdf2_sha256"` (Django),
`"bcrypt"`, or `"spring_sha256"`. Verify it later with [`check_password`](@ref).

Throws `ArgumentError` for an empty password, for one longer than `MAX_PASSWORD_BYTES` (4096)
bytes, for a cost above what verification accepts (`iterations` up to 10 000 000 at the default
32-byte key, `bcrypt_cost` 4–15), and for an unknown algorithm. The byte limit applies to raw client input, so cap or
validate the field before calling this: a signup handler that lets the `ArgumentError` escape
answers `500`.
"""
function make_password(password::AbstractString; algorithm::String=DEFAULT_ALGORITHM(), iterations::Int=DEFAULT_PBKDF2_ITERATIONS, bcrypt_cost::Int=DEFAULT_BCRYPT_COST)
    _require_hashable(password)
    algorithm = lowercase(algorithm)

    if algorithm == "pbkdf2_sha256"
        return encode(PBKDF2PasswordEncoder(iterations=iterations), password)
    elseif algorithm == "bcrypt"
        return encode(BCryptPasswordEncoder(cost=bcrypt_cost), password)
    elseif algorithm == "spring_sha256"
        spring_iters = iterations == DEFAULT_PBKDF2_ITERATIONS ? DEFAULT_SPRING_ITERATIONS : iterations
        return encode(SpringSecurityPBKDF2PasswordEncoder(iterations=spring_iters), password)
    end

    throw(ArgumentError("Unsupported password algorithm: $algorithm"))
end

# The formats `DelegatingPasswordEncoder` can actually verify. Narrower than
# `is_password_usable`, which also says `true` for `$argon2`, a format nothing here verifies.
function _verifiable_format(encoded_hash::AbstractString)
    encoded = strip(encoded_hash)
    return startswith(encoded, "pbkdf2_sha256\$") || startswith(encoded, "sha256:") || _is_bcrypt_hash(encoded)
end

# Django's timing equalizer (`hashers.verify_password`; its #20760 and CVE-2024-39329): with
# no hash to verify against, hash once at the default cost anyway, so the time taken does
# not tell an unknown account from a known one with the wrong password.
const _DUMMY_PASSWORD = "nitro-timing-equalizer"

function _equalize_timing()
    make_password(_DUMMY_PASSWORD)
    return nothing
end

"""
    check_password(password, encoded_hash) -> Bool
    check_password(password, nothing) -> false

Verify `password` against a stored hash produced by [`make_password`](@ref), or imported from
Django (`pbkdf2_sha256\$…`), Spring Security (`sha256:…`), or any bcrypt library (`\$2a\$…`,
also as `bcrypt\$…` or `{bcrypt}…`).

**Pass `nothing` when there is no stored hash — an unknown user — rather than returning early.**
It then hashes once at the default algorithm's cost before answering `false`, and so does a
stored value that no encoder can verify (an unusable or unknown-format hash). A login handler
written that way takes the same time whether or not the account exists, so it is not a
username-enumeration oracle:

```julia
user = find_user(username)                   # `nothing` for an unknown username
if !check_password(password, isnothing(user) ? nothing : user.password_hash)
    return Res.json(Dict("error" => "invalid credentials"); status = 401)
end
```

The equalizer costs what the *current default* costs (`DEFAULT_ALGORITHM()` and its default
cost). While stored hashes still use an older algorithm or cost, the two paths still differ by
the gap between the two costs.

An empty password, or one longer than `MAX_PASSWORD_BYTES` (4096) bytes, is `false` before any
hashing, whatever the stored hash — so that answer reveals nothing about the account. A stored
hash whose cost parameters are out of bounds (PBKDF2 iterations × 32-byte key blocks above
10 000 000, a Spring key length outside 16–64 bytes, a bcrypt cost above 15) is refused without
hashing and logged, without the hash. So is a malformed hash in a known format, though silently.
Either way that account cannot log in until it is re-hashed, and its fast `false` is the one
answer that still tells it apart from an unknown user.
"""
function check_password(password::AbstractString, encoded_hash::AbstractString)
    _hashable(password) || return false
    encoded = String(encoded_hash)
    if startswith(encoded, "bcrypt\$") || startswith(encoded, "{bcrypt}")
        inner = if startswith(encoded, "bcrypt\$")
            String(split(encoded, '\$', limit=2)[2])
        else
            replace(encoded, "{bcrypt}" => "")
        end
        _is_bcrypt_hash(strip(inner)) || _equalize_timing()
        return _check_bcrypt(password, inner)
    end
    if !_verifiable_format(encoded)
        _equalize_timing()
        # Django's unusable-password marker is a legitimate state, not corruption: answer it
        # without spending `matches`'s once-only unknown-format warning.
        startswith(encoded, "!") && return false
    end
    return matches(GLOBAL_PASSWORD_ENCODER[], password, encoded)
end

function check_password(password::AbstractString, ::Nothing)
    _hashable(password) && _equalize_timing()
    return false
end

function validate_password(password::AbstractString;
    min_length::Int=8,
    max_length::Int=128,
    require_uppercase::Bool=true,
    require_lowercase::Bool=true,
    require_digit::Bool=true,
    require_special::Bool=false,
    messages::Union{Dict{Symbol, String}, Nothing}=nothing)
    validator = PasswordValidator(
        min_length=min_length,
        max_length=max_length,
        require_uppercase=require_uppercase,
        require_lowercase=require_lowercase,
        require_digit=require_digit,
        require_special=require_special,
        messages=messages,
    )
    return validate(validator, password)
end

function password_needs_upgrade(encoded_hash::AbstractString; min_iterations::Int=DEFAULT_PBKDF2_ITERATIONS)
    return upgrade_encoding(DelegatingPasswordEncoder(pbkdf2_iterations=min_iterations), encoded_hash)
end