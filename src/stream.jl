using BufferedStreams

import Base: bytesavailable, close, eof, isopen, unsafe_read, read

const CRC32_INIT = 0x00000000

function crc32(data::Ptr{UInt8}, n::UInt, crc::UInt32=CRC32_INIT)
    return ccall((:crc32, "libz"), Culong, (Culong, Ptr{Cchar}, Cuint), crc, data, n) % UInt32
end

crc32(data::Vector{UInt8}, crc::UInt32=CRC32_INIT) = GC.@preserve data crc32(pointer(data), UInt(length(data)), crc)
crc32(s::String, crc::UInt32=CRC32_INIT) = crc32(Vector{UInt8}(s), crc)

"""
    CRC32InputStream

A wrapper around an IO object that that calculates a CRC-32 checksum for data
read.
"""
mutable struct CRC32InputStream{T} <: IO
    source::T
    bytes_read::UInt64
    crc32::UInt32
end

function CRC32InputStream(source::T) where {T}
    return CRC32InputStream{T}(source, 0, CRC32_INIT)
end

Base.bytesavailable(s::CRC32InputStream) = bytesavailable(s.source)
Base.close(s::CRC32InputStream) = close(s.source)
Base.eof(s::CRC32InputStream) = eof(s.source)
Base.isopen(s::CRC32InputStream) = isopen(s.source)

function Base.unsafe_read(s::CRC32InputStream, p::Ptr{UInt8}, nb::UInt)
    unsafe_read(s.source, p, nb)
    # NOTE: might overflow
    s.bytes_read += nb
    s.crc32 = crc32(p, nb, s.crc32)
    return
end

function Base.read(s::CRC32InputStream, ::Type{UInt8})
    x = read(s.source, UInt8)
    s.bytes_read += 1
    s.crc32 = crc32([x], s.crc32)
    return x
end

"""
    TruncatedInputStream

A wrapper around an IO object that emulates a fixed-size array without actually
filling and using a fixed-size array.
"""
mutable struct TruncatedInputStream{T} <: IO
    source::T
    max_bytes::UInt64
    bytes_remaining::UInt64
end

function TruncatedInputStream(source::T, nb::UInt64=typemax(UInt64)) where T
    return TruncatedInputStream{T}(source, nb, nb)
end
TruncatedInputStream(source::T, nb::Union{Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64}) where T = TruncatedInputStream(source, UInt64(nb))

Base.bytesavailable(s::TruncatedInputStream) = min(bytesavailable(s.source), s.bytes_remaining)
Base.close(s::TruncatedInputStream) = close(s.source)
Base.eof(s::TruncatedInputStream) = s.bytes_remaining == 0 || eof(s.source)
Base.isopen(s::TruncatedInputStream) = isopen(s.source)

function Base.unsafe_read(s::TruncatedInputStream, p::Ptr{UInt8}, nb::UInt)
    nread = min(nb, bytesavailable(s))
    unsafe_read(s.source, p, nread)
    if nread > s.bytes_remaining
        throw(BoundsError(s))
    end
    s.bytes_remaining -= nread
    return
end

function Base.read(s::TruncatedInputStream, ::Type{UInt8})
    if eof(s)
        throw(EOFError())
    end
    s.bytes_remaining -= 1
    return read(s.source, UInt8)
end

"""
    SentinelInputStream

A wrapper around an IO object that treats a sentinel as EOF.
"""
mutable struct SentinelInputStream{S} <: IO
    source::BufferedInputStream{S}
    sentinel::Vector{UInt8}
    eof::Bool
end

function SentinelInputStream(source::S, sentinel::Vector{UInt8}) where S
    buffer = BufferedInputStream(source)
    mark(buffer)
    eof = false
    if read(buffer, length(sentinel)) == sentinel
        eof = true
    end
    reset(buffer)
    return SentinelInputStream{S}(buffer, copy(sentinel), eof)
end

function SentinelInputStream(source::S, sentinel) where S
    buf = IOBuffer()
    write(buf, sentinel)
    return SentinelInputStream{S}(BufferedInputStream(source), take!(buf), false)
end

# slightly more efficient
function SentinelInputStream(source::S, sentinel::AbstractString) where S
    return SentinelInputStream{S}(BufferedInputStream(source), collect(codeunits(sentinel)), false)
end

Base.bytesavailable(s::SentinelInputStream) = bytesavailable(s.source)
Base.close(s::SentinelInputStream) = close(s.source)
Base.eof(s::SentinelInputStream) = s.eof || eof(s.source)
Base.isopen(s::SentinelInputStream) = isopen(s.source)

function Base.unsafe_read(s::SentinelInputStream, p::Ptr{UInt8}, nb::UInt)
    if eof(s)
        throw(EOFError())
    end
    # read one byte at a time, pausing if a sentinel match is found
    j = one(UInt)
    for i in 1:nb
        byte = read(s.source, UInt8)
        if eof(s.source)
            s.eof = true
            throw(EOFError())
        end
        if byte == s.sentinel[j]
            if j == length(s.sentinel)
                # EOF, seek backward and return
                upanchor!(s.source)
                skip(s.source, -length(s.sentinel))
                s.eof = true
                return
            else
                j += 1
                # continue to pause read
                if !isanchored(s.source)
                    anchor!(s.source)
                end
                continue
            end
        else
            if isanchored(s.source)
                # TODO: read anchored data
                chunk = takeanchored!(s.source)
                GC.@preserve chunk unsafe_copyto!(p + i - 1, pointer(chunk), length(chunk))
            end
            unsafe_store!(p, byte, i)
            j = 1
        end
    end

    return
end

function Base.read(s::SentinelInputStream, ::Type{UInt8})
    if eof(s)
        throw(EOFError())
    end
    # Invariant: the first byte is free and not a part of the sentinel

    byte = read(s.source, UInt8)

    # Check if the remaining is the sentinel
    mark(s.source)
    if read(s.source, length(s.sentinel)) == s.sentinel
        s.eof = true
    end
    reset(s.source)
    return byte
end

"""
    ZipStream

A read-only lazy streamable representation of a Zip archive.

Zip archive files are optimized for reading from the beginning of the archive
_and_ appending to the end of the archive. Because information about what files
are stored in the archive are recorded at the end of the file, a Zip archive
technically cannot be validated unless the entire file is present, making
reading a Zip archive sequentially from a stream of data technically not
standards-compliant. However, one can build the Central Directory information
while streaming the data and check validity later (if ever) for faster reading
and processing of a Zip archive.

ZipStream objects are IOStream objects, allowing you to read data from the
archive byte-by-byte. Because this is usually not useful, ZipStream objects
can also be iterated to produce IO-like ZipFile objects (in archive order)
and can be addressed with Filesystem-like methods to access particular files.

# Examples
"""
mutable struct ZipStream
end