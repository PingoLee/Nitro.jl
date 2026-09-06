@testitem "Parallel" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using Suppressor
using Nitro

port = get_free_port()
localhost = "http://$HOST:$port"

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
        @async serve(port=port, show_errors=false, show_banner=false, queuesize=100)
        sleep(1)  # give the server time to start before making requests
        r = HTTP.get("$localhost/get")
        @test r.status == 200

        # clean up the server on tests without additional threads
        terminate()
    end

    # only run these tests if we have more than one thread to work with
    if Threads.nthreads() > 1

        serve(host=HOST, port=port, show_errors=true, async=true, show_banner=true)
        sleep(3)

        r = HTTP.get("$localhost/get")
        @test r.status == 200

        r = HTTP.post("$localhost/post", body="some demo content")
        @test text(r) == "some demo content"

        # Error-path guard for the parallel handler (#39). To be clear about what this
        # does and does not prove: it does NOT discriminate the #39 change — the nested
        # `@async` + second `wait` that was removed rethrew just as the single `wait`
        # does, so this passes on both shapes. It is here because #39 rewrote the only
        # path a live request takes, and "a throwing handler still becomes a 500 rather
        # than hanging or dropping the connection" is the invariant that rewrite could
        # plausibly have broken. `status_exception=false` makes it an assertion about
        # the response rather than about which exception the client chose to raise.
        @suppress_err begin
            r = HTTP.get("$localhost/customerror", connect_timeout=3, retry=false,
                         status_exception=false)
            @test r.status == 500
        end
        
        terminate()

        serve(host=HOST, port=port, middleware=[handler1, handler2, handler3], show_errors=true, async=true, show_banner=false)
        sleep(1)

        r = HTTP.get("$localhost/get")
        @test r.status == 200

        terminate()
    end

end
end