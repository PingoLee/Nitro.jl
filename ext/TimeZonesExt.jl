module TimeZonesExt

import HTTP
import TimeZones: ZonedDateTime, ISOZonedDateTimeFormat
import Nitro.Core.Types: Nullable
import Nitro.Core.Util: parseparam

export parseparam

####################################
# Util parsing overloads           #
####################################

function parseparam(::Type{T}, str::String; escape=true) where {T <: ZonedDateTime}
    return parse(T, escape ? HTTP.unescapeuri(str) : str)
end

end