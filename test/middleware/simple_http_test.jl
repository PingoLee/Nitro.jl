@testitem "Simple HTTP test" setup=[NitroCommon] begin
    using HTTP
    @test HTTP.Request("GET", "/") isa HTTP.Request
end
