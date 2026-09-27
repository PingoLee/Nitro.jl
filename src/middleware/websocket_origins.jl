module WebSocketOriginsMiddleware

using HTTP
using ...Types: WebSocketOriginPolicy, REQUEST_WS_ORIGINS_KEY

export WebSocketOrigins

"""
    WebSocketOrigins(origins::AbstractVector{<:AbstractString})

Let WebSocket upgrades from the listed cross-origin pages through, alongside this server's own
origin (#382). Every upgrade passes a same-origin check on the browser's `Origin` — the only
defense against cross-site WebSocket hijacking, where a page on another site opens a socket that
rides your users' cookies. An SPA served from a different origin than its API
(`https://app.example.com` talking to `https://api.example.com`, or a CDN host) is refused by that
check; list its origin here instead of weakening the check.

This middleware only records the list for the handshake. It rejects nothing itself, and it does not
touch ordinary HTTP requests —
[`Cors`](@ref Nitro.Core.Middleware.CORSMiddleware.Cors) governs those, and does **not** govern
WebSocket handshakes.

```julia
# Every WebSocket route in the app:
serve(middleware = [WebSocketOrigins(["https://app.example.com"])])

# Only where it is needed:
urlpatterns("",
    path("/ws/chat", chat; method = "WEBSOCKET",
         middleware = [WebSocketOrigins(["https://app.example.com"])]),
)
```

- **Matching is exact** on scheme, host and port: `https://app.example.com` does not admit
  `http://app.example.com`, `https://app.example.com:8443`, or `https://evil-app.example.com`.
  A default port may be written or left out: `https://app.example.com:443` is the same entry.
- **Same-origin always stays allowed**, and a handshake with no `Origin` (a non-browser client)
  passes as before.
- **The layer closest to the route wins.** A route-level `WebSocketOrigins` replaces a global or
  router-level one rather than adding to it, and `WebSocketOrigins(String[])` narrows a route back
  to same-origin only.
- Entries are checked when the middleware is built, and a malformed one is an `ArgumentError`:
  `*`, `null`, a `ws://`/`wss://` scheme (a browser sends the page's `http(s)` scheme), a path — a
  trailing `/` included — a query, a fragment, a user, or a non-ASCII host (write its punycode
  `xn--` form, which is what a browser sends). So is any spelling a browser never sends and that
  could therefore never match: a trailing `.`, or an IPv4 address other than four plain decimals.

Behind a proxy that terminates TLS, same-origin additionally needs
`ExtractIP(forwarded_proto = …)`; listed origins do not depend on it. See
"WebSocket upgrades and the Origin check" in the reverse-proxy tutorial.
"""
function WebSocketOrigins(origins::AbstractVector{<:AbstractString})
    policy = WebSocketOriginPolicy(origins)
    return function (handle::Function)
        return function (req::HTTP.Request)
            req.context[REQUEST_WS_ORIGINS_KEY] = policy
            return handle(req)
        end
    end
end

end
