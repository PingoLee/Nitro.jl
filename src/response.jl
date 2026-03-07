module Res

using HTTP
import JSON

"""
    json(data; status=200, headers=[])

Return an HTTP.Response with the provided data serialized to JSON and the Content-Type header set to application/json.
"""
function json(data; status::Int=200, headers::Vector=[])
    json_headers = ["Content-Type" => "application/json; charset=utf-8"]
    for h in headers
        push!(json_headers, h)
    end
    return HTTP.Response(status, json_headers, body=JSON.json(data))
end

"""
    status(code::Int; headers=[])

Return an empty HTTP.Response with the specified status code.
"""
function status(code::Int; headers::Vector=[])
    return HTTP.Response(code, headers, body="")
end

"""
    send(body::String; status=200, headers=[])

Return an HTTP.Response with the provided string body and the Content-Type header set to text/plain.
"""
function send(body::String; status::Int=200, headers::Vector=[])
    text_headers = ["Content-Type" => "text/plain; charset=utf-8"]
    for h in headers
        push!(text_headers, h)
    end
    return HTTP.Response(status, text_headers, body=body)
end

end
