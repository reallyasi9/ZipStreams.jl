using Dates
using StringEncodings

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
bytesle2int(a::AbstractArray{UInt8}, ::Type{T}) where {T<:Integer} =
    first(reinterpret(T, ltoh(a)))

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

"""
    seek_backward_to(io, signature)

Seek an IO stream backward until `signature` is found.

Actually jumps backward 4k at a time, then searches forward for the last matching
signature in the chunk. This repeats until `signature` is found or until the
algorithm attempts to seek backward when `position(io) == 0`.

On success, the stream's position is set to the starting byte of the last found
signature in the stream.

Seeks to `seekend(io)` if the signature is not found.
"""
function seek_backward_to(io::IO, signature::Union{UInt8,AbstractVector{UInt8}})
    # TODO: This number was pulled out of a hat. Should probably be tuned.
    nbytes = max(4096, 10 * length(signature))
    # Initialize in a way to avoid accidental matches in dirty memory.
    cache = (all(==(0), signature)) ? ones(UInt8, nbytes) : zeros(UInt8, nbytes)
    skip(io, -nbytes)
    # Move back some large number of bytes per jump, but make sure there is
    # enough overlap to find the signature if the last jump stradled the line.
    jump_distance = nbytes - sizeof(signature) + 1
    while true
        mark(io)
        here = position(io)
        last_time = here == 0
        read!(io, cache)
        pos = findlast(signature, cache)
        if !isnothing(pos)
            reset(io)
            skip(io, first(pos) - 1)
            break
        end
        if last_time
            unmark(io)
            seekend(io)
            break
        end
        reset(io)
        # skipping to beyond the beginning of the IO causes problems!
        skip(io, -min(jump_distance, here))
    end
    return
end
