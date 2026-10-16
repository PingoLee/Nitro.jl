# Write the multipart body `stall.sh`'s `route:/hold/multipart@<file>` variant sends (#588): the
# shape `suite/holds.jl` parses -- one text field, one file part of random bytes -- at a total of
# BYTES (default 64 MiB, the whole of the default `max_body_bytes`). Prints the Content-Type to
# pass as ROUTE_CT.
#
#   julia bench/socket/multipart_body.jl bench/results/multipart-64mib.bin [bytes]
const BOUNDARY = "----NitroBenchBoundary7MA4YWxkTrZu0gW"
path = ARGS[1]
total = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 64 * 1024 * 1024
head = string("--", BOUNDARY, "\r\n",
              "Content-Disposition: form-data; name=\"note\"\r\n\r\nhello\r\n",
              "--", BOUNDARY, "\r\n",
              "Content-Disposition: form-data; name=\"upload\"; filename=\"data.bin\"\r\n",
              "Content-Type: application/octet-stream\r\n\r\n")
tail = string("\r\n--", BOUNDARY, "--\r\n")
open(path, "w") do io
    write(io, head, rand(UInt8, total - sizeof(head) - sizeof(tail)), tail)
end
filesize(path) == total || error("wrote $(filesize(path)) bytes, expected $total")
println("multipart/form-data; boundary=", BOUNDARY)
