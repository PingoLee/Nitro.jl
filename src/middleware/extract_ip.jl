
module ExtractIPMiddleware
using HTTP
using Sockets
# `getpeerip` is not called here — this middleware writes `:peer_ip` and `getpeerip` reads it —
# but importing it lets the `@ref` cross-references in the docstrings below resolve.
using ...Core: getip, setip!, getpeerip, header_name_isequal
using ...Types: Nullable

export ExtractIP, extract_ip

# The forwarding headers Nitro knows how to read, and the canonical name each maps to.
# Deliberately a CLOSED set: the operator names exactly one, and a typo is an ArgumentError
# rather than a header that silently never matches.
const _HEADER_NAMES = (
    x_forwarded_for  = "X-Forwarded-For",
    x_real_ip        = "X-Real-IP",
    cf_connecting_ip = "CF-Connecting-IP",
    true_client_ip   = "True-Client-IP",
)

# A trusted-proxy entry, normalized to a family-tagged network/mask pair. IPv4 lives in the low
# 32 bits of `net`/`mask`; `v6` keeps the families apart so `0.0.0.0/0` can never match `::/0`.
struct _IPPrefix
    net  :: UInt128
    mask :: UInt128
    v6   :: Bool
end

# The whole trust configuration, resolved and validated once at construction so the request
# path is a few integer comparisons with no `Any` (nitro-core §7).
struct _TrustPolicy
    header  :: Nullable{String}    # canonical header name; `nothing` when `:none`
    is_list :: Bool                # true only for X-Forwarded-For, which carries a chain
    proxies :: Vector{_IPPrefix}   # empty exactly when no trust is configured
end

const _NO_TRUST = _TrustPolicy(nothing, false, _IPPrefix[])

"""
    ExtractIP(; forwarded_header::Symbol = :none, trusted_proxies = nothing)

Middleware that resolves the client IP address and assigns it to `getip(req)`, preserving the
socket peer address under [`getpeerip`](@ref).

**Security:** client-supplied forwarding headers are trivially spoofable. Anything that keys on
the client IP for a security decision — rate limiting, audit logging, allow/deny lists — is only
as trustworthy as the proxy in front of it. This middleware therefore **ignores forwarding
headers by default** and uses the socket peer address, which Nitro sets from the real TCP
connection.

To read a forwarding header you must declare **both** where the trust boundary is
(`trusted_proxies`) and **which single header** your proxy writes (`forwarded_header`). Setting
either alone is an `ArgumentError` — a trust boundary with no header reads nothing, and a header
with no boundary honors it from any client. Exactly one header is ever read; every other
forwarding header is ignored, so a proxy that forgets to strip `CF-Connecting-IP` cannot be used
to bypass your `X-Forwarded-For` configuration.

# Keyword Arguments
- `forwarded_header::Symbol`: the one header your proxy writes. One of `:none` (default, no
  header is read), `:x_forwarded_for`, `:x_real_ip`, `:cf_connecting_ip`, `:true_client_ip`.
- `trusted_proxies`: the proxies whose forwarding header may be believed. Entries are either an
  `IPAddr` (`ip"127.0.0.1"`) or a CIDR string (`"10.244.0.0/16"`, `"2400:cb00::/32"`). The
  header is read **only** when the socket peer matches one of them.

# Your proxy must *set*, not forward, the header
`X-Real-IP`, `CF-Connecting-IP` and `True-Client-IP` are single-valued: Nitro believes whatever
the trusted proxy wrote. If your proxy passes a client-supplied value straight through, the
client controls it. Configure the proxy to overwrite it (nginx: `proxy_set_header X-Real-IP
\$remote_addr`), and strip the forwarding headers you do *not* use so downstream tooling isn't
fooled either.

`X-Forwarded-For` is a chain (`client, proxy1, proxy2`) and is handled differently: Nitro walks
it right-to-left, discarding hops that match `trusted_proxies`, and takes the first address that
is not one of your proxies. Entries a client prepends are therefore never reached. See
[`extract_ip`](@ref) for the exact rules.

# Examples
```julia
# Not behind a proxy — the socket peer is the client. This is the default.
ExtractIP()

# Local nginx/Caddy writing X-Forwarded-For
ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = [ip"127.0.0.1"])

# Kubernetes: the ingress pod IP changes per rollout, so trust the pod CIDR
ExtractIP(forwarded_header = :x_forwarded_for, trusted_proxies = ["10.244.0.0/16"])

# Cloudflare in front of a local nginx that sets X-Real-IP from its own peer
ExtractIP(forwarded_header = :x_real_ip, trusted_proxies = [ip"127.0.0.1"])
```
"""
function ExtractIP(;
    forwarded_header :: Symbol                   = :none,
    trusted_proxies  :: Nullable{AbstractVector} = nothing,
    trust_forwarded                              = nothing)

    policy = _trust_policy(forwarded_header, trusted_proxies, trust_forwarded)
    function(handle::Function)
        function(req::HTTP.Request)
            peer = getip(req)
            # Preserve the address that actually connected before `:ip` is overwritten, so an
            # audit trail can still tell a proxied request from a direct one.
            peer === nothing || (req.context[:peer_ip] = peer)
            resolved = _resolve(req, policy, peer)
            resolved === nothing || setip!(req, resolved)
            return handle(req)
        end
    end
end


"""
    extract_ip(req::HTTP.Request; forwarded_header::Symbol = :none, trusted_proxies = nothing) -> Union{IPAddr, Nothing}

Resolve the client IP address for `req`. Returns `nothing` only when the request carries no peer
address at all (a hand-constructed request that never went through the server).

With no trust configured this returns the socket peer address and **ignores every forwarding
header**, because those headers can be set to any value by the client.

When `trusted_proxies` is configured *and* the socket peer matches one of them, the single header
named by `forwarded_header` is read — and nothing else.

# Resolution rules
`X-Real-IP`, `CF-Connecting-IP`, `True-Client-IP` carry one address, written by the trusted
proxy; it is used as-is, falling back to the peer if it does not parse. If the header appears
more than once the **last** instance wins — proxies append or replace, so the last one present
is the one written closest to us.

`X-Forwarded-For` carries a chain and is walked **right-to-left**:

- a blank entry (from `,,` or a trailing comma) is skipped;
- an entry that does not parse aborts the walk and yields the peer — the chain cannot be trusted
  past a value we cannot read, and skipping it would hand back whatever the client prepended;
- the header may appear on several lines; per RFC 9110 §5.3 they are treated as one chain, joined
  in order, so a client-sent line cannot shadow the one your proxy appended;
- an entry matching `trusted_proxies` is a known hop and the walk continues left;
- the first entry that is *not* one of your proxies is the client;
- if every entry was a trusted proxy the peer is returned, since the request originated inside
  your own infrastructure.

Entries may carry a port (`203.0.113.7:1234`, `[2001:db8::1]:443`); it is stripped before
parsing. Falling back to the peer degrades gracefully — clients behind the proxy share one
rate-limit bucket — rather than letting a client choose its own address.

An address resolved *out of a header* is canonicalized (an IPv4-mapped `::ffff:203.0.113.7`
becomes `203.0.113.7`), so one host cannot occupy several buckets. The **peer is returned exactly
as the server observed it** — this function never rewrites what `serve` seeded. On a dual-stack
listener that means a direct client can be keyed as `::ffff:203.0.113.7` while the same host
arriving through a proxy is keyed as `203.0.113.7`; they are separate paths into the server, and
preserving the socket's own spelling keeps `getip` and [`getpeerip`](@ref) agreeing when no
header was read.

See [`ExtractIP`](@ref) for configuration and [`getpeerip`](@ref) for the preserved socket peer.
"""
function extract_ip(req::HTTP.Request;
    forwarded_header :: Symbol                   = :none,
    trusted_proxies  :: Nullable{AbstractVector} = nothing,
    trust_forwarded                              = nothing) :: Nullable{IPAddr}

    policy = _trust_policy(forwarded_header, trusted_proxies, trust_forwarded)
    return _resolve(req, policy, getip(req))
end

# ── Resolution (request hot path) ──────────────────────────────────────────────────────────

function _resolve(req::HTTP.Request, policy::_TrustPolicy, peer)::Nullable{IPAddr}
    peer isa IPAddr || return nothing
    isempty(policy.proxies) && return peer          # no trust configured — never read a header

    pv6, ph = _norm(peer)
    _is_trusted(policy, pv6, ph) || return peer     # direct client — headers are ignored

    raw = _header_value(req, policy.header::String, policy.is_list)
    raw === nothing && return peer

    policy.is_list && return _walk_chain(raw, policy, peer)

    ip = _try_parse_ip(_normalize_entry(raw))
    return ip === nothing ? peer : _canonical(ip)
end

# Walk X-Forwarded-For from the right, peeling hops we recognize as our own proxies.
function _walk_chain(raw::AbstractString, policy::_TrustPolicy, peer::IPAddr)::IPAddr
    parts = split(raw, ',')
    for i in length(parts):-1:1
        # Blankness is decided on the RAW token: `",,"` and a trailing comma are common proxy
        # quirks and carry no payload. A NON-blank token that normalizes to nothing (`"[]"`) is
        # opaque and must abort like any other unreadable hop — skipping it would let an
        # attacker step over the boundary entry and reach a value they prepended.
        isempty(strip(parts[i])) && continue
        entry = _normalize_entry(parts[i])
        isempty(entry) && return peer               # unreadable hop — stop trusting the chain
        ip = _try_parse_ip(entry)
        ip === nothing && return peer               # opaque hop — stop trusting the chain here
        v6, h = _norm(ip)
        # First address that isn't ours: the client. Returned in canonical form so the four
        # spellings of one host can't become four rate-limit buckets.
        _is_trusted(policy, v6, h) || return _canonical(ip)
    end
    return peer                                     # every hop was a trusted proxy
end

# Resolve a header to a single value, in one pass.
#
# RFC 9110 §5.3: repeated field lines are equivalent to the single comma-joined value, in order.
# HTTP.jl only folds duplicates that are ADJACENT (`appendheader`, http_core.jl:902 — it compares
# against `entries[end]`), so a client-sent `X-Forwarded-For` separated from the proxy-appended
# one by any other field survives as its own entry. Reading only the first would hand the client
# control of the result, which is the very bug #16 is about; HAProxy's `option forwardfor` appends
# a new header line rather than rewriting, so this is a live configuration, not a theoretical one.
#
# For a chain header every instance is kept, joined in order, so the right-to-left walk sees the
# whole path. For a single-valued header the LAST instance wins: proxies append or replace, so
# the last one present is the one written closest to us.
#
# `HTTP.header` is not usable here — it canonicalizes only the key it is given and then compares
# with `==`, so it misses a lowercase `cf-connecting-ip`.
function _header_value(req::HTTP.Request, name::String, join_all::Bool)::Nullable{String}
    val = nothing
    for (k, v) in req.headers
        header_name_isequal(k, name) || continue
        val = val === nothing ? String(v) :
              join_all        ? string(val, ", ", v) : String(v)
    end
    return val
end

_is_trusted(policy::_TrustPolicy, v6::Bool, host::UInt128) =
    any(p -> p.v6 === v6 && (host & p.mask) == p.net, policy.proxies)

# Strip a port and/or brackets so a proxy that writes `203.0.113.7:1234` or `[2001:db8::1]:443`
# still parses. A bare IPv6 address has at least two colons, so the single-colon test is
# unambiguous.
function _normalize_entry(s::AbstractString)::String
    t = strip(s)
    isempty(t) && return ""
    if startswith(t, '[')
        j = findfirst(==(']'), t)
        j === nothing && return String(t)
        return String(t[nextind(t, firstindex(t)):prevind(t, j)])
    end
    if count(==(':'), t) == 1 && occursin('.', t)
        return String(t[firstindex(t):prevind(t, findfirst(==(':'), t))])
    end
    return String(t)
end

function _try_parse_ip(value::Union{AbstractString, Nothing})::Nullable{IPAddr}
    (isnothing(value) || isempty(value)) && return nothing
    # `Sockets` provides `parse(::Type{IPAddr}, ...)` but no `tryparse` for the abstract
    # `IPAddr`, so guard against malformed input ourselves.
    return try
        parse(IPAddr, String(value))
    catch
        nothing
    end
end

# ── Address normalization ──────────────────────────────────────────────────────────────────

# The address as it should be reported to callers and used as a bucket key. `::ffff:203.0.113.7`
# and `203.0.113.7` are the same host, and `_is_trusted` already treats them as one — without
# this the *returned* value would still differ, splitting one client across several rate-limit
# buckets and several access-log spellings.
_canonical(a::IPv4) = a
function _canonical(a::IPv6)
    v6, h = _norm(a)
    return v6 ? a : IPv4(UInt32(h))
end

_norm(a::IPv4) = (false, UInt128(a.host))

function _norm(a::IPv6)
    h = a.host
    # ::ffff:0:0/96 — IPv4-mapped. A dual-stack listener reports IPv4 peers this way on some
    # platforms; without demoting, `trusted_proxies=[ip"127.0.0.1"]` would silently fail to
    # match a real loopback proxy. The deprecated IPv4-compatible `::a.b.c.d` form is NOT
    # demoted — it is not a reliable indicator of an IPv4 peer.
    (h >> 32) == 0x0000_0000_0000_ffff && return (false, h & 0xffff_ffff)
    return (true, h)
end

_full_mask(v6::Bool) = v6 ? typemax(UInt128) : UInt128(typemax(UInt32))

# ── Construction-time validation ───────────────────────────────────────────────────────────

function _trust_policy(forwarded_header::Symbol, trusted_proxies, trust_forwarded)::_TrustPolicy
    # Security: `trust_forwarded=true` honored forwarding headers from ANY peer, with the header
    # guessed from a fixed priority list — which let a direct client pick its own IP. It has no
    # replacement mode; naming the proxies is now the only way to enable header parsing.
    if trust_forwarded !== nothing
        throw(ArgumentError(
            "ExtractIP misconfiguration: `trust_forwarded` was removed. It trusted forwarding " *
            "headers from every peer and guessed which header to read, so a client connecting " *
            "directly could choose the IP used for rate limiting, audit logs and allow/deny " *
            "lists. Name the proxies you trust and the one header they write instead, e.g. " *
            "`ExtractIP(forwarded_header=:x_forwarded_for, trusted_proxies=[ip\"127.0.0.1\"])`; " *
            "`trusted_proxies` accepts CIDR strings when your proxy addresses are dynamic."
        ))
    end

    # V1 — a typo here would silently never match, so reject it rather than degrade.
    if forwarded_header !== :none && !haskey(_HEADER_NAMES, forwarded_header)
        throw(ArgumentError(
            "ExtractIP misconfiguration: forwarded_header=:$(forwarded_header) is not a " *
            "recognized forwarding header. A typo would silently disable proxy support " *
            "instead of failing, so it is rejected at construction. Valid values are :none, " *
            ":x_forwarded_for, :x_real_ip, :cf_connecting_ip and :true_client_ip — declare the " *
            "ONE header your reverse proxy writes."
        ))
    end

    has_proxies = trusted_proxies !== nothing
    has_header  = forwarded_header !== :none

    # V2 — a trust boundary with no header named reads nothing at all.
    if has_proxies && !has_header
        throw(ArgumentError(
            "ExtractIP misconfiguration: trusted_proxies cannot be combined with " *
            "forwarded_header=:none. Trusting a proxy without saying WHICH header it writes " *
            "means no header is ever read, so every client behind the proxy collapses onto the " *
            "proxy's own address and shares one rate-limit bucket while the setting looks " *
            "active. Set forwarded_header to the single header your proxy writes, e.g. " *
            "forwarded_header=:x_forwarded_for."
        ))
    end

    # V3 — Security: a header with no trust boundary is honored from any peer, which is exactly
    # the spoofing this middleware exists to prevent.
    if has_header && !has_proxies
        throw(ArgumentError(
            "ExtractIP misconfiguration: forwarded_header=:$(forwarded_header) cannot be used " *
            "without trusted_proxies. Forwarding headers are set by the client on a direct " *
            "connection, so honoring one from any peer hands the client control of the IP used " *
            "for rate limiting, audit logs and allow/deny lists. List the addresses or CIDR " *
            "ranges of your proxies, e.g. trusted_proxies=[ip\"127.0.0.1\"]."
        ))
    end

    has_proxies || return _NO_TRUST

    # V4 — an empty list trusts nobody, which looks configured but behaves like the default.
    if isempty(trusted_proxies)
        throw(ArgumentError(
            "ExtractIP misconfiguration: trusted_proxies cannot be empty. An empty list trusts " *
            "no peer, so the declared forwarding header is never read and the setting looks " *
            "active while doing nothing. List your proxy addresses or CIDR ranges, or drop " *
            "both keywords to key on the socket peer."
        ))
    end

    prefixes = Vector{_IPPrefix}(undef, length(trusted_proxies))
    for (i, entry) in enumerate(trusted_proxies)
        prefixes[i] = _parse_prefix(entry)
    end
    return _TrustPolicy(_HEADER_NAMES[forwarded_header], forwarded_header === :x_forwarded_for, prefixes)
end

function _parse_prefix(entry)::_IPPrefix
    if entry isa IPAddr
        v6, h = _norm(entry)
        return _IPPrefix(h, _full_mask(v6), v6)
    end

    entry isa AbstractString || throw(ArgumentError(_bad_entry_message(entry)))
    s = strip(entry)
    slash = findfirst(==('/'), s)

    if slash === nothing
        addr = _try_parse_ip(String(s))
        addr === nothing && throw(ArgumentError(_bad_entry_message(entry)))
        v6, h = _norm(addr)
        return _IPPrefix(h, _full_mask(v6), v6)
    end

    addr = _try_parse_ip(String(s[firstindex(s):prevind(s, slash)]))
    len  = tryparse(Int, String(s[nextind(s, slash):lastindex(s)]))
    (addr === nothing || len === nothing) && throw(ArgumentError(_bad_entry_message(entry)))

    v6, h = _norm(addr)
    # An IPv4-mapped literal written with a prefix (`::ffff:10.0.0.0/104`) demotes to IPv4, so
    # the prefix length must be rebased out of the /96 mapped block.
    if !v6 && addr isa IPv6
        len >= 96 || throw(ArgumentError(
            "ExtractIP misconfiguration: trusted_proxies entry $(repr(entry)) is an " *
            "IPv4-mapped address with a prefix shorter than /96, which would span more than " *
            "the IPv4 range it maps to. Write the range in IPv4 form instead, e.g. " *
            "\"10.0.0.0/8\"."
        ))
        len -= 96
    end

    bits = v6 ? 128 : 32
    (0 <= len <= bits) || throw(ArgumentError(
        "ExtractIP misconfiguration: trusted_proxies entry $(repr(entry)) has an out-of-range " *
        "prefix length. IPv4 prefixes must be /0-/32 and IPv6 prefixes /0-/128."
    ))

    full = _full_mask(v6)
    mask = len == 0 ? UInt128(0) : ((full << (bits - len)) & full)

    # V7 — Security: the CIDR analogue of a wildcard CORS origin. A catch-all range trusts the
    # forwarding header from every peer on the internet, which is precisely the spoofing the
    # trusted_proxies gate exists to prevent.
    if mask == 0
        throw(ArgumentError(
            "ExtractIP misconfiguration: trusted_proxies cannot contain the catch-all range " *
            "$(repr(entry)). It trusts the forwarding header from every peer, which is exactly " *
            "the spoofing the trusted_proxies gate exists to prevent. List the real address " *
            "ranges your proxies use."
        ))
    end

    return _IPPrefix(h & mask, mask, v6)
end

_bad_entry_message(entry) =
    "ExtractIP misconfiguration: trusted_proxies entry $(repr(entry)) is not an IP address or " *
    "CIDR range. A silently-skipped entry would leave a proxy untrusted and collapse its " *
    "clients onto one rate-limit bucket. Entries must be an `IPAddr` (e.g. ip\"127.0.0.1\") or " *
    "a string in CIDR form (e.g. \"10.0.0.0/8\", \"2400:cb00::/32\")."

end
