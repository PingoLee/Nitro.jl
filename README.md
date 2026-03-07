# Nitro.jl

<!-- START HTML -->
<div>
  </br>
  <p align="center"><img src="nitro.png" width="20%"></p>
  <p align="center">
    <strong>A breath of fresh air for programming web apps in Julia.</strong>
  </p>
  <p align="center">
    <a href='https://juliahub.com/ui/Packages/General/Nitro'><img src='https://juliahub.com/docs/General/Nitro/stable/version.svg' alt='Version' /></a>
    <a href='https://nitroframework.github.io/Nitro.jl/stable/'><img src='https://img.shields.io/badge/docs-stable-blue.svg' alt='documentation stable' /></a>
    <a href='https://github.com/NitroFramework/Nitro.jl/actions/workflows/ci.yml'><img src='https://github.com/NitroFramework/Nitro.jl/actions/workflows/ci.yml/badge.svg' alt='Build Status' /></a>
    <a href='https://coveralls.io/github/NitroFramework/Nitro.jl?branch=master'><img src='https://coveralls.io/repos/github/NitroFramework/Nitro.jl/badge.svg?branch=master' alt='Coverage Status' /></a>
  </p>
</div>
<!-- END HTML -->

## About
Nitro is a micro-framework built on top of the HTTP.jl library. 
Breathe easy knowing you can quickly spin up a web server with abstractions you're already familiar with.

## Contact

Need Help? Feel free to reach out on our social media channels.

[![Chat on Discord](https://img.shields.io/badge/chat-Discord-7289DA?logo=discord)](https://discord.gg/g5dmzRkdAR) 
[![Discuss on GitHub](https://img.shields.io/badge/discussions-GitHub-333333?logo=github)](https://github.com/NitroFramework/Nitro.jl/discussions)

## Features

- Straightforward routing (macro & function syntax)
- Django-style centralized routing (`path`, `urlpatterns`, `include_routes`)
- Out-of-the-box JSON serialization & deserialization (JSON.jl)
- Type definition support for path parameters
- Request Extractors
- Application Context
- Multiple Instance Support
- Cookie management & Encrypted Extractors
- Session Management & Guards (`login_required`, `role_required`)
- Multithreading by default (`Threads.@spawn` for all requests)
- Websockets, Streaming, and Server-Sent Events
- SPA History Mode (`spafiles` for Vue/React/Quasar)
- Middleware chaining (at the application, router, and route levels)
- Prebuilt Middleware (RateLimiter, Cors, BearerAuth, SessionMiddleware, GuardMiddleware)
- Static & Dynamic file hosting
- Response helpers (`Res.json`, `Res.status`, `Res.send`)
- Request convenience properties (`req.params`, `req.query`, `req.session`, `req.ip`)
- Hot reloads with Revise.jl
- Templating Support (Mustache.jl, OteraEngine.jl)

## Installation

```julia
pkg> add Nitro
```

## Minimalistic Example

Create a web-server with very few lines of code
```julia
using Nitro
using HTTP

@get "/greet" function(req::HTTP.Request)
    return "hello world!"
end

# start the web server (multithreaded by default)
serve()
```
## Handlers

Handlers are used to connect your code to the server in a clean & straightforward way. 
They assign a url to a function and invoke the function when an incoming request matches that url.


- Handlers can be imported from other modules and distributed across multiple files for better organization and modularity
- All handlers have equivalent macro & function implementations and support `do..end` block syntax
- The type of first argument is used to identify what kind of handler is being registered
- This package assumes it's a `Request` handler by default when no type information is provided


There are 3 types of supported handlers:

- `Request` Handlers
- `Stream` Handlers
- `Websocket` Handlers

```julia
using HTTP
using Nitro

# Request Handler
@get "/" function(req::HTTP.Request)
    ...
end

# Stream Handler
@stream "/stream" function(stream::HTTP.Stream)
    ...
end

# Websocket Handler
@websocket "/ws" function(ws::HTTP.WebSocket)
    ...
end
```

They are just functions which means there are many ways that they can be expressed and defined. Below is an example of several different ways you can express and assign a `Request` handler.
```julia
@get "/greet" function()
    "hello world!"
end

@get("/gruessen") do 
    "Hallo Welt!"
end

@get "/saluer" () -> begin
    "Bonjour le monde!"
end

@get "/saludar" () -> "¡Hola Mundo!"
@get "/salutare" f() = "ciao mondo!"

# This function can be declared in another module
function subtract(req, a::Float64, b::Float64)
  return a - b
end

# register foreign request handlers like this
@get "/subtract/{a}/{b}" subtract
```

<details>
    <summary><b>More Handler Docs</b></summary>
    
### Request Handlers
Request handlers are used to handle HTTP requests. They are defined using macros or their function equivalents, and accept a `HTTP.Request` object as the first argument. These handlers support both function and do-block syntax.

- The default Handler when no type information is provided
- Routing Macros: `@get`, `@post`, `@put`, `@patch`, `@delete`, `@route`
- Routing Functions: `get()`, `post()`, `put()`, `patch()`, `delete()`, `route()`

### Stream Handlers
Stream handlers are used to stream data. They are defined using the `@stream` macro or the `stream()` function and accept a `HTTP.Stream` object as the first argument. These handlers support both function and do-block syntax.

- `@stream` and `stream()` don't require a type definition on the first argument, they assume it's a stream.
- `Stream` handlers can be assigned with standard routing macros & functions: `@get`, `@post`, etc
- You need to explicitly include the type definition so Nitro can identify this as a `Stream` handler

### Websocket Handlers
Websocket handlers are used to handle websocket connections. They are defined using the `@websocket` macro or the `websocket()` function and accept a `HTTP.WebSocket` object as the first argument. These handlers support both function and do-block syntax.

- `@websocket` and `websocket()` don't require a type definition on the first argument, they assume it's a websocket.
- `Websocket` handlers can also be assigned with the `@get` macro or `get()` function, because the websocket protocol requires a `GET` request to initiate the handshake. 
- You need to explicitly include the type definition so Nitro can identify this as a `Websocket` handler

</details>


## Routing Macro & Function Syntax

There are two primary ways to register your request handlers: the standard routing macros or the routing functions which utilize the do-block syntax. 

For each routing macro, we now have a an equivalent routing function

```julia
@get    -> get()
@post   -> post()
@put    -> put()
@patch  -> patch()
@delete -> delete()
@route  -> route()
```

The only practical difference between the two is that the routing macros are called during the precompilation
stage, whereas the routing functions are only called when invoked. (The routing macros call the routing functions under the hood)

```julia
# Routing Macro syntax
@get "/add/{x}/{y}" function(request::HTTP.Request, x::Int, y::Int)
    x + y
end

# Routing Function syntax
get("/add/{x}/{y}") do request::HTTP.Request, x::Int, y::Int
    x + y
end
```

## Django-Style Routing

Nitro supports centralized URL dispatching inspired by Django. This is useful for organizing large applications into modular components.

### `path()` — Define a single route

```julia
using Nitro

# Path converters automatically coerce types
path("/users/<int:id>", get_user, method="GET")
path("/articles/<str:slug>", get_article, method="GET")
path("/keys/<uuid:key>", get_key, method="GET")
```

Supported converters: `<int:name>`, `<str:name>`, `<float:name>`, `<bool:name>`, `<uuid:name>`

### `urlpatterns()` — Group routes under a prefix

```julia
using Nitro

function list_users(req)
    return json(Dict("users" => ["Alice", "Bob"]))
end

function get_user(req, id::Int)
    return json(Dict("user_id" => id))
end

function create_user(req)
    return json(Dict("created" => true))
end

# Register routes under /api/v1
urlpatterns("/api/v1",
    path("/users", list_users, method="GET"),
    path("/users/<int:id>", get_user, method="GET"),
    path("/users", create_user, method="POST"),
)

serve()
```

### `include_routes()` — Modular app structures

```julia
# In your users module
user_routes = [
    path("/profile", get_profile, method="GET"),
    path("/settings", update_settings, method="POST"),
]

# In your main app
urlpatterns("",
    include_routes("/user", user_routes)...
)
```

## Render Functions

Nitro, by default, automatically identifies the Content-Type of the return value from a request handler when building a Response.
This default functionality is quite useful, but it does have an impact on performance. In situations where the return type is known,
It's recommended to use one of the pre-existing render functions to speed things up.

Here's a list of the currently supported render functions:
`html`, `text`, `json`, `file`, `xml`, `js`, `css`, `binary`

Below is an example of how to use these functions:

```julia
using Nitro 

get("/html") do 
    html("<h1>Hello World</h1>")
end

get("/text") do 
    text("Hello World")
end

get("/json") do 
    json(Dict("message" => "Hello World"))
end

serve()
```

In most cases, these functions accept plain strings as inputs. The only exceptions are the `binary` function, which accepts a `Vector{UInt8}`, and the `json` function which accepts any serializable type. 
- Each render function accepts a status and custom headers.
- The Content-Type and Content-Length headers are automatically set by these render functions

## Response Helpers (`Res` Module)

For a more Express.js-like experience, Nitro provides the `Res` module with clean response builders:

```julia
using Nitro

# Return JSON with automatic Content-Type
@get "/api/users" function(req)
    return Res.json(Dict("users" => ["Alice", "Bob"]), status=200)
end

# Return a plain status code
@post "/api/action" function(req)
    # ... do something
    return Res.status(201)
end

# Return plain text
@get "/health" function(req)
    return Res.send("OK", status=200)
end

serve()
```

## Request Convenience Properties

Nitro extends `HTTP.Request` with shorthand properties for common operations:

```julia
@get "/users/{id}" function(req)
    req.params    # => Dict with path parameters (e.g. Dict("id" => "42"))
    req.query     # => Dict with query parameters
    req.session   # => Session dict (if SessionMiddleware is active), or nothing
    req.ip        # => Caller's IP address, or nothing
    
    id = req.params["id"]
    return Res.json(Dict("user_id" => id))
end
```

All standard `HTTP.Request` fields (`req.method`, `req.target`, `req.headers`, `req.body`) continue to work as usual.


## Path parameters

Path parameters are declared with braces and are passed directly to your request handler. 
```julia
using Nitro

# use path params without type definitions (defaults to Strings)
@get "/add/{a}/{b}" function(req, a, b)
    return parse(Float64, a) + parse(Float64, b)
end

# use path params with type definitions (they are automatically converted)
@get "/multiply/{a}/{b}" function(req, a::Float64, b::Float64)
    return a * b
end

# The order of the parameters doesn't matter (just the name matters)
@get "/subtract/{a}/{b}" function(req, b::Int64, a::Int64)
    return a - b
end

# start the web server
serve()
```

## Query parameters


Query parameters can be declared directly inside of your handlers signature. Any parameter that isn't mentioned inside the route path is assumed to be a query parameter.

- If a default value is not provided, it's assumed to be a required parameter

```julia
@get "/query" function(req::HTTP.Request, a::Int, message::String="hello world")
    return (a, message)
end
```

Alternatively, you can use the `queryparams()` function to extract the raw values from the url as a dictionary. 

```julia
@get "/query" function(req::HTTP.Request)
    return queryparams(req)
end
```

## HTML Forms

Use the `formdata()` function to extract and parse the form data from the body of a request. This function returns a dictionary of key-value pairs from the form
```julia
using Nitro

# Setup a basic form
@get "/" function()
    html("""
    <form action="/form" method="post">
        <label for="firstname">First name:</label><br>
        <input type="text" id="firstname" name="firstname"><br>
        <label for="lastname">Last name:</label><br>
        <input type="text" id="lastname" name="lastname"><br><br>
        <input type="submit" value="Submit">
    </form>
    """)
end

# Parse the form data and return it
@post "/form" function(req)
    data = formdata(req)
    return data
end

serve()
```

## Return JSON

All objects are automatically deserialized into JSON using the JSON.jl library

```julia
using Nitro
using HTTP

@get "/data" function(req::HTTP.Request)
    return Dict("message" => "hello!", "value" => 99.3)
end

# start the web server
serve()
```

## Deserialize & Serialize custom structs
Nitro provides out-of-the-box serialization & deserialization for all objects and structs using the JSON.jl package

```julia
using Nitro
using HTTP

struct Animal
    id::Int
    type::String
    name::String
end

@get "/get" function(req::HTTP.Request)
    # serialize struct into JSON automatically
    return Animal(1, "cat", "whiskers")
end

@post "/echo" function(req::HTTP.Request)
    # deserialize JSON from the request body into an Animal struct
    animal = json(req, Animal)
    # serialize struct back into JSON automatically
    return animal
end

# start the web server
serve()
```

## Extractors

Nitro comes with several built-in extractors designed to reduce the amount of boilerplate required to serialize inputs to your handler functions. By simply defining a struct and specifying the data source, these extractors streamline the process of data ingestion & validation through a uniform api.

- The serialized data is accessible through the `payload` property
- Can be used alongside other parameters and extractors
- Default values can be assigned when defined with the `@kwdef` macro
- Includes both global and local validators
- Struct definitions can be deeply nested

Supported Extractors:

- `Path` - extracts from path parameters
- `Query` - extracts from query parameters, 
- `Header` - extracts from request headers
- `Form` - extracts form data from the request body
- `Body` - serializes the entire request body to a given type (String, Float64, etc..)
- `Json` - extracts json from the request body
- `JsonFragment` - extracts a "fragment" of the json body using the parameter name to identify and extract the corresponding top-level key


#### Using Extractors & Parameters

In this example we show that the `Path` extractor can be used alongside regular path parameters. This Also works with regular query parameters and the `Query` extractor.

```julia
struct Add
    b::Int
    c::Int
end

@get "/add/{a}/{b}/{c}" function(req, a::Int, pathparams::Path{Add})
    add = pathparams.payload # access the serialized payload
    return a + add.b + add.c
end
```

#### Default Values

Default values can be setup with structs using the `@kwdef` macro.

```julia
@kwdef struct Pet
    name::String
    age::Int = 10
end

@post "/pet" function(req, params::Json{Pet})
    return params.payload # access the serialized payload
end
```

#### Nullable Types
You can indicate that a field may be null by declaring it as a Union type with `Nothing`.
> **Note:** While the serializer can handle type `::Union{T,Missing}` it will fail if a default value of `missing` provided. Instead use `::Union{T,Nothing} = nothing`.

```julia
@kwdef struct Pet
    name::Union{String,Nothing} # Valid
    surname::Union{String,Nothing} = nothing # Valid
    eyecolor::Union{ColorStruct, Missing} # Valid 
    coatcolor::Union{ColorStruct,Missing} = missing # Invalid: no schema will be generated for `Pet` 
    age::Int = 10
end

```

#### Validation

On top of serializing incoming data, you can also define your own validation rules by using the `validate` function. In the example below we show how to use both `global` and `local` validators in your code.

- Validators are completely optional
- During the validation phase, nitro will call the `global` validator before running a `local` validator.

```julia
import Nitro: validate

struct Person
    name::String
    age::Int
end

# Define a global validator 
validate(p::Person) = p.age >= 0

# Only the global validator is ran here
@post "/person" function(req, newperson::Json{Person})
    return newperson.payload
end

# In this case, both global and local validators are ran (this also makes sure the person is age 21+)
# You can also use this sytnax instead: Json(Person, p -> p.age >= 21)
@post "/adult" function(req, newperson = Json{Person}(p -> p.age >= 21))
    return newperson.payload
end
```

## Application Context

Most applications at some point will need to rely on some shared global state across the codebase. 
This usually comes in the form of a shared database connection pool or some other in memory store. 
Nitro provides a `context` argument which acts as a free spot for developers to store any objects that 
should be available throughout the lifetime of an application.

There are three primary ways to get access to your application context
- Injected into any request handler using the `Context` struct.
- The `context` keyword argument in a function handler
- Through the `context()` function 

*There are no built-in data race protections*, but this is intentional. Not all applications have the same requirements, 
so it's up to the developer to decide how to best handle this. For those who need to share mutable state across multiple
threads I'd recommend looking into using `Actors`, `Channels`, or `ReentrantLocks` to handle this quickly.

Below is a simplified example where we store a `Person` as the application context to show how things are 
connected and shared.

```julia
using Nitro

struct Person
    name::String
end

# The ctx argument here is injected through the Context class
@get "/ctx-injection" function(req, ctx::Context{Person})
    person :: Person = ctx.payload # access the underlying value
    return "Hello $(person.name)!"
end

# Access the context through the 'context' keyword argument 
@get "/ctx-kwarg" function(req; context)
    person :: Person = context 
    return "Hello $(person.name)!"
end

# Access context through the 'context()' function
@get "/ctx-function" function(req)
    person :: Person = context()
    return "Hello $(person.name)!"
end

# This represents the application context shared between all handlers
person = Person("John")

# Here is how we set the application context in our server
serve(context=person)
```

## Cookies

Nitro provides a high-performance cookie management system with native support for encryption and declarative data fetching.

### Setting Cookies
Use `set_cookie!` to attach cookies to your responses. By default, it sets `HttpOnly`, `Secure`, and `SameSite=Lax` for better security.

```julia
@get "/login" function(res::Response)
    set_cookie!(res, "session", "xyz-789", maxage=3600)
    return "Logged in!"
end
```

### Getting Cookies
You can use the `get_cookie` helper or the `Cookie` extractor to fetch cookie values.

```julia
# Using the Extractor (converts value to Int automatically)
@get "/dashboard" function(user_id::Cookie{Int})
    return "Welcome user $(user_id.value)"
end

# Using the helper
@get "/profile" function(req::Request)
    theme = get_cookie(req, "theme", "light")
    return "Theme: $theme"
end
```

### Encrypted Cookies
If a `secret_key` is configured, Nitro uses AES-256-GCM for authenticated encryption.

```julia
# Global configuration (requires NitroCryptoExt)
configcookies(secret_key = "your-32-character-secret-key")

@get "/secure" function(res::Response)
    set_cookie!(res, "secret", "shhh!", encrypted=true)
end
```

## Interpolating variables into endpoints

You can interpolate variables directly into the paths, which makes dynamically registering routes a breeze 

(Thanks to @anandijain for the idea)
```julia
using Nitro

operations = Dict("add" => +, "multiply" => *)
for (pathname, operator) in operations
    @get "/$pathname/{a}/{b}" function (req, a::Float64, b::Float64)
        return operator(a, b)
    end
end

# start the web server
serve()
```
## Routers

The `router()` function is an HOF (higher order function) that allows you to reuse the same path prefix & properties across multiple endpoints. This is helpful when your api starts to grow and you want to keep your path operations organized.

Below are the arguments the `router()` function can take:
```julia
router(prefix::String; tags::Vector, middleware::Vector)
```
- `tags` - are used to organize endpoints
- `middleware` - is used to setup router & route-specific middleware

```julia
using Nitro

# Any routes that use this router will be automatically grouped 
math = router("/math", tags=["math"])

@get math("/multiply/{a}/{b}") function(req, a::Float64, b::Float64)
    return a * b
end

@get math("/divide/{a}/{b}") function(req, a::Float64, b::Float64)
    return a / b
end

serve()
```

## Session Management

Nitro includes a built-in `SessionMiddleware` that provides server-side session management with automatic cookie handling.

```julia
using Nitro

# Add session middleware to your app
serve(middleware=[SessionMiddleware()])
```

Once active, session data is available via `req.session` (or `req.context[:session]`):

```julia
@post "/login" function(req)
    body = json(req)
    req.context[:session]["user_id"] = body["user_id"]
    req.context[:session]["role"] = body["role"]
    return Res.json(Dict("status" => "logged in"))
end

@get "/profile" function(req)
    user_id = req.session["user_id"]
    return Res.json(Dict("user_id" => user_id))
end
```

### Guards (`login_required`, `role_required`)

Guards are composable functions that run before a route handler. If a guard returns a response, the handler is skipped.

```julia
using Nitro

# Protect a route — redirect to /login if no session
serve(middleware=[
    SessionMiddleware(),
    GuardMiddleware(login_required())
])

# Stack multiple guards
serve(middleware=[
    SessionMiddleware(),
    GuardMiddleware(login_required(), role_required("admin"))
])
```

## SPA History Mode

For Single Page Applications (Vue, React, Quasar, Svelte), Nitro provides `spafiles()` which serves static files and automatically falls back to `index.html` for unmatched routes — enabling client-side routing.

```julia
using Nitro

# Mount your SPA build folder under /app
spafiles("dist", "app")

# API routes still work normally
@get "/api/data" function(req)
    return Res.json(Dict("value" => 42))
end

serve()
```

With this setup:
- `/app/css/style.css` → serves the actual CSS file
- `/app/users/123` → serves `dist/index.html` (client-side router handles it)

> **Note:** In production, use nginx to serve static files and SPA fallback via `try_files`. Nitro's `spafiles` is designed for development convenience.

## Hot reloads with Revise

Nitro can integrate with Revise to provide hot reloads, speeding up development. Since Revise recommends keeping all code to be revised in a package, you first need to move to this type of a layout.

[First make sure your `Project.toml` has the required fields such as `name` to work on a package rather than a project.](https://pkgdocs.julialang.org/v1/toml-files/)

Next, write the main code for you routes in a module `src/MyModule.jl`:

```
module MyModule

using Nitro; @oxidize

@get "/greet" function(req::HTTP.Request)
    return "hello world!"
end

end
```

Then you can make a `debug.jl` entrypoint script:

```
using Revise
using Nitro
using MyModule

MyModule.serve(revise=:eager)
```

The `revise` option can also be set to `:lazy`, in which case revisions will always be left to just before a request is served, rather than being attempted eagerly when source files change on disk.

Note that you should run another entrypoint script without Revise in production.

## Multiple Instances

In some advanced scenarios, you might need to spin up multiple web severs within the same module on different ports. Nitro provides both a static and dynamic way to create multiple instances of a web server.

As a general rule of thumb, if you know how many instances you need ahead of time it's best to go with the static approach.

### Static: multiple instance's with `@oxidize` 

Nitro provides a new macro which makes it possible to setup and run multiple instances. It generates methods and binds them to a new internal state for the current module. 

In the example below, two simple servers are defined within modules A and B and are started in the parent module. Both modules contain all of the functions exported from Nitro which can be called directly as shown below.

```julia
module A
    using Nitro; @oxidize

    get("/") do
        text("server A")
    end
end

module B
    using Nitro; @oxidize

    get("/") do
        text("server B")
    end
end

try 
    # start both instances
    A.serve(port=8001, async=true)
    B.serve(port=8002, async=false)
finally
    # shut down if we `Ctrl+C`
    A.terminate()
    B.terminate()
end
```

### Dynamic: multiple instance's with `instance()` 

The `instance` function helps you create a completely independent instance of an Nitro web server at runtime. It works by dynamically creating a julia module at runtime and loading the Nitro code within it.

All of the same methods from Nitro are available under the named instance. In the example below we can use the `get`, and `serve` by simply using dot syntax on the `app1` variable to access the underlying methods.


```julia
using Nitro

######### Setup the first app #########

app1 = instance()

app1.get("/") do
    text("server A")
end

######### Setup the second app #########

app2 = instance()

app2.get("/") do
    text("server B")
end

######### Start both instances #########

try 
    # start both servers together
    app1.serve(port=8001, async=true)
    app2.serve(port=8002)
finally
    # clean it up
    app1.terminate()
    app2.terminate()
end
```

## Multithreading & Parallelism

Nitro runs in **multithreaded mode by default**. All incoming requests are dispatched via `Threads.@spawn` to available threads in the pool, similar to Go's goroutine model.

To take full advantage, start Julia with multiple threads:
```shell 
julia --threads 4
# or
julia -t auto
```

```julia
using Nitro
using Base.Threads

x = Atomic{Int64}(0);

@get "/show" function()
    return x
end

@get "/increment" function()
    atomic_add!(x, 1)
    return x
end

# serve() is multithreaded by default — no need for serveparallel()
serve()
```

> **Note:** `serveparallel()` is deprecated. Use `serve()` directly — it is parallel by default.

## Mounting Static Files

You can mount static files using this handy function which recursively searches a folder for files and mounts everything. All files are 
loaded into memory on startup.

```julia
using Nitro

# mount all files inside the "content" folder under the "/static" path
staticfiles("content", "static")

# start the web server
serve()
```

## Mounting Dynamic Files 

Similar to staticfiles, this function mounts each path and re-reads the file for each request. This means that any changes to the files after the server has started will be displayed.

```julia
using Nitro

# mount all files inside the "content" folder under the "/dynamic" path
dynamicfiles("content", "dynamic")

# start the web server
serve()
```
## Performance Tips

Disabling the internal logger can provide massive performance gains, which can be helpful in some scenarios.

```julia 
serve(access_log=nothing)
```

## Logging

Nitro provides a default logging format but allows you to customize the format using the `access_log` parameter.

You can read more about the logging options [here](https://juliaweb.github.io/HTTP.jl/stable/reference/#HTTP.@logfmt_str)

```julia 
# Uses the default logging format
serve()

# Customize the logging format 
serve(access_log=logfmt"[$time_iso8601] \"$request\" $status")

# Disable internal request logging 
serve(access_log=nothing)
```

## Middleware

Middleware functions make it easy to create custom workflows to intercept all incoming requests and outgoing responses.
They are executed in the same order they are passed in (from left to right).

They can be set at the application, router, and route layer with the `middleware` keyword argument. All middleware is additive and any middleware defined in these layers will be combined and executed.

Middleware will always be executed in the following order:

```
application -> router -> route
```

Now lets see some middleware in action:
```julia
using Nitro
using HTTP

function AuthMiddleware(handler)
    return function(req::HTTP.Request)
        println("Auth middleware")
        # ** NOT an actual security check ** #
        if !HTTP.headercontains(req, "Authorization", "true")
            return HTTP.Response(403)
        else 
            return handler(req) # passes the request to your application
        end
    end
end

function middleware1(handle)
    function(req)
        println("middleware1")
        handle(req)
    end
end

function middleware2(handle)
    function(req)
        println("middleware2")
        handle(req)
    end
end

# set middleware at the router level
math = router("math", middleware=[middleware1])

# set middleware at the route level 
@get math("/divide/{a}/{b}", middleware=[middleware2]) function(req, a::Float64, b::Float64)
    return a / b
end

# set application level middleware
serve(middleware=[AuthMiddleware])
```

## Built-in Middleware

Nitro ships with prebuilt middleware functions so you can easily integrate bearer auth, rate limiting, CORS support, sessions, and guards to your app. You can add these at the application, router, or route level through the `middleware` keyword.


### RateLimiter

The `RateLimiter` middleware lets you set a cap on how many requests each client IP can make in a given time window.

```julia
# Limit each client to 50 requests every 3 seconds (fixed window - default)
serve(middleware=[RateLimiter(rate_limit=50, window=Second(3))])

# Use sliding window for more precise rate limiting
serve(middleware=[RateLimiter(strategy=:sliding_window, rate_limit=100, window=Minute(1))])

# Skip rate limiting for certain paths
serve(middleware=[RateLimiter(rate_limit=50, exempt_paths=["/health"])])
```

**Strategy Options:**
- `:fixed_window` (default): Efficient memory usage with periodic reset windows
- `:sliding_window`: More precise tracking but higher memory usage per client

---

### ExtractIP

The `ExtractIP` middleware pulls the caller's real IP from common proxy headers and assigns it to `req.context[:ip]`.

```julia
# run this before rate limiting when behind a proxy
serve(middleware=[ExtractIP(), RateLimiter(auto_extract_ip=false)])
```

### BearerAuth

The `BearerAuth` middleware extracts the bearer token from the authorization header and passes it to your custom function. If the token's good, your handler runs; if not, the request gets bounced.

```julia
function validate_token(token::String)
    return Dict("name" => "joe")
end

serve(middleware=[BearerAuth(validate_token)])
```

### CORS

The `Cors` middleware handles Cross-Origin Resource Sharing for your API.

```julia
serve(middleware=[Cors(allowed_origins="*")])
```

---

### Bringing it all together

```julia
# Mix CORS, rate limiting, sessions, and auth
serve(middleware=[
    Cors(),
    RateLimiter(),
    SessionMiddleware(),
    BearerAuth(validate_token)
])
```

## Custom Response Serializers

If you don't want to use Nitro's default response serializer, you can turn it off and add your own! Just create your own special middleware function to serialize the response and add it at the end of your own middleware chain. 

`serve()` has a `serialize` keyword argument which can toggle off the default serializer.

```julia
using Nitro
using HTTP
using JSON

@get "/divide/{a}/{b}" function(req::HTTP.Request, a::Float64, b::Float64)
    return a / b
end

# This is just a regular middleware function
function myserializer(handle)
    function(req)
        try
          response = handle(req)
          # convert all responses to JSON
          return HTTP.Response(200, [], body=JSON.json(response)) 
        catch error 
            @error "ERROR: " exception=(error, catch_backtrace())
            return HTTP.Response(500, "The Server encountered a problem")
        end 
    end
end

# make sure 'myserializer' is the last middleware function in this list
serve(middleware=[myserializer], serialize=false)
```

## Templating

Rather than building an internal engine for templating or adding additional dependencies, Nitro 
provides two package extensions to support `Mustache.jl` and `OteraEngine.jl` templates.

Nitro provides a simple wrapper api around both packages that makes it easy to render templates from strings,
templates, and files. This wrapper api returns a `render` function which accepts a dictionary of inputs to fill out the
template.

In all scenarios, the rendered template is returned inside a HTTP.Response object ready to get served by the api.
By default, the mime types are auto-detected either by looking at the content of the template or the extension name on the file.
If you know the mime type you can pass it directly through the `mime_type` keyword argument to skip the detection process.

### Mustache Templating
Please take a look at the [Mustache.jl](https://jverzani.github.io/Mustache.jl/dev/) documentation to learn the full capabilities of the package

```julia
using Mustache
using Nitro

render = mustache("./templates/greeting.txt", from_file=true)

@get "/mustache/file" function()
    data = Dict("name" => "Chris")
    return render(data)
end
```

### Otera Templating
Please take a look at the [OteraEngine.jl](https://mommawatasu.github.io/OteraEngine.jl/dev/tutorial/#API) documentation to learn the full capabilities of the package

```julia
using OteraEngine
using Nitro

template_str = """
<html>
    <head><title>{{ title }}</title></head>
    <body>
        {% for name in names %}
        Hello {{ name }}<br>
        {% end %}
    </body>
</html>
"""

render = otera(template_str)

@get "/otera/loop" function()
    data = Dict("title" => "Greetings", "names" => ["Alice", "Bob", "Chris"])
    return render(data)
end
```

# API Reference (macros)

#### @get, @post, @put, @patch, @delete
```julia
  @get(path, func)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `path` | `string` or `router()` | **Required**. The route to register |
| `func` | `function` | **Required**. The request handler for this route |

Used to register a function to a specific endpoint to handle that corresponding type of request

#### @route
```julia
  @route(methods, path, func)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `methods` | `array` | **Required**. The types of HTTP requests to register to this route|
| `path` | `string` or `router()` | **Required**. The route to register |
| `func` | `function` | **Required**. The request handler for this route |

Low-level macro that allows a route to be handle multiple request types


#### staticfiles
```julia
  staticfiles(folder, mount)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `folder` | `string` | **Required**. The folder to serve files from |
| `mountdir` | `string` | The root endpoint to mount files under (default is "static")|
| `set_headers` | `function` | Customize the http response headers when returning these files |
| `loadfile` | `function` | Customize behavior when loading files |

Serve all static files within a folder. This function recursively searches a directory
and mounts all files under the mount directory using their relative paths.

#### dynamicfiles

```julia
  dynamicfiles(folder, mount)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `folder` | `string` | **Required**. The folder to serve files from |
| `mountdir` | `string` | The root endpoint to mount files under (default is "static")|
| `set_headers` | `function` | Customize the http response headers when returning these files |
| `loadfile` | `function` | Customize behavior when loading files |

Serve all static files within a folder. This function recursively searches a directory
and mounts all files under the mount directory using their relative paths. The file is loaded
on each request, potentially picking up any file changes.

#### spafiles

```julia
  spafiles(folder, mount)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `folder` | `string` | **Required**. The folder to serve files from |
| `mountdir` | `string` | The root endpoint to mount files under (default is "static")|
| `headers` | `Vector` | Custom headers for file responses |
| `loadfile` | `function` | Customize behavior when loading files |

Serve all static files within a folder with SPA History Mode fallback.
Any unmatched routes within the mount directory will serve `index.html`, enabling client-side routing.

### Request helper functions

#### html()
```julia
  html(content, status, headers)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `content` | `string` | **Required**. The string to be returned as HTML |
| `status` | `integer` | The HTTP response code (default is 200)|
| `headers` | `dict` | The headers for the HTTP response (default has content-type header set to "text/html; charset=utf-8") |

Helper function to designate when content should be returned as HTML


#### queryparams()
```julia
  queryparams(request)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `req` | `HTTP.Request` | **Required**. The HTTP request object |

Returns the query parameters from a request as a Dict()

### Body Functions

#### text()
```julia
  text(request)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `req` | `HTTP.Request` | **Required**. The HTTP request object |

Returns the body of a request as a string

#### binary()
```julia
  binary(request)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `req` | `HTTP.Request` | **Required**. The HTTP request object |

Returns the body of a request as a binary file (returns a vector of `UInt8`s)

#### json()
```julia
  json(request, class_type)
```
| Parameter | Type     | Description                |
| :-------- | :------- | :------------------------- |
| `req` | `HTTP.Request` | **Required**. The HTTP request object |
| `class_type` | `struct` | A struct to deserialize a JSON object into |

Deserialize the body of a request into a julia struct
