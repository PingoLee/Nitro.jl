module SessionMiddleware_

using HTTP
using Dates
using JSON
using UUIDs
using ...Types: AbstractSessionStore, MemoryStore, SessionPayload, Nullable, is_expired,
    update_session!, delete_session!, session_store_full, SESSION_AUTH_HASH_KEY,
    _session_auth_hash_current
using ...Types: CookieConfig, LifecycleMiddleware
using ..JanitorMiddleware: _janitor
using ...Cookies: get_cookie, set_cookie!, storesession!, prunesessions!, regenerate_session!,
    _validate_cookie_prefix
using ...Crypto: secure_uuid4
using ...Errors: is_unrecoverable
using ...Core: own_response_headers
using ...Util: _mark_private!

export SessionMiddleware, SessionPruner, rehash_session!

# There is deliberately NO default store (#171). A `const DEFAULT_STORE` used to live here, and
# every `SessionMiddleware()` built without `store=` shared that one process-wide instance --
# so two notionally-independent `App`s in one process shared a session table, and each
# activation spawned its own prune janitor over it. That is the same class of process-global
# #31 removed when `App` replaced the `CONTEXT[]` singleton. `store` is now required, and
# omitting it is an `UndefKeywordError` rather than a silent share.

# ── Background pruning (#36) ───────────────────────────────────────────────────────────────
#
# Pruning used to run INLINE on the request path: `rand() < prune_probability` (default 0.01)
# made roughly 1 request in 100 pay a full O(N) scan of the store, and `MemoryStore` runs that
# scan under the single lock every other session read and write also needs. At 100k live
# sessions every concurrent request blocked behind that scan — periodic p99 spikes and a
# throughput cliff, caused by the component that is on every stateful request.
#
# That design is PHP's `session.gc_probability`/`gc_divisor`, and PHP is where the evidence
# against it comes from too: Debian and Ubuntu ship PHP with `session.gc_probability=0` and a
# cron job instead, for exactly this reason. Django (`manage.py clearsessions`) and Rails
# (`rake db:sessions:trim`) never prune on the request path at all. Nitro can do better than
# an external cron because it already has `LifecycleMiddleware`: the prune becomes an
# in-process janitor tied to server startup and shutdown, which is the Go idiom (`go-cache`'s
# janitor goroutine).
#
# Note what this does NOT need to fix: expiry is already enforced lazily on the read path
# (`get_session` refuses a payload whose `expires` has passed, src/types.jl), so an unpruned
# store has never served a stale session. Pruning is purely about reclaiming memory.



# Builds the `(on_startup, on_shutdown)` pair for a store-pruning janitor.
#
# The whole lifecycle discipline — `Threads.@spawn`/`errormonitor`, the per-activation stop token,
# the post-`sleep` re-check, the per-tick `try` with its `InterruptException` rethrow, and the
# `finally` that retires the activation so a later `on_startup()` can respawn — lives in
# `_janitor` (src/middleware/janitor.jl) and is shared with `FixedRateLimiter`. This used to be a
# hand-rolled copy of it, and the copies had drifted: only the rate limiter's rethrew
# `InterruptException`, and a session prune over a user store (a blocking SQL DELETE for
# `PormGSessionStore`) is by far the more interruptible of the two (#190, #185).
#
# What stays here is the only part that is actually session-specific: the work, and the labels.
# `kwname`, not a hardcoded "prune_interval": `SessionPruner`'s keyword is `interval`, and an
# error naming a keyword the caller's function does not have sends them hunting.
function _prune_janitor(store::AbstractSessionStore, interval::Period, label::String,
                       kwname::String)
    return _janitor(() -> prunesessions!(store), interval, label, "session prune", kwname)
end

"""
    SessionPruner(store::AbstractSessionStore; interval::Period = Minute(10))

A `LifecycleMiddleware` that periodically removes expired sessions from `store` and does
nothing else to the request — a pass-through with a background janitor attached.

`SessionMiddleware` already installs one of these internally, so you only need `SessionPruner`
when you reach sessions **without** it: the `Session{T}` extractor and `storesession!` both
work against a store passed through the app context, and nothing on that path ever prunes. A
long-lived `MemoryStore` used that way grows until the process runs out of memory. (It never
serves a stale session — expiry is checked on read — so this is a memory concern, not a
correctness one.)

```julia
store = MemoryStore{String, Dict{String,Any}}()
serve(app, middleware = [SessionPruner(store; interval = Minute(5))], context = store)
```

The janitor starts on `serve()` and stops on `terminate()`. Its hooks are idempotent, so a
`serve(); terminate(); serve()` cycle does not leak a task.
"""
function SessionPruner(store::AbstractSessionStore; interval::Period = Minute(10))
    on_startup, on_shutdown = _prune_janitor(store, interval, "SessionPruner", "interval")
    return LifecycleMiddleware(;
        middleware = handle -> (req -> handle(req)),
        on_startup = on_startup,
        on_shutdown = on_shutdown)
end

# The `absolute_max_age` a `SessionMiddleware` gets when none is given: seven days, in seconds
# (#362). Long enough that a user who keeps coming back signs in again about once a week; short
# enough that a stolen session id stops working within a week however much it is used.
const DEFAULT_ABSOLUTE_MAX_AGE = 7 * 86400

# The largest `absolute_max_age` accepted: 100 years. Far past any real session, and far short of
# where `DateTime + Second(n)` overflows and wraps round to the past.
const MAX_ABSOLUTE_MAX_AGE = 100 * 365 * 86400

# The `unconfirmed_max_age` a `SessionMiddleware` gets when none is given (#440): one hour, the
# default `CSRFMiddleware` `ttl`. With both defaults, a form left open long enough to lose its
# unconfirmed session has already lost its CSRF cookie, so the default adds no 403 a stock app did
# not already have. That holds only while the two are equal: a shorter `max_age` halves this one,
# and a form idle between the two lifetimes then gets a 403 it did not get before.
const DEFAULT_UNCONFIRMED_MAX_AGE = 3600

# Below this full lifetime the default switches confirm-on-return off. An unconfirmed lifetime must
# sit well clear of the full one -- see `_unconfirmed_payload` -- and a session that lives two
# minutes in total has no flood worth bounding.
const MIN_LIFETIME_FOR_UNCONFIRMED = 120

# The lifetime a confirmed session gets from a write made the moment it is created: `max_age`,
# cut short by the absolute cap.
_full_lifetime(max_age::Int, absolute_max_age::Nullable{Int}) =
    absolute_max_age === nothing ? max_age : min(max_age, absolute_max_age)

# `min(1 h, half the full lifetime)`, or off when the full lifetime is too short to split.
function _default_unconfirmed_max_age(max_age::Int, absolute_max_age::Nullable{Int})::Nullable{Int}
    full = _full_lifetime(max_age, absolute_max_age)
    full >= MIN_LIFETIME_FOR_UNCONFIRMED || return nothing
    return min(DEFAULT_UNCONFIRMED_MAX_AGE, full ÷ 2)
end

"""
    SessionMiddleware(; store, cookie_name, max_age, absolute_max_age, unconfirmed_max_age,
                        prune_interval, rotate_on_auth, auth_key, validator, session_auth_hash, ...)

Creates a `LifecycleMiddleware` that manages server-side sessions with cookie-based session
IDs. The mutable session dictionary is read with `getsession(req)` (`req.context[:session]`).

# Required keyword

- `store::AbstractSessionStore{String, Dict{String,Any}}` — where sessions are persisted.
  [`MemoryStore()`](@ref) for in-process sessions, `pormg_nitro_session()` for a database.

  **There is no default, on purpose (#171).** A shared process-global store would be silently
  shared by every `App` in the process — several can coexist — and by every test that forgot to
  pass one. Omitting `store` is an `UndefKeywordError` at construction, never a silent share.
  Two apps that each want their own session table each call `MemoryStore()`.

Expired sessions are reclaimed by a background janitor that starts on `serve()` and stops on
`terminate()` — see `prune_interval` below and [`SessionPruner`](@ref). Nothing prunes on the
request path.

# When a session is saved

A request without a valid session cookie gets a fresh id in `req.context[:session_id]` and an
empty `getsession(req)`. That new session is **saved, and its cookie set, only if** the handler
leaves data in it, rotates it (`regenerate_session!`), or sets
`req.context[:session_modified] = true` (#317). Otherwise nothing is stored and no cookie is sent,
so health checks and static files do not create sessions. `CSRFMiddleware` sets the flag whenever
it issues a token bound to the session, and it issues one to a new visitor only when a handler
asks for it with `csrf_token!` (#431), so a global `CSRFMiddleware` keeps this guarantee. Set the
flag yourself when you hand the client anything else bound to `req.context[:session_id]`.

An existing session is written back when its data changed, when it was rotated, when it is still
unconfirmed (below), or when the flag is set (which also refreshes its expiry). A request that only
reads it writes nothing, so its expiry does not move (#452). That write is update-only (`update_session!`, #318). If a
concurrent logout deleted the session meanwhile, the write is dropped and the cookie is not re-set.
The one exception is a rotated session that ends the request empty and with no identity, such as
a logout. It is written with `set_session!` as a fresh session; see *Session lifetime* below.

Rotation holds against the same race (#361). `regenerate_session!` and `rotate_on_auth` move the
session with the store's atomic `rotate_session!`, which moves it only if it still exists. After a
concurrent logout there is nothing to move, so the logged-out data is not copied into a fresh id,
this request's write is dropped, and no cookie is set.

# Unconfirmed anonymous sessions (`unconfirmed_max_age`, `session_store_full`)

A new session that ends its first request with no identity is saved **unconfirmed** (#440): its
stored expiry and its cookie's `Max-Age` are `unconfirmed_max_age`, not `max_age`. When the browser
sends the cookie back, the session is confirmed: one write moves it to the full lifetime and re-sets
the cookie. A real browser usually does that within seconds, on the next page or asset it fetches,
as long as that request passes through this middleware (an asset served outside it, or a
route-scoped middleware, confirms nothing). A script
that never returns its cookie leaves rows the janitor reclaims after `unconfirmed_max_age`, so a
cookieless flood against a route that writes the session cannot grow the store for a whole
`max_age`. A new session that ends the request signed in, such as a login from a cookieless client,
is saved with the full lifetime at once.

- `unconfirmed_max_age::Nullable{Int}` — defaults to one hour, the default `CSRFMiddleware` `ttl`,
  or half of `min(max_age, absolute_max_age)` when that is shorter. A full lifetime under two
  minutes switches the default off. An explicit value must be positive and at most half that
  lifetime, or it is an `ArgumentError`. `nothing` switches confirm-on-return off: every new
  session gets `max_age`, as before #440.
- The one session it costs is a client that makes a single session-writing request and comes back
  after `unconfirmed_max_age`: it finds a fresh session.
- The store must return a `SessionPayload` whose `created` and `expires` come from the same clock,
  as `MemoryStore` and `pormg_nitro_session()` do: a session is recognised as unconfirmed by its
  stored lifetime, `expires - created`. A store whose `Base.get` returns bare data carries no
  lifetime, so its sessions are never confirmed and every anonymous one lasts only
  `unconfirmed_max_age`; the middleware warns once when it sees one. Pass
  `unconfirmed_max_age = nothing` for such a store.
- A store may also bound itself. Before saving a new anonymous session the middleware asks
  [`session_store_full`](@ref Nitro.Core.Types.session_store_full)`(store)`; when it answers
  `true` the session is not saved and no cookie is set, the request still succeeds, and one
  warning is logged. Sessions that end signed in, existing sessions and rotations are never
  refused. `pormg_nitro_session(max_sessions = N)` implements it. Under a full store a new visitor
  holds no session, so a session-bound CSRF token handed to them does not verify on their next
  request, and a cookieless visitor cannot sign in through such a form until the store has room.

A response that sets the session cookie also gets `Vary: Cookie`, and `Cache-Control: private` in
place of any `public` (other directives are kept). A shared cache therefore never serves one
visitor's session to another.

# Session lifetime (`max_age`, `absolute_max_age`)

A session has two lifetimes, and it ends at whichever comes first.

- `max_age::Int = 86400` — the **sliding** lifetime, in seconds. Every write moves the expiry to
  `max_age` from now, so a session that keeps being written keeps going and an idle one lapses.
  It slides on **writes, not reads** (#452), as Django's does by default: a request that only
  reads the session costs no store write, so a session that is only read lapses `max_age` after
  its last write. A handler that wants a read to keep the session alive sets
  `req.context[:session_modified] = true`.
- `absolute_max_age::Nullable{Int} = 604800` (7 days) — the **absolute** lifetime, in seconds,
  measured from when the session was first stored (#362). A session older than that is treated as
  absent, like an expired one: the visitor gets a fresh id and signs in again, however recently
  the old session was used. Without it, a stolen session id stayed valid for as long as the
  thief kept using it. `nothing` switches it off, which is Django's default; OWASP recommends
  an absolute timeout.

Rotation does not restart the absolute clock: `regenerate_session!` and `rotate_on_auth` move a
session to a new id and keep its creation time, so the cap bounds the whole chain of ids. The one
exception is a rotated session that **ends the request empty**, which is what the logout recipe
(`empty!` + `regenerate_session!`) leaves. It carries no identity, so it is written with a fresh
clock, and logging back in gets a full window. The check is made on the final contents, so emptying
a session, rotating it and putting the identity back keeps the old clock.

The cap binds every reader of the store, not only this middleware. Each write sets the expiry to
`max_age` from now or the absolute deadline, whichever is sooner, and the cookie's `Max-Age`
likewise. The `Session{T}` extractor and `Auth.session_user_validator` read the store directly,
and the expiry check they already make then enforces the cap too. A session this middleware finds
past its cap anyway is deleted. That happens after a cap was *lowered*, after a direct
`set_session!`, or when another `SessionMiddleware` with a looser cap shares the store, so give
middlewares that share a store the same cap. A session that reaches its deadline while a request
runs ends with that request: nothing is written, not even a rotation, and no cookie is set.

`absolute_max_age` must be at most 100 years; pass `nothing`, not a huge number, for no cap.

# Session fixation defense (`rotate_on_auth`, `auth_key`, `validator`)

When `rotate_on_auth=true` (the default), an existing session is assigned a **new** session
ID whenever its authenticated identity changes during a request — i.e. on login, logout, or
a user switch — so a pre-login session ID can never be replayed against the post-login
session. The identity is captured before the handler runs and compared after.

How that identity is resolved, in order:

- `auth_key::String = "user_id"` — the session key whose value *is* the identity. This is
  the common case: your login handler sets `getsession(req)["user_id"] = …` and logout clears
  it; the change triggers regeneration.
- `validator::Union{Function, Nothing} = nothing` — an optional **fallback identity
  resolver**, consulted *only* when `auth_key` is absent from the session (and a session ID
  exists). It is arity-dispatched — called as `validator(session_id, session_data)` if that
  method exists, else `validator(session_id)` — and its return value is the identity marker
  used for change detection.

The `validator` participates in fixation detection **only**; it never populates
`getuser(req)`. Authenticating a request (attaching a principal) is the job of `BearerAuth` /
`CookieAuthMiddleware`, and guards read `getuser(req)` / the raw session there. This separation
is deliberate: `SessionMiddleware` owns session *state and rotation*, not the auth identity
contract.

# Signing out everywhere (`session_auth_hash`)

`session_auth_hash::Union{Function, Nothing} = nothing` ends **every** session of a user at once
(#391), which a per-session logout cannot do: it only knows the id in the request that asked. The
hook is called as `session_auth_hash(identity)`, with the identity `auth_key`/`validator` resolve
above, and returns a string or `nothing`. The value is saved in the session when the identity is
set (login, or a user switch) and checked every time an authenticated session is loaded. When it no
longer matches, the session is deleted and the request continues as a new, anonymous visitor.

```julia
SessionMiddleware(; store,
    session_auth_hash = uid -> string(find_user(uid).session_version))

# "Sign out everywhere": every session the user has, on every device, ends on its next request.
bump_session_version!(uid)
```

Nitro has no user model, so the value lives in your application. A per-user counter you bump is
the simplest. Django's choice, derived from the stored password hash, also ends every session when
the password changes, with no extra code. The value is stored in the session row, so derive it with
an HMAC keyed by a server secret, never the password hash itself or a plain hash of it. Returning
`nothing` says the user no longer exists, and the session is refused.

This closes the ordering a per-session logout leaves open. If a request rotates the session just
*before* the logout commits, the logout finds the old id gone and the rotated session lives on
(see *Logout Semantics* in the sessions tutorial). A logout that changes the user's value ends that
session too, whatever its id. Rotation keeps the value the session was stamped with at login, so a
rotation cannot pick up the new one.

- The value is kept under the reserved session key `"_nitro_auth_hash"`. It is removed when the
  identity is cleared.
- Anonymous sessions never call the hook. An authenticated one calls it once per request, so keep it
  cheap, for example a cached column read.
- Requests run concurrently, so the hook must be thread-safe. An exception it throws is not caught
  and the request fails with a 500. That fails closed: a session is never accepted without a check.
- A `validator` identity must come from the session data it is passed, not from reading the store
  by id. The stamp is taken before the request's writes reach the store, so a store-reading
  validator does not see a login and leaves it unstamped, and the next request then refuses it.
  `Auth.session_user_validator` reads the data it is handed.
- **Turning the hook on signs everyone out once.** Sessions authenticated before it have no value,
  and nothing vouches for them.
- To keep the current session through a password change, call [`rehash_session!`](@ref) in the
  handler that changes it.
- `Auth.session_user_validator` takes the same `session_auth_hash` keyword and applies the same
  check. `get_session` and the `Session{T}` extractor do not.

# Other keyword arguments

- `cookie_name` — defaults to the most protected name the cookie's attributes allow (#329):
  `"__Host-nitro_session"` when `secure` with `path = "/"` and no `domain`,
  `"__Secure-nitro_session"` when `secure` with a `domain` or another `path`, and
  `"nitro_session"` only when `secure = false`. The `__Host-` prefix is what stops a sibling
  subdomain or a plain-HTTP attacker planting their own session cookie on the victim (login CSRF /
  session swapping): browsers refuse to let anyone but this origin, over HTTPS, set one. An
  explicit `__Host-`/`__Secure-` name the attributes cannot carry is an `ArgumentError` at
  construction, since browsers would silently drop it.
- `max_age`, `absolute_max_age` — see *Session lifetime* above; `unconfirmed_max_age` — see
  *Unconfirmed anonymous sessions* above. An `absolute_max_age` that is
  not positive, or is over 100 years, is an `ArgumentError` at construction.
- `prune_interval::Period = Minute(10)` — how often the background janitor removes expired
  sessions from `store`. Must be a positive fixed-length `Period`; calendar periods (`Month`,
  `Quarter`, `Year`) are rejected, since they cannot be slept on. This replaced a `prune_probability` that ran the prune inline on a
  fraction of requests; see the comment above `_prune_janitor` for why that had to go.
- Cookie attributes (`secure`, `httponly`, `samesite`, `path`, `domain`) or a fully-formed
  `config::CookieConfig`.

There is no `secret_key` (#339). The cookie carries only a random UUIDv4 session id and the data
stays on the server, so there is nothing to encrypt. Signing the id would not stop fixation or
session swapping either; the `__Host-` default above is what stops swapping. A `config` whose
`secret_key` is set is an `ArgumentError`, because it would be silently ignored.

# Returns
A `LifecycleMiddleware`. `serve()` and `urlpatterns()` accept it directly; if you are composing
the chain by hand, the request function is its `.middleware` field.
"""
function SessionMiddleware(;
    cookie_name::Nullable{String} = nothing,
    max_age::Int = 86400,
    absolute_max_age::Nullable{Int} = DEFAULT_ABSOLUTE_MAX_AGE,
    unconfirmed_max_age::Nullable{Int} = _default_unconfirmed_max_age(max_age, absolute_max_age),
    store::AbstractSessionStore{String, Dict{String,Any}},
    prune_interval::Period = Minute(10),
    secure::Bool = true,
    httponly::Bool = true,
    samesite::String = "Lax",
    path::String = "/",
    domain::Nullable{String} = nothing,
    rotate_on_auth::Bool = true,
    auth_key::String = "user_id",
    config::CookieConfig = CookieConfig(
        httponly = httponly,
        secure = secure,
        samesite = samesite,
        path = path,
        domain = domain,
        maxage = max_age,
    ),
    validator::Union{Function, Nothing} = nothing,
    session_auth_hash::Union{Function, Nothing} = nothing)

    # There is no `secret_key` keyword any more (#339): it was accepted and never used, since the
    # id cookie was always written and read raw. A caller passing one reasonably believed the
    # session cookie was encrypted or signed. A `config` carrying one would be the same silent
    # no-op, so it is refused rather than ignored.
    config.secret_key === nothing || throw(ArgumentError(
        "SessionMiddleware does not encrypt or sign its cookie, so `config.secret_key` would be " *
        "ignored. The cookie holds only a random 122-bit session id; the session data stays on " *
        "the server. Build the `CookieConfig` without `secret_key` (#339)."))

    # A zero or negative cap would refuse every session the moment it was stored; `nothing` is
    # how the cap is switched off. The upper bound is arithmetic, not policy: `created +
    # Second(typemax(Int))` wraps `DateTime` round to the past, so "effectively unbounded"
    # written as a huge number refused EVERY session. `nothing` says unbounded.
    absolute_max_age === nothing ||
        0 < absolute_max_age <= MAX_ABSOLUTE_MAX_AGE || throw(ArgumentError(
        "SessionMiddleware: `absolute_max_age` must be a positive number of seconds, at most " *
        "$MAX_ABSOLUTE_MAX_AGE (100 years), or `nothing` for no absolute lifetime; got " *
        "$absolute_max_age (#362)."))

    # At most half the full lifetime (#440). A loaded session is recognised as unconfirmed by its
    # stored lifetime being exactly `unconfirmed_max_age` (`_unconfirmed_payload`), and every
    # confirmed write leaves at least the full lifetime -- so the two must sit well apart, or a
    # confirmed session would read as unconfirmed and the other way round.
    full_lifetime = _full_lifetime(max_age, absolute_max_age)
    unconfirmed_max_age === nothing ||
        0 < unconfirmed_max_age && 2 * unconfirmed_max_age <= full_lifetime || throw(ArgumentError(
        "SessionMiddleware: `unconfirmed_max_age` must be a positive number of seconds, at most " *
        "half of the full session lifetime (min(max_age, absolute_max_age) = $full_lifetime s), " *
        "or `nothing` to switch confirm-on-return off; got $unconfirmed_max_age (#440)."))

    # Resolved from the FINAL config -- `config` may be passed whole -- and checked before any
    # janitor exists, so a name browsers would drop fails at construction.
    session_cookie = something(cookie_name, _default_session_cookie_name(config))
    _validate_cookie_prefix(session_cookie, config; label = "Session cookie",
                            plain_name = "nitro_session")

    on_startup, on_shutdown = _prune_janitor(store, prune_interval, "SessionMiddleware",
                                             "prune_interval")
    # Once per spell of fullness, not per refused session: at capacity EVERY anonymous insert is
    # refused, and a warning each would be a second flood riding on the first.
    warned_full = Threads.Atomic{Bool}(false)

    middleware = function(handle::Function)
        return function(req::HTTP.Request)
            # Load the current payload and remember the auth marker before the handler runs.
            session_id = _get_session_id(req, session_cookie)
            session_data, is_new, created, unconfirmed =
                _load_session(store, session_id, absolute_max_age, unconfirmed_max_age)
            # A signed-in session whose user has since been signed out everywhere (#391) is
            # ended the way a session past its absolute lifetime is: deleted, and this request
            # starts as a new visitor. Checked before the marker below is taken, so the handler
            # sees -- and `rotate_on_auth` compares against -- the anonymous session it now has.
            if !is_new && session_auth_hash !== nothing &&
               _auth_hash_stale(session_data, session_id, auth_key, validator, session_auth_hash)
                _end_session!(store, session_id, "whose sign-in was revoked")
                session_data, is_new, created, unconfirmed =
                    Dict{String,Any}(), true, Dates.now(Dates.UTC), false
            end
            original_session = deepcopy(session_data)
            original_auth_marker = _auth_marker(session_data, session_id, auth_key, validator)

            # New visitors start with a fresh random session identifier.
            if is_new
                session_id = _generate_session_id()
            end

            # Expose the mutable session dictionary through the request context.
            req.context[:session] = session_data
            req.context[:session_id] = session_id
            # Tells `regenerate_session!` whether this id is in the store: a minted one is not,
            # and moving it with `rotate_session!` would find nothing and read as a logout.
            req.context[:session_new] = is_new

            # Let downstream middleware and the handler read or mutate the session.
            response = handle(req)

            current_session = req.context[:session]
            final_session_id = get(req.context, :session_id, session_id)

            # Every write below -- insert, update, rotation -- and the cookie use this, so the
            # stored expiry never passes the absolute deadline (#362). A new session's clock
            # starts when it is written, not when the request began, so a slow first request can
            # never leave it with no lifetime at all.
            write_now = Dates.now(Dates.UTC)
            ttl = _write_ttl(max_age, absolute_max_age, is_new ? write_now : created, write_now)

            # A loaded session that reached its absolute deadline while this request ran (it had
            # under a second left, or the handler took longer than what was left) is ended the
            # way the load path ends one: no rotation, no write, no cookie. Writing it with a TTL
            # of 0 would store a row that is expired on arrival -- and a rotation would move the
            # session into it, reporting success for a login the next request cannot see. It
            # would also hand every store method a TTL some backends reject (Redis `EX 0`).
            # Whatever id it now lives under, the handler's own rotation included, is deleted.
            if !is_new && ttl == 0
                _end_session!(store, final_session_id, "past its absolute lifetime")
                return response
            end

            # Stamp the sign-in with the user's current `session_auth_hash` (#391). Before the
            # rotation below, so the data it moves already carries the stamp.
            if session_auth_hash !== nothing
                _stamp_auth_hash!(current_session, final_session_id, original_auth_marker, auth_key,
                                  validator, session_auth_hash,
                                  get(req.context, :session_auth_rehash, false) === true)
            end

            # Retire the previous ID when an existing session crosses an auth boundary. If a
            # concurrent logout deleted the session meanwhile, the rotation finds nothing to move
            # and the id stays put, so the update-only write below drops this request's data
            # (#361).
            if rotate_on_auth && !is_new && final_session_id == session_id
                current_auth_marker = _auth_marker(current_session, final_session_id, auth_key, validator)
                if _auth_marker_changed(original_auth_marker, current_auth_marker)
                    regenerate_session!(req, store; ttl=ttl)
                    final_session_id = req.context[:session_id]
                end
            end

            # `:session_modified` is Django's `modified` flag: something OUTSIDE the session data
            # depends on this session existing. `CSRFMiddleware` sets it whenever it hands out a
            # token bound to the id -- without it an anonymous visitor's token would be bound to
            # an id that was never saved, and every later POST would 403. It hands one to a new
            # visitor only when a handler asked (`csrf_token!`, #431), never on every safe request.
            #
            # A loaded session that is still UNCONFIRMED is forced too (#440): its browser just
            # sent the cookie back, which is the confirmation. One write moves it to the full
            # lifetime and re-sets the cookie; a confirmed session never pays it.
            forced = get(req.context, :session_modified, false) === true || unconfirmed
            rotated = final_session_id != session_id

            # A NEW session is saved lazily (#317): only once it holds data, was rotated, or was
            # marked modified. It used to be saved for `max_age` -- and handed a cookie -- on
            # every cookieless request, so a `/health` loop grew `MemoryStore` without bound and
            # cost a PormG store a SELECT plus an INSERT per request.
            #
            # A new visitor's session -- whatever id it ends the request under -- is inserted. A
            # session the request LOADED is written back update-only (#318): if a concurrent
            # logout or rotation deleted it meanwhile, the write is dropped and the cookie is not
            # re-set. Upserting it re-created the deleted session, so a stolen id outlived the
            # logout meant to kill it and the browser was logged back in.
            #
            # That covers a loaded session this request ROTATED too (#361). `rotate_session!` has
            # already moved it to `final_session_id`, so the row exists, and the update carries
            # whatever the handler changed after rotating. This branch used to upsert the new id;
            # update-only is the same write, except that it never re-creates a row something
            # deleted after the rotation. It also re-clamps the expiry of a handler's own
            # `regenerate_session!(…; ttl)` to the absolute deadline, and keeps `created` (#362),
            # which an upsert would reset. The single exception, a rotated session left empty
            # and anonymous, is the branch just below the new-visitor one.
            #
            # A new session that ends the request ANONYMOUS is saved UNCONFIRMED (#440): with the
            # short `unconfirmed_max_age` until its browser sends the cookie back. A script that
            # never returns its cookie leaves rows the janitor reclaims within the hour, not the
            # day. If the store reports itself full (`session_store_full`), it is not saved at all.
            # A new session that ends the request signed in -- a cookieless login -- is neither.
            if is_new && (rotated || forced || !isempty(current_session))
                anonymous = _auth_marker(current_session, final_session_id, auth_key,
                                         validator) === nothing
                # `::Bool`: an optional contract method a custom store implements, asserted like
                # `update_session!` below so a wrong return fails by name.
                if anonymous && session_store_full(store)::Bool
                    _warn_store_full(warned_full, store)
                    session_written = false
                else
                    if anonymous
                        # The store has room again: the next time it fills is worth a warning too.
                        warned_full[] && (warned_full[] = false)
                        unconfirmed_max_age === nothing || (ttl = min(ttl, unconfirmed_max_age))
                    end
                    _save_session(store, final_session_id, current_session, ttl)
                    session_written = true
                end
            elseif !is_new && rotated && isempty(current_session) &&
                   _auth_marker(current_session, final_session_id, auth_key, validator) === nothing
                # A rotated session that ENDS the request empty, with no identity -- what the
                # logout recipe (`empty!` + `regenerate_session!`) leaves -- starts a fresh
                # absolute clock (#362). There is nothing for the cap to bound, and carrying the
                # clock meant logging out and back in on day 6 left a day. `set_session!` stamps a
                # new `created`. Decided HERE, on the final contents, not when
                # `regenerate_session!` ran: a handler that emptied, rotated, then put the identity
                # back would otherwise have handed a stolen session a fresh week. "No identity"
                # asks the same `auth_key`/`validator` question `rotate_on_auth` does, so an app
                # that keys identity outside the session dict -- by id, through `validator` -- is
                # not mistaken for logged out. Only this request knows the id.
                ttl = _write_ttl(max_age, absolute_max_age, write_now, write_now)
                _save_session(store, final_session_id, current_session, ttl)
                session_written = true
            elseif !is_new && (rotated || forced || current_session != original_session)
                # `::Bool`: the contract's return type, asserted so inference does not carry `Any`
                # (`current_session` comes out of `req.context`) into the branch below.
                session_written = update_session!(store, final_session_id, current_session;
                                                  ttl = ttl)::Bool
            else
                session_written = false
            end

            if session_written
                # Own the headers before adding Set-Cookie: `response` may be a shared/`const`
                # object (e.g. an auth-rejection response). Mutating it in place would attach
                # this visitor's session cookie to every later request that returns the same
                # object — a cross-request session leak — and races other threads.
                response = own_response_headers(response)
                # Append the session cookie without clobbering any sibling Set-Cookie headers.
                set_cookie!(response, session_cookie, final_session_id; config=config, encrypted=false, maxage=ttl)
                _mark_private!(response)
            end

            return response
        end
    end

    return LifecycleMiddleware(; middleware, on_startup, on_shutdown)
end

function _get_session_id(req::HTTP.Request, cookie_name::String)
    return get_cookie(req, cookie_name)
end

# The most protected name the attributes allow (#329). `nitro_session` used to be the default
# whatever the attributes, so a sibling subdomain or a plain-HTTP attacker could plant
# `nitro_session=<their own logged-in id>; Path=/account` -- sent first, so it won -- and the
# victim acted inside the attacker's account. Fixation and CSRF bypass were not possible
# (unknown ids are refused, CSRF tokens are session-bound); session swapping was.
function _default_session_cookie_name(config::CookieConfig)
    config.secure || return "nitro_session"
    return (config.domain === nothing && config.path == "/") ?
        "__Host-nitro_session" : "__Secure-nitro_session"
end

function _generate_session_id()
    return string(secure_uuid4())
end

# Returns `(data, is_new, created, unconfirmed)`. `created` is the loaded session's creation
# instant, or now for a new one -- the instant its absolute lifetime will be measured from once it
# is saved. `unconfirmed` is whether a loaded session is still on its unconfirmed lifetime (#440).
function _load_session(store::AbstractSessionStore{String, Dict{String,Any}}, session_id::Nullable{String},
                       absolute_max_age::Nullable{Int}, unconfirmed_max_age::Nullable{Int})
    now = Dates.now(Dates.UTC)
    if isnothing(session_id)
        return Dict{String,Any}(), true, now, false
    end

    payload = Base.get(store, session_id, nothing)
    if isnothing(payload)
        return Dict{String,Any}(), true, now, false
    end

    # DEEP copies (#318). A shallow `copy` shared every nested value -- the docs' `cart` vector,
    # a nested `Dict` -- between the store and every concurrent request of the session, which
    # all mutated it at once: lost writes, and a corrupted `Dict` that threw on every later
    # request. `PormGSessionStore` decodes fresh JSON per read and never had the bug.
    if payload isa SessionPayload
        if is_expired(payload, now)
            return Dict{String,Any}(), true, now, false
        end
        if _past_absolute_age(payload.created, absolute_max_age, now)
            # Past its absolute lifetime (#362): absent, like an expired session, whatever its
            # sliding expiry says. Deleted rather than merely refused, because the readers that
            # bypass this middleware -- `get_session`, the `Session{T}` extractor,
            # `session_user_validator` -- see only `expires`. This middleware's own writes never
            # put `expires` past the deadline, so such a row was written some other way: under a
            # cap since lowered, by a direct `set_session!`/`storesession!`, or by another
            # `SessionMiddleware` on the same store with a looser cap. Deleting it makes this
            # middleware's cap bind them all -- which is why two middlewares sharing a store
            # should share a cap too.
            _end_session!(store, session_id, "past its absolute lifetime")
            return Dict{String,Any}(), true, now, false
        end
        return deepcopy(payload.data), false, payload.created,
               _unconfirmed_payload(payload, unconfirmed_max_age)
    end

    # A store whose `Base.get` hands back bare data breaks the contract (it must return a
    # `SessionPayload`) and says nothing about when the session was created. Serving it under a
    # cap would switch the cap off without a word, so it is refused instead -- loudly, once.
    if absolute_max_age !== nothing
        @warn "SessionMiddleware: the session store returned something other than a " *
              "`SessionPayload`, so the session's age cannot be checked against " *
              "`absolute_max_age` and the session is treated as absent. Return a " *
              "`SessionPayload(data, expires, created)` from `Base.get` (#362), or pass " *
              "`absolute_max_age = nothing`." store_type = typeof(store) maxlog = 1
        return Dict{String,Any}(), true, now, false
    end
    # A bare payload carries no lifetime, so it cannot be recognised as unconfirmed: it reads as
    # confirmed and is never promoted. Every anonymous session in such a store therefore lapses at
    # `unconfirmed_max_age` however much it is used -- said once, since nothing else would (#440).
    if unconfirmed_max_age !== nothing
        @warn "SessionMiddleware: the session store returned something other than a " *
              "`SessionPayload`, so a new anonymous session can never be confirmed and lapses " *
              "after `unconfirmed_max_age` however often its visitor returns. Return a " *
              "`SessionPayload(data, expires, created)` from `Base.get`, or pass " *
              "`unconfirmed_max_age = nothing` (#440)." store_type = typeof(store) maxlog = 1
    end
    data = payload isa AbstractDict ? deepcopy(payload) : payload
    return data, false, now, false
end

# Whether a stored session is still UNCONFIRMED (#440): saved anonymous by the request that created
# it, and not yet seen again. That save is the only write that gives a session a lifetime of exactly
# `unconfirmed_max_age` (`expires - created`), so the payload says it with no extra column and no
# reserved session key -- the store contract is unchanged. Every other write leaves at least the
# full lifetime, which the constructor keeps at twice `unconfirmed_max_age` or more.
#
# "Within a second", not "equal": a store keeping whole seconds truncates both instants. They come
# from one `now` and differ by a whole number of seconds, so it does not move their difference, but
# a custom store is free to round each differently.
function _unconfirmed_payload(payload::SessionPayload, unconfirmed_max_age::Nullable{Int})::Bool
    unconfirmed_max_age === nothing && return false
    lifetime = payload.expires - payload.created
    return abs(Dates.value(lifetime) - 1000 * unconfirmed_max_age) < 1000
end

# Once per spell of fullness: a full store refuses every anonymous insert, and a warning per refusal
# would be a second flood. The flag is cleared by the next anonymous save the store accepts, so a
# store that fills again later warns again. The store type is named; never a session id.
function _warn_store_full(warned::Threads.Atomic{Bool}, store::AbstractSessionStore)
    Threads.atomic_xchg!(warned, true) && return nothing
    @warn "SessionMiddleware: the session store is full, so new anonymous sessions are not being " *
          "saved. Signed-in and existing sessions are unaffected. Raise the store's bound, or " *
          "look for a flood of cookieless requests to a route that writes the session (#440)." store_type = typeof(store)
    return nothing
end

# Deletes a session this middleware refuses: one that has outlived its absolute lifetime (#362),
# or whose sign-in a `session_auth_hash` change revoked (#391). `why` completes "a session ..." in
# the log. Nothing depends on the delete succeeding: the session is treated as absent either way.
# So a failing store is logged and the request carries on without the session, rather than
# failing with a 500 before the handler even runs. The log names the exception's type only -- a
# store's own error could quote the key, and the key is the credential. An interrupt, an overflow
# or an out-of-memory still propagates (#254).
function _end_session!(store::AbstractSessionStore, session_id::String, why::String)
    try
        delete_session!(store, session_id)
    catch e
        is_unrecoverable(e) && rethrow()
        @warn "SessionMiddleware: failed to delete a session $why; it is refused anyway" exception_type = typeof(e)
    end
    return nothing
end

# Whether a loaded session's sign-in has been revoked (#391): it has an identity, and it does not
# carry the hash `hook` gives that identity now. An anonymous session has nothing to revoke and
# never costs a hook call.
function _auth_hash_stale(session_data::Dict{String,Any}, session_id::String, auth_key::String,
                          validator::Union{Function, Nothing}, hook::Function)::Bool
    marker = _auth_marker(session_data, session_id, auth_key, validator)
    marker === nothing && return false
    return !_session_auth_hash_current(session_data, marker, hook)
end

# Keeps the `SESSION_AUTH_HASH_KEY` stamp in step with the session's identity at the end of a
# request (#391). The stamp is written when the identity is SET -- a login or a user switch -- or
# when the handler asked for it with `rehash_session!`, and removed when the identity is cleared.
#
# It is deliberately NOT refreshed on a rotation. That is the whole point: the #391 residual is a
# request that rotates the session while a "sign out everywhere" lands. Re-stamping on rotation
# would read the user's post-logout value into the rotated session and let it outlive the logout
# it raced. A session keeps the value it was signed in with until something re-authenticates it.
#
# A hook answering `nothing` for a new identity leaves no stamp, so the next load refuses the
# session; the stale stamp of a previous identity is removed rather than inherited.
function _stamp_auth_hash!(session::Dict{String,Any}, session_id::String, original_marker,
                           auth_key::String, validator::Union{Function, Nothing}, hook::Function,
                           rehash::Bool)
    marker = _auth_marker(session, session_id, auth_key, validator)
    if marker === nothing
        delete!(session, SESSION_AUTH_HASH_KEY)
    elseif rehash || _auth_marker_changed(original_marker, marker)
        stamp = hook(marker)::Nullable{AbstractString}
        # Stored as a plain `String`, whatever string type the hook returned, so every store
        # (PormG's JSON column included) holds the same thing.
        stamp === nothing ? delete!(session, SESSION_AUTH_HASH_KEY) :
                            (session[SESSION_AUTH_HASH_KEY] = String(stamp))
    end
    return nothing
end

"""
    rehash_session!(req::HTTP.Request) -> Nothing

Re-stamp the current session with the user's current `session_auth_hash` value at the end of this
request, so a change that revokes the user's other sessions does not revoke this one (#391). This
is Django's `update_session_auth_hash`.

The typical case is a password change under a hook derived from the password hash, or a "sign out
my other devices" button:

```julia
function change_password(req)
    set_password!(current_user(req), getjson(req)["new_password"])   # the hook's value changes
    rehash_session!(req)                           # ...and this session keeps up with it
    regenerate_session!(req, store)                # a fresh id after a credential change
    return Res.status(204)
end
```

Without it, the session that made the change is refused on its next request, like every other
session of the user.

The stamp is taken when the request ends, so it is whatever the hook returns at that point. A
"sign out everywhere" that commits while this request is still running is therefore overtaken by
it, and this session survives. The re-stamp really did happen after the logout.

This call only sets a flag. It has no effect without `SessionMiddleware(session_auth_hash = …)`,
or when the session has no signed-in identity.
"""
function rehash_session!(req::HTTP.Request)
    req.context[:session_auth_rehash] = true
    return nothing
end

# Whether a session created at `created` has outlived `absolute_max_age` as of `now`. The
# boundary counts as past, the same convention `is_expired` uses for the sliding expiry.
function _past_absolute_age(created::DateTime, absolute_max_age::Nullable{Int}, now::DateTime)
    absolute_max_age === nothing && return false
    return created + Dates.Second(absolute_max_age) <= now
end

# The seconds a write may keep a session alive: the sliding `max_age`, cut short at the
# absolute deadline (#362). Every store write and the cookie's Max-Age go through this, so the
# stored `expires` never passes the deadline -- which is what makes the cap bind the readers
# that never pass through this middleware, through the `is_expired` check they already make.
function _write_ttl(max_age::Int, absolute_max_age::Nullable{Int}, created::DateTime,
                    now::DateTime)::Int
    absolute_max_age === nothing && return max_age
    # Whole seconds, rounded DOWN: rounding up would let the expiry overshoot the deadline.
    left = fld(Dates.value(created + Dates.Second(absolute_max_age) - now), 1000)
    return clamp(left, 0, max_age)
end

function _auth_marker(session_data::Dict{String,Any}, session_id::Nullable{String}, auth_key::String, validator::Union{Function, Nothing})
    # Prefer the explicit session key and fall back to a validator-derived identity.
    auth_marker = _auth_marker_for_key(session_data, auth_key)
    if !isnothing(auth_marker) || isnothing(validator) || isnothing(session_id)
        return auth_marker
    end

    if applicable(validator, session_id, session_data)
        return validator(session_id, session_data)
    end

    if applicable(validator, session_id)
        return validator(session_id)
    end

    return nothing
end

function _auth_marker_for_key(session_data::Dict{String,Any}, auth_key::String)
    if haskey(session_data, auth_key)
        return session_data[auth_key]
    end

    auth_sym = Symbol(auth_key)
    if haskey(session_data, auth_sym)
        return session_data[auth_sym]
    end

    return nothing
end

function _auth_marker_changed(original_auth_marker, current_auth_marker)
    return !isequal(original_auth_marker, current_auth_marker)
end

function _save_session(store::AbstractSessionStore{String, Dict{String,Any}}, session_id::String, data::Dict{String,Any}, max_age::Int)
    storesession!(store, session_id, data; ttl=max_age)
end

end # module SessionMiddleware_
