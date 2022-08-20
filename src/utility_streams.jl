import Base: bytesavailable, close, eof, isopen, unsafe_read, read

using BufferedStreams

"""
    CRC32InputStream

A wrapper around an IO object that that calculates a CRC-32 checksum for data
read.
"""
mutable struct CRC32InputStream{T} <: IO
    source::T
    crc32::UInt32
end

function CRC32InputStream(source::T) where {T}
    return CRC32InputStream{T}(source, CRC32_INIT)
end

Base.bytesavailable(s::CRC32InputStream) = bytesavailable(s.source)
Base.close(s::CRC32InputStream) = close(s.source)
Base.eof(s::CRC32InputStream) = eof(s.source)
Base.isopen(s::CRC32InputStream) = isopen(s.source)

function Base.unsafe_read(s::CRC32InputStream, p::Ptr{UInt8}, nb::UInt)
    x = unsafe_read(s.source, p, nb)
    s.crc32 = crc32(p, nb, s.crc32)
    return x
end

function Base.read(s::CRC32InputStream, ::Type{UInt8})
    x = read(s.source, UInt8)
    s.crc32 = crc32([x], s.crc32)
    return x
end

"""
    TruncatedInputStream

A wrapper around an IO object that reads up to some fixed number of bytes.
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

function Base.read(s::TruncatedInputStream, ::Type{UInt8})
    if eof(s)
        throw(EOFError())
    end
    s.bytes_remaining -= 1
    return read(s.source, UInt8)
end

"""
    SentinelInputStream

A wrapper around an IO object that treats a sentinel as EOF. Consumes the sentinel.
"""
mutable struct SentinelInputStream{S} <: IO
    source::BufferedInputStream{S}
    sentinel::Vector{UInt8}
    eof::Bool
end

function SentinelInputStream(source::S, sentinel::Vector{UInt8}) where S
    buffer = BufferedInputStream(source)
    return SentinelInputStream{S}(buffer, copy(sentinel), false)
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

function Base.bytesavailable(s::SentinelInputStream)
    next = findfirst(s.sentinel, s.source.buffer)
    return bytesavailable(s.source) - (isnothing(next) ? 0 : first(next))
end
Base.close(s::SentinelInputStream) = close(s.source)
Base.eof(s::SentinelInputStream) = s.eof || eof(s.source)
Base.isopen(s::SentinelInputStream) = isopen(s.source)

# function Base.unsafe_read(s::SentinelInputStream, p::Ptr{UInt8}, nb::UInt)
#     if eof(s)
#         throw(EOFError())
#     end
#     # read one byte at a time, pausing if a sentinel match is found
#     j = one(UInt)
#     for i in 1:nb
#         byte = read(s.source, UInt8)
#         if eof(s.source)
#             s.eof = true
#             throw(EOFError())
#         end
#         if byte == s.sentinel[j]
#             if j == length(s.sentinel)
#                 # EOF, throw
#                 upanchor!(s.source)
#                 s.eof = true
#                 throw(EOFError())
#             else
#                 j += 1
#                 # continue to pause read
#                 if !isanchored(s.source)
#                     anchor!(s.source)
#                 end
#                 continue
#             end
#         else
#             if isanchored(s.source)
#                 chunk = takeanchored!(s.source)
#                 GC.@preserve chunk unsafe_copyto!(p + i - 1, pointer(chunk), length(chunk))
#             end
#             unsafe_store!(p, byte, i)
#             j = one(UInt)
#         end
#     end

#     return
# end

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
    else
        reset(s.source)
    end
    return byte
end