@testsetup module NitroCommon

using Test
using HTTP
using HTTP.WebSockets
using Nitro
using Dates
using JSON
using UUIDs
using Sockets
using Suppressor

import Nitro: PACKAGE_DIR, ServerContext, Nullable, HOFRouter
import Nitro: GET, POST, PUT, DELETE, PATCH, STREAM, WEBSOCKET

export HOST, PORT, localhost
export values_present, value_absent, value_count, has_property
export get_free_port

# ── Constants ────────────────────────────────────────────────────────

const HOST = "127.0.0.1"
const PORT = 6060
const localhost = "http://$HOST:$PORT"

# ── Test helpers (from test_utils.jl) ────────────────────────────────

"""
    values_present(dict, key, values)

Asserts that the passed dictionary both safely contains the specified key,
and all the passed values are found in that collection.
Collection may contain additional values.
"""
function values_present(dict, key, values)
    return haskey(dict, key) && all(x -> x in dict[key], values)
end

"""
    value_count(dict, key, value)
Returns occurence count of value in collection specified by key
"""
function value_count(dict, key, value)
    if !haskey(dict, key)
        return 0
    end
    return count(x -> x == value, dict[key])
end

"""
    value_absent(dict, key, value)

Tests that specified value is not found in the collection referenced
by the key on the dict, or that key's value in Dict is missing.
"""
function value_absent(dict, key, value)
    if !haskey(dict, key)
        return true
    end
    return !any(x -> x == value, dict[key])
end

"""
    has_property(object, propertyName)

Test that generated OpenAPI schema object defintion has the specified property.
Safely check that `properties` key exists on dictionary first
"""
function has_property(object::Dict, propertyName::String)
    return haskey(object, "properties") && haskey(object["properties"], propertyName)
end

"""
    get_free_port() -> Int

Find an available TCP port by briefly binding to port 0 and reading
the OS-assigned port number.
"""
function get_free_port()
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(getsockname(server)[2])
    close(server)
    return port
end

end # module NitroCommon
