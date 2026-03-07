module CairoMakieTests
using HTTP
using Test
using CairoMakie: heatmap
using Nitro; @oxidize
import Nitro: text
using ..Constants

@testset "CairoMakie Utils" begin 
    # create a random heatmap
    fig, ax, pl = heatmap(rand(50, 50))

    response = png(fig)
    @test response isa HTTP.Response
    @test response.status == 200
    @test HTTP.header(response, "Content-Type") == "image/png"
    @test parse(Int, HTTP.header(response, "Content-Length")) >= 0

    response = svg(fig)
    @test response isa HTTP.Response
    @test response.status == 200
    @test HTTP.header(response, "Content-Type") == "image/svg+xml"
    @test parse(Int, HTTP.header(response, "Content-Length")) >= 0

    response = pdf(fig)
    @test response isa HTTP.Response
    @test response.status == 200
    @test HTTP.header(response, "Content-Type") == "application/pdf"
    @test parse(Int, HTTP.header(response, "Content-Length")) >= 0

    response = html(fig)
    @test response isa HTTP.Response
    @test response.status == 200
    @test HTTP.header(response, "Content-Type") == "text/html"
    @test parse(Int, HTTP.header(response, "Content-Length")) >= 0
end

@testset "CairoMakie server" begin

    route(["GET"], "/", function()
        text("hello world")
    end)

    route(["GET"], "/html", function()
        html("hello world")
    end)

    # generate a random plot
    route(["GET"], "/plot/png", function()
        fig, ax, pl = heatmap(rand(50, 50)) # or something
        png(fig)
    end)

    route(["GET"], "/plot/svg", function()
        fig, ax, pl = heatmap(rand(50, 50)) # or something
        svg(fig)
    end)

    route(["GET"], "/plot/pdf", function()
        fig, ax, pl = heatmap(rand(50, 50)) # or something
        pdf(fig)
    end)

    route(["GET"], "/plot/html", function()
        fig, ax, pl = heatmap(rand(50, 50)) # or something
        html(fig)
    end)

    serve(host=HOST, port=PORT, async=true, show_banner=false, access_log=nothing)

    # Test overloaded text() function
    r = HTTP.get("$localhost/")
    @test r.status == 200
    @test HTTP.header(r, "Content-Type") == "text/plain; charset=utf-8"
    @test parse(Int, HTTP.header(r, "Content-Length")) >= 0

    # Test overloaded html function
    r = HTTP.get("$localhost/html")
    @test r.status == 200
    @test HTTP.header(r, "Content-Type") == "text/html; charset=utf-8"
    @test parse(Int, HTTP.header(r, "Content-Length")) >= 0

    # Test for /plot/png endpoint
    r = HTTP.get("$localhost/plot/png")
    @test r.status == 200
    @test HTTP.header(r, "Content-Type") == "image/png"
    @test parse(Int, HTTP.header(r, "Content-Length")) >= 0

    # Test for /plot/svg endpoint
    r = HTTP.get("$localhost/plot/svg")
    @test r.status == 200
    @test HTTP.header(r, "Content-Type") == "image/svg+xml"
    @test parse(Int, HTTP.header(r, "Content-Length")) >= 0

    # Test for /plot/pdf endpoint
    r = HTTP.get("$localhost/plot/pdf")
    @test r.status == 200
    @test HTTP.header(r, "Content-Type") == "application/pdf"
    @test parse(Int, HTTP.header(r, "Content-Length")) >= 0

    # Test for /plot/html endpoint
    r = HTTP.get("$localhost/plot/html")
    @test r.status == 200
    @test HTTP.header(r, "Content-Type") == "text/html"
    @test parse(Int, HTTP.header(r, "Content-Length")) >= 0
    terminate()
end

end