module GuardsMiddleware

using HTTP
using ...Core: getsession
using ...Types: Nullable

export GuardMiddleware, login_required, role_required, permission_required

function GuardMiddleware(guards::Function...)
return function(handle::Function)
return function(req::HTTP.Request)
for guard in guards
result = guard(req)
if result isa HTTP.Response
return result
end
end
return handle(req)
end
end
end

end # module GuardsMiddleware
