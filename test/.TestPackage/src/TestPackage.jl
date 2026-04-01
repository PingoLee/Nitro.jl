module TestPackage

using Base: @kwdef

push!(LOAD_PATH, "../../")
using Nitro

export start, stop

@kwdef struct Add
    a::Int
    b::Int = 3
end

function __init__()
    urlpatterns("",
        path("/", function() text("hello world") end, method="GET"),
        path("/add", function(req::Request, a::Int, b::Int=3) a + b end, method="GET"),
        path("/add/extractor", function(req::Request, qparams::Query{Add})
            add = qparams.payload
            add.a + add.b
        end, method="GET"),
    )
end

start(;kwargs...) = serve(;kwargs...)
stop() = terminate()

end