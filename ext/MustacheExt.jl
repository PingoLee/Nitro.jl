module MustacheExt

using HTTP
using MIMEs
using Mustache

import Nitro: mustache, Res
import Nitro.Util: response

export mustache

"""
    mustache(template::String; kwargs...)

Create a function that renders a Mustache `template` string with the provided `kwargs`.
If `template` is a file path, it reads the file content as the template string.
Returns a function that takes a dictionary `data`, optional `status`, and `headers`, and
returns an HTTP Response object with the rendered content.

The template is parsed **once, here**, not on every render. A malformed template — a tag left
open, or a section closed that was never opened or under another name — throws Mustache's
`ArgumentError` from this call, the way `otera` does, rather than failing every request. A `tags`
keyword (custom delimiters, e.g. `tags = ("<<", ">>")`) is spent on that parse; every other
keyword reaches each render, as before.

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
    return _parse_once(template; mime_type=mime_type, kwargs...)
end

# `Mustache.render(::String, …)` re-tokenizes its template on every call; this parses it once, when
# the handler is built, and serves every request from the tokens (#550). `tags` is the one keyword
# that render spent on parsing a string, so it stops here: passed on to the tokens method it would
# become a template variable.
function _parse_once(template::String; mime_type=nothing, tags=("{{", "}}"), kwargs...)
    return mustache(Mustache.parse(template, tags); mime_type=mime_type, kwargs...)
end

"""
    mustache(tokens::Mustache.MustacheTokens; kwargs...)

Create a function that renders a Mustache template defined by `tokens` with the provided `kwargs`.
Returns a function that takes a dictionary `data`, optional `status`, and `headers`, and
returns an HTTP Response object with the rendered content.

To get more info read the docs here: https://github.com/jverzani/Mustache.jl
"""
function mustache(tokens::Mustache.MustacheTokens; mime_type=nothing, kwargs...)
    return function(data::AbstractDict = Dict(); status=200, headers=Res.NO_HEADERS)
        content = Mustache.render(tokens, data; kwargs...)
        response(content, status, headers; content_type=mime_type)
    end 
end

"""
    mustache(file::IO; kwargs...)

Create a function that renders a Mustache template from a file `file` with the provided `kwargs`.
Returns a function that takes a dictionary `data`, optional `status`, and `headers`, and
returns an HTTP Response object with the rendered content.

The template is read and parsed once, here, as for `mustache(template::String)`: a malformed one
throws Mustache's `ArgumentError` from this call.

To get more info read the docs here: https://github.com/jverzani/Mustache.jl
"""
function mustache(file::IO; mime_type=nothing, kwargs...)
    return _parse_once(read(file, String); mime_type=mime_type, kwargs...)
end


end