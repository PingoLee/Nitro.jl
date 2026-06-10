
module ExtractIPMiddleware
using HTTP
using Sockets
using ...Core: getip, setip!

export ExtractIP, extract_ip

"""
    ExtractIP(; trust_forwarded::Bool=false, trusted_proxies::Union{Nothing, Vector{IPAddr}}=nothing)

Middleware that extracts the client IP address and assigns it to `getip(req)`.

**Security:** client-supplied forwarding headers (`X-Forwarded-For`, `X-Real-IP`,
`CF-Connecting-IP`, `True-Client-IP`) are trivially spoofable. Any code that keys
on the client IP for a security decision (rate limiting, audit logging, allow/deny
lists) is only as trustworthy as the proxy in front of it. For that reason this
middleware **ignores forwarding headers by default** and uses the socket peer
address (`getip(req)`), which Nitro sets from the real TCP connection.

Enable header parsing only when you actually run behind a trusted reverse proxy:

- `trusted_proxies`: a list of proxy IPs. Forwarding headers are honored **only**
  when the direct socket peer is one of these addresses. This is the recommended,
  safe option (e.g. `trusted_proxies=[ip"127.0.0.1"]` for a local nginx/Caddy).
- `trust_forwarded=true`: trust forwarding headers from *any* peer. Only safe when
  the server is not directly reachable by clients (e.g. bound to a private network
  segment that only the proxy can reach).

If neither is set, the socket peer address is always used.

See [`extract_ip`](@ref) for the header priority order.
"""
function ExtractIP(; trust_forwarded::Bool=false, trusted_proxies::Union{Nothing, Vector{<:IPAddr}}=nothing)
    function(handle::Function)
        function(req::HTTP.Request)
            setip!(req, extract_ip(req; trust_forwarded, trusted_proxies))
            return handle(req)
        end
    end
end


"""
    extract_ip(req::HTTP.Request; trust_forwarded::Bool=false, trusted_proxies=nothing) :: IPAddr

Resolve the client IP address for `req`.

By default (no trust configured) this returns the socket peer address
`getip(req)` and **ignores** all forwarding headers, because those headers can be
set to any value by the client.

When the request arrives through a trusted proxy (see [`ExtractIP`](@ref)),
forwarding headers are consulted in priority order:

1. `CF-Connecting-IP` (Cloudflare)
2. `True-Client-IP` (Akamai/Enterprise proxies)
3. `X-Forwarded-For` (standard; may be a comma-separated list — the first entry is used)
4. `X-Real-IP` (Nginx/other proxies)

Any header that fails to parse as an IP address is skipped and the socket peer
address is used instead, so a malformed header can never crash the pipeline.
"""
function extract_ip(req::HTTP.Request;
    trust_forwarded::Bool=false,
    trusted_proxies::Union{Nothing, Vector{<:IPAddr}}=nothing) :: IPAddr

    peer = getip(req)

    # Decide whether the forwarding headers on this request can be trusted.
    headers_trusted = if !isnothing(trusted_proxies)
        # Only honor headers when the direct peer is a configured proxy.
        peer isa IPAddr && any(p -> p == peer, trusted_proxies)
    else
        trust_forwarded
    end

    if !headers_trusted
        return peer
    end

    return _extract_forwarded_ip(req, peer)
end

# Parse the highest-priority forwarding header that yields a valid IP address.
# Falls back to `peer` when no header is present or parseable.
function _extract_forwarded_ip(req::HTTP.Request, peer)::IPAddr
    cfip :: Union{String,Nothing} = nothing
    tci  :: Union{String,Nothing} = nothing
    xff  :: Union{String,Nothing} = nothing
    xri  :: Union{String,Nothing} = nothing

    for (k, v) in req.headers
        if isnothing(cfip) && HTTP.Messages.field_name_isequal(k, "CF-Connecting-IP")
            cfip = v
        elseif isnothing(tci) && HTTP.Messages.field_name_isequal(k, "True-Client-IP")
            tci = v
        elseif isnothing(xff) && HTTP.Messages.field_name_isequal(k, "X-Forwarded-For")
            xff = v
        elseif isnothing(xri) && HTTP.Messages.field_name_isequal(k, "X-Real-IP")
            xri = v
        end
    end

    # Priority order: Cloudflare → Akamai → X-Forwarded-For → X-Real-IP.
    ip = _try_parse_ip(cfip)
    !isnothing(ip) && return ip

    ip = _try_parse_ip(tci)
    !isnothing(ip) && return ip

    if !isnothing(xff) && !isempty(xff)
        # X-Forwarded-For is a list "client, proxy1, proxy2"; the client is first.
        ip = _try_parse_ip(strip(split(xff, ",")[1]))
        !isnothing(ip) && return ip
    end

    ip = _try_parse_ip(xri)
    !isnothing(ip) && return ip

    # No usable forwarding header — fall back to the socket peer.
    return peer
end

function _try_parse_ip(value::Union{AbstractString, Nothing})::Union{IPAddr, Nothing}
    (isnothing(value) || isempty(value)) && return nothing
    # `Sockets` provides `parse(::Type{IPAddr}, ...)` but no `tryparse` for the
    # abstract `IPAddr`, so guard against malformed input ourselves.
    return try
        parse(IPAddr, String(value))
    catch
        nothing
    end
end

end
