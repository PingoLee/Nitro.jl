# Cookies And Sessions API

## Cookies

[`configcookies`](@ref) sets an app's cookie defaults, including the `secret_key` that turns on
encryption; [`get_cookie`](@ref) and [`set_cookie!`](@ref) then read and write through them. The
guides are [Working with Cookies](../tutorial/cookies/basics.md),
[Cookie Configuration](../tutorial/cookies/configuration.md) and
[Cookie Security](../tutorial/cookies/security.md).

```@docs
configcookies
get_cookie
set_cookie!
```

## Sessions

```@docs
SessionMiddleware
SessionPruner
regenerate_session!
AbstractSessionStore
Nitro.Core.Types.SessionPayload
MemoryStore
is_expired
Nitro.Core.Types.update_session!
Nitro.Core.Types.rotate_session!
Nitro.Core.Types.cleanup_expired_sessions!
Nitro.Core.Types.missing_session_methods
Nitro.Errors.StoreInterfaceError
Nitro.pormg_nitro_session
```

## The `Cookies` Module

`Nitro.Cookies` is the layer [`get_cookie`](@ref) and [`set_cookie!`](@ref) are built on. Its
functions take the cookie configuration and secret explicitly instead of reading them off an app,
which is what a middleware or a test that owns no `App` needs.

```@docs
Nitro.Core.Types.CookieConfig
Nitro.Cookies.get_cookie
Nitro.Cookies.set_cookie!
Nitro.Cookies.parse_cookies
Nitro.Cookies.format_cookie
Nitro.Cookies.load_cookie_settings!
Nitro.Cookies.storesession!
Nitro.Cookies.prunesessions!
```
