module Res

using HTTP
using MIMEs: MIME, mime_from_path, contenttype_from_mime
import JSON

function apply_headers!(response::HTTP.Response, headers)
    for header in headers
        HTTP.setheader(response, header)
    end
    return response
end

function content_disposition(filename::String, disposition::String)
    return string(disposition, "; filename=\"", filename, "\"")
end

"""
    json(data; status=200, headers=[])

Return an HTTP.Response with the provided data serialized to JSON and the Content-Type header set to application/json.
"""
function json(data; status::Int=200, headers::Vector=[])
    response = HTTP.Response(status, body=JSON.json(data))
    HTTP.setheader(response, "Content-Type" => "application/json; charset=utf-8")
    apply_headers!(response, headers)
    return response
end

"""
    status(code::Int; headers=[])

Return an empty HTTP.Response with the specified status code.
"""
function status(code::Int; headers::Vector=[])
    response = HTTP.Response(code, body="")
    apply_headers!(response, headers)
    return response
end

"""
    send(body::String; status=200, headers=[])

Return an HTTP.Response with the provided string body and the Content-Type header set to text/plain.
"""
function send(body::String; status::Int=200, headers::Vector=[])
    response = HTTP.Response(status, body=body)
    HTTP.setheader(response, "Content-Type" => "text/plain; charset=utf-8")
    apply_headers!(response, headers)
    return response
end

"""
    file(path; status=200, headers=[], filename=nothing, disposition="attachment", loadfile=nothing)

Return an HTTP.Response for a file download, setting Content-Type, Content-Length,
and Content-Disposition. Custom headers are applied last and may override defaults.
"""
function file(path::String; status::Int=200, headers::Vector=[], filename=nothing, disposition::String="attachment", loadfile=nothing)
    body = isnothing(loadfile) ? read(path) : loadfile(path)
    response = HTTP.Response(status, body=body)
    resolved_filename = isnothing(filename) ? basename(path) : filename
    content_type = mime_from_path(path, MIME"application/octet-stream"()) |> contenttype_from_mime

    HTTP.setheader(response, "Content-Type" => content_type)
    HTTP.setheader(response, "Content-Length" => string(length(body)))
    HTTP.setheader(response, "Content-Disposition" => content_disposition(resolved_filename, disposition))
    apply_headers!(response, headers)
    return response
end

"""
    redirect(url; status=302, headers=[])

Return an HTTP redirect response with the Location header set.
"""
function redirect(url::String; status::Int=302, headers::Vector=[])
    response = HTTP.Response(status, body="")
    HTTP.setheader(response, "Location" => url)
    apply_headers!(response, headers)
    return response
end

end
