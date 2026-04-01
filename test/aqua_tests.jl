@testitem "Aqua quality checks" tags=[:aqua] begin
    using Aqua
    using Nitro
    Aqua.test_all(Nitro; ambiguities=false)
end
