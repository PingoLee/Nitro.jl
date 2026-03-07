module PathPrefixUrlTests

using Test
using HTTP
using ..Constants
using Nitro; @oxidise

route(["GET"], "/test", function()
    return "Hello World"
end)

serve(prefix="/custom-api", port=PORT, host=HOST, async=true,  show_errors=false, show_banner=false)

@testset "Valid Prefixed requests" begin 
    r = internalrequest(HTTP.Request("GET", "/custom-api/test"))
    @test r.status == 200
    @test text(r) == "Hello World"

end


# 404 related tests (direct hits which shouldn't work)
@testset "Invalid Non-Prefixed requests" begin 

    r = internalrequest(HTTP.Request("GET", "/test"))
    @test r.status == 404

end

terminate()

end