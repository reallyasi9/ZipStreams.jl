import Base: bytesavailable, close, eof, isopen, isreadable, iswritable, unsafe_read, read

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
Base.isreadable(s::CRC32InputStream) = isreadable(s.source)
Base.iswritable(s::CRC32InputStream) = false

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
    CRC32OutputStream

A wrapper around an IO object that that calculates a CRC-32 checksum for data
written.
"""
mutable struct CRC32OutputStream{T} <: IO
    sink::T
    crc32::UInt32
end

function CRC32OutputStream(sink::T) where {T}
    return CRC32OutputStream{T}(sink, CRC32_INIT)
end

Base.close(s::CRC32OutputStream) = close(s.ssinkurce)
Base.eof(s::CRC32OutputStream) = eof(s.sink)
Base.isopen(s::CRC32OutputStream) = isopen(s.sink)
Base.isreadable(s::CRC32OutputStream) = false
Base.iswritable(s::CRC32OutputStream) = iswritable(s.sink)

function Base.unsafe_write(s::CRC32OutputStream, p::Ptr{UInt8}, nb::UInt)
    n = unsafe_write(s.sink, p, nb)
    s.crc32 = crc32(p, n, s.crc32)
    return n
end

function Base.write(s::CRC32OutputStream, x)
    nb = write(s.sink, x)
    s.crc32 = crc32([x], s.crc32)
    return nb
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

function Base.read(s::TruncatedInputStream, ::Type{T}) where {T <: Integer}
    sz = sizeof(T)
    if eof(s) || sz > s.bytes_remaining
        throw(EOFError())
    end
    s.bytes_remaining -= sz
    return read(s.source, T)
end

function Base.read(s::TruncatedInputStream, ::Type{UInt8})
    if eof(s)
        throw(EOFError())
    end
    s.bytes_remaining -= 1
    return read(s.source, UInt8)
end
