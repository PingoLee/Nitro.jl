# #745: root every signature of a roots file (from roots.jl) with
# `Base.Experimental.entrypoint`, while a juliac image is built. Included by an entry file AFTER
# the app it roots is loaded, so the app's types resolve. The counts go to `Core.stdout`, which
# lands in the build log.
#
# A signature is evaluated in a module that binds every loaded package by name, since the trace
# names types by their package path (`HTTP.Request`, `Nitro.Core.…`) and the app's `Main` does not
# import all of them. Counted, not rooted:
#   - unresolved: evaluating the line threw (a name the build process cannot see);
#   - nonconcrete: the value is not a dispatch tuple (an abstract argument, a `Vararg`);
#   - refused: `entrypoint` threw.

module RootsEnv end

function load_roots(file::AbstractString)
    for m in values(Base.loaded_modules)
        name = nameof(m)
        isdefined(RootsEnv, name) || Core.eval(RootsEnv, :(const $name = $m))
    end
    rooted = unresolved = nonconcrete = refused = 0
    for line in eachline(file)
        isempty(line) && continue
        T = try
            Core.eval(RootsEnv, Meta.parse(line))
        catch
            unresolved += 1
            continue
        end
        if !(T isa Type && Base.isdispatchtuple(T))
            nonconcrete += 1
            continue
        end
        try
            Base.Experimental.entrypoint(T)
            rooted += 1
        catch
            refused += 1
        end
    end
    println(Core.stdout, "roots_loader: rooted=", rooted, " unresolved=", unresolved,
            " nonconcrete=", nonconcrete, " refused=", refused, " (", file, ")")
    return nothing
end
