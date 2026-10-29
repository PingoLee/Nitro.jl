module HealthHandlers

using HTTP
using Nitro

health(req::HTTP.Request) = Res.json(Dict("status" => "ok"))

end # module
