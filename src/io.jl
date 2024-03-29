using Dates
using StringEncodings
using Printf

"""
    readle(io, T)

Read and return a value of type T read from `io` in little-endian format.
"""
readle(io::IO, ::Type{T}) where {T} = ltoh(read(io, T))

"""
    writele(io, ...)

Write a value to `io` in little-endian format. Return the number of bytes written.
"""
writele(io::IO, value::T) where {T} = write(io, htol(value))

"""
    bytearray(i)

Reinterpret a value `i` as an appropriately sized array of bytes.

See: https://stackoverflow.com/a/70782597/5075720
"""
bytearray(a::AbstractArray) = reinterpret(UInt8, a)
bytearray(i::T) where {T} = reinterpret(UInt8, [i])

"""
    bytesle2int(a, T)

Reinterpret an array of little-endian bytes `a` as an integer of type T.
"""
bytesle2int(::Type{T}, a::AbstractArray{UInt8}) where {T<:Integer} =
    first(reinterpret(T, ltoh(a)))
unsafe_bytesle2int(::Type{T}, ptr::Ptr{UInt8}, nb::UInt=sizeof(T)) where {T<:Integer} = 
    bytesle2int(T, unsafe_wrap(Vector{UInt8}, ptr, nb; own=false))

"""
    readstring(io, [nb; encoding="IBM437"])

Try to read bytes from `io` into a `String`.

If `nb` is provided, only the first `nb` bytes from the stream will be read (or until
EOF is detected). Otherwise, all the remaining data will be read.

Returns a tuple of the parsed `String` and the number of bytes read.

The `encoding` parameter will enforce that particular encoding for the data. The
returned `String` object will always be a proper UTF-8 string.
"""
function readstring(io::IO, nb::Integer; encoding::Union{String,Encoding} = enc"IBM437")
    arr = Array{UInt8}(undef, nb)
    bytes_read = readbytes!(io, arr, nb)
    s = decode(arr, encoding)
    return (s, bytes_read)
end

function readstring(io::IO; encoding::Union{String,Encoding} = enc"IBM437")
    s = read(io, String, encoding)
    bytes_read = sizeof(s)
    return (s, bytes_read)
end

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
| 0-4 | Day of the month (0x01 = 1st, 0x02 = 2nd, ..., 0x1F = 31th) |
| 5-8 | Month (0x1 = January, 0x2 = February, ..., 0xC = December) |
| 9-15 | Year from 1980 (0x00 = 1980, 0x01 = 1981, ..., 0x7F = 2107) |

Note that day and month equal to `0x00` is not defined. We choose to raise an
exception if these cases are encountered. Months greater than `0xC` will also
throw an exception.

* Time:
| Bits | Description |
|:-----|:------------|
| 0-4 | Second divided by 2 (0x00 = :00, 0x01 = :02, ..., 0x1d = :58) |
| 5-10 | Minute (0x00 = :00:, 0x01 = :01:, ..., 0x3b = :59:) |
| 11-15 | Hour (0x00 = 00:, 0x01 = 01:, ..., 0x17 = 23:) |

Note that the smallest unit of time is 2 seconds. `0x1e == 60` seconds and
`0x1f == 62` seconds are valid values, but there is no clear specification for how
they should be interpreted. There is likewise no specification for handling
minutes greater than `0x3b` or hours greater than `0x17`. We choose to raise an
exception.
"""
function msdos2datetime(dosdate::UInt16, dostime::UInt16)
    day = (dosdate & 0x1f)
    month = (dosdate >> 5) & 0xf
    year = (dosdate >> 9) + 1980

    second = (dostime & 0x1f) * 2
    minute = (dostime >> 5) & 0x3f
    hour = (dostime >> 11)

    return DateTime(year, month, day, hour, minute, second)
end
msdos2datetime(datetime::Tuple{UInt16, UInt16}) = msdos2datetime(datetime[1], datetime[2])

@doc (@doc msdos2datetime) function datetime2msdos(datetime::DateTime)
    # corner case: 24:00:00 of 12/31/2107 is interpreted by Julia to be in year 2108
    if year(datetime) > 2107
        throw(ArgumentError("Year: $(year(datetime)) out of range (1980:2107)"))
    end
    dosdate =
        UInt16(day(datetime)) |
        (UInt16(month(datetime)) << 5) |
        ((UInt16(year(datetime) - 1980) & 0x7f) << 9)
    dostime =
        UInt16(second(datetime) ÷ 2) |
        (UInt16(minute(datetime)) << 5) |
        (UInt16(hour(datetime)) << 11)
    return dosdate, dostime
end

const SIZE_PREFIXES = String["", "K", "M", "G", "T", "P", "E"]
const BINARY_SIZE_LIMITS = [0; 2 .^ (10:10:60)]
const DECIMAL_SIZE_LIMITS = [0; 10 .^ (3:3:18)]
"""
    human_readable_bytes(b, [denominator=0]; [decimal=false, prefix=nothing]) -> String

Convert the number of bytes `b` into a nicely formatted, human-readable string
using byte prefixes. If `denominator` is non-zero, the number will be formatted
as `"b/denominator"`, and `denominator` will be used to scale the prefix.

If `decimal` is `true`, decimal prefixes will be used
instead of binary prefixes; for example, 1 KB is 1,000 B in decimal, while
1 KiB = 1,024 = 2^10 in binary). If `prefix` is one of "K", "M", "G", "T", "P", "E",
or an empty string. that prefix will be used; if it is `nothing` (the default),
the prefix will be selected automatically based on the magnitude of `b`.
"""
function human_readable_bytes(b::Integer; decimal::Bool=false, prefix::Union{Nothing,String,Symbol}=nothing)
    scale, prefix_string = auto_prefix(b; decimal=decimal, prefix=prefix)
    if scale <= 1
        return "$b B"
    end
    return @sprintf("%0.1f %sB", b/scale, prefix_string)
end

function human_readable_bytes(b::Integer, denominator::Integer; decimal::Bool=false, prefix::Union{Nothing,String,Symbol}=nothing)
    scale, prefix_string = auto_prefix(denominator; decimal=decimal, prefix=prefix)
    if scale <= 1
        return "$b/$denominator B"
    end
    return @sprintf("%0.1f/%0.1f %sB", b/scale, denominator/scale, prefix_string)
end

function auto_prefix(b::Integer; decimal::Bool=false, prefix::Union{Nothing,String,Symbol}=nothing)
    if isnothing(prefix)
        indices = decimal ? DECIMAL_SIZE_LIMITS : BINARY_SIZE_LIMITS
        index = findlast(<=(abs(b)), indices)
        prefix_string = SIZE_PREFIXES[index]
    else
        prefix_string = string(prefix)
        index = findfirst(==(prefix_string), SIZE_PREFIXES)
        if isnothing(index)
            throw(ArgumentError("unknown prefix '$prefix_string': valid values are $SIZE_PREFIXES"))
        end
    end
    if index > 1 && !decimal
        prefix_string *= "i"
    end
    scale = decimal ? DECIMAL_SIZE_LIMITS[index] : BINARY_SIZE_LIMITS[index]
    return scale, prefix_string
end