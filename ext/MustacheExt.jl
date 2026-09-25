module MustacheExt

using HTTP
using MIMEs
using Mustache

import Nitro: mustache
import Nitro.Util: response

export mustache

"""
    mustache(template::String; kwargs...)

Create a function that renders a Mustache `template` string with the provided `kwargs`.
If `template` is a file path, it reads the file content as the template string.
Returns a function that takes a dictionary `data`, optional `status`, and `headers`, and
returns an HTTP Response object with the rendered content.

The response's `Content-Type` is a `Content-Type` in the per-call `headers` if there is one, else
`mime_type`, else a type sniffed from the rendered output (see `Nitro.Util.response`). Sniffing
never overrides a type you set: `render(data; headers = ["Content-Type" => "text/plain"])` stays
`text/plain` even when a `{{{triple-stashed}}}` value renders as `<script>`.

To get more info read the docs here: https://github.com/jverzani/Mustache.jl
"""
function mustache(template::String; mime_type=nothing, from_file=false, kwargs...)
    mime_is_known = !isnothing(mime_type)

    # Case 1: a path to a file was passed
    if from_file
        if mime_is_known
            return open(io -> mustache(io; mime_type=mime_type, kwargs...), template)
        else
            # deterime the mime type based on the extension type 
            content_type = mime_from_path(template, MIME"application/octet-stream"()) |> contenttype_from_mime
            return open(io -> mustache(io; mime_type=content_type, kwargs...), template)
        end
    end

    # Case 2: A string template was passed directly
    function(data::AbstractDict = Dict(); status=200, headers=[])
        content = Mustache.render(template, data; kwargs...)        
        response(content, status, headers; content_type=mime_type)
    end
end

"""
    mustache(tokens::Mustache.MustacheTokens; kwargs...)

Create a function that renders a Mustache template defined by `tokens` with the provided `kwargs`.
Returns a function that takes a dictionary `data`, optional `status`, and `headers`, and
returns an HTTP Response object with the rendered content.

To get more info read the docs here: https://github.com/jverzani/Mustache.jl
"""
function mustache(tokens::Mustache.MustacheTokens; mime_type=nothing, kwargs...)
    return function(data::AbstractDict = Dict(); status=200, headers=[])
        content = Mustache.render(tokens, data; kwargs...)
        response(content, status, headers; content_type=mime_type)
    end 
end

"""
    mustache(file::IO; kwargs...)

Create a function that renders a Mustache template from a file `file` with the provided `kwargs`.
Returns a function that takes a dictionary `data`, optional `status`, and `headers`, and
returns an HTTP Response object with the rendered content.

To get more info read the docs here: https://github.com/jverzani/Mustache.jl
"""
function mustache(file::IO; mime_type=nothing, kwargs...)
    template = read(file, String)
    return function(data::AbstractDict = Dict(); status=200, headers=[])
        content = Mustache.render(template, data; kwargs...)
        response(content, status, headers; content_type=mime_type)
    end
end


end