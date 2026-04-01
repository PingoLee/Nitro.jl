@testitem "Parallel" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Suppressor
using Nitro

@testset "parallel tests" begin

    invocation = []

    function handler1(handler)
        return function(req::HTTP.Request)
            push!(invocation, 1)
            handler(req)
        end
    end

    function handler2(handler)
        return function(req::HTTP.Request)
            push!(invocation, 2)
            handler(req)
        end
    end

    function handler3(handler)
        return function(req::HTTP.Request)
            push!(invocation, 3)
            handler(req)
        end
    end

    urlpatterns("",
        path("/get", function() return "Hello World" end, method="GET"),
        path("/post", function(req::Request) return text(req) end, method="POST"),
        path("/customerror", function()
            function processtring(input::String)
                "<$input>"
            end
            processtring(3)
        end, method="GET"),
    )

    if Threads.nthreads() <= 1
        # the service should work even when we only have a single thread available (not ideal)
        @async serve(port=PORT, show_errors=false, show_banner=false, queuesize=100)
        sleep(1)  # give the server time to start before making requests
        r = HTTP.get("$localhost/get")
        @test r.status == 200

        # clean up the server on tests without additional threads
        terminate()
    end

    # only run these tests if we have more than one thread to work with
    if Threads.nthreads() > 1

        serve(host=HOST, port=PORT, show_errors=true, async=true, show_banner=true)
        sleep(3)

        r = HTTP.get("$localhost/get")
        @test r.status == 200

        r = HTTP.post("$localhost/post", body="some demo content")
        @test text(r) == "some demo content"

        try
            @suppress_err r = HTTP.get("$localhost/customerror", connect_timeout=3)
        catch e 
            @test e isa MethodError || e isa HTTP.ExceptionRequest.StatusError
        end
        
        terminate()

        serve(host=HOST, port=PORT, middleware=[handler1, handler2, handler3], show_errors=true, async=true, show_banner=false)
        sleep(1)

        r = HTTP.get("$localhost/get")
        @test r.status == 200

        terminate()
    end

end
end