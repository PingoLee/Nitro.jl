module OteraEngineExt

using HTTP
using MIMEs
using OteraEngine

import Nitro: otera
import Nitro.Util: response

export otera

"""
    otera(template::String; kwargs...)

Create a function that renders an Otera `template` string with the provided `kwargs`.
If `template` is a file path, it reads the file content as the template string.
Returns a function that takes a dictionary `data` (default is an empty dictionary),
optional `status`, `headers`, and `template_kwargs`, and returns an HTTP Response object
with the rendered content.

The response's `Content-Type` is a `Content-Type` in the per-call `headers` if there is one, else
`mime_type`, else a type sniffed from the rendered output (see `Nitro.Util.response`). Sniffing
never overrides a type you set. Rendered output is markup. `{{ x }}` is HTML-escaped by default
(OteraEngine's `autoescape = true`). Two things render a value raw: the `safe` filter
(`{{ x |> safe }}`), and a template built with `config = Dict("autoescape" => false)`. Keep both
away from user-influenced data, or serve the output with a non-markup type.

To get more info read the docs here: https://github.com/MommaWatasu/OteraEngine.jl
"""
function otera(template::String; mime_type=nothing, from_file=false, kwargs...)
    mime_is_known = !isnothing(mime_type)

    # Case 1: a path to a file was passed
    if from_file
        if mime_is_known
            return open(io -> otera(io; mime_type=mime_type, kwargs...), template)
        else
            # deterime the mime type based on the extension type 
            content_type = mime_from_path(template, MIME"application/octet-stream"()) |> contenttype_from_mime
            return open(io -> otera(io; mime_type=content_type, kwargs...), template)
        end
    end

    # Case 2: A string template was passed directly
    tmp = Template(template, path=from_file; kwargs...)
    return function(data = nothing; status=200, headers=[], template_kwargs...)
        combined_kwargs = Dict{Symbol, Any}(template_kwargs)
        if data !== nothing
            combined_kwargs[:init] = data
        end
        content = tmp(; combined_kwargs...)
        response(content, status, headers; content_type=mime_type)
    end
end


"""
    otera(file::IO; kwargs...)

Create a function that renders an Otera template from a file `file` with the provided `kwargs`.
Returns a function that takes a dictionary `data`, optional `status`, `headers`, and `template_kwargs`,
and returns an HTTP Response object with the rendered content.

To get more info read the docs here: https://github.com/MommaWatasu/OteraEngine.jl
"""
function otera(file::IO; mime_type=nothing, kwargs...)
    template = read(file, String)
    tmp = Template(template, path=false; kwargs...)
    
    return function(data = nothing; status=200, headers=[], template_kwargs...)
        combined_kwargs = Dict{Symbol, Any}(template_kwargs)
        if data !== nothing
            combined_kwargs[:init] = data
        end
        content = tmp(; combined_kwargs...)
        response(content, status, headers; content_type=mime_type)
    end
end

end