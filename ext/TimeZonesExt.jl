module TimeZonesExt

import TimeZones: ZonedDateTime, ISOZonedDateTimeFormat
import Nitro.Core.Types: Nullable
import Nitro.Core.Util: parseparam

export parseparam

####################################
# Util parsing overloads           #
####################################

# No percent-decoding here: the `Types.*` accessors decode exactly once at the boundary, so
# `parseparam` is pure type conversion across the whole family, extensions included (#70).
function parseparam(::Type{T}, str::String) where {T <: ZonedDateTime}
    return parse(T, str)
end

end