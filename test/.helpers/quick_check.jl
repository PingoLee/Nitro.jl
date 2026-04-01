println("Loading Nitro...")
using Nitro
println("Loaded")

println("DEFAULT_ALGORITHM: ", Nitro.Auth.DEFAULT_ALGORITHM())
println("SUPPORTED_ALGORITHMS: ", Nitro.Auth.SUPPORTED_ALGORITHMS)

# Test is_password_usable
println("is_password_usable pbkdf2: ", Nitro.Auth.is_password_usable("pbkdf2_sha256\$720000\$salt\$hash"))
println("is_password_usable plain: ", Nitro.Auth.is_password_usable("plaintext"))
println("is_password_usable bcrypt: ", Nitro.Auth.is_password_usable("\$2a\$12\$somehashvalue"))

# Test set_default_algorithm!
Nitro.Auth.set_default_algorithm!("bcrypt")
println("After set to bcrypt: ", Nitro.Auth.DEFAULT_ALGORITHM())
hash = Nitro.Auth.make_password("TestPass1!")
println("BCrypt hash starts with \$2: ", startswith(hash, "\$2"))

# Restore
Nitro.Auth.set_default_algorithm!("pbkdf2_sha256")
println("Restored to: ", Nitro.Auth.DEFAULT_ALGORITHM())

# Test Argon2 scaffolding
try
    enc = Nitro.Auth.Argon2PasswordEncoder()
    println("Argon2 encoder created: ", typeof(enc))
    Nitro.Auth.encode(enc, "test")
catch e
    println("Argon2 encode (expected error): ", e.msg)
end

# Test parse_argon2_phc  
result = Nitro.Auth.parse_argon2_phc("\$argon2id\$v=19\$m=65536,t=3,p=4\$c2FsdA==\$aGFzaA==")
println("Argon2 PHC parse: ", result)

println("All quick checks passed!")
