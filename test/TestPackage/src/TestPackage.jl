module TestPackage

using Base: @kwdef

push!(LOAD_PATH, "../../")
using Nitro; @oxidize

export start, stop

@kwdef struct Add
    a::Int
    b::Int = 3
end

route(["GET"], "/", function()
    text("hello world")
end)

route(["GET"], "/add", function(req::Request, a::Int, b::Int=3)
    a + b
end)

route(["GET"], "/add/extractor", function(req::Request, qparams::Query{Add})
    add = qparams.payload
    add.a + add.b
end)

start(;kwargs...) = serve(;kwargs...)
stop() = terminate()

end