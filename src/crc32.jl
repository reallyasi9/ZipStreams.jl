import Base: close, flush, isopen, unsafe_write, isreadable, iswritable

using TranscodingStreams

const CRC32_INIT = 0x00000000

function crc32(data::Ptr{UInt8}, n::UInt, crc::UInt32=CRC32_INIT)
    return ccall((:crc32, "libz"), Culong, (Culong, Ptr{Cchar}, Cuint), crc, data, n) % UInt32
end

crc32(data::Ptr{UInt8}, n::Int, crc::UInt32=CRC32_INIT) = crc32(data, reinterpret(UInt, n), crc)
crc32(data::Vector{UInt8}, crc::UInt32=CRC32_INIT) = GC.@preserve data crc32(pointer(data), UInt(length(data)), crc)
crc32(data::Vector, crc::UInt32=CRC32_INIT) = GC.@preserve data crc32(pointer(reinterpret(UInt8, data)), UInt(sizeof(data)), crc)
crc32(s::String, crc::UInt32=CRC32_INIT) = crc32(Vector{UInt8}(s), crc)

mutable struct CRC32Sink <: IO
    crc32::UInt32
    sink::TranscodingStream
end

function Base.unsafe_write(s::CRC32Sink, p::Ptr{UInt8}, n::UInt)
    s.crc32 = crc32(p, n, s.crc32)
    return unsafe_write(s.sink, p, n)
end

Base.write(s::CRC32Sink, t::TranscodingStreams.EndToken) = write(s.sink, t)

Base.close(s::CRC32Sink) = close(s.sink)
Base.flush(s::CRC32Sink) = flush(s.sink)
Base.isopen(s::CRC32Sink) = isopen(s.sink)
Base.isreadable(s::CRC32Sink) = false
Base.iswritable(s::CRC32Sink) = iswritable(s.sink)