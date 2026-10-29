module MiscHandlers

using HTTP
using Nitro
import ..ROOT

# Under `SessionMiddleware` on the PormG session store: count this session's visits.
function session_visits(req::HTTP.Request)
    session = getsession(req)
    visits = get(session, "visits", 0)::Int + 1
    session["visits"] = visits
    return Res.json(Dict("visits" => visits))
end

# Under `BearerAuth` with `jwt_validator`.
me(req::HTTP.Request) = Res.json(Dict("sub" => getprincipal(req).id))

file(req::HTTP.Request) = Res.file(joinpath(ROOT[], "static", "hello.txt"))

# An error route: the handler throws, Nitro answers 400.
bad(req::HTTP.Request) = throw(ValidationError("bad request on purpose"))

end # module
