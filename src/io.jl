using Dates
using StringEncodings

"""
    readle(io, T)

Read and return a value of type T read from `io` in little-endian format.
"""
readle(io::IO, ::Type{T}) where T = ltoh(read(io, T))

"""
    bytearray(i)

Reinterpret a value `i` as an appropriately sized array of bytes.

See: https://stackoverflow.com/a/70782597/5075720
"""
bytearray(a::AbstractArray) = reinterpret(UInt8, a)
bytearray(i::T) where T = reinterpret(UInt8, [i])

"""
    bytesle2int(a, T)

Reinterpret an array of little-endian bytes `a` as an integer of type T.
"""
bytesle2int(a::AbstractArray{UInt8}, ::Type{T}) where T<:Integer = first(reinterpret(T, ltoh(a)))

"""
    readstring(io, [nb; encoding="IBM437"])

Try to read bytes from `io` into a `String`.

If `nb` is provided, only the first `nb` bytes from the stream will be read (or until
EOF is detected). Otherwise, all the remaining data will be read.

Returns a tuple of the parsed `String` and the number of bytes read.

The `encoding` parameter will enforce that particular encoding for the data. The
returned `String` object will always be a proper UTF-8 string.
"""
function readstring(io::IO, nb::Integer; encoding::Union{String, Encoding}=enc"IBM437")
    arr = Array{UInt8}(undef, nb)
    bytes_read = readbytes!(io, arr, nb)
    s = decode(arr, encoding)
    return (s, bytes_read)
end

function readstring(io::IO; encoding::Union{String, Encoding}=enc"IBM437")
    s = read(io, String, encoding)
    bytes_read = sizeof(s)
    return (s, bytes_read)
end

# For MS-DOS time/date format, see:
# http://msdn.microsoft.com/en-us/library/ms724247(v=VS.85).aspx

# Convert seconds since epoch to MS-DOS time/date, which has
# a resolution of 2 seconds.
"""
    msdos2datetime(dosdate, dostime)
    datetime2msdos(datetime)

Convert MS-DOS packed date and time values to a `DateTime` object and back.

MS-DOS date and time formats are documented at
https://docs.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-dosdatetimetofiletime.
The general format is as follows:

* Date:
| Bits | Description |
|:-----|:------------|
| 0-4 | Day of the month (0x00 = 1st, 0x01 = 2nd, ..., 0x1F = 31st) |
| 5-8 | Month (0x1 = January, 0x2 = February, ..., 0xC = December) |
| 9-15 | Year from 1980 (0x00 = 1980, 0x01 = 1981, ..., 0x7F = 2107) |

* Time:
| Bits | Description |
|:-----|:------------|
| 0-4 | Second divided by 2 (0x00 = :00, 0x01 = :01, ..., 0x1d = :59) |
| 5-10 | Minute (0x00 = :00:, 0x01 = :01:, ..., 0x3b = :59:) |
| 11-15 | Hour (0x00 = 00:, 0x01 = 01:, ..., 0x17 = 23:) |
"""
function msdos2datetime(dosdate::UInt16, dostime::UInt16)
    day = (dosdate & 0x1f) + 1
    month = (dosdate >> 5) & 0xf
    year = (dosdate >> 9) + 1980

    second = (dostime & 0x1f) * 2
    minute = (dostime >> 5) & 0x3f
    hour = (dostime >> 11)

    return DateTime(year, month, day, hour, minute, second)
end

@doc (@doc msdos2datetime)
function datetime2msdos(datetime::DateTime)
    dosdate = UInt16(day(datetime) - 1) | (UInt16(month(datetime)) << 5) | ((UInt16(year(datetime) - 1980) & 0x7f) << 9)
    dostime = UInt16(second(datetime) ÷ 2) | (UInt16(minute(datetime)) << 5) | (UInt16(hour(datetime)) << 11)
    return dosdate, dostime
end
