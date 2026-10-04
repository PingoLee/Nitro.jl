
module ExtractIPMiddleware
using HTTP
using Sockets
# `getpeerip` is not called here — this middleware writes `:peer_ip` and `getpeerip` reads it —
# but importing it lets the `@ref` cross-references in the docstrings below resolve.
using ...Core: getip, setip!, getpeerip, header_name_isequal
using ...Types: Nullable, REQUEST_FORWARDED_PROTO_KEY
using ...Errors: is_unrecoverable
# Byte-safe header-value helpers: malformed UTF-8 must not turn into a 500 (see their comment).
using ...Util: _ows_strip, _ascii_lower_eq

export ExtractIP, extract_ip

# The forwarding headers Nitro knows how to read, and the canonical name each maps to.
# Deliberately a CLOSED set: the operator names exactly one, and a typo is an ArgumentError
# rather than a header that silently never matches.
const _HEADER_NAMES = (
    x_forwarded_for  = "X-Forwarded-For",
    x_real_ip        = "X-Real-IP",
    cf_connecting_ip = "CF-Connecting-IP",
    true_client_ip   = "True-Client-IP",
    forwarded        = "Forwarded",
)

# The protocol headers Nitro knows how to read (#374) — closed for the same reason. RFC 7239
# `Forwarded` is in both sets (#383) and is read by ONE walk for both halves, so the address and
# the scheme always come from the same element (see `_walk_forwarded`).
const _PROTO_HEADERS = (
    x_forwarded_proto = "X-Forwarded-Proto",
    forwarded         = "Forwarded",
)

# How the address header is read: one value the proxy wrote, the X-Forwarded-For chain, or the
# RFC 7239 element list.
@enum _AddrFormat::UInt8 _SINGLE _XFF_CHAIN _RFC7239

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
    header        :: Nullable{String}    # canonical header name; `nothing` when `:none`
    format        :: _AddrFormat         # how `header` is read
    proxies       :: Vector{_IPPrefix}   # empty exactly when no trust is configured
    proto         :: Nullable{String}    # canonical protocol header name; `nothing` when `:none`
    proto_rfc7239 :: Bool                # the scheme comes from `Forwarded: proto=`
end

const _NO_TRUST = _TrustPolicy(nothing, _SINGLE, _IPPrefix[], nothing, false)

"""
    ExtractIP(; forwarded_header::Symbol = :none, forwarded_proto::Symbol = :none, trusted_proxies = nothing)

Middleware that resolves the client IP address and assigns it to `getip(req)`, preserving the
socket peer address under [`getpeerip`](@ref). With `forwarded_proto` it also records the scheme a
trusted proxy reports, which is what lets a WebSocket upgrade pass its Origin check behind a proxy
that terminates TLS (see *Behind a TLS-terminating proxy* below).

**Security:** client-supplied forwarding headers are trivially spoofable. Anything that keys on
the client IP for a security decision — rate limiting, audit logging, allow/deny lists — is only
as trustworthy as the proxy in front of it. This middleware therefore **ignores forwarding
headers by default** and uses the socket peer address, which Nitro sets from the real TCP
connection.

To read a forwarding header you must declare **both** where the trust boundary is
(`trusted_proxies`) and **which headers** your proxy writes (`forwarded_header` for the address,
`forwarded_proto` for the scheme). A boundary with neither header named, and a header with no
boundary, are each an `ArgumentError` — the first reads nothing, and the second honors the header
from any client. Exactly one address header is ever read; every other forwarding header is
ignored, so a proxy that forgets to strip `CF-Connecting-IP` cannot be used to bypass your
`X-Forwarded-For` configuration.

# Keyword Arguments
- `forwarded_header::Symbol`: the one address header your proxy writes. One of `:none` (default,
  no header is read), `:x_forwarded_for`, `:x_real_ip`, `:cf_connecting_ip`, `:true_client_ip`,
  `:forwarded` (RFC 7239 `Forwarded: for=`).
- `forwarded_proto::Symbol`: the header your proxy writes the client's scheme into. One of
  `:none` (default), `:x_forwarded_proto`, `:forwarded` (RFC 7239 `Forwarded: proto=`).
- `trusted_proxies`: the proxies whose forwarding headers may be believed. Entries are either an
  `IPAddr` (`ip"127.0.0.1"`) or a CIDR string (`"10.244.0.0/16"`, `"2400:cb00::/32"`). A header
  is read **only** when the nearest hop the chain has established matches one of them: the
  socket peer, unless an earlier extractor already resolved a client (see *More than one
  extractor in a chain* below).

# Behind a TLS-terminating proxy
A browser on `https://app.example.com` opens its WebSocket with `Origin: https://app.example.com`,
but the proxy reaches Nitro over plain TCP, so the upgrade's same-origin check sees a secure origin
on an insecure connection and refuses it with `403`. `forwarded_proto = :x_forwarded_proto` tells
it which scheme the client really used: from a trusted proxy, `https` (or `wss`) makes the check
compare against `https://<Host>`, `http` (or `ws`) against `http://<Host>`. The leftmost value
counts when `X-Forwarded-Proto` carries a list, and a value that is none of those four is ignored.
With `forwarded_proto = :forwarded` the `proto=` that counts is the one in the same `Forwarded`
element as the client's address — see [`extract_ip`](@ref).

The scheme is not a way around the check. It only chooses which scheme of *your own host* counts
as same-origin, so it can never admit a page from another site — and a browser page cannot set the
header on a WebSocket handshake in the first place. **Do not strip `Origin` at the proxy instead**:
that turns the check off, and with it the only protection against cross-site WebSocket hijacking.
A page served from a genuinely different origin is listed with [`WebSocketOrigins`](@ref Nitro.Core.Middleware.WebSocketOriginsMiddleware.WebSocketOrigins).

# Your proxy must *set*, not forward, the header
`X-Real-IP`, `CF-Connecting-IP` and `True-Client-IP` are single-valued: Nitro believes whatever
the trusted proxy wrote. If your proxy passes a client-supplied value straight through, the
client controls it. Configure the proxy to overwrite it (nginx: `proxy_set_header X-Real-IP
\$remote_addr`), and strip the forwarding headers you do *not* use so downstream tooling isn't
fooled either.

`X-Forwarded-For` is a chain (`client, proxy1, proxy2`) and is handled differently: Nitro walks
it right-to-left, discarding hops that match `trusted_proxies`, and takes the first address that
is not one of your proxies. Entries a client prepends are therefore never reached. The RFC 7239
`Forwarded` header is a chain too, walked the same way. See [`extract_ip`](@ref) for the exact
rules.

# More than one extractor in a chain
A chain can hold several, and the usual way is a global `ExtractIP` plus a `RateLimiter` at its
default `auto_extract_ip = true`, which builds its own. Extractors **chain**:

- the socket peer is recorded once, by the first extractor, and never overwritten, so
  [`getpeerip`](@ref) is always the address that actually connected (#330);
- each extractor judges `trusted_proxies` against `getip` as the chain left it: the socket peer
  for the first, the client an earlier extractor resolved for a later one;
- so a later extractor with no trust configured, or one that does not trust the resolved client,
  leaves `getip` as it found it — a `RateLimiter` with its own `trusted_proxies` behind a global
  `ExtractIP` keys on the same client;
- and a later extractor that *does* trust the resolved address peels one more hop, reading its
  own header. That is how two tiers with different headers compose: an `ExtractIP` trusting your
  nginx on `:x_real_ip` resolves the CDN edge nginx saw, and a second one trusting the CDN's
  ranges on `:cf_connecting_ip` resolves the client the CDN saw.

A later tier believes its header from **any** address in its ranges, including one that
connected to Nitro directly and that the tier before it therefore never resolved. Make sure only
the first tier can reach Nitro: bind it to loopback behind nginx, or firewall it.

Chaining is for tiers that write *different* headers. For one `X-Forwarded-For` chain through
several proxies, use a single extractor whose `trusted_proxies` lists every one of them: a second
`:x_forwarded_for` extractor walks the whole header again with only its own list, and stops at
the first inner proxy that list does not name.

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

# A local nginx terminating TLS, with WebSocket routes behind it
ExtractIP(forwarded_header = :x_forwarded_for, forwarded_proto = :x_forwarded_proto,
          trusted_proxies  = [ip"127.0.0.1"])

# A proxy that writes only the RFC 7239 header: `Forwarded: for=192.0.2.60;proto=https`
ExtractIP(forwarded_header = :forwarded, forwarded_proto = :forwarded,
          trusted_proxies  = [ip"127.0.0.1"])
```
"""
function ExtractIP(;
    forwarded_header :: Symbol                   = :none,
    forwarded_proto  :: Symbol                   = :none,
    trusted_proxies  :: Nullable{AbstractVector} = nothing,
    trust_forwarded                              = nothing)

    policy = _trust_policy(forwarded_header, trusted_proxies, trust_forwarded, forwarded_proto)
    function(handle::Function)
        function(req::HTTP.Request)
            # The nearest hop the chain has established: the socket peer for the first
            # extractor, the client an earlier one resolved for a later one. Trust is judged
            # against it, so extractors chain -- see "More than one extractor" above.
            peer = getip(req)
            # Recorded once, by the first extractor, while `:ip` still is the socket peer. A
            # later one used to re-record whatever `:ip` held by then (#330), which made a
            # forwarded address the "socket peer" an audit trail relies on to spot a forged
            # header. A global `ExtractIP` plus a `RateLimiter` at its default
            # `auto_extract_ip = true` is exactly that chain.
            peer === nothing || haskey(req.context, :peer_ip) || (req.context[:peer_ip] = peer)
            # Judged against the same hop as the address header, and BEFORE `_resolve` moves
            # `getip` on: the proxy that wrote the scheme is the one this extractor trusts.
            policy.proto === nothing || _record_forwarded_proto!(req, policy, peer)
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

It resolves from `getip(req)` as the chain left it, which is the socket peer unless an `ExtractIP`
earlier in the chain already resolved a client — the same chaining [`ExtractIP`](@ref) documents.
With no trust configured this returns that address and **ignores every forwarding header**,
because those headers can be set to any value by the client.

When `trusted_proxies` is configured *and* that address matches one of them, the single header
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

RFC 7239 `Forwarded` (`for=203.0.113.7;proto=https, for="[2001:db8::1]:4711"`) is a chain of
*elements*, each written by one proxy about the connection it received. It is walked
**right-to-left** under the same rules as `X-Forwarded-For`, using each element's `for=`:

- an element whose `for=` names one of your proxies is peeled, and the walk continues left;
- the first `for=` that is *not* one of your proxies is the client;
- an element that cannot be read (bad syntax, a repeated parameter, an unterminated quote), and a
  `for=` that is missing, `unknown`, obfuscated (`_hidden`) or not an address, stop the walk and
  yield the peer;
- parameter names are case-insensitive, values may be quoted, and a port is stripped as above.

The line is split **from the right**, and only as far as the walk goes, so whatever a client
writes before your proxy's element — an unterminated `"` or malformed bytes included — cannot
change how that element is read. Never have the proxy interpolate a client-controlled value
(`host=\$host`) into the header: that can inject an element to the *right* of yours.

The scheme (`forwarded_proto = :forwarded`) is the `proto=` of the element the walk stopped at:
the one that names the client. Your trusted proxy wrote that element about the connection the
client opened, so its `proto=` is the scheme the client used. A client can prepend elements of its
own but never reach that one, which is why this is not `X-Forwarded-Proto`'s leftmost rule. That
header is a separate list with nothing binding it to an address. An element with no usable `for=`
still supplies its `proto=`, so a proxy that writes only `Forwarded: proto=https` works. If every
`for=` is one of your proxies, the leftmost element supplies it.

An address resolved *out of a header* is canonicalized (an IPv4-mapped `::ffff:203.0.113.7`
becomes `203.0.113.7`), so one host cannot occupy several buckets. The **peer is returned exactly
as the server observed it** — this function never rewrites what `serve` seeded. Since #66 it does
not need to: `serve` seeds an already-canonical address, so a direct client and the same host
arriving through a proxy key the same way, and `getip` and [`getpeerip`](@ref) still agree when no
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
    policy.header === nothing && return peer        # trust for the scheme only (#374)

    pv6, ph = _norm(peer)
    _is_trusted(policy, pv6, ph) || return peer     # direct client — headers are ignored

    policy.format === _RFC7239 && return first(_walk_forwarded(req, policy, peer))

    raw = _header_value(req, policy.header::String, policy.format === _XFF_CHAIN)
    raw === nothing && return peer

    policy.format === _XFF_CHAIN && return _walk_chain(raw, policy, peer)

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
        isempty(_ows_strip(parts[i])) && continue
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

# Record the scheme a trusted proxy reports (#374), for the WebSocket upgrade's Origin check.
# Only ever WRITES the key: an extractor that does not trust its hop leaves an earlier one's
# answer alone, exactly as `_resolve` leaves `getip` alone.
function _record_forwarded_proto!(req::HTTP.Request, policy::_TrustPolicy, peer)::Nothing
    peer isa IPAddr || return nothing
    pv6, ph = _norm(peer)
    _is_trusted(policy, pv6, ph) || return nothing
    scheme = if policy.proto_rfc7239
        last(_walk_forwarded(req, policy, peer))
    else
        raw = _header_value(req, policy.proto::String, true)
        raw === nothing ? nothing : _forwarded_scheme(raw)
    end
    scheme === nothing || (req.context[REQUEST_FORWARDED_PROTO_KEY] = scheme)
    return nothing
end

# The scheme the client used at the edge, from X-Forwarded-Proto: the LEFTMOST value, which is
# how Django's `SECURE_PROXY_SSL_HEADER` and Express's `trust proxy` read a list. Spoofing the
# leftmost value buys nothing a browser page could use: it only chooses which scheme of this
# server's own host is same-origin, and a page cannot set the header on a WebSocket handshake at
# all. `Forwarded` does better than leftmost — see `_walk_forwarded`.
function _forwarded_scheme(raw::AbstractString)::Nullable{String}
    comma = findfirst(==(','), raw)
    return _scheme_token(comma === nothing ? raw : raw[firstindex(raw):prevind(raw, comma)])
end

# Traefik writes `ws`/`wss` on upgrade requests, so those fold onto their HTTP schemes; anything
# else is not a scheme this server can be reached over and is ignored rather than guessed at.
function _scheme_token(value::Nullable{AbstractString})::Nullable{String}
    value === nothing && return nothing
    token = _ows_strip(value)
    all(isascii, token) || return nothing
    token = lowercase(token)
    (token == "https" || token == "wss") && return "https"
    (token == "http"  || token == "ws")  && return "http"
    return nothing
end

# ── RFC 7239 `Forwarded` (#383) ────────────────────────────────────────────────────────────

# One element, reduced to the two parameters Nitro reads. `ok = false` is an element that could
# not be read; the walk stops at it.
struct _FwdElement
    ok    :: Bool
    for_  :: Nullable{SubString{String}}
    proto :: Nullable{SubString{String}}
end

const _FWD_UNREADABLE = _FwdElement(false, nothing, nothing)

# Walk `Forwarded` right-to-left and return `(client, scheme)` in one pass, so the address and the
# scheme always come from the SAME element. Element i was written by a hop already known to be
# trusted -- the peer for the rightmost one, then each peeled `for=` -- so the element the walk
# stops at was written by your own proxy about the connection the client opened, and its
# `proto=` is the scheme the client used. The leftmost `proto=` is client-writable; this one is
# not, which is why `X-Forwarded-Proto`'s leftmost rule is not reused here.
#
# The stop rules are `_walk_chain`'s: anything unreadable yields the peer rather than letting the
# walk step past it. An element with no usable `for=` still yields its `proto=` -- a trusted hop
# wrote it -- so `Forwarded: proto=https` alone works for a scheme-only configuration.
function _walk_forwarded(req::HTTP.Request, policy::_TrustPolicy,
                         peer::IPAddr)::Tuple{IPAddr, Nullable{String}}
    raw = _header_value(req, "Forwarded", true)
    raw === nothing && return (peer, nothing)
    s = String(raw)
    i = ncodeunits(s)
    seen = false
    leftmost :: Nullable{SubString{String}} = nothing   # `proto=` of the last element peeled
    while i >= 1
        el, i = _prev_forwarded_element(s, i)
        el === nothing && continue                  # a blank element (`,,`): no payload
        el.ok || return (peer, nothing)             # unreadable -- stop trusting the chain
        ip = _forwarded_node(el.for_)
        ip === nothing && return (peer, _scheme_token(el.proto))
        v6, h = _norm(ip)
        _is_trusted(policy, v6, h) || return (_canonical(ip), _scheme_token(el.proto))
        seen, leftmost = true, el.proto
    end
    # Every `for=` was one of ours (or there were no elements): the request originated inside
    # your own infrastructure. The leftmost element still says how it reached the edge.
    return (peer, seen ? _scheme_token(leftmost) : nothing)
end

# A `for=` node (RFC 7239 §6): an address, possibly bracketed and with a port, or `unknown`, or an
# obfuscated `_identifier`. Only an address resolves.
function _forwarded_node(value::Nullable{AbstractString})::Nullable{IPAddr}
    value === nothing && return nothing
    v = _ows_strip(value)
    (isempty(v) || startswith(v, '_') || _ascii_lower_eq(v, "unknown")) && return nothing
    return _try_parse_ip(_normalize_entry(v))
end

# Read the element that ENDS at byte `i` of a (possibly multi-line, comma-joined) `Forwarded`
# value, scanning RIGHT-TO-LEFT, and return it with the byte where the next element to its left
# ends (0 when there is none). `nothing` is a blank element.
#
# Why from the right: a quoted-string carries state, so a left-to-right split lets whatever comes
# first decide how everything after it is read. A client that sends `Forwarded: for="` -- an
# unterminated quote -- would swallow the element your proxy appends, and HTTP.jl folds ADJACENT
# duplicate lines into one value (`appendheader`), so sending it as a separate line does not
# isolate it. Scanning from the right, the proxy's well-formed suffix is split first and exactly:
# inside a quoted-string a `"` is escaped iff an odd number of backslashes precede it, so the
# backward split agrees with the forward grammar on any well-formed text.
#
# One element per call, so the walk parses nothing left of where it stops: text a client wrote
# there is never even looked at, whatever bytes it holds. Delimiters are ASCII, so scanning code
# units is safe for any UTF-8 -- or any invalid UTF-8 -- in a value.
function _prev_forwarded_element(s::String, i::Int)::Tuple{Nullable{_FwdElement}, Int}
    cu = codeunits(s)
    for_  :: Nullable{SubString{String}} = nothing
    proto :: Nullable{SubString{String}} = nothing
    nonblank = false                                # the element held at least one pair
    stop = i                                        # last byte of the pair being scanned
    inq = false
    while i >= 1
        c = cu[i]
        if inq
            if c == UInt8('"')
                j = i - 1
                while j >= 1 && cu[j] == UInt8('\\')
                    j -= 1
                end
                if isodd(i - 1 - j)                 # an escaped quote: content, keep going
                    i = j
                    continue
                end
                inq = false                         # the opening quote
            end
        elseif c == UInt8('"')
            inq = true                              # a closing quote, seen from the right
        elseif c == UInt8(',') || c == UInt8(';')
            ok, for_, proto, nonblank = _forwarded_pair(s, i + 1, stop, for_, proto, nonblank)
            ok || return (_FWD_UNREADABLE, 0)
            c == UInt8(',') && return (nonblank ? _FwdElement(true, for_, proto) : nothing, i - 1)
            stop = i - 1
        end
        i -= 1
    end
    # Still inside a quote at the left edge: an unterminated quoted-string. Nothing past it can
    # be read.
    inq && return (_FWD_UNREADABLE, 0)
    ok, for_, proto, nonblank = _forwarded_pair(s, 1, stop, for_, proto, nonblank)
    ok || return (_FWD_UNREADABLE, 0)
    return (nonblank ? _FwdElement(true, for_, proto) : nothing, 0)
end

# Parse one `name=value` pair occupying bytes `a:b` of `s` and fold it into the element's state.
# An empty pair (`for=x;` or a blank element) is allowed by RFC 7239's grammar and skipped.
# Returns `ok = false` for anything the grammar does not allow, including a repeated `for`/`proto`
# (§4: a parameter MUST NOT occur more than once per element).
function _forwarded_pair(s::String, a::Int, b::Int, for_::Nullable{SubString{String}},
                         proto::Nullable{SubString{String}}, nonblank::Bool)
    pair = b < a ? SubString(s, 1, 0) : _ows_strip(SubString(s, a, thisind(s, b)))
    isempty(pair) && return (true, for_, proto, nonblank)
    eq = findfirst(==('='), pair)
    eq === nothing && return (false, for_, proto, nonblank)
    name  = _ows_strip(SubString(pair, firstindex(pair), prevind(pair, eq)))
    value = _forwarded_value(_ows_strip(SubString(pair, nextind(pair, eq), lastindex(pair))))
    (isempty(name) || !all(_is_tchar, name) || value === nothing) &&
        return (false, for_, proto, nonblank)
    key = lowercase(name)                           # ASCII: every char is a tchar
    if key == "for"
        for_ === nothing || return (false, for_, proto, nonblank)
        for_ = value
    elseif key == "proto"
        proto === nothing || return (false, for_, proto, nonblank)
        proto = value
    end                                             # `by`, `host`, extensions: not read
    return (true, for_, proto, true)
end

# A value is a token or a quoted-string. A quoted-string is checked FORWARD here, so a value the
# backward split accepted but the grammar does not (`"abc\"`) is still refused. Unquoted values
# are taken leniently -- some proxies write `for=[2001:db8::1]` without the quotes the RFC asks
# for -- but never with a stray `"`, and never empty.
function _forwarded_value(v::AbstractString)::Nullable{SubString{String}}
    isempty(v) && return nothing
    if startswith(v, '"')
        buf = IOBuffer()
        i = nextind(v, firstindex(v))
        while i <= lastindex(v)
            c = v[i]
            if c == '\\'
                i = nextind(v, i)
                i > lastindex(v) && return nothing
                print(buf, v[i])
            elseif c == '"'
                i == lastindex(v) || return nothing  # text after the closing quote
                return SubString(String(take!(buf)))
            else
                print(buf, c)
            end
            i = nextind(v, i)
        end
        return nothing                              # no closing quote
    end
    occursin('"', v) && return nothing
    return SubString(String(v))
end

# RFC 9110 §5.6.2 tchar.
_is_tchar(c::AbstractChar) =
    isascii(c) && (isletter(c) || isdigit(c) || c in "!#\$%&'*+-.^_`|~")

# Resolve a header to a single value, in one pass.
#
# RFC 9110 §5.3: repeated field lines are equivalent to the single comma-joined value, in order.
# HTTP.jl only folds duplicates that are ADJACENT (`appendheader`, http_core.jl:953 — it compares
# against `entries[end]`), so a client-sent `X-Forwarded-For` separated from the proxy-appended
# one by any other field survives as its own entry. Reading only the first would hand the client
# control of the result, which is the very bug #16 is about; HAProxy's `option forwardfor` appends
# a new header line rather than rewriting, so this is a live configuration, not a theoretical one.
#
# For a chain header every instance is kept, joined in order, so the right-to-left walk sees the
# whole path. For a single-valued header the LAST instance wins: proxies append or replace, so
# the last one present is the one written closest to us.
#
# `HTTP.header` is not usable here: it returns the FIRST instance only, and this needs every
# instance joined, or the last one.
function _header_value(req::HTTP.Request, name::String, join_all::Bool)::Nullable{String}
    val = nothing
    for (k, v) in req.headers
        header_name_isequal(k, name) || continue
        val = val === nothing ? String(v) :
              join_all        ? string(val, ", ", v) : String(v)
    end
    return val
end

# An unspecified address (`0.0.0.0`, `::`, and `::ffff:0.0.0.0`, which `_norm` folds onto the
# first) is never a proxy, whatever `trusted_proxies` says. No connection has it as its peer: it
# is what `_peer_ip` records when it could NOT read the peer (src/core/transport.jl, #404), so
# trusting it would hand the forwarding header to every client whose address was lost. Refused
# here, at the one check `_resolve`, `_walk_chain`, `_walk_forwarded` and
# `_record_forwarded_proto!` all go through, rather than by rejecting entries: a range like
# `"0.0.0.0/8"` stays a valid entry for the addresses it really covers.
_is_trusted(policy::_TrustPolicy, v6::Bool, host::UInt128) =
    !iszero(host) && any(p -> p.v6 === v6 && (host & p.mask) == p.net, policy.proxies)

# Strip a port and/or brackets so a proxy that writes `203.0.113.7:1234` or `[2001:db8::1]:443`
# still parses. A bare IPv6 address has at least two colons, so the single-colon test is
# unambiguous.
function _normalize_entry(s::AbstractString)::String
    t = _ows_strip(s)
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
    catch e
        # A malformed address is `nothing`; the three in `is_unrecoverable` are not (#254).
        # `parse(IPAddr, …)` does not recurse, so no request input reaches this block with
        # one of them -- this ships for consistency, and deliberately without a test, since
        # any test written for it would pass against the unpatched code too.
        is_unrecoverable(e) && rethrow()
        nothing
    end
end

# ── Address normalization ──────────────────────────────────────────────────────────────────

# The address as it should be reported to callers and used as a bucket key. `::ffff:203.0.113.7`
# and `203.0.113.7` are the same host, and `_is_trusted` already treats them as one — without
# this the *returned* value would still differ, splitting one client across several rate-limit
# buckets and several access-log spellings.
#
# This owns the HEADER-derived half only. The socket peer is canonicalized by
# `_ipaddr_from_bytes` in src/core/transport.jl, where the OS's bytes become a Julia value (#66);
# the two are deliberately separate, since Core must not depend upward on this module and the
# inputs differ (raw bytes vs. a parsed address). Keep the `::ffff:0:0/96` rule below in step
# with that copy.
_canonical(a::IPv4) = a
function _canonical(a::IPv6)
    v6, h = _norm(a)
    return v6 ? a : IPv4(UInt32(h))
end

_norm(a::IPv4) = (false, UInt128(a.host))

function _norm(a::IPv6)
    h = a.host
    # ::ffff:0:0/96 — IPv4-mapped. DO NOT DELETE THIS BRANCH. Since #66 the socket peer
    # arrives already demoted from `_ipaddr_from_bytes` (src/core/transport.jl), so the case
    # this comment used to cite — a dual-stack listener whose mapped peer failed to match
    # `trusted_proxies=[ip"127.0.0.1"]` — can no longer arise from the transport. Three live
    # callers still depend on the fold, and none of them sees a transport-seeded address:
    #   * `_walk_chain` (:196) — a hop a proxy wrote into X-Forwarded-For as `::ffff:10.0.0.8`;
    #   * `_parse_prefix` (:368/:379/:387) — a mapped literal or CIDR in `trusted_proxies`;
    #   * `_resolve` (:171) — a peer a custom middleware wrote with `setip!`.
    # Removing it would stop `_is_trusted` recognizing a mapped hop, so the walk would fall
    # back to the proxy's own address and collapse every client behind it into one bucket.
    # The deprecated IPv4-compatible `::a.b.c.d` form is NOT demoted — it is not a reliable
    # indicator of an IPv4 peer. Keep this rule in step with `_ipaddr_from_bytes`.
    (h >> 32) == 0x0000_0000_0000_ffff && return (false, h & 0xffff_ffff)
    return (true, h)
end

_full_mask(v6::Bool) = v6 ? typemax(UInt128) : UInt128(typemax(UInt32))

# ── Construction-time validation ───────────────────────────────────────────────────────────

function _trust_policy(forwarded_header::Symbol, trusted_proxies, trust_forwarded,
                       forwarded_proto::Symbol = :none)::_TrustPolicy
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
            ":x_forwarded_for, :x_real_ip, :cf_connecting_ip, :true_client_ip and :forwarded " *
            "(RFC 7239) — declare the " *
            "ONE header your reverse proxy writes."
        ))
    end

    # V1b — the same closed-set rule for the protocol header (#374).
    if forwarded_proto !== :none && !haskey(_PROTO_HEADERS, forwarded_proto)
        throw(ArgumentError(
            "ExtractIP misconfiguration: forwarded_proto=:$(forwarded_proto) is not a " *
            "recognized protocol header. A typo would silently disable it instead of failing, " *
            "so it is rejected at construction. Valid values are :none, :x_forwarded_proto " *
            "and :forwarded (RFC 7239)."
        ))
    end

    has_proxies = trusted_proxies !== nothing
    has_header  = forwarded_header !== :none
    has_proto   = forwarded_proto !== :none

    # V2 — a trust boundary with no header named reads nothing at all.
    if has_proxies && !has_header && !has_proto
        throw(ArgumentError(
            "ExtractIP misconfiguration: trusted_proxies cannot be combined with " *
            "forwarded_header=:none. Trusting a proxy without saying WHICH header it writes " *
            "means no header is ever read, so every client behind the proxy collapses onto the " *
            "proxy's own address and shares one rate-limit bucket while the setting looks " *
            "active. Set forwarded_header to the single header your proxy writes, e.g. " *
            "forwarded_header=:x_forwarded_for (or, on `ExtractIP`, set " *
            "forwarded_proto=:x_forwarded_proto if the proxy's scheme is all you need)."
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

    # V3b — the same rule for the scheme: a direct client writes whatever it likes.
    if has_proto && !has_proxies
        throw(ArgumentError(
            "ExtractIP misconfiguration: forwarded_proto=:$(forwarded_proto) cannot be used " *
            "without trusted_proxies. A client connecting directly can send that header " *
            "with any value, so honoring it from any peer would let the client choose the " *
            "scheme the WebSocket Origin check compares against. List the addresses or CIDR " *
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
    # A scheme-only policy has no address header: `_resolve` returns the peer for it.
    header = has_header ? _HEADER_NAMES[forwarded_header] : nothing
    proto  = has_proto  ? _PROTO_HEADERS[forwarded_proto] : nothing
    format = forwarded_header === :x_forwarded_for ? _XFF_CHAIN :
             forwarded_header === :forwarded       ? _RFC7239   : _SINGLE
    return _TrustPolicy(header, format, prefixes, proto, forwarded_proto === :forwarded)
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
