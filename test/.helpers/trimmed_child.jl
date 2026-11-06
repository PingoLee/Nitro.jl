# The child `test/trimmed_branches_tests.jl` spawns (#858). Run as a script:
#
#     julia --project=<the test env> test/.helpers/trimmed_child.jl
#
# Under the JIT `_trimmed()` is the constant `false`, so the branches a trimmed image takes are dead
# code in every test process. This one runs each case twice: first under the JIT, then after
# redefining `_trimmed()` to `true` the way a `--trim` build's first route registration does
# (`_flip_trimmed!`, src/routeendpoint.jl). The redefinition invalidates every caller compiled
# against `false`, so the second run takes the trimmed branches. The two outcomes are compared, and
# each refusal's optimized code is searched for a dynamic call.
#
# Every function is called directly. Nothing goes through `internalrequest` or a served request:
# with `_trimmed()` true a `RouteEndpoint` `ccall`s a thunk only a `--trim` build exports.
#
# Each check prints one line, which the parent reads:
#   OK <file>:<func> | <case>
#   FAIL <file>:<func> | <case>: <detail>
#   NOCHECK <file>:<func> | <what is missing>
#   FLIP=<whether the redefinition reached Nitro's compiled code>

include(joinpath(@__DIR__, "trimmed_sites.jl"))

import Nitro, Test, JSON, Sockets
const HTTP = Nitro.Core.HTTP
const T = Nitro.Core.Types
const U = Nitro.Core.Util
const MW = Nitro.Core.Middleware
const SM = MW.SessionMiddleware_
const CSRF = MW.CSRFMiddleware_
const G = MW.GuardsMiddleware
const AM = MW.AuthMiddleware
const EIP = MW.ExtractIPMiddleware
const AL = MW.StructuredAccessLogMiddleware
const SH = MW.SecurityHeadersMiddleware
const RH = Nitro.Core.RouterHOF
const Auth = Nitro.Auth

# A value no message may carry. A refusal names the type it got, never the value.
const SENTINEL = "S3NT1NEL"
const BIG_SENTINEL = big(1234567890123)

struct TrimSentinel
    secret::String
end

struct TrimBody
    secret::String
end

# The same walk as `dynamic_calls` in test/setup_tests.jl (a child cannot load the `NitroCommon`
# testsetup). With `closures = true` it also walks the closures the method builds, one level down:
# a `lock(l) do … end` body is a method of its own, and `register_serve_lifecycle!`'s refusal sits
# in one.
function dynamic_calls(f, types; closures::Bool = false)
    found = String[]
    walked = Ref(0)
    _dynamic_calls!(found, walked, code_typed(f, types; optimize = true), closures ? 1 : 0)
    # A closure walk that found no closure would pass without looking at the refusal.
    closures && walked[] == 0 && push!(found, "no closure built in the method, so none was walked")
    return found
end

function _dynamic_calls!(found, walked, typed, depth)
    for (ci, _) in typed, st in ci.code
        st isa Expr || continue
        if st.head === :call
            g = st.args[1]
            callee = g isa GlobalRef ? getglobal(g.mod, g.name) : g isa QuoteNode ? g.value : g
            callee isa Core.Builtin || push!(found, sprint(show, st))
        elseif st.head === :new && depth > 0
            C = st.args[1]
            C isa GlobalRef && (C = getglobal(C.mod, C.name))
            if C isa DataType && C <: Function && occursin('#', string(nameof(C)))
                walked[] += 1
                _dynamic_calls!(found, walked, Base.code_typed_by_type(Tuple{C}; optimize = true), depth - 1)
            end
        end
    end
    return found
end

# ── The cases ──────────────────────────────────────────────────────────────────────────────────
#
# Each one runs in both phases. `expect` says how the two outcomes must relate:
#   (:same, want)           both answer a value, equal by `isequal` and by the types all the way
#                           down; `want`, unless `nothing`, is also the expected value, so both
#                           cannot be wrong together. `want = Raises(name)` instead: both throw a
#                           `name`, with the same message
#   (:message, text, jit)   the trimmed image refuses with an `ArgumentError` whose message is
#                           exactly `text`, and the JIT answers `jit` (`:any` when not pinned). Every
#                           refusal's text is fixed but for the type it names, so the exact text
#                           also tells which site refused. For a value outside the JSON types this is
#                           the documented trimmed divergence
#   (:names, type, jit)     the same, for the one refusal that prints a whole type, which only has
#                           to name `type`
#   (:fallback, value, jit) the trimmed image answers `value` where the JIT answers `jit`
#   (:diverges, jit, error) the JIT answers `jit` and the trimmed image throws an `error`: a case
#                           built so the two branches disagree, which shows the trimmed one ran
# Every message must also be free of the sentinels.

struct Raises
    name::String
end

# The refusals' texts, as src/ writes them, up to the type each names.
const READS_JSON = "Nitro: a trimmed image reads only JSON-shaped claim and session values; got a "  # jsonvalue.jl
const COMPARES_JSON = "Nitro: a trimmed image compares only JSON-shaped session values; got a "      # jsonvalue.jl
const COPIES_JSON = "Nitro: a trimmed image copies only JSON-shaped session values; got a "          # jsonvalue.jl
const READS_IDENTITY = "Nitro: a trimmed image reads an identity as a String or a Dict{String,Any}; got a "
const LOADS_SESSION = "Nitro: a trimmed image loads only a Dict{String,Any} session; got a "
const READS_SESSION = "Nitro: a trimmed image reads only the Dict{String,Any} session SessionMiddleware stores; got a "
const READS_ADDRESS = "Nitro: a trimmed image reads the client address only as an IPv4 or IPv6; got a "
const READS_CLAIMS = "Nitro: a trimmed image reads claims from a Principal or a Dict{String,Any}; got a "
const READS_CONTAINS = "Nitro: a trimmed image reads a :contains claim as a JSON array; got a "
const READS_TIME = "Nitro: a trimmed image reads a time claim as an Int64, a Float64 or a String; got a "
const READS_STRING = "Nitro: a trimmed image reads a claim as a string only from a JSON scalar; got a "
const BINDS_CSRF = "Nitro: a trimmed image binds CSRF tokens only to a String session id; got a "

const CASES = Tuple{String, String, Function, Tuple}[]
case!(file, func, name, thunk, expect...) = push!(CASES, ("$file:$func", name, thunk, expect))

const DYNAMIC = Tuple{String, Any, Tuple, Bool}[]
dynamic!(file, func, f, types...; closures::Bool = false) = push!(DYNAMIC, ("$file:$func", f, types, closures))

outcome(thunk) = try
    (:value, thunk())
catch e
    (:error, string(nameof(typeof(e))), e isa ArgumentError ? e.msg : sprint(showerror, e))
end

shape(v::AbstractDict) = (typeof(v), sort!([string(k) => shape(x) for (k, x) in v]; by = first))
shape(v::AbstractVector) = (typeof(v), map(shape, v))
shape(v::Tuple) = map(shape, v)
shape(v) = typeof(v)

same_value(a, b) = isequal(a, b) && shape(a) == shape(b)

# ── A: sessions ────────────────────────────────────────────────────────────────────────────────

const SMF = "src/middleware/session_middleware.jl"

empty_session() = Dict{String, Any}()
flat() = Dict{String, Any}("s" => "x", "i" => 1, "f" => 1.5, "b" => true, "n" => nothing)
nested() = Dict{String, Any}(
    "user" => Dict{String, Any}("id" => 7, "roles" => Any["admin", "ops"], "name" => "A"),
    "cart" => Any[Dict{String, Any}("sku" => "x1", "qty" => 2)],
    "matrix" => Any[Any[1, 2], Any[3.5, nothing]])
with_object() = Dict{String, Any}("prefs" => JSON.parse("""{"theme":"dark","tags":["a",{"k":1}]}"""))
with_missing() = Dict{String, Any}("m" => missing, "s" => SENTINEL)
with_symbol() = Dict{String, Any}("k" => Symbol(SENTINEL))
edited(f, d) = (f(d); d)

for (name, current, original, want) in (
        ("unchanged nested", nested, nested, false),
        ("empty", empty_session, empty_session, false),
        ("a nested push", () -> edited(d -> push!(d["cart"], 1), nested()), nested, true),
        ("a nested edit", () -> edited(d -> (d["user"]["roles"][2] = "dev"), nested()), nested, true),
        ("an added key", () -> edited(d -> (d["new"] = 1), nested()), nested, true),
        ("a renamed key", () -> Dict{String, Any}("a" => 1), () -> Dict{String, Any}("b" => 1), true),
        ("1 against 1.0", () -> Dict{String, Any}("i" => 1), () -> Dict{String, Any}("i" => 1.0), false),
        ("-0.0 against 0.0", () -> Dict{String, Any}("z" => -0.0), () -> Dict{String, Any}("z" => 0.0), false),
        ("NaN against NaN", () -> Dict{String, Any}("x" => NaN), () -> Dict{String, Any}("x" => NaN), true),
        ("a Dict against an equal JSON.Object",
         () -> Dict{String, Any}("p" => Dict{String, Any}("a" => 1, "b" => Any["c"])),
         () -> Dict{String, Any}("p" => JSON.parse("""{"a":1,"b":["c"]}""")), false),
        ("a JSON.Object value, unchanged", with_object, with_object, false),
        ("against no original", nested, () -> nothing, true))
    case!(SMF, "_session_changed", name, () -> SM._session_changed(current(), original()), :same, want)
end
case!(SMF, "_session_changed", "a missing value", () -> SM._session_changed(with_missing(), with_missing()),
      :message, COMPARES_JSON * "Missing", missing)
case!(SMF, "_session_changed", "a Symbol value", () -> SM._session_changed(with_symbol(), with_symbol()),
      :message, COMPARES_JSON * "Symbol", false)

# The copy is checked for isolation, not only for equality: the handler edits its copy, and the
# change check compares it with the stored original afterwards (#318).
function isolation(copy)
    original = nested()
    c = copy(original)
    push!(c["cart"], Dict{String, Any}("sku" => "x2", "qty" => 1))
    c["user"]["roles"][1] = "changed"
    c["matrix"][1][1] = 99
    untouched = isequal(original, nested())
    original["user"]["name"] = "B"
    push!(original["matrix"], 0)
    separate = c["user"]["name"] == "A" && length(c["matrix"]) == 2
    return (untouched, separate, SM._session_changed(c, nested()))
end

for (file, func, copy) in ((SMF, "_copy_session", SM._copy_session),
                           ("src/types.jl", "_copy_session_value", T._copy_session_value))
    for (name, input) in (("empty", empty_session), ("flat scalars", flat), ("nested", nested),
                          ("a JSON.Object value", with_object))
        case!(file, func, name, () -> copy(input()), :same, input())
    end
    case!(file, func, "the copy is isolated", () -> isolation(copy), :same, (true, true, true))
    case!(file, func, "a missing value", () -> copy(with_missing()), :message, COPIES_JSON * "Missing", :any)
    case!(file, func, "a Symbol value", () -> copy(with_symbol()), :message, COPIES_JSON * "Symbol", :any)
end
# MemoryStore copies values other than a session dict too; those keep `deepcopy` in both.
case!("src/types.jl", "_copy_session_value", "a Vector", () -> T._copy_session_value([1, 2]), :same, [1, 2])
case!("src/types.jl", "_copy_session_value", "a String", () -> T._copy_session_value("x"), :same, "x")

# ── A: JWT claims ─────────────────────────────────────────────────────────────────────────────

const CLAIMS = """{"sub":"u1","iat":1700000000,"exp":1.7e9,"admin":true,"n":null,"roles":["a","b"],
                  "ctx":{"org":{"id":7,"tags":[{"k":"v"},[1,2.5,null]]}}}"""
for (name, text, max_fields, want) in (
        ("nested claims", CLAIMS, 0, nothing),
        ("a duplicate key: the later one wins", """{"a":1,"a":{"b":2}}""", 0,
         Dict{String, Any}("a" => Dict{String, Any}("b" => 2))),
        ("an empty object", "{}", 0, Dict{String, Any}()),
        ("objects inside arrays inside arrays", """{"x":[[{"a":[{}]}]],"y":[]}""", 0,
         Dict{String, Any}("x" => Any[Any[Dict{String, Any}("a" => Any[Dict{String, Any}()])]], "y" => Any[])),
        ("unicode", """{"nome":"São Paulo","ключ":"значение","emoji":"🚀"}""", 0, nothing),
        ("numbers", """{"i":-5,"f":1.25e3,"big":12345678901234,"z":0}""", 0,
         Dict{String, Any}("i" => -5, "f" => 1250.0, "big" => 12345678901234, "z" => 0)),
        ("within max_fields", """{"a":1,"b":{"c":2}}""", 10, nothing),
        ("over max_fields", """{"a":1,"b":2,"c":3,"d":{"e":4}}""", 2, Raises("ValidationError")),
        ("not JSON", """{"a":""", 0, Raises("ArgumentError")))
    case!("src/Auth/jwt.jl", "_parse_jwt_claims", name,
          () -> Auth._parse_jwt_claims(Vector{UInt8}(text); max_fields), :same, want)
end

# ── A: the validator's arity ───────────────────────────────────────────────────────────────────

one_arg(token) = "one:" * token
two_args(token, req) = "two:" * token * ":" * req.target
# What the middleware answers when it is built (src/middleware/auth_middleware.jl,
# src/Auth/validators.jl): before the redefinition, as at build time.
const BUILT_ONE = U._takes_request(one_arg)
const BUILT_TWO = U._takes_request(two_args)
const REQ = HTTP.Request("GET", "/path")

case!("src/Auth/validators.jl", "_validator_takes_request", "a one-argument validator",
      () -> Auth._validator_takes_request(one_arg, BUILT_ONE), :same, false)
case!("src/Auth/validators.jl", "_validator_takes_request", "a two-argument validator",
      () -> Auth._validator_takes_request(two_args, BUILT_TWO), :same, true)
case!("src/middleware/auth_middleware.jl", "_validate_token", "a one-argument validator",
      () -> AM._validate_token(one_arg, REQ, "tok", BUILT_ONE), :same, "one:tok")
case!("src/middleware/auth_middleware.jl", "_validate_token", "a two-argument validator",
      () -> AM._validate_token(two_args, REQ, "tok", BUILT_TWO), :same, "two:tok:/path")
# The answers above agree whichever branch ran, because `built` is the truth. With `built` wrong, the
# JIT still asks the method table and a trimmed image believes `built`, which shows its branch ran.
case!("src/middleware/auth_middleware.jl", "_validate_token", "a one-argument validator built as two",
      () -> AM._validate_token(one_arg, REQ, "tok", true), :diverges, "one:tok", "MethodError")

# ── B: refusals, fallbacks, and the missing cases ──────────────────────────────────────────────

const JV = "src/jsonvalue.jl"
case!(JV, "_with_foreign_json_value", "a claim of another type, read as a string",
      () -> Auth._claim_string(TrimSentinel(SENTINEL)), :message, READS_JSON * "TrimSentinel", :any)
# An app's own claims dict can hold a `missing` (#849's review). The JIT keeps Base's three-valued
# answer; a trimmed image refuses the value.
case!(JV, "_with_foreign_json_value", "claim_required(:equals) on a missing claim",
      () -> G._claim_equals(Dict{String, Any}("role" => missing, "s" => SENTINEL), "role", "admin"),
      :message, READS_JSON * "Missing", missing)
case!(JV, "_with_foreign_json_value", "claim_required(:contains) over Any[missing, \"write\"], a match",
      () -> G._claim_contains(Dict{String, Any}("scope" => Any[missing, "write"]), "scope", "write"),
      :message, READS_JSON * "Missing", true)
case!(JV, "_with_foreign_json_value", "claim_required(:contains) over Any[missing, \"write\"], no match",
      () -> G._claim_contains(Dict{String, Any}("scope" => Any[missing, "write"]), "scope", "read"),
      :message, READS_JSON * "Missing", missing)
dynamic!(JV, "_with_foreign_json_value", T._with_foreign_json_value, typeof(Auth._claim_string_typed), Any)
dynamic!(JV, "_with_foreign_json_value", T._with_foreign_json_value, typeof(T._json_equal_scalar), Any, typeof(==), Any)
dynamic!(JV, "_with_foreign_json_value", T._with_foreign_json_value, typeof(G._is_equal_to), Any, String)

case!(JV, "_foreign_equal", "a session value of another type, by ==",
      () -> T._json_equal(==, Any[TrimSentinel(SENTINEL)], Any[TrimSentinel(SENTINEL)]),
      :message, COMPARES_JSON * "TrimSentinel", :any)
case!(JV, "_foreign_equal", "an auth marker of another type, by isequal",
      () -> SM._auth_marker_changed(TrimSentinel(SENTINEL), "marker"), :message, COMPARES_JSON * "TrimSentinel", true)
dynamic!(JV, "_foreign_equal", T._foreign_equal, typeof(==), Any, Any)
dynamic!(JV, "_foreign_equal", T._foreign_equal, typeof(isequal), Any, Any)

case!(JV, "_foreign_copy", "a session value of another type",
      () -> T._json_copy(Dict{String, Any}("k" => TrimSentinel(SENTINEL))), :message, COPIES_JSON * "TrimSentinel", :any)
dynamic!(JV, "_foreign_copy", T._foreign_copy, Any)

case!("src/types.jl", "_is_nonempty_abstract", "an identity of another string type",
      () -> T._is_identity(Test.GenericString(SENTINEL)), :message, READS_IDENTITY * "GenericString", true)
dynamic!("src/types.jl", "_is_nonempty_abstract", T._is_nonempty_abstract, Any)

case!("src/types.jl", "_pathparams_foreign", "a :params map a middleware wrote",
      () -> T._pathparams_foreign(Dict("id" => SENTINEL)),
      :message, "Nitro: req.context[:params] holds a value that is not HTTP.Handlers.Params",
      Dict("id" => SENTINEL))
dynamic!("src/types.jl", "_pathparams_foreign", T._pathparams_foreign, Any)

case!(SMF, "_copy_foreign_session", "a session of another shape",
      () -> SM._copy_session(Dict{Symbol, Any}(:k => SENTINEL)), :message, LOADS_SESSION * "Dict", :any)
dynamic!(SMF, "_copy_foreign_session", SM._copy_foreign_session, Any)

function foreign_session_request()
    req = HTTP.Request("GET", "/")
    req.context[:session] = Dict{Symbol, Any}(:user => SENTINEL)
    return req
end
case!("src/core/request.jl", "_with_foreign_session", "a session of another shape",
      () -> Nitro.Core.with_session(CSRF._holds_data, foreign_session_request()), :message, READS_SESSION * "Dict", true)
dynamic!("src/core/request.jl", "_with_foreign_session", Nitro.Core._with_foreign_session, typeof(CSRF._holds_data), Any)
dynamic!("src/core/request.jl", "_with_foreign_session", Nitro.Core._with_foreign_session, typeof(G._session_claims), Any, String)

next_handler(req) = HTTP.Response(200)
case!("src/middleware/extract_ip.jl", "_extract_foreign!", "a :ip of another type",
      () -> EIP._extract_foreign!(next_handler, HTTP.Request("GET", "/"), EIP._NO_TRUST, TrimSentinel(SENTINEL)),
      :message, READS_ADDRESS * "TrimSentinel", :any)
dynamic!("src/middleware/extract_ip.jl", "_extract_foreign!", EIP._extract_foreign!,
         typeof(next_handler), typeof(REQ), EIP._TrustPolicy, Any)

const GF = "src/middleware/guards.jl"
case!(GF, "_with_foreign_claims", "claims of another shape",
      () -> G._with_claims(G._claim_equals, Dict{Symbol, Any}(:role => SENTINEL), "role", "admin"),
      :message, READS_CLAIMS * "Dict", :any)
dynamic!(GF, "_with_foreign_claims", G._with_foreign_claims, typeof(G._claim_equals), Any, String, String)
dynamic!(GF, "_with_foreign_claims", G._with_foreign_claims, typeof(G._claim_contains), Any, String, String)

case!(GF, "_foreign_contains", "a :contains claim that is not a JSON array",
      () -> G._claim_contains(Dict{String, Any}("scope" => [SENTINEL]), "scope", "x"), :message, READS_CONTAINS * "Array", false)
dynamic!(GF, "_foreign_contains", G._foreign_contains, Any, String)

case!("src/Auth/claims.jl", "_claim_int_abstract", "a time claim of another number type",
      () -> Auth._claim_int(BIG_SENTINEL, "exp"), :message, READS_TIME * "BigInt", Int(BIG_SENTINEL))
dynamic!("src/Auth/claims.jl", "_claim_int_abstract", Auth._claim_int_abstract, Any, String)

case!("src/Auth/claims.jl", "_claim_string_other", "a JSON array read as a string",
      () -> Auth._claim_string(Any[SENTINEL]), :message, READS_STRING * "Array", :any)
dynamic!("src/Auth/claims.jl", "_claim_string_other", Auth._claim_string_other, Any)

case!("src/Auth/validators.jl", "_warn_iss", "an iss that is a JSON array",
      () -> Auth._warn_iss(Any[SENTINEL]), :fallback, "(Array)", "Any[\"$SENTINEL\"]")
case!("src/Auth/validators.jl", "_warn_iss", "an iss that is a JSON object",
      () -> Auth._warn_iss(Dict{String, Any}("k" => SENTINEL)), :fallback, "(Dict)",
      "Dict{String, Any}(\"k\" => \"$SENTINEL\")")
case!("src/Auth/validators.jl", "_warn_iss", "a string iss", () -> Auth._warn_iss("issuer-1"), :same, "issuer-1")
dynamic!("src/Auth/validators.jl", "_warn_iss", Auth._warn_iss, Any)

const CF = "src/middleware/csrf_middleware.jl"
# #851's pin, moved here from test/middleware/csrf_middleware_tests.jl.
case!(CF, "_foreign_binding", "a session id of another string type",
      () -> CSRF._foreign_binding(Test.GenericString("x")),
      :message, BINDS_CSRF * "GenericString", "x")
function generic_binding_request()
    req = HTTP.Request("GET", "/")
    req.context[:session_id] = Test.GenericString(SENTINEL)
    return req
end
case!(CF, "_foreign_binding", "through _binding", () -> CSRF._binding(generic_binding_request()),
      :message, BINDS_CSRF * "GenericString", SENTINEL)
dynamic!(CF, "_foreign_binding", CSRF._foreign_binding, Any)

case!(CF, "_foreign_field_token", "a parsed body of another shape",
      () -> CSRF._foreign_field_token(Dict{Symbol, Any}(:_csrf => SENTINEL), "_csrf"), :fallback, nothing, SENTINEL)
dynamic!(CF, "_foreign_field_token", CSRF._foreign_field_token, Any, String)

const ALF = "src/middleware/access_log.jl"
case!(ALF, "_client_ip_string", "a :ip of another type", () -> AL._client_ip_string(SENTINEL),
      :fallback, nothing, SENTINEL)
case!(ALF, "_client_ip_string", "an IPv4", () -> AL._client_ip_string(Sockets.IPv4("10.0.0.1")),
      :same, "10.0.0.1")
dynamic!(ALF, "_client_ip_string", AL._client_ip_string, Any)

const RE = "src/routeendpoint.jl"
unformatted_endpoint() = T.RouteEndpoint(req -> SENTINEL, "", nothing, C_NULL, C_NULL)
case!(RE, "_format_unregistered", "a leaf endpoint built without its formatted call",
      () -> T._format_unregistered(unformatted_endpoint(), HTTP.Request("GET", "/")),
      :message, "Nitro: a route handler endpoint has no formatted call; register routes with path()", :any)
dynamic!(RE, "_format_unregistered", T._format_unregistered, T.RouteEndpoint, typeof(REQ))

unlisted_response() = HTTP.Response(200, "OK", HTTP.Headers(), HTTP.Headers(), TrimBody(SENTINEL), 0,
                                    0x01, 0x01, false, nothing, nothing, nothing, 0)
case!(RE, "_with_unlisted_body", "a response body Nitro does not build",
      () -> T.with_response(SH._with_security_headers, unlisted_response(), Pair{String, String}[]),
      :names, "TrimBody", :any)
dynamic!(RE, "_with_unlisted_body", T._with_unlisted_body,
         typeof(SH._with_security_headers), HTTP.Response, Vector{Pair{String, String}})

const RF = "src/routerhof.jl"
sentinel_lifecycle() = Nitro.Core.LifecycleMiddleware(middleware = h -> h, on_startup = () -> SENTINEL)
case!(RF, "register_route_lifecycle!", "route middleware with hooks, registered at run time",
      () -> (RH.register_route_lifecycle!(Nitro.Core.App(), Any[sentinel_lifecycle()]); :registered),
      :message, "Nitro: in a trimmed image, register route middleware with lifecycle hooks at top level, " *
                "while the image is built (#719)", :registered)
# The refusal is in the method itself. Its `lock` closure is the registration, which a trimmed image
# runs only while it is being built (`Base.JLOptions().trim != 0`), so the closure is not walked.
dynamic!(RF, "register_route_lifecycle!", RH.register_route_lifecycle!, Nitro.Core.App, Vector{Any})
case!(RF, "register_serve_lifecycle!", "a Vector of serve middleware with hooks",
      () -> (RH.register_serve_lifecycle!(Nitro.Core.App(), Any[sentinel_lifecycle()]); :registered),
      :message, "Nitro: in a trimmed build, pass `serve(middleware = (…))` as a Tuple when it holds " *
                "a LifecycleMiddleware; a Vector's members have no compiled hooks (#719)", :registered)
# Here the refusal is inside the `lock` closure, so that is walked too.
dynamic!(RF, "register_serve_lifecycle!", RH.register_serve_lifecycle!, Nitro.Core.App, Vector{Any};
         closures = true)

# ── Run ────────────────────────────────────────────────────────────────────────────────────────

clip(x) = (s = sprint(show, x); length(s) > 300 ? first(s, 300) * "…" : s)
report(ok, key, name, detail = "") =
    println(ok ? "OK " : "FAIL ", key, " | ", name, ok ? "" : ": " * detail)

value_free(msg) = !occursin(SENTINEL, msg) && !occursin(string(BIG_SENTINEL), msg)

function judge(key, name, expect, jit, trimmed)
    kind = expect[1]
    both = "jit=$(clip(jit)) trimmed=$(clip(trimmed))"
    if kind === :same
        want = expect[2]
        # An error is equivalence only where it was asked for: the same error in both phases is
        # otherwise what a call that no longer fits the method (a `MethodError`) looks like.
        ok = if want isa Raises
            jit[1] === :error && jit[2] == want.name && jit == trimmed
        else
            jit[1] === :value && trimmed[1] === :value && same_value(jit[2], trimmed[2]) &&
                (want === nothing || same_value(jit[2], want))
        end
        return report(ok, key, name, both)
    elseif kind === :diverges
        ok = jit[1] === :value && isequal(jit[2], expect[2]) && trimmed[1] === :error && trimmed[2] == expect[3]
        return report(ok, key, name, both)
    end
    jit_want = expect[3]
    jit_ok = jit_want === :any || (jit[1] === :value && isequal(jit[2], jit_want))
    jit_ok || return report(false, key, name, "the JIT answered $(clip(jit)), expected $(clip(jit_want))")
    if kind === :fallback
        ok = trimmed[1] === :value && isequal(trimmed[2], expect[2]) && value_free(sprint(show, trimmed[2]))
        return report(ok, key, name, "trimmed=$(clip(trimmed)), expected $(clip(expect[2]))")
    end
    refused = trimmed[1] === :error && trimmed[2] == "ArgumentError"
    refused || return report(false, key, name, "trimmed did not refuse: $(clip(trimmed))")
    msg = trimmed[3]
    ok = value_free(msg) && (kind === :message ? msg == expect[2] : occursin(expect[2], msg))
    return report(ok, key, name, "message $(clip(msg))")
end

# The redefinition must reach a method compiled before it: `_validator_takes_request` is compiled
# here, with `_trimmed()` folded to `false`, and has to answer from `built` afterwards.
@assert T._trimmed() === false
jit = [outcome(c[3]) for c in CASES]
flip_before = Auth._validator_takes_request(one_arg, true)

Core.eval(T, :(_trimmed() = true))

flip_after = Auth._validator_takes_request(one_arg, true)
println("FLIP=", T._trimmed() === true && flip_before === false && flip_after === true)

for (i, (key, name, thunk, expect)) in enumerate(CASES)
    judge(key, name, expect, jit[i], outcome(thunk))
end
for (key, f, types, closures) in DYNAMIC
    found = try
        dynamic_calls(f, types; closures)
    catch e
        ["code_typed failed: " * sprint(showerror, e)]
    end
    report(isempty(found), key, "no dynamic call on $(types)", join(found, " ; "))
end

# Every listed site has its checks: A at least one case, B a case and a dynamic-call check.
cased = Set(c[1] for c in CASES)
dynamic_keys = Set(d[1] for d in DYNAMIC)
for ((file, func), kind) in sort!(collect(TRIMMED_SITES); by = first)
    key = "$file:$func"
    kind === :A && !(key in cased) && println("NOCHECK ", key, " | no case")
    if kind === :B
        key in cased || println("NOCHECK ", key, " | no case")
        key in dynamic_keys || println("NOCHECK ", key, " | no dynamic-call check")
    end
end
for key in union(cased, dynamic_keys)
    file, func = split(key, ':'; limit = 2)
    get(TRIMMED_SITES, (file, func), nothing) in (:A, :B) || println("NOCHECK ", key, " | checked but not listed as A or B")
end
println("DONE")
