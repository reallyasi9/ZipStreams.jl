import Base: bytesavailable, close, eof, flush, isopen, isreadable, iswritable, unsafe_read, read

"""
    TruncatedInputStream(io, bytes)

A wrapper around an `IO` object that reads up to some fixed number of bytes.
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

function Base.unsafe_read(s::TruncatedInputStream, p::Ptr{UInt8}, n::UInt)
    if eof(s) || n > s.bytes_remaining
        throw(EOFError())
    end
    # nb = min(s.bytes_remaining, n)
    unsafe_read(s.source, p, n)
    s.bytes_remaining -= n
    return n
end