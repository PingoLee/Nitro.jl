# Internals

!!! warning "Not public API"
    Nothing on this page is exported by `Nitro`. These are helpers that Nitro's own submodules
    export to each other, and they can change or disappear in any release without an
    [`upgrading/`](../upgrading.md) entry. They are rendered because the docs build requires
    every docstring that any Nitro module exports to appear somewhere, which is what makes a
    public name with a docstring missing from the manual fail the build instead of going
    unnoticed.

    If you find yourself depending on one of these, that is a gap in the public API worth an issue.

## Routing And Server

```@docs
Nitro.Core.Routing.convert_django_path
Nitro.Core.RouterHOF.router
Nitro.Core.RouterHOF.HOFRouter
Nitro.Core.RouterHOF.OuterRouter
Nitro.Core.RouterHOF.InnerRouter
Nitro.Core.RouterHOF.compose
Nitro.Core.RouterHOF.genkey
Nitro.Core.RouterHOF.process_middleware
Nitro.Core.RouterHOF.register_route_lifecycle!
Nitro.Core.RouterHOF.register_serve_lifecycle!
Nitro.Core.RouterHOF.lifecycle_snapshot
Nitro.Core.RouterHOF.normalize_middleware
Nitro.Core.Types.ChainCache
Nitro.Core.Types.cached_chain
Nitro.Core.Handlers.select_handler
Nitro.Core.Handlers.first_arg_type
Base.close(::Nitro.Core.AppContext.Service)
```

## Binding, Responses And Files

```@docs
Nitro.Core.Reflection.struct_builder
Nitro.Core.Reflection.splitdef
Nitro.Core.Util.parseparam
Nitro.Core.Util.parseparam_checked
Nitro.Core.Util.parsebody
Nitro.Core.Util.response
Nitro.Core.Util.add_response_headers
Nitro.Core.Util.own_response_headers
Nitro.Core.Util.header_name_isequal
Nitro.Core.Util.join_url_path
Nitro.Core.Util.readfile
Nitro.Core.Util.mountable_files
Nitro.Core.Util.mountfolder
```

## Shared Helpers

```@docs
Nitro.Core.Types.require_fixed_period
Nitro.Core.Crypto.secure_random_bytes
Nitro.Core.Crypto.secure_uuid4
Nitro.Core.Crypto.encrypt_payload
Nitro.Core.Crypto.decrypt_payload
```
