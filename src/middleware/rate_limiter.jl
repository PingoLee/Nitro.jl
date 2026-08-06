module RateLimiterMiddleware
using HTTP
using Dates
using Sockets
using LRUCache
using ...Core: getip, header_name_isequal, own_response_headers

# Import top level types module
using ...Types 
using ..ExtractIPMiddleware: ExtractIP

export RateLimiter

# Response returned when the limiter fails closed (its default). Built fresh per
# call so callers can't mutate a shared response object's headers.
SERVICE_UNAVAILABLE() = HTTP.Response(503, "Service Unavailable")

function RateLimiter(;strategy::Symbol = :fixed_window, kwargs...)
    # The element type is load-bearing: `Dict(kwargs)` narrows to the value type it happens to
    # see, so `RateLimiter(rate_limit=100)` built a `Dict{Symbol, Int64}` and missed the
    # `Dict{Symbol, Any}` signatures below with a `MethodError`. Only calls mixing two unrelated
    # value types widened to `Any` and worked, which is why the tests never caught it.
    kwargs_dict = Dict{Symbol, Any}(kwargs)

    # setup alias for :window_period => :window (for backwards compatibility for v1.9.0)
    rename_key!(kwargs_dict, :window_period, :window; message = "The :window_period keyword argument was renamed to :window")

    # `trust_forwarded` was removed here as well as on `ExtractIP` (#16). Deleting a keyword
    # outright leaves only Julia's bare "unsupported keyword argument", which names no
    # replacement, so reject it explicitly — this is a migration error, not a compatibility shim.
    reject_key!(kwargs_dict, :trust_forwarded,
        "RateLimiter: `trust_forwarded` was removed. It honored forwarding headers from every " *
        "peer and guessed which header to read, so a client connecting directly could choose " *
        "the IP its rate-limit bucket keyed on. Name the proxies you trust and the one header " *
        "they write instead, e.g. `RateLimiter(rate_limit=100, " *
        "forwarded_header=:x_forwarded_for, trusted_proxies=[ip\"127.0.0.1\"])`; " *
        "`trusted_proxies` accepts CIDR strings when your proxy addresses are dynamic.")

    # Return the rate limiter middleware
    dispatch_rate_limiter(Val(strategy); kwargs_dict...)
end

# Call the RateLimiter based on the strategy
dispatch_rate_limiter(::Val{:fixed_window}; kwargs...) = FixedRateLimiter(;kwargs...)
dispatch_rate_limiter(::Val{:sliding_window}; kwargs...) = SlidingRateLimiter(;kwargs...)

"""
Updates the key name inside a dictionary
"""
function rename_key!(kwargs_dict::Dict{Symbol, Any}, old_key::Symbol, new_key::Symbol; message::Union{String,Nothing}=nothing)
    if haskey(kwargs_dict, old_key)
        # show any custom warning message for this rename case
        if !isnothing(message) 
            @warn message
        end
        # remove and reassign value to new key
        kwargs_dict[new_key] = pop!(kwargs_dict, old_key)
    end
end

"""
Rejects a keyword that was removed outright, with a message naming what replaced it.

`rename_key!`'s sibling for the case where there is no new key to forward the value to.
"""
function reject_key!(kwargs_dict::Dict{Symbol, Any}, key::Symbol, message::String)
    haskey(kwargs_dict, key) && throw(ArgumentError(message))
end

"""
Builds the `ExtractIP` middleware the limiter composes in front of itself, or `nothing` when
`auto_extract_ip=false`.

`ExtractIP` is the only thing that acts on `forwarded_header`/`trusted_proxies`. Building it here
rather than inside the composed middleware moves its `ArgumentError` from `serve()` to
`RateLimiter(...)`, where the offending call actually is. With `auto_extract_ip=false` there is
nothing to build, so both keywords would be accepted, never validated, and silently have no
effect — the same "looks configured, isn't" failure `ExtractIP` throws to prevent, so reject the
combination rather than degrade into one bucket for every client.
"""
function build_ip_extractor(auto_extract_ip::Bool, forwarded_header::Symbol, trusted_proxies)
    if !auto_extract_ip
        if forwarded_header !== :none || trusted_proxies !== nothing
            throw(ArgumentError(
                "RateLimiter misconfiguration: `forwarded_header`/`trusted_proxies` have no " *
                "effect when `auto_extract_ip=false`, because the limiter then keys on whatever " *
                "`getip(req)` your own middleware assigned. Every client behind the proxy would " *
                "share one bucket while the setting looks active. Drop the two keywords and set " *
                "the IP yourself, or drop `auto_extract_ip=false` and let the limiter run " *
                "`ExtractIP` with them."))
        end
        return nothing
    end
    return ExtractIP(; forwarded_header, trusted_proxies)
end

"""
    FixedRateLimiter(; rate_limit::Int = 100, window::Period = Minute(1), cleanup_period::Period = Minute(10), cleanup_threshold::Period = Minute(10), auto_extract_ip::Bool = true, forwarded_header::Symbol = :none, trusted_proxies = nothing, fail_open::Bool = false, exempt_paths::Vector{String} = String[])

Creates a middleware function that enforces rate limiting based on IP address, with automatic background cleanup to prevent memory leaks.

# Arguments
- `rate_limit::Int`: Maximum number of requests allowed per IP within the window period. Default is 100. Must be positive.
- `window::Period`: Time window for rate limiting. Default is 1 minute. Must be positive.
- `cleanup_period::Period`: Interval for running the background cleanup task. Default is 10 minutes. Must be positive.
- `cleanup_threshold::Period`: Minimum age of inactive IP entries before deletion during cleanup. Default is 10 minutes. Must be positive.
- `auto_extract_ip::Bool`: If `true` (default), the middleware will automatically extract the client IP address from the request using the built-in extractor. Setting `false` is incompatible with `forwarded_header`/`trusted_proxies`, since nothing would then apply them.
- `forwarded_header::Symbol`: Forwarded to [`ExtractIP`](@ref) — the single header your reverse proxy writes. One of `:none` (default), `:x_forwarded_for`, `:x_real_ip`, `:cf_connecting_ip`, `:true_client_ip`. Must be set together with `trusted_proxies`.
- `trusted_proxies`: Forwarded to [`ExtractIP`](@ref) — the proxies whose forwarding header may be believed, as `IPAddr` values or CIDR strings (`"10.244.0.0/16"`). The header is read only when the socket peer matches one of them.
- `fail_open::Bool`: If `true`, an internal error in the limiter lets the request through instead of returning 503. Default `false` (fail closed).
- `exempt_paths::Vector{String}`: Request path prefixes to skip rate limiting. Default is empty.

# Behind a reverse proxy
Without `trusted_proxies`, every client shares the proxy's socket address and therefore one rate-limit bucket. Declaring the proxy and the header it writes restores per-client limits:

```julia
RateLimiter(rate_limit = 100,
            forwarded_header = :x_forwarded_for,
            trusted_proxies  = [ip"127.0.0.1"])
```

Forwarding headers are **never** honored from a peer that is not a listed proxy, so a client cannot pick its own bucket. See [`ExtractIP`](@ref) for the full trust model.

# Customization
To customize IP extraction, set `auto_extract_ip=false` and insert your own middleware before the rate limiter to assign the desired IP address to `getip(req)`. This is useful for advanced scenarios such as extracting IPs from custom headers, authentication tokens, or supporting non-standard proxy setups.

# Note
This implementation uses UTC time to avoid timezone and DST issues. Significant system clock adjustments (NTP sync, manual changes) may temporarily affect rate limiting accuracy.

# Returns
An `LifecycleMiddleware` struct containing the middleware function and a cleanup function to stop the background task on server shutdown.
"""
function FixedRateLimiter(;
    rate_limit          :: Int = 100,
    window              :: Period = Minute(1),
    cleanup_period      :: Period = Minute(10),
    cleanup_threshold   :: Period = Minute(10),
    auto_extract_ip     :: Bool = true,
    forwarded_header    :: Symbol = :none,
    trusted_proxies     :: Union{Nothing, AbstractVector} = nothing,
    fail_open           :: Bool = false,
    exempt_paths        :: Vector{String} = String[])

    # Validate parameters
    rate_limit > 0 || throw(ArgumentError("rate_limit must be positive, got $rate_limit"))
    Dates.value(window) > 0 || throw(ArgumentError("window must be a positive duration"))
    Dates.value(cleanup_period) > 0 || throw(ArgumentError("cleanup_period must be a positive duration"))
    Dates.value(cleanup_threshold) > 0 || throw(ArgumentError("cleanup_threshold must be a positive duration"))

    # Validates the trust configuration here, not at `serve()` — see `build_ip_extractor`.
    extract_client_ip = build_ip_extractor(auto_extract_ip, forwarded_header, trusted_proxies)

    rate_limit_store = Dict{IPAddr, Tuple{Int, DateTime}}()
    store_lock = ReentrantLock()
    
    running = Ref{Bool}(false)
    cleanup_task = Ref{Union{Task,Nothing}}(nothing)

    function on_startup()
        # enable the flag
        running[] = true

        # prevent multiple cleanup tasks from being started
        if isnothing(cleanup_task[])
            # Start Background cleanup task
            cleanup_task[] = @async while running[]
                sleep(cleanup_period)
                lock(store_lock) do
                    current_time = now(UTC)
                    to_delete = []
                    # Find old entries
                    for (ip, (_, last_reset)) in rate_limit_store
                        if current_time - last_reset > cleanup_threshold
                            push!(to_delete, ip)
                        end
                    end
                    # Cleanup old entries
                    for ip in to_delete
                        delete!(rate_limit_store, ip)
                    end
                end
            end
        end
    end

    # Stop function to halt the task
    function on_shutdown()
        running[] = false
        cleanup_task[] = nothing
    end

    function rate_limit_only(handle::Function)
        return function(req::HTTP.Request)
            try

                # allow passthrough for exempt paths
                for ex in exempt_paths
                    if startswith(req.target, ex)
                        return handle(req)
                    end
                end
                        
                # No client address means there is no bucket to key on. Without this guard the
                # `nothing` reaches the `Dict{IPAddr,…}` store and fails closed via the catch
                # below, logging a backtrace per request. Honour `fail_open` the same way.
                if getip(req) === nothing
                    @warn "Rate limiter: no client IP on this request; cannot apply a per-IP " *
                          "limit. Put `ExtractIP` before the limiter, or leave " *
                          "`auto_extract_ip=true`." maxlog=1
                    fail_open && return handle(req)
                    return SERVICE_UNAVAILABLE()
                end

                reset_time = 0
                should_limit = false
                remaining_requests = rate_limit

                lock(store_lock) do
                    current_time = now(UTC)
                    ip = getip(req)

                    if haskey(rate_limit_store, ip)
                        count, last_reset = rate_limit_store[ip]

                        # Case 2: Expired Window 
                        if current_time - last_reset > window
                            rate_limit_store[ip] = (1, current_time)
                            remaining_requests = rate_limit - 1
                            # Reset to current time, so reset time is full window period
                            reset_time = calculate_reset_time(current_time, current_time, window)

                        # Case 3: Limit Exceeded
                        elseif count >= rate_limit
                            should_limit = true
                            remaining_requests = 0
                            # Use original last_reset to calculate remaining time
                            reset_time = calculate_reset_time(current_time, last_reset, window)

                        # Case 4: Within Limit
                        else
                            rate_limit_store[ip] = (count + 1, last_reset)
                            remaining_requests = rate_limit - (count + 1)
                            # Calculate reset based on original last_reset
                            reset_time = calculate_reset_time(current_time, last_reset, window)
                        end
                    else
                        # Case 1: New IP
                        rate_limit_store[ip] = (1, current_time)
                        remaining_requests = rate_limit - 1
                        # Start from current time, full window period
                        reset_time = calculate_reset_time(current_time, current_time, window)
                    end
                end

                # Prepare the response
                if should_limit
                    # Create a new response for rate-limited requests
                    response = HTTP.Response(429, "Rate limit exceeded")
                    set_rate_headers!(response, rate_limit, 0, reset_time)
                    return response
                else
                    # Get the response, then own its headers before adding ours — the
                    # handler's response may be a shared/`const` object.
                    response = own_response_headers(handle(req))
                    # Add rate limit headers to successful responses
                    set_rate_headers!(response, rate_limit, remaining_requests, reset_time)
                    return response
                end

            catch error
                @error "Fixed Rate limiter error" exception=(error, catch_backtrace())
                # Fail closed by default: a bug or attacker-triggered error in the
                # limiter must not become a way to bypass the limit. Operators can
                # opt into fail-open (prioritising availability) via `fail_open=true`.
                fail_open && return handle(req)
                return SERVICE_UNAVAILABLE()
            end
        end
    end

    # If auto_extract_ip is true, then we'll use this composed version of the middleware
    function extract_ip_and_rate_limit(handle::Function) :: Function
        reduce(|>, [handle, rate_limit_only, extract_client_ip])
    end

    return LifecycleMiddleware(;
        middleware = auto_extract_ip ? extract_ip_and_rate_limit : rate_limit_only, 
        on_startup = on_startup,
        on_shutdown = on_shutdown
    )
end



"""
    SlidingRateLimiter(; rate_limit::Int=100, window::Period=Minute(1), max_clients::Int=10000, exempt_paths::Vector{String}=String[], auto_extract_ip::Bool=true, forwarded_header::Symbol=:none, trusted_proxies=nothing, fail_open::Bool=false)

Creates a middleware function that enforces rate limiting using an LRU cache for sliding window tracking.
This implementation provides true sliding window behavior where each request creates its own expiration time,
offering more precise rate limiting than fixed windows but with higher memory usage.

# Arguments
- `rate_limit::Int`: Maximum requests per client per window. Default 100. Must be positive.
- `window::Period`: Sliding time window duration. Default 1 minute. Must be positive.
- `max_clients::Int`: Maximum distinct client buckets in LRU cache. Default 10000. Must be positive.
- `exempt_paths::Vector{String}`: Request path prefixes to skip rate limiting. Default empty.
- `auto_extract_ip::Bool`: If true, automatically extract IP address from request. Default true. Setting `false` is incompatible with `forwarded_header`/`trusted_proxies`, since nothing would then apply them.
- `forwarded_header::Symbol`: Forwarded to [`ExtractIP`](@ref) — the single header your reverse proxy writes. One of `:none` (default), `:x_forwarded_for`, `:x_real_ip`, `:cf_connecting_ip`, `:true_client_ip`. Must be set together with `trusted_proxies`.
- `trusted_proxies`: Forwarded to [`ExtractIP`](@ref) — the proxies whose forwarding header may be believed, as `IPAddr` values or CIDR strings (`"10.244.0.0/16"`). The header is read only when the socket peer matches one of them.
- `fail_open::Bool`: If `true`, an internal error in the limiter lets the request through instead of returning 503. Default `false` (fail closed).

# Behind a reverse proxy
Without `trusted_proxies`, every client shares the proxy's socket address and therefore one rate-limit bucket. Declaring the proxy and the header it writes restores per-client limits:

```julia
RateLimiter(strategy = :sliding_window, rate_limit = 100,
            forwarded_header = :x_forwarded_for,
            trusted_proxies  = [ip"127.0.0.1"])
```

Forwarding headers are **never** honored from a peer that is not a listed proxy, so a client cannot pick its own bucket. See [`ExtractIP`](@ref) for the full trust model.

# Algorithm
Uses a sliding window approach where:
1. Each request timestamp is stored individually
2. On each request, expired timestamps are pruned
3. Current request count is checked against limit
4. LRU eviction prevents unbounded memory growth

# Note
- The `X-RateLimit-Reset` header indicates when the oldest request expires (when at least 1 request slot becomes available), not when the full quota resets.
- This implementation uses UTC time to avoid timezone and DST issues. Significant system clock adjustments (NTP sync, manual changes) may temporarily affect rate limiting accuracy.
- Concurrency: the downstream handler runs **outside** the limiter's internal lock, so a slow handler delays only its own request. The lock guards only the per-client timestamp bucket; `X-RateLimit-Remaining`/`-Reset` are sampled when the request is admitted.

# Returns
A middleware function with signature: `handle -> req -> response`
"""
function SlidingRateLimiter(;
    rate_limit      :: Int = 100,
    window          :: Period = Minute(1),
    max_clients     :: Int = 10000,
    exempt_paths    :: Vector{String} = String[],
    auto_extract_ip :: Bool = true,
    forwarded_header:: Symbol = :none,
    trusted_proxies :: Union{Nothing, AbstractVector} = nothing,
    fail_open       :: Bool = false)

    # Validate parameters
    rate_limit > 0 || throw(ArgumentError("rate_limit must be positive, got $rate_limit"))
    Dates.value(window) > 0 || throw(ArgumentError("window must be a positive duration"))
    max_clients > 0 || throw(ArgumentError("max_clients must be positive, got $max_clients"))

    # Validates the trust configuration here, not at `serve()` — see `build_ip_extractor`.
    extract_client_ip = build_ip_extractor(auto_extract_ip, forwarded_header, trusted_proxies)

    # LRU cache: IPAddr -> Vector of request timestamps
    rate_limit_store = LRU{IPAddr, Vector{DateTime}}(maxsize = max_clients)
    store_lock = ReentrantLock()
    
    # Precompute fallback reset seconds (window in milliseconds → seconds)
    default_reset_seconds = Int(ceil(Dates.value(window) / 1000))

    # Compute reset time from timestamps (safe for empty vectors)
    function compute_reset_time_safe(current_time::DateTime, timestamps::Vector{DateTime})
        if isempty(timestamps)
            return default_reset_seconds
        else
            oldest_timestamp = minimum(timestamps)
            return calculate_reset_time(current_time, oldest_timestamp, window)
        end
    end

    function rate_limit_only(handle::Function)
        return function(req::HTTP.Request)
            try
                # Check exempt paths first (most efficient early return)
                for exempt_path in exempt_paths
                    if startswith(req.target, exempt_path)
                        return handle(req)
                    end
                end

                # No client address means there is no bucket to key on. Without this guard the
                # `nothing` reaches the `LRU{IPAddr,…}` store and fails closed via the catch
                # below, logging a backtrace per request. Honour `fail_open` the same way.
                if getip(req) === nothing
                    @warn "Rate limiter: no client IP on this request; cannot apply a per-IP " *
                          "limit. Put `ExtractIP` before the limiter, or leave " *
                          "`auto_extract_ip=true`." maxlog=1
                    fail_open && return handle(req)
                    return SERVICE_UNAVAILABLE()
                end

                # CONCURRENCY (nitro-core §2) — DO NOT call `handle(req)` in here.
                # Nitro serves every request via `Threads.@spawn`; this lock is shared
                # by every client of this limiter instance, so anything held under it
                # is serialised. Running the downstream chain here made one slow
                # handler block every other request from every IP (#15).
                #
                # The lock is still required: `get!` hands back a *shared mutable*
                # `Vector{DateTime}`, and LRUCache's internal SpinLock protects only
                # the container, not that vector. Every read/write of `timestamps`
                # must therefore stay inside this block.
                #
                # The decision is returned as a concrete `Tuple{Bool,Int,Int}` rather
                # than assigned to hoisted locals: assigning an enclosing-scope local
                # from inside a closure boxes it, which would hand `set_rate_headers!`
                # three `Any`s on the request hot path (nitro-core §7).
                should_limit, remaining_requests, reset_time = lock(store_lock) do
                    current_time = now(UTC)
                    ip = getip(req)

                    # Get existing timestamps or create empty vector
                    timestamps = get!(rate_limit_store, ip, DateTime[])

                    # Prune expired timestamps (sliding window cleanup)
                    # Keep only timestamps within the current window
                    cutoff_time = current_time - window
                    filter!(timestamp -> timestamp > cutoff_time, timestamps)

                    # Check if adding this request would exceed the limit
                    if length(timestamps) >= rate_limit
                        return (true, 0, compute_reset_time_safe(current_time, timestamps))
                    end

                    # Within the limit: consume the slot and snapshot the header values
                    # now, while the vector is still guarded. These are the same values
                    # the old code produced — it computed them after `handle(req)`, but
                    # the vector could not change meanwhile because the lock was
                    # (wrongly) held across the handler.
                    push!(timestamps, current_time)
                    # Remaining quota, and time until the oldest request expires (when
                    # 1 slot becomes available).
                    return (false, rate_limit - length(timestamps),
                            compute_reset_time_safe(current_time, timestamps))
                end

                # Prepare the response — outside the lock, so a slow handler delays
                # only its own request.
                if should_limit
                    resp = HTTP.Response(429, "429 Too Many Requests")
                    set_rate_headers!(resp, rate_limit, 0, reset_time)
                    return resp
                else
                    # Own the handler's (possibly shared/`const`) response before adding headers.
                    response = own_response_headers(handle(req))
                    set_rate_headers!(response, rate_limit, remaining_requests, reset_time)
                    return response
                end

            catch error
                @error "Sliding Window Rate limiter error" exception=(error, catch_backtrace())
                # Fail closed by default so a limiter error can't be used to bypass
                # the limit; set `fail_open=true` to prioritise availability instead.
                fail_open && return handle(req)
                return SERVICE_UNAVAILABLE()
            end
        end
    end

    # Compose with IP extraction if auto_extract_ip is enabled
    function extract_ip_and_rate_limit(handle::Function)
        return reduce(|>, [handle, rate_limit_only, extract_client_ip])
    end

    return auto_extract_ip ? extract_ip_and_rate_limit : rate_limit_only
end



"""
    calculate_reset_time(current_time::DateTime, last_reset::DateTime, window::Period) -> Int

Calculates the number of seconds remaining until the current rate limit window resets.

# Arguments
- `current_time::DateTime`: The current server time.
- `last_reset::DateTime`: The start time of the current rate limit window for the client/IP.
- `window::Period`: The duration of the rate limit window.

# Returns
- `Int`: The number of seconds until the rate limit window resets. Returns 0 if the window has already expired.

This value is used for the `X-RateLimit-Reset` response header, allowing clients to know when they can make new requests.
"""
function calculate_reset_time(current_time::DateTime, last_reset::DateTime, window::Period)
    window_end = last_reset + window
    seconds_remaining = ceil(Int, Dates.value(window_end - current_time) / 1000)
    return max(0, seconds_remaining)
end


"""
    set_rate_headers!(resp::HTTP.Response, rate_limit::Int, remaining_requests::Int, reset_time::Int)

Conditionally sets standard rate limiting headers on an HTTP response if they are not already present.
This function implements a "header preservation" pattern, ensuring that headers set by inner middleware
(e.g., route-level rate limits) are not overwritten by outer middleware (e.g., router-level limits),
allowing the most restrictive or specific limits to take precedence in nested middleware chains.

# Arguments
- `resp::HTTP.Response`: The HTTP response object to modify. Headers are added in-place.
- `rate_limit::Int`: The maximum number of requests allowed in the current window. Used for the `X-RateLimit-Limit` header.
- `remaining_requests::Int`: The number of requests remaining in the current window. Used for the `X-RateLimit-Remaining` header (clamped to 0 if negative).
- `reset_time::Int`: The number of seconds until the rate limit window resets. Used for the `X-RateLimit-Reset` header.
"""
function set_rate_headers!(resp::HTTP.Response, rate_limit::Int, remaining_requests::Int, reset_time::Int)
    
    # Header flags which are set to true when they're found
    has_limit = false
    has_remaining = false
    has_reset = false
    has_retry = false
    
    # Loop over the headers once and try to find each header
    for (k, _) in resp.headers
        # End if all headers are found
        if has_retry && has_limit && has_remaining && has_reset
            break
        elseif !has_retry && header_name_isequal(k, "Retry-After")
            has_retry = true
        elseif !has_limit && header_name_isequal(k, "X-RateLimit-Limit")
            has_limit = true
        elseif !has_remaining && header_name_isequal(k, "X-RateLimit-Remaining" )
            has_remaining = true
        elseif !has_reset && header_name_isequal(k, "X-RateLimit-Reset")
            has_reset = true
        end
    end

    # Conditionally set the headers if they don't exist
    if !has_retry
        HTTP.setheader(resp, "Retry-After" => string(reset_time))
    end
    if !has_limit
        HTTP.setheader(resp, "X-RateLimit-Limit" => string(rate_limit))
    end
    if !has_remaining
        HTTP.setheader(resp, "X-RateLimit-Remaining" => string(max(0, remaining_requests)))
    end
    if !has_reset
        HTTP.setheader(resp, "X-RateLimit-Reset" => string(reset_time))
    end  

end

end