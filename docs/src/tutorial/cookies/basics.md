# Working with Cookies

Cookies are fundamental for maintaining state in web applications. Nitro provides a secure and flexible interface for handling them, including automatic encryption, configuration defaults, and protection against common attacks (XSS/CSRF).

## Quick Start

```julia
using Nitro

# The key comes from the environment, never from source, and must be at least 32 random
# bytes. Generate one once: julia -e 'using Nitro; println(bytes2hex(Nitro.Crypto.secure_random_bytes(32)))'
configcookies(secret_key = SecretString(ENV["COOKIE_SECRET"]))

# 1. Set a cookie — encrypted, because a key is configured
function save_theme(req)
    res = Res.send("Theme saved")
    set_cookie!(res, "theme", get(getquery(req), "theme", "light"), maxage=30 * 24 * 3600)
    return res
end

# 2. Read it back — decrypted. A cookie that does not open reads as the default.
function preferences(req)
    theme = get_cookie(req, "theme", "light")
    return Res.json(Dict("theme" => theme))
end

urlpatterns("",
    path("/theme", save_theme, method="POST"),
    path("/preferences", preferences, method="GET"),
)

serve()
```

!!! warning "Do not keep who the user is in a cookie"
    A cookie — encrypted or not — is the wrong place for a login. Nitro cannot revoke it, so a
    copy keeps working after logout until it expires, and a cookie with no key is plain text
    the client can simply rewrite. For identity use
    [`SessionMiddleware`](sessions.md), where the cookie is only a random id and the data
    stays on the server, or a JWT with an `exp` claim — see
    [Sessions and Auth](../sessions_and_auth.md). Use cookies for preferences and other state
    that is harmless in the client's hands.

## Basic Usage

### Setting Cookies

To set a cookie, use the `set_cookie!` function on an `HTTP.Response` object.

```julia
set_cookie!(response, name, value; kwargs...)
```

| Argument | Description | Default |
|---|---|---|
| `response` | The `HTTP.Response` object to modify | Required |
| `name` | Name of the cookie (String) | Required |
| `value` | Value to store (String, Int, Bool) | Required |
| `maxage` | Lifetime in seconds — also enforced on the server for an encrypted cookie | `nothing` (Session) |
| `httponly` | Prevent JavaScript access | `true` |
| `encrypted` | Encrypt the value | `true` when a `secret_key` is configured, else `false` |

**Example:**
```julia
res = Res.send("Cookie set")

# Simple value, readable by JavaScript
set_cookie!(res, "theme", "dark", httponly=false, encrypted=false)

# Encrypted value
set_cookie!(res, "cart", "item-17,item-42", encrypted=true, maxage=86400)
```

### Reading Cookies

To read a cookie, use `get_cookie` with the `HTTP.Request`.

```julia
value = get_cookie(request, name, default=nothing; encrypted)
```

`encrypted` defaults to whether a `secret_key` is configured. An encrypted value is bound to the
cookie's name and to the lifetime it was set with; one that does not open (tampered, expired,
sealed under another key or for another cookie) reads as `default`. See
[Cookie Security](security.md) for the details.

**Examples:**
```julia
# Get raw string
theme = get_cookie(req, "theme", "light"; encrypted=false)

# Get encrypted value (automatically decrypts)
cart = get_cookie(req, "cart"; encrypted=true)

# Get with type conversion
count = get_cookie(req, "counter", 0) # returns Int
```

### Removing Cookies (Logout)

To "delete" a cookie, you set its `maxage` to `0`. This tells the browser to expire it immediately.

```julia
function clear_cart(req)
    res = Res.send("Cart cleared")

    # Overwrite the cookie with empty data and immediate expiration
    set_cookie!(res, "cart", "", maxage=0)

    return res
end

urlpatterns("",
    path("/cart/clear", clear_cart, method="POST"),
)
```
