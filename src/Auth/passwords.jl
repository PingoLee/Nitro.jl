using Bcrypt
using Printf

const DEFAULT_PBKDF2_ITERATIONS = 720000
const DEFAULT_PBKDF2_KEY_LENGTH = 32
const DEFAULT_BCRYPT_COST = 12
const DEFAULT_SPRING_ITERATIONS = 310000

const SUPPORTED_ALGORITHMS = ["pbkdf2_sha256", "bcrypt", "spring_sha256"]
# Future: push!(SUPPORTED_ALGORITHMS, "argon2") when backend is ready

const _DEFAULT_ALGORITHM = Ref{String}("pbkdf2_sha256")

_isalnum(char::Char) = isletter(char) || isdigit(char)

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
        iterations < 1 && throw(ArgumentError("Iterations must be positive"))
        salt_length < 8 && throw(ArgumentError("Salt length must be at least 8"))
        key_length < 16 && throw(ArgumentError("Key length must be at least 16"))
        new(iterations, salt_length, key_length)
    end
end

struct BCryptPasswordEncoder <: PasswordEncoder
    cost::Int

    function BCryptPasswordEncoder(; cost::Int=DEFAULT_BCRYPT_COST)
        (cost < 4 || cost > 31) && throw(ArgumentError("BCrypt cost must be between 4 and 31"))
        new(cost)
    end
end

struct SpringSecurityPBKDF2PasswordEncoder <: PasswordEncoder
    iterations::Int
    salt_length::Int
    key_length::Int

    function SpringSecurityPBKDF2PasswordEncoder(; iterations::Int=DEFAULT_SPRING_ITERATIONS, salt_length::Int=24, key_length::Int=DEFAULT_PBKDF2_KEY_LENGTH)
        iterations < 1 && throw(ArgumentError("Iterations must be positive"))
        salt_length < 8 && throw(ArgumentError("Salt length must be at least 8"))
        key_length < 16 && throw(ArgumentError("Key length must be at least 16"))
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
    raw = rand(UInt8, length)
    encoded = Base64.base64encode(raw)
    safe = replace(replace(encoded, '+' => '.'), '/' => '_')
    return safe[1:min(length, lastindex(safe))]
end

function _pbkdf2_block(password::Vector{UInt8}, salt::Vector{UInt8}, iterations::Int, index::Int)
    counter = UInt8[
        UInt8((index >> 24) & 0xff),
        UInt8((index >> 16) & 0xff),
        UInt8((index >> 8) & 0xff),
        UInt8(index & 0xff),
    ]
    u = SHA.hmac_sha256(password, vcat(salt, counter))
    result = copy(u)
    for _ in 2:iterations
        u = SHA.hmac_sha256(password, u)
        for position in eachindex(result)
            result[position] = xor(result[position], u[position])
        end
    end
    return result
end

function _pbkdf2_sha256(password::AbstractString, salt::AbstractString, iterations::Int; key_length::Int=DEFAULT_PBKDF2_KEY_LENGTH)
    password_bytes = Vector{UInt8}(codeunits(password))
    salt_bytes = Vector{UInt8}(codeunits(salt))
    block_size = 32
    block_count = cld(key_length, block_size)
    derived = UInt8[]
    for index in 1:block_count
        append!(derived, _pbkdf2_block(password_bytes, salt_bytes, iterations, index))
    end
    return derived[1:key_length]
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
    isempty(password) && throw(ArgumentError("Password cannot be empty"))
    salt = _generate_salt(encoder.salt_length)
    hash = Base64.base64encode(_pbkdf2_sha256(password, salt, encoder.iterations; key_length=encoder.key_length))
    return string("pbkdf2_sha256\$", encoder.iterations, "\$", salt, "\$", hash)
end

function matches(encoder::PBKDF2PasswordEncoder, password::AbstractString, encoded_hash::AbstractString)
    encoded = String(strip(String(encoded_hash)))
    isempty(encoded) && return false
    isempty(password) && return false
    startswith(encoded, "pbkdf2_sha256\$") || return false
    parts = split(encoded, '\$')
    length(parts) == 4 || return false
    iterations = tryparse(Int, parts[2])
    isnothing(iterations) && return false
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

function _check_bcrypt(password::AbstractString, encoded_hash::AbstractString)
    hash = String(strip(String(encoded_hash)))
    isempty(hash) && return false
    if !startswith(hash, "\$2a\$") && !startswith(hash, "\$2b\$") && !startswith(hash, "\$2y\$")
        return false
    end
    return Bcrypt.CompareHashAndPassword(hash, String(password))
end

function encode(encoder::BCryptPasswordEncoder, password::AbstractString)
    isempty(password) && throw(ArgumentError("Password cannot be empty"))
    if sizeof(password) > 72
        @warn "Password exceeds 72 bytes, will be truncated by BCrypt" maxlog=1
    end
    return String(Bcrypt.GenerateFromPassword(password, encoder.cost))
end

function matches(::BCryptPasswordEncoder, password::AbstractString, encoded_hash::AbstractString)
    isempty(password) && return false
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
    isempty(password) && throw(ArgumentError("Password cannot be empty"))
    salt_bytes = rand(UInt8, encoder.salt_length)
    salt_b64 = Base64.base64encode(salt_bytes)
    derived = _pbkdf2_sha256(password, String(salt_b64), encoder.iterations; key_length=encoder.key_length)
    hash_b64 = Base64.base64encode(derived)
    return string("sha256:", encoder.iterations, ":", encoder.key_length, ":", salt_b64, ":", hash_b64)
end

function matches(::SpringSecurityPBKDF2PasswordEncoder, password::AbstractString, encoded_hash::AbstractString)
    encoded = String(strip(String(encoded_hash)))
    isempty(encoded) && return false
    isempty(password) && return false
    parts = split(encoded, ':')
    length(parts) == 5 || return false
    parts[1] == "sha256" || return false
    iterations = tryparse(Int, parts[2])
    key_length = tryparse(Int, parts[3])
    (isnothing(iterations) || isnothing(key_length)) && return false
    salt_bytes = try
        Base64.base64decode(parts[4])
    catch
        return false
    end
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
    @warn "Unknown hash format. Password may be stored in plain text." maxlog=1
    return _constant_time_equals(password, encoded)
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

function make_password(password::AbstractString; algorithm::String=DEFAULT_ALGORITHM(), iterations::Int=DEFAULT_PBKDF2_ITERATIONS, bcrypt_cost::Int=DEFAULT_BCRYPT_COST)
    isempty(password) && throw(ArgumentError("Password cannot be empty"))
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

function _check_pbkdf2(password::AbstractString, encoded_hash::AbstractString)
    parts = split(encoded_hash, '$')
    length(parts) == 4 || return false
    iterations = tryparse(Int, parts[2])
    isnothing(iterations) && return false
    computed = Base64.base64encode(_pbkdf2_sha256(password, parts[3], iterations))
    return _constant_time_equals(computed, parts[4])
end

function _check_spring(password::AbstractString, encoded_hash::AbstractString)
    parts = split(encoded_hash, ':')
    length(parts) == 5 || return false
    iterations = tryparse(Int, parts[2])
    key_length = tryparse(Int, parts[3])
    if isnothing(iterations) || isnothing(key_length)
        return false
    end
    salt_b64 = parts[4]
    computed = Base64.base64encode(_pbkdf2_sha256(password, salt_b64, iterations; key_length=key_length))
    return _constant_time_equals(computed, parts[5])
end

function check_password(password::AbstractString, encoded_hash::AbstractString)
    encoded = String(encoded_hash)
    if startswith(encoded, "bcrypt\$") || startswith(encoded, "{bcrypt}")
        if startswith(encoded, "bcrypt\$")
            return _check_bcrypt(password, String(split(encoded, '\$', limit=2)[2]))
        end
        return _check_bcrypt(password, replace(encoded, "{bcrypt}" => ""))
    end
    return matches(GLOBAL_PASSWORD_ENCODER[], password, encoded)
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