# Request Body 

Whenever you need to send data from a client to your API,  you send it as a request body.

A request body is data sent by the client to your API (usually JSON). A response body is the data your API sends to the client.

Request bodies are useful when you need to send more complicated information
to an API. Imagine we wanted to request an uber/lyft to come pick us up. The app (a client) will have to send a lot of information to make this happen. It'd need to send information about the user (like location data, membership info) and data about the destination. The api in turn will have to figure out pricing, available drivers and potential routes to take. 

The inputs of this api are pretty complicated which means it's a perfect case where we'd want to use the request body to send this information. You could send this kind of information through the URL, but I'd highly recommend you don't. Request bodies can store data in pretty much any format which is a lot more flexible than what a URL can support.


## Handler-first parsing

For normal handlers, Nitro extends `HTTP.Request` with body accessors:

- `req.json` for parsed JSON bodies
- `req.form` for parsed form bodies
- `req.input` for a merged view of path params, form data, JSON, and query parameters

`req.json` returns `nothing` on empty or malformed JSON. `req.form` returns an empty `Dict{String,String}` when the request does not contain form data.

```julia
using HTTP
using Nitro

struct Person
    name::String
    age::Int
end

function create_person(req::HTTP.Request)
    data = req.json
    if isnothing(data)
        return Res.send("Expected a JSON body", status=400)
    end

    return Res.json(Dict(
        "name" => data["name"],
        "age" => data["age"],
    ))
end

function create_person_form(req::HTTP.Request)
    form = req.form
    return Res.json(Dict(
        "name" => get(form, "name", "anonymous"),
        "age" => get(form, "age", "unknown"),
    ))
end

urlpatterns("",
    path("/create/json", create_person, method="POST"),
    path("/create/form", create_person_form, method="POST"),
)

serve()
```

## Typed extraction

If you want typed conversion and validation, use Nitro extractors. `LazyRequest` is still the internal/request-wrapper mechanism behind extractors, but handler code should generally prefer direct `HTTP.Request` accessors.

```julia
using HTTP
using Nitro

struct Person
    name::String
    age::Int
end

function create_typed(req::HTTP.Request, payload::Json{Person})
    person = payload.payload
    return Res.json(Dict("name" => person.name, "age" => person.age))
end

urlpatterns("",
    path("/create/typed", create_typed, method="POST"),
)

serve()
```

## Genie migration

If you are coming from Genie-style handlers, the easiest migration path is:

- replace body parsing helpers with `req.json` or `req.form`
- use `req.input` when you want one merged dictionary for simple CRUD handlers
- move to extractors when you need typed conversion or validation

If you still need manual parsing utilities outside a handler, the lower-level `json(req, T)` and `formdata(req)` helpers remain available.
