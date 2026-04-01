using Nitro

println("=== Generating cross-compatibility fixtures for testpassword123 ===")
println()

# PBKDF2 Django-format hash with 720000 iterations
pbkdf2_hash = Nitro.Auth.make_password("testpassword123"; algorithm="pbkdf2_sha256")
println("Django PBKDF2 fixture:")
println(repr(pbkdf2_hash))
println("Verify: ", Nitro.Auth.check_password("testpassword123", pbkdf2_hash))
println("Wrong:  ", Nitro.Auth.check_password("wrongpassword", pbkdf2_hash))
println()

# Spring Security-format hash with 310000 iterations
spring_hash = Nitro.Auth.make_password("testpassword123"; algorithm="spring_sha256")
println("Spring PBKDF2 fixture:")
println(repr(spring_hash))
println("Verify: ", Nitro.Auth.check_password("testpassword123", spring_hash))
println("Wrong:  ", Nitro.Auth.check_password("wrongpassword", spring_hash))
println()

# Verify iterations in the Spring hash
parts = split(spring_hash, ':')
println("Spring iterations in hash: ", parts[2])
