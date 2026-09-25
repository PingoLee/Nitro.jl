@testitem "Templating extension" tags=[:extension] setup=[NitroCommon] begin
using HTTP
using MIMEs
using Mustache
using OteraEngine
import Nitro: mustache, otera

const TEST_CONTENT_DIR = normpath(joinpath(@__DIR__, "..", "content"))
content_path(parts...) = joinpath(TEST_CONTENT_DIR, parts...)

function clean_output(result::String)
    # Replace carriage returns followed by line feeds (\r\n) with a single newline (\n)
    tmp = replace(result, "\r\n" => "\n")

    # Replace sequences of newline followed by spaces (\n\s*) with a single newline (\n)
    tmp = replace(tmp, r"\n\s*\n" => "\n")

    return tmp
end


function remove_trailing_newline(s::String)::String
    if !isempty(s) && last(s) == '\n'
        return s[1:end-1]
    end
    return s
end


data = Dict(
    "name" => "Chris",
    "value" => 10000,
    "taxed_value" => 10000 - (10000 * 0.4),
    "in_ca" => true
)

mustache_template = mt"""
Hello {{name}}
You have just won {{value}} dollars!
{{#in_ca}}
Well, {{taxed_value}} dollars, after taxes.
{{/in_ca}}
"""

mustache_template_str = """
Hello {{name}}
You have just won {{value}} dollars!
{{#in_ca}}
Well, {{taxed_value}} dollars, after taxes.
{{/in_ca}}
"""

expected_output = """
Hello Chris
You have just won 10000 dollars!
Well, 6000.0 dollars, after taxes.
"""

@testset "Templating Module Tests" begin

    @testset "mustache() from string no args " begin 
        plain_temp = "Hello World!"
        render = mustache(plain_temp, mime_type="text/plain")
        response = render()
        @test response.body |> String |> clean_output == plain_temp
    end

    @testset "mustache() from string tests " begin 
        render = mustache(mustache_template_str, mime_type="text/plain")
        response = render(data)
        @test response.body |> String |> clean_output == expected_output
    end

    @testset "mustache() from string tests w/ content type" begin 
        render = mustache(mustache_template_str)
        response = render(data)
        @test response.body |> String |> clean_output == expected_output
    end



    @testset "mustache() from file no content type" begin 
        render = mustache(content_path("mustache_template.txt"), from_file=true)
        response = render(data)
        @test response.body |> String |> clean_output == expected_output
    end

    @testset "mustache() from file w/ content type" begin 
        render = mustache(content_path("mustache_template.txt"), mime_type="text/plain", from_file=true)
        response = render(data)
        @test response.body |> String |> clean_output == expected_output
    end

    @testset "mustache() from file with no content type" begin 
        render = open(mustache, content_path("mustache_template.txt"))
        response = render(data)
        @test response.body |> String |> clean_output == expected_output
    end

    @testset "mustache() from file with content type" begin 
        render = open(io -> mustache(io; mime_type="text/plain"), content_path("mustache_template.txt"))
        response = render(data)
        @test response.body |> String |> clean_output == expected_output
    end



    @testset "mustache() from template" begin 
        render = mustache(mustache_template)
        response = render(data)
        @test response.body |> String |> clean_output == expected_output
    end

    @testset "mustache() from template with content type" begin 
        render = mustache(mustache_template, mime_type="text/plain")
        response = render(data)
        @test response.body |> String |> clean_output == expected_output
    end


    @testset "mustache api tests" begin 

        mus_str = mustache(mustache_template_str)
        mus_tpl = mustache(mustache_template)
        mus_file = mustache(content_path("mustache_template.txt"), from_file=true)
        
        urlpatterns("",
            path("/mustache/string",   function() return mus_str(data) end, method="GET"),
            path("/mustache/template", function() return mus_tpl(data) end, method="GET"),
            path("/mustache/file",     function() return mus_file(data) end, method="GET"),
        )
        
        r = internalrequest(HTTP.Request("GET", "/mustache/string"))
        @test r.status == 200
        @test r.body |> String |> clean_output == expected_output
        
        r = internalrequest(HTTP.Request("GET", "/mustache/template"))
        @test r.status == 200
        @test r.body |> String |> clean_output == expected_output
        
        r = internalrequest(HTTP.Request("GET", "/mustache/file"))
        @test r.status == 200
        @test r.body |> String |> clean_output == expected_output
        
    end


    @testset "otera() from string" begin 

        template = """
        <html>
            <head><title>MyPage</title></head>
            <body>
                {% if name=="watasu" %}
                your name is {{ name }}, right?
                {% end %}
                {% for i in 1 : 10 %}
                Hello {{i}}
                {% end %}
                {% if age == 15 %}
                and your age is {{ age }}.
                {% end %}
            </body>
        </html>
        """ |> remove_trailing_newline

        expected_output = """
        <html>
            <head><title>MyPage</title></head>
            <body>
                your name is watasu, right?
                Hello 1
                Hello 2
                Hello 3
                Hello 4
                Hello 5
                Hello 6
                Hello 7
                Hello 8
                Hello 9
                Hello 10
                and your age is 15.
            </body>
        </html>
        """ |> remove_trailing_newline

        # detect content type
        data = Dict(:name => "watasu", :age => 15)
        render = otera(template)
        result = render(data)
        @test result.body |> String |> clean_output  == expected_output

        # with explicit content type
        data = Dict(:name => "watasu", :age => 15)
        render = otera(template; mime_type="text/html")
        result = render(data)
        @test result.body |> String |> clean_output == expected_output

    end


    @testset "otera() from template file" begin 

        expected_output = """
        <html>
            <head><title>MyPage</title></head>
            <body>
                your name is watasu, right?
                Hello 1
                Hello 2
                Hello 3
                Hello 4
                Hello 5
                Hello 6
                Hello 7
                Hello 8
                Hello 9
                Hello 10
                and your age is 15.
            </body>
        </html>
        """ |> remove_trailing_newline

        data = Dict(:name => "watasu", :age => 15)

        render = otera(content_path("otera_template.html"), from_file=true)
        result = render(data)
        x =  result.body |> String |> clean_output
        @test result.body |> String |> clean_output == expected_output

        # with explicit content type
        render = open(io -> otera(io; mime_type="text/html"), content_path("otera_template.html"))
        result = render(data)
        @test result.body |> String |> clean_output == expected_output
    end


    @testset "otera() from template file with no args" begin 

        expected_output = """
        <html>
            <head><title>MyPage</title></head>
            <body>
                your name is watasu, right?
                Hello 1
                Hello 2
                Hello 3
                Hello 4
                Hello 5
                Hello 6
                Hello 7
                Hello 8
                Hello 9
                Hello 10
                and your age is 15.
            </body>
        </html>
        """ |> remove_trailing_newline

        render = otera(content_path("otera_template_no_vars.html"), from_file=true)
        result = render()
        @test result.body |> String |> clean_output == expected_output

        render = otera(content_path("otera_template_no_vars.html"), mime_type="text/html", from_file=true)
        result = render()
        @test result.body |> String |> clean_output == expected_output
    end


    @testset "otera() from template file with jl init data" begin 

        expected_output = """
        <html>
            <head><title>MyPage</title></head>
            <body>
                <h1>Hello World!</h1>
            </body>
        </html>
        """ |> remove_trailing_newline

        render = otera(content_path("otera_template_jl.html"), from_file=true)
        result = render(Dict(:name => "World"))
        @test result.body |> String |> clean_output == expected_output
    end

    @testset "otera() passing evaluated inputs to template" begin 
        template = "{{value}}. Hello {{ name }}!"
        expected_output = "27. Hello world!"
        render = otera(template)
        result = render(Dict(:name => "world", :value => 3 ^ 3))
        @test result.body |> String |> clean_output == expected_output

        template = """
        <html>
            <head><title>Jinja Test Page</title></head>
            <body>
                Hello, {{name}}!
            </body>
        </html>
        """ |> remove_trailing_newline

        expected_output = """
        <html>
            <head><title>Jinja Test Page</title></head>
            <body>
                Hello, world!
            </body>
        </html>
        """ |> remove_trailing_newline

        render = otera(template)
        result = render(Dict(:name => "world"))
        @test result.body |> String |> clean_output == expected_output
    end

    # #328: sniffing replaced an explicit `Content-Type`, so a template served as text/plain --
    # chosen precisely so that unescaped output is safe -- went out as text/html once the output
    # looked like markup. And `mime_type` plus a per-call header sent both, which HTTP.jl folds
    # into one malformed `text/html,text/plain; charset=utf-8`.
    @testset "an explicit Content-Type is never overridden by sniffing (#328)" begin
        content_types(resp) = [v for (k, v) in resp.headers if lowercase(k) == "content-type"]
        plain = ["Content-Type" => "text/plain; charset=utf-8"]
        payload = "<script>alert(1)</script>"

        renderers = [
            "mustache(string)" => (mustache("<html><body>{{{msg}}}</body></html>"),
                                   Dict("msg" => payload)),
            "mustache(tokens)" => (mustache(mt"<html><body>{{{msg}}}</body></html>"),
                                   Dict("msg" => payload)),
            "mustache(io)"     => (mustache(IOBuffer("<html><body>{{{msg}}}</body></html>")),
                                   Dict("msg" => payload)),
            "otera(string)"    => (otera("<html><body>{{ msg }}</body></html>"),
                                   Dict(:msg => payload)),
            "otera(io)"        => (otera(IOBuffer("<html><body>{{ msg }}</body></html>")),
                                   Dict(:msg => payload)),
        ]
        for (label, (render, vars)) in renderers
            @testset "$label" begin
                # The caller's type wins, and it is the only one.
                @test content_types(render(vars; headers = plain)) == ["text/plain; charset=utf-8"]
                # With no type anywhere, the output is still sniffed.
                @test only(content_types(render(vars))) == "text/html; charset=utf-8"
            end
        end

        @testset "mime_type plus a per-call header: one header, the per-call one" begin
            render = mustache("<html>{{{msg}}}</html>"; mime_type = "text/html")
            @test content_types(render(Dict("msg" => payload); headers = plain)) ==
                ["text/plain; charset=utf-8"]
            @test content_types(render(Dict("msg" => payload))) == ["text/html"]

            render = otera("<html>{{ msg }}</html>"; mime_type = "text/html")
            @test content_types(render(Dict(:msg => payload); headers = plain)) ==
                ["text/plain; charset=utf-8"]
        end

        @testset "Util.response precedence" begin
            @test content_types(Nitro.Util.response("<html></html>", 200, plain)) ==
                ["text/plain; charset=utf-8"]
            @test content_types(Nitro.Util.response("<html></html>"; content_type = "text/css")) ==
                ["text/css"]
            @test isempty(content_types(Nitro.Util.response("<html></html>"; detect = false)))
        end
    end

end

end
