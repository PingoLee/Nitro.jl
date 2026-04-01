@testitem "Original integration" tags=[:core, :network] setup=[NitroCommon] begin

using Test
using HTTP
using JSON
using Sockets
using Dates 
using Suppressor
using Nitro

struct Person
    name::String
    age::Int
end

struct Book
    name::String
    author::String
end


# mount all files inside the content folder under /static
#@staticfiles "content"
staticfiles("content")

# mount files under /dynamic
#@dynamicfiles "content" "/dynamic"
dynamicfiles("content", "/dynamic")

# test that trailing system file path separators are allowed
dynamicfiles("content/", "/dynamic2")

function errormiddleware(handler)
    return function(req::HTTP.Request)
        throw("an random error")
        handler(req)
    end
end

function middleware1(handler)
    return function(req::HTTP.Request)
        handler(req)
    end
end

function middleware2(handler)
    return function(req::HTTP.Request)
        handler(req)
    end
end

function middleware3(handler)
    return function(req::HTTP.Request)
        handler(req)
    end
end

function middleware4(handler)
    return function(req::HTTP.Request)
        handler(req)
    end
end

@enum Fruit apple=1 orange=2 kiwi=3
struct Student
    name  :: String
    age   :: Int8
end

urlpatterns("",
    path("/killserver",        function(; context) terminate() end,         method="GET"),
    path("/anonymous",         function(; request, context) return "no args" end, method="GET"),
    path("/anyparams/{message}", function(req, message::Any; context) return message end, method="GET"),
    path("/test",              function(req) return "hello world!" end,     method="GET"),
    path("/testredirect",      function(req) return redirect("/test") end,  method="GET"),
    path("/middleware-error",  function() return "shouldn't get here" end,  method="GET", middleware=[errormiddleware]),
    path("/customerror",       function()
        function processtring(input::String)
            "<$input>"
        end
        processtring(3)
    end, method="GET"),
    path("/data",              function() return Dict("message" => "hello world") end, method="GET"),
    path("/undefinederror",    function() asdf end,                         method="GET"),
    path("/unsupported-struct", function() return Book("mobdy dick", "blah") end, method="GET"),
    path("/add/{a}/{b}",       function(req, a::Int32, b::Int64) return a + b end, method="GET"),
    path("/divide/{a}/{b}",    function(req, a, b; request, context) return parse(Float64, a) / parse(Float64, b) end, method="GET"),
    path("/file",              function(req) return file("content/sample.html") end, method="GET"),
    path("/multiply/{a}/{b}",  function(req, a::Float64, b::Float64) return a * b end, method="GET"),
    path("/person",            function(req) return Person("joe", 20) end,  method="GET"),
    path("/text",              function(req) return text(req) end,          method="GET"),
    path("/binary",            function(req) return binary(req) end,        method="GET"),
    path("/json",              function(req) return json(req) end,          method="GET"),
    path("/person-json",       function(req) return json(req, Person) end,  method="GET"),
    path("/html",              function(req)
        return html("""
            <!DOCTYPE html>
                <html>
                <body>
                    <h1>hello world</h1>
                </body>
            </html>
        """)
    end, method="GET"),
    path("/get",               function() return "get" end,                 method="GET"),
    path("/query",             function(req) return queryparams(req) end,   method="GET"),
    path("/post",              function(req) return text(req) end,          method="POST"),
    path("/put",               function(req) return "put" end,             method="PUT"),
    path("/patch",             function(req) return "patch" end,           method="PATCH"),
    path("/delete",            function(req) return "delete" end,          method="DELETE"),
    path("/fruit/{fruit}",     function(req, fruit::Fruit; request, context) return fruit end, method="GET"),
    path("/date/{date}",       function(req, date::Date) return date end,   method="GET"),
    path("/datetime/{datetime}", function(req, datetime::DateTime) return datetime end, method="GET"),
    path("/complex/{complex}", function(req, complex::Complex{Float64}) return complex end, method="GET"),
    path("/list/{list}",       function(req, list::Vector{Float32}) return list end, method="GET"),
    path("/dict/{dict}",       function(req, dict::Dict{String, Any}) return dict end, method="GET"),
    path("/tuple/{tuple}",     function(req, tuple::Tuple{String, String}) return tuple end, method="GET"),
    path("/union/{value}",     function(req, value::Union{Bool, String}) return value end, method="GET"),
    path("/boolean/{bool}",    function(req, bool::Bool) return bool end,   method="GET"),
    path("/struct/{student}",  function(req, student::Student) return student end, method="GET"),
    path("/float/{float}",     function(req, float::Float32) return float end, method="GET"),
    # math routes (cases 1-6 for middleware variations — all pass-through middleware)
    path("/math/add/{a}/{b}",      function(req::HTTP.Request, a::Float64, b::Float64) return a + b end, method="GET"),
    path("/math/power/{a}/{b}",    function(req::HTTP.Request, a::Float64, b::Float64) return a ^ b end, method="GET"),
    path("/math/cube/{a}",         function(req, a::Float64) return a * a * a end, method="GET"),
    path("/math/multiply/{a}/{b}", function(req::HTTP.Request, a::Float64, b::Float64) return a * b end, method="GET", middleware=[middleware3]),
    path("/math/divide/{a}/{b}",   function(req::HTTP.Request, a::Float64, b::Float64) return a / b end, method="GET", middleware=[middleware4]),
    path("/math/subtract/{a}/{b}", function(req::HTTP.Request, a::Float64, b::Float64) return a - b end, method="GET", middleware=[middleware3]),
    path("/math/square/{a}",       function(req, a::Float64) return a * a end, method="GET", middleware=[middleware3]),
    path("/emptyrouter",           function(req) return "emptyrouter" end,  method="GET"),
    path("/emptysubpath",          function(req) return "emptysubpath" end, method="GET",  middleware=[middleware1]),
    path("/emptysubpath",          function(req) return "emptysubpath - post" end, method="POST"),
)

# mismatched-params error tests — should throw on registration
try
    urlpatterns("",
        path("/mismatched-params/{a}/{b}", function(a, c; request, context) return "$a, $c" end, method="GET"),
    )
catch e
    @test true
end

try
    urlpatterns("",
        path("/mismatched-params/{a}/{b}", function(req, a, b, c) return "$a, $b, $c" end, method="GET"),
    )
catch e
    @test true
end

try
    urlpatterns("",
        path("/mismatched-params/{a}/{b}", function(req, a) return "$a, $b, $c" end, method="GET"),
    )
catch e
    @test true
end

serve(async=true, port=PORT, show_errors=false, show_banner=true)

r = internalrequest(HTTP.Request("GET", "/anonymous"))
@test r.status == 200
@test text(r) == "no args"

r = internalrequest(HTTP.Request("GET", "/fake-endpoint"))
@test r.status == 404

r = internalrequest(HTTP.Request("GET", "/test"))
@test r.status == 200
@test text(r) == "hello world!"

r = internalrequest(HTTP.Request("GET", "/testredirect"))
@test r.status == 307
@test Dict(r.headers)["Location"] == "/test"

r = internalrequest(HTTP.Request("GET", "/multiply/5/8"))
@test r.status == 200
@test text(r) == "40.0"

r = internalrequest(HTTP.Request("GET", "/person"))
@test r.status == 200
@test json(r, Person) == Person("joe", 20)

r = internalrequest(HTTP.Request("GET", "/html"))
@test r.status == 200
@test Dict(r.headers)["Content-Type"] == "text/html; charset=utf-8"


# path param tests 

# boolean
r = internalrequest(HTTP.Request("GET", "/boolean/true"))
@test r.status == 200

r = internalrequest(HTTP.Request("GET", "/boolean/false"))
@test r.status == 200

@suppress global r = internalrequest(HTTP.Request("GET", "/boolean/asdf"))
@test r.status == 500

# Test parsing of Any type inside a request handler
r = internalrequest(HTTP.Request("GET", "/anyparams/hello"))
@test r.status == 200
@test text(r) == "hello"


# # enums
r = internalrequest(HTTP.Request("GET", "/fruit/1"))
@test r.status == 200

@suppress global r = internalrequest(HTTP.Request("GET", "/fruit/4"))
@test r.status == 500

@suppress global r = internalrequest(HTTP.Request("GET", "/fruit/-3"))
@test r.status == 500

# date
r = internalrequest(HTTP.Request("GET", "/date/2022"))
@test r.status == 200

r = internalrequest(HTTP.Request("GET", "/date/2022-01-01"))
@test r.status == 200


# datetime

r = internalrequest(HTTP.Request("GET", "/datetime/2022-01-01"))
@test r.status == 200

# complex
r = internalrequest(HTTP.Request("GET", "/complex/3.2e-1"))
@test r.status == 200

# list 
r = internalrequest(HTTP.Request("GET", "/list/[1,2,3]"))
@test r.status == 200

r = internalrequest(HTTP.Request("GET", "/list/[]"))
@test r.status == 200

# dictionary 
r = internalrequest(HTTP.Request("GET", """/dict/{"msg": "hello world"}"""))
@test r.status == 200
@test json(r)["msg"] == "hello world"

r = internalrequest(HTTP.Request("GET", "/dict/{}"))
@test r.status == 200

# tuple 
r = internalrequest(HTTP.Request("GET", """/tuple/["a","b"]"""))
@test r.status == 200
@test text(r) == """["a","b"]"""

r = internalrequest(HTTP.Request("GET", """/tuple/["a","b","c"]"""))
@test r.status == 200
@test text(r) == """["a","b"]"""

# union 
r = internalrequest(HTTP.Request("GET", "/union/true"))
@test r.status == 200
@test Dict(r.headers)["Content-Type"] == "text/plain; charset=utf-8"

r = internalrequest(HTTP.Request("GET", "/union/false"))
@test r.status == 200
@test Dict(r.headers)["Content-Type"] == "text/plain; charset=utf-8"

r = internalrequest(HTTP.Request("GET", "/union/asdfasd"))
@test r.status == 200
@test Dict(r.headers)["Content-Type"] == "text/plain; charset=utf-8"

# struct 
r = internalrequest(HTTP.Request("GET", """/struct/{"name": "jim", "age": 20}"""))
@test r.status == 200
@test json(r, Student) == Student("jim", 20)

@suppress global r = internalrequest(HTTP.Request("GET", """/struct/{"aged": 20}"""))
@test r.status == 500

@suppress global r = internalrequest(HTTP.Request("GET", """/struct/{"aged": 20}"""))
@test r.status == 500

# float 
r = internalrequest(HTTP.Request("GET", "/float/3.5"))
@test r.status == 200

r = internalrequest(HTTP.Request("GET", "/float/3"))
@test r.status == 200

# GET, PUT, POST, PATCH, DELETE, route tests 

r = internalrequest(HTTP.Request("GET", "/get"))
@test r.status == 200
@test text(r) == "get"

r = internalrequest(HTTP.Request("POST", "/post", [], "this is some data"))
@test r.status == 200
@test text(r) == "this is some data"

r = internalrequest(HTTP.Request("PUT", "/put"))
@test r.status == 200
@test text(r) == "put"

r = internalrequest(HTTP.Request("PATCH", "/patch"))
@test r.status == 200
@test text(r) == "patch"


# # Query params tests 

r = internalrequest(HTTP.Request("GET", "/query?message=hello"))
@test r.status == 200
@test json(r)["message"] == "hello"

r = internalrequest(HTTP.Request("GET", "/query?message=hello&value=5"))
data = json(r)
@test r.status == 200
@test data["message"] == "hello"
@test data["value"] == "5"

# Get mounted static files

r = internalrequest(HTTP.Request("GET", "/static/test.txt"))
body = text(r)
@test r.status == 200
@test Dict(r.headers)["Content-Type"] == "text/plain; charset=utf-8"
@test body == file("content/test.txt") |> text
@test body == "this is a sample text file"

r = internalrequest(HTTP.Request("GET", "/static/sample.html"))
@test r.status == 200
@test Dict(r.headers)["Content-Type"] == "text/html; charset=utf-8"
@test text(r) == file("content/sample.html") |> text

r = internalrequest(HTTP.Request("GET", "/static/index.html"))
@test r.status == 200
@test Dict(r.headers)["Content-Type"] == "text/html; charset=utf-8"
@test text(r) == file("content/index.html") |> text

r = internalrequest(HTTP.Request("GET", "/static/"))
@test r.status == 200
@test Dict(r.headers)["Content-Type"] == "text/html; charset=utf-8"
@test text(r) == file("content/index.html") |> text


# # Body transformation tests

r = internalrequest(HTTP.Request("GET", "/text", [], "hello there!"))
@test r.status == 200
@test text(r) == "hello there!"

r = internalrequest(HTTP.Request("GET", "/binary", [], "hello there!"))
@test r.status == 200
@test String(r.body) == "[104,101,108,108,111,32,116,104,101,114,101,33]"

r = internalrequest(HTTP.Request("GET", "/json", [], "{\"message\": \"hi\"}"))
@test r.status == 200
@test json(r)["message"] == "hi"

r = internalrequest(HTTP.Request("GET", "/person"))
person = json(r, Person)
@test r.status == 200
@test person.name == "joe"
@test person.age == 20

r = internalrequest(HTTP.Request("GET", "/person-json", [], "{\"name\":\"jim\",\"age\":25}"))
person = json(r, Person)
@test r.status == 200
@test person.name == "jim"
@test person.age == 25

function testfolder(prefix::String, folder::String)
    filepaths = Nitro.Core.Util.getfiles(folder)
    for path in filepaths
        link =  "/$prefix/$(relpath(path, folder))"
        r = internalrequest(HTTP.Request("GET", link))
        @test r.status == 200
        @test text(r) == file(path) |> text
    end
end

@testset "Test all mounted files" begin
    testfolder("static", "./content")
    testfolder("dynamic", "./content")
    testfolder("dynamic2", "./content")
end

r = internalrequest(HTTP.Request("GET", "/file"))
@test r.status == 200
@test text(r) == file("content/sample.html") |> text

r = internalrequest(HTTP.Request("GET", "/dynamic/sample.html"))
@test r.status == 200
@test text(r) == file("content/sample.html") |> text

r = internalrequest(HTTP.Request("GET", "/dynamic2/sample.html"))
@test r.status == 200
@test text(r) == file("content/sample.html") |> text

r = internalrequest(HTTP.Request("GET", "/static/sample.html"))
@test r.status == 200
@test text(r) == file("content/sample.html") |> text

@suppress global r = internalrequest(HTTP.Request("GET", "/multiply/a/8"))
@test r.status == 500

# don't suppress error reporting for this test
@suppress global r = internalrequest(HTTP.Request("GET", "/multiply/a/8"))
@test r.status == 500

# hit endpoint that doesn't exist
@suppress global r = internalrequest(HTTP.Request("GET", "asdfasdf"))
@test r.status == 404

@suppress global r = internalrequest(HTTP.Request("GET", "asdfasdf"))
@test r.status == 404

@suppress global r = internalrequest(HTTP.Request("GET", "/somefakeendpoint"))
@test r.status == 404

@suppress global r = internalrequest(HTTP.Request("GET", "/customerror"))
@test r.status == 500

@suppress global r = internalrequest(HTTP.Request("GET", "/undefinederror"))
@test r.status == 500    

# Test struct serializaiton without any explicit struct types (will work with the new JSON library)
r = internalrequest(HTTP.Request("GET", "/unsupported-struct"))
@test r.status == 200

# ## Router related tests

# case 1
r = internalrequest(HTTP.Request("GET", "/math/add/6/5"))
@test r.status == 200
@test text(r) == "11.0"

# case 1
r = internalrequest(HTTP.Request("GET", "/math/power/6/5"))
@test r.status == 200
@test text(r) == "7776.0"

# case 2
r = internalrequest(HTTP.Request("GET", "/math/cube/3"))
@test r.status == 200
@test text(r) == "27.0"

# case 3
r = internalrequest(HTTP.Request("GET", "/math/multiply/3/5"))
@test r.status == 200
@test text(r) == "15.0"

# case 4
r = internalrequest(HTTP.Request("GET", "/math/divide/3/5"))
@test r.status == 200
@test text(r) == "0.6"

# case 5
r = internalrequest(HTTP.Request("GET", "/math/subtract/3/5"))
@test r.status == 200
@test text(r) == "-2.0"

# case 6
r = internalrequest(HTTP.Request("GET", "/math/square/3"))
@test r.status == 200
@test text(r) == "9.0"

r = internalrequest(HTTP.Request("GET", "/emptyrouter"))
@test r.status == 200
@test text(r) == "emptyrouter"

r = internalrequest(HTTP.Request("GET", "/emptysubpath"))
@test r.status == 200
@test text(r) == "emptysubpath"

r = internalrequest(HTTP.Request("POST", "/emptysubpath"))
@test r.status == 200
@test text(r) == "emptysubpath - post"


## internal docs and metrics tests

r = internalrequest(HTTP.Request("GET", "/get"))
@test r.status == 200


terminate()

try
    # This should throw an error now that serivce isn't running
    url = getexternalurl()
    @test false
catch e
    @test true
end

@async serve(middleware=[middleware1, middleware2, middleware3], port=PORT, show_errors=false, show_banner=false)
sleep(1)

# This should be a non-empty string now that the service is running
@test getexternalurl() == "http://127.0.0.1:6060"

r = internalrequest(HTTP.Request("GET", "/get"))
@test r.status == 200

# redundant terminate() calls should have no affect
terminate()
terminate()
terminate()

function errorcatcher(handle)
    function(req)
        try 
            response = handle(req)
            return response
        catch e 
            return HTTP.Response(500, "here's a custom error response")
        end
    end
end

# Test default handler by turning off serializaiton
@async serve(serialize=false, middleware=[error_catcher], catch_errors=false, show_banner=false)
sleep(3)
r = internalrequest(HTTP.Request("GET", "/get"), catch_errors=false)
@test r.status == 200

try 
    # test the error handler inside the default handler
    r = HTTP.get("$localhost/undefinederror"; readtimeout=1)
catch e
    @test true
end

try 
    # service should not have started and get requests should throw some error
    r = HTTP.get("$localhost/data"; readtimeout=1)
catch e
    @test true
finally
    terminate()
end

terminate()

end 
